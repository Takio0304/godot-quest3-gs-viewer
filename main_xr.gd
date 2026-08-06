extends Node3D
## Meta Quest (OpenXR) version of the gaussian splat viewer.
##
## - Grip (one hand): grab the scene to move / rotate it.
## - Grip (both hands): scale and turn the scene.
## - Right A: reset the scene transform.
## - Right B: next splat file / Left X: previous splat file.
## Extra files: copy .ply/.compressed.ply/.splat/.sog into
## Android/data/<package name>/files/splats via USB, then restart.

const SPLAT_NODE_SCRIPT := preload("res://addons/gdgs/runtime/nodes/gaussian_splat_node.gd")
const COMPOSITOR_EFFECT_SCRIPT := preload("res://addons/gdgs/runtime/compositor/gaussian_compositor_effect.gd")
const BinaryPlyReader := preload("res://addons/gdgs/importers/parsers/binary_ply_reader.gd")
const GaussianResourceBuilder := preload("res://addons/gdgs/importers/builders/gaussian_resource_builder.gd")
const StandardPlyDecoder := preload("res://addons/gdgs/importers/decoders/standard_ply_decoder.gd")
const CompressedPlyDecoder := preload("res://addons/gdgs/importers/decoders/compressed_ply_decoder.gd")
const SplatDecoder := preload("res://addons/gdgs/importers/decoders/splat_decoder.gd")
const SogDecoder := preload("res://addons/gdgs/importers/decoders/sog_decoder.gd")

const SAMPLE_CANDIDATES := [
	"res://samples/h2a_trained_clean.ply",
	"res://samples/h2a_trained_1m.ply",
	"res://samples/h2a_quest.ply",
	"res://samples/demo.compressed.ply",
	"res://samples/h2a_desktop.ply",
	"res://samples/h2a_full.ply",
]
const SPLAT_DIR := "user://splats"
const GRIP_THRESHOLD := 0.6
const INITIAL_PIVOT := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.3, -2.0))
const MOVE_SPEED := 2.5
const VERTICAL_SPEED := 1.5
const SNAP_TURN_DEG := 30.0

var _pivot: Node3D
var _splat_node: Node3D
var _status: Label3D
var _origin: XROrigin3D
var _camera: XRCamera3D
var _left: XRController3D
var _right: XRController3D
var _snap_ready := true

var _files: PackedStringArray = []
var _file_index := 0
var _current_name := "(none)"
var _point_count := 0
var _message := ""

var _held: Array = []
var _pivot_start := Transform3D.IDENTITY
var _single_inv := Transform3D.IDENTITY
var _dual_p1 := Vector3.ZERO
var _dual_p2 := Vector3.ZERO

func _ready() -> void:
	_setup_xr()
	_setup_environment()
	_setup_rig()
	_scan_files()
	_load_index(0)

func _setup_xr() -> void:
	var xr := XRServer.find_interface("OpenXR")
	if xr != null and xr.is_initialized():
		get_viewport().use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	else:
		_message = "OpenXR not initialized (flat preview)"

func _setup_environment() -> void:
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.06, 0.08)
	world_env.environment = env
	# The compositor effect is only used by the Compute backend (Forward+).
	if RenderingServer.get_current_rendering_method() == "forward_plus":
		var compositor := Compositor.new()
		compositor.compositor_effects = [COMPOSITOR_EFFECT_SCRIPT.new()]
		world_env.compositor = compositor
	add_child(world_env)

func _setup_rig() -> void:
	_origin = XROrigin3D.new()
	add_child(_origin)

	_camera = XRCamera3D.new()
	_origin.add_child(_camera)

	_left = _make_controller(_origin, "left_hand")
	_right = _make_controller(_origin, "right_hand")
	_left.button_pressed.connect(_on_left_button)
	_right.button_pressed.connect(_on_right_button)

	_status = Label3D.new()
	_status.pixel_size = 0.0004
	_status.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_status.no_depth_test = true
	_status.position = Vector3(0, 0.08, -0.05)
	_left.add_child(_status)

	_pivot = Node3D.new()
	_pivot.transform = INITIAL_PIVOT
	add_child(_pivot)

func _make_controller(origin: XROrigin3D, tracker: String) -> XRController3D:
	var controller := XRController3D.new()
	controller.tracker = tracker
	origin.add_child(controller)
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.02
	sphere.height = 0.04
	mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.7, 0.8, 1.0)
	mesh.material_override = mat
	controller.add_child(mesh)
	return controller

var _status_cooldown := 0.0

func _process(delta: float) -> void:
	# Label3D text changes rebuild the glyph mesh; throttle to 5 Hz.
	_status_cooldown -= delta
	if _status_cooldown > 0.0:
		return
	_status_cooldown = 0.2
	var text := "%s\n%s splats  |  %d fps\n%s" % [
		_current_name,
		_format_count(_point_count),
		int(Engine.get_frames_per_second()),
		_message,
	]
	if text != _status.text:
		_status.text = text

func _physics_process(delta: float) -> void:
	_apply_locomotion(delta)
	var held: Array = []
	for controller in [_left, _right]:
		if controller.get_float("grip") > GRIP_THRESHOLD or controller.get_float("trigger") > GRIP_THRESHOLD:
			held.append(controller)

	if held.size() != _held.size() or (held.size() > 0 and held != _held):
		_held = held
		_anchor_grab()
		return

	if _held.size() == 1:
		var controller: XRController3D = _held[0]
		_pivot.global_transform = controller.global_transform * _single_inv * _pivot_start
	elif _held.size() == 2:
		_apply_two_hand_grab()

func _apply_locomotion(delta: float) -> void:
	# Left stick: fly relative to gaze (XZ plane). Right stick: snap turn + up/down.
	var move := _left.get_vector2("primary")
	if move.length() > 0.15:
		var basis := _camera.global_transform.basis
		var forward := -basis.z
		forward.y = 0.0
		forward = forward.normalized()
		var right := basis.x
		right.y = 0.0
		right = right.normalized()
		_origin.global_position += (right * move.x + forward * move.y) * MOVE_SPEED * delta
	var turn := _right.get_vector2("primary")
	if absf(turn.x) > 0.7:
		if _snap_ready:
			_snap_ready = false
			var angle := -signf(turn.x) * deg_to_rad(SNAP_TURN_DEG)
			var cam_pos := _camera.global_position
			var rot := Basis(Vector3.UP, angle)
			var xform := Transform3D(rot, cam_pos - rot * cam_pos)
			_origin.global_transform = xform * _origin.global_transform
	else:
		_snap_ready = true
	if absf(turn.y) > 0.3:
		_origin.global_position.y += turn.y * VERTICAL_SPEED * delta

func _anchor_grab() -> void:
	_pivot_start = _pivot.global_transform
	if _held.size() == 1:
		var controller: XRController3D = _held[0]
		_single_inv = controller.global_transform.affine_inverse()
	elif _held.size() == 2:
		_dual_p1 = _left.global_position
		_dual_p2 = _right.global_position

func _apply_two_hand_grab() -> void:
	var p1 := _left.global_position
	var p2 := _right.global_position
	var mid0 := (_dual_p1 + _dual_p2) * 0.5
	var mid := (p1 + p2) * 0.5
	var v0 := _dual_p2 - _dual_p1
	var v := p2 - p1
	var scale := clampf(v.length() / maxf(v0.length(), 0.001), 0.02, 50.0)
	var flat0 := Vector2(v0.x, v0.z)
	var flat := Vector2(v.x, v.z)
	var dyaw := 0.0
	if flat0.length() > 0.01 and flat.length() > 0.01:
		dyaw = flat0.angle() - flat.angle()
	var rot := Basis(Vector3.UP, dyaw).scaled(Vector3.ONE * scale)
	var xform := Transform3D(Basis.IDENTITY, mid) * Transform3D(rot, Vector3.ZERO) * Transform3D(Basis.IDENTITY, -mid0)
	_pivot.global_transform = xform * _pivot_start

func _on_right_button(button: String) -> void:
	print("[viewer] right button: %s" % button)
	if button == "ax_button":
		_pivot.transform = INITIAL_PIVOT
	elif button == "by_button":
		_load_index(_file_index + 1)

func _on_left_button(button: String) -> void:
	print("[viewer] left button: %s" % button)
	if button == "ax_button":
		_load_index(_file_index - 1)

func _scan_files() -> void:
	_files = PackedStringArray()
	for candidate in SAMPLE_CANDIDATES:
		# The dense desktop/full samples are too heavy for standalone Quest.
		if OS.has_feature("mobile") and (candidate.ends_with("h2a_desktop.ply") or candidate.ends_with("h2a_full.ply")):
			continue
		if ResourceLoader.exists(candidate):
			_files.append(candidate)
	DirAccess.make_dir_recursive_absolute(SPLAT_DIR)
	var dir := DirAccess.open(SPLAT_DIR)
	if dir == null:
		return
	for file in dir.get_files():
		var lower := file.to_lower()
		if lower.ends_with(".ply") or lower.ends_with(".splat") or lower.ends_with(".sog"):
			_files.append(SPLAT_DIR.path_join(file))

func _load_index(index: int) -> void:
	if _files.is_empty():
		return
	_file_index = posmod(index, _files.size())
	var path := _files[_file_index]
	if path.begins_with("res://"):
		var res: Resource = load(path)
		if res != null:
			_show_gaussian(res, path.get_file())
		else:
			_message = "Failed to load %s" % path.get_file()
		return
	_message = "Loading %s ..." % path.get_file()
	var decode_result := _decode_source(path)
	if not decode_result.get("ok", false):
		_message = "Load failed: %s" % decode_result.get("message", "unknown error")
		return
	var build_result: Dictionary = GaussianResourceBuilder.build(decode_result["canonical"])
	if not build_result.get("ok", false):
		_message = "Build failed: %s" % build_result.get("message", "unknown error")
		return
	_show_gaussian(build_result["resource"], path.get_file())

func _decode_source(path: String) -> Dictionary:
	var lower := path.to_lower()
	if lower.ends_with(".splat"):
		return SplatDecoder.decode(path)
	if lower.ends_with(".sog"):
		return SogDecoder.decode(path)
	if lower.ends_with(".ply"):
		var header: Dictionary = BinaryPlyReader.read(path, false)
		if not header.get("ok", false):
			return header
		var chunk: Dictionary = BinaryPlyReader.get_element(header, "chunk")
		if lower.ends_with(".compressed.ply") or not chunk.is_empty():
			return CompressedPlyDecoder.decode(path)
		return StandardPlyDecoder.decode(path)
	return {
		"ok": false,
		"message": "Unsupported file type: %s" % path.get_extension(),
	}

func _show_gaussian(gaussian: Resource, display_name: String) -> void:
	if _splat_node != null:
		_splat_node.queue_free()
	_splat_node = SPLAT_NODE_SCRIPT.new()
	_splat_node.name = "GaussianSplat"
	_splat_node.set("gaussian", gaussian)
	_pivot.add_child(_splat_node)
	_current_name = "%s (%d/%d)" % [display_name, _file_index + 1, _files.size()]
	_point_count = int(gaussian.get("point_count"))
	_message = ""

func _format_count(count: int) -> String:
	if count >= 1_000_000:
		return "%.2fM" % (count / 1_000_000.0)
	if count >= 1_000:
		return "%.1fk" % (count / 1_000.0)
	return str(count)
