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
const MENU_VISIBLE_ROWS := 7
const BAR_WIDTH := 0.28

var _pivot: Node3D
var _splat_node: Node3D
var _status: Label3D
var _menu: Label3D
var _progress_label: Label3D
var _progress_background: MeshInstance3D
var _progress_fill: MeshInstance3D
var _origin: XROrigin3D
var _camera: XRCamera3D
var _left: XRController3D
var _right: XRController3D
var _snap_ready := true

var _files: PackedStringArray = []
var _file_index := 0
var _selected_index := 0
var _menu_visible := true
var _status_cooldown := 0.0
var _current_name := "(none)"
var _point_count := 0
var _message := ""

# Worker writes only phase + fraction protected by a Mutex. Scene-tree
# mutations and resource activation are always performed on the main thread.
var _loader_thread: Thread
var _loader_mutex := Mutex.new()
var _loader_phase := ""
var _loader_fraction := 0.0
var _loading := false
var _loading_path := ""
var _queued_index := -1
var _resource_loading := false

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
	_menu_visible = true
	_update_menu()
	_message = "Choose a scene. Initial scan reads names, not model contents."

func _exit_tree() -> void:
	if _loader_thread != null:
		_loader_thread.wait_to_finish()
		_loader_thread = null

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

	_menu = Label3D.new()
	_menu.pixel_size = 0.00055
	_menu.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_menu.no_depth_test = true
	_menu.position = Vector3(0, 0.11, -0.8)
	_camera.add_child(_menu)

	_progress_label = Label3D.new()
	_progress_label.pixel_size = 0.00055
	_progress_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_progress_label.no_depth_test = true
	_progress_label.position = Vector3(0, -0.20, -0.74)
	_camera.add_child(_progress_label)
	_progress_label.visible = false

	_progress_background = _make_bar(Color(0.13, 0.17, 0.22))
	_progress_fill = _make_bar(Color(0.18, 0.75, 0.86))
	_progress_background.position = Vector3(0, -0.25, -0.73)
	_progress_fill.position = Vector3(-BAR_WIDTH * 0.5, -0.25, -0.727)
	_camera.add_child(_progress_background)
	_camera.add_child(_progress_fill)
	_progress_background.visible = false
	_progress_fill.visible = false

	_pivot = Node3D.new()
	_pivot.transform = INITIAL_PIVOT
	add_child(_pivot)

func _make_bar(color: Color) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var shape := BoxMesh.new()
	shape.size = Vector3(BAR_WIDTH, 0.009, 0.003)
	mesh.mesh = shape
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.albedo_color = color
	mesh.material_override = mat
	return mesh

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

func _process(delta: float) -> void:
	_poll_loader()
	_status_cooldown -= delta
	if _status_cooldown > 0.0:
		return
	_status_cooldown = 0.2
	var info := ""
	if _loading:
		var snapshot := _progress_snapshot()
		info = "%s: %d%%" % [snapshot["phase"], roundi(snapshot["fraction"] * 100.0)]
		_update_progress_bar(snapshot["fraction"])
	else:
		_update_progress_bar(0.0)
	var text := "%s\n%s splats  |  %d fps\n%s\n%s" % [
		_current_name,
		_format_count(_point_count),
		int(Engine.get_frames_per_second()),
		info,
		_message,
	]
	if text != _status.text:
		_status.text = text

func _update_progress_bar(fraction: float) -> void:
	_progress_background.visible = _loading
	_progress_fill.visible = _loading
	_progress_label.visible = _loading
	if not _loading:
		return
	var snapshot := _progress_snapshot()
	_progress_label.text = "%s  |  %d%%" % [snapshot["phase"], roundi(fraction * 100.0)]
	var f := clampf(fraction, 0.0, 1.0)
	_progress_fill.scale.x = maxf(f, 0.001)
	_progress_fill.position.x = (f - 1.0) * BAR_WIDTH * 0.5

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
	if button == "ax_button":
		if _menu_visible:
			_load_index(_selected_index)
		else:
			_pivot.transform = INITIAL_PIVOT
	elif button == "by_button":
		if _menu_visible:
			_move_selection(1)
		else:
			_load_index(_file_index + 1)

func _on_left_button(button: String) -> void:
	if button == "by_button":
		_menu_visible = not _menu_visible
		_update_menu()
	elif button == "ax_button":
		if _menu_visible:
			_move_selection(-1)
		else:
			_load_index(_file_index - 1)

func _move_selection(step: int) -> void:
	if _files.is_empty():
		return
	_selected_index = posmod(_selected_index + step, _files.size())
	_update_menu()

func _scan_files() -> void:
	_files = PackedStringArray()
	var bundled := PackedStringArray()
	for candidate in SAMPLE_CANDIDATES:
		if OS.has_feature("mobile") and (candidate.ends_with("h2a_desktop.ply") or candidate.ends_with("h2a_full.ply")):
			continue
		if ResourceLoader.exists(candidate):
			bundled.append(candidate)
	DirAccess.make_dir_recursive_absolute(SPLAT_DIR)
	var dir := DirAccess.open(SPLAT_DIR)
	if dir != null:
		for filename in dir.get_files():
			var lower := filename.to_lower()
			if lower.ends_with(".ply") or lower.ends_with(".splat") or lower.ends_with(".sog"):
				_files.append(SPLAT_DIR.path_join(filename))
	_files.sort()
	bundled.sort()
	_files.append_array(bundled)
	_selected_index = 0
	_message = "Indexed %d filenames only; no model data loaded." % _files.size()

func _update_menu() -> void:
	_menu.visible = _menu_visible
	if not _menu_visible:
		return
	if _files.is_empty():
		_menu.text = "SCENE BROWSER\nNo files in user://splats"
		return
	var first := maxi(0, _selected_index - 3)
	first = mini(first, maxi(0, _files.size() - MENU_VISIBLE_ROWS))
	var lines := PackedStringArray(["SCENES (%d)" % _files.size(), "X / B: select   A: load   Y: close", "--------------------------"])
	for i in range(first, mini(first + MENU_VISIBLE_ROWS, _files.size())):
		var path := _files[i]
		var marker := "> " if i == _selected_index else "  "
		lines.append("%s%d. %s" % [marker, i + 1, path.get_file()])
	var selected_path := _files[_selected_index]
	lines.append("--------------------------")
	lines.append(_quick_metadata(selected_path))
	lines.append("Only selected scene contents are loaded.")
	if _loading:
		lines.append("Loading %s" % _loading_path.get_file())
	_menu.text = "\n".join(lines)

func _quick_metadata(path: String) -> String:
	if path.begins_with("res://"):
		return "Bundled resource; metadata on load"
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "Unable to read metadata"
	var bytes := file.get_length()
	var count := -1
	var lower := path.to_lower()
	if lower.ends_with(".splat") and bytes % 32 == 0:
		count = int(bytes / 32)
	elif lower.ends_with(".ply"):
		for _i in range(256):
			if file.eof_reached():
				break
			var line := file.get_line().strip_edges()
			if line.begins_with("element vertex "):
				count = int(line.get_slice(" ", 2))
				break
			if line == "end_header":
				break
	var info := "%.1f MiB" % (float(bytes) / 1048576.0)
	if count >= 0:
		info += " | %s splats" % _format_count(count)
	return info

func _load_index(index: int) -> void:
	if _files.is_empty():
		return
	var candidate := posmod(index, _files.size())
	if _loading:
		_queued_index = candidate
		_message = "Queued %s" % _files[candidate].get_file()
		return
	_file_index = candidate
	_selected_index = candidate
	_loading_path = _files[candidate]
	_loading = true
	_message = "Loading selected scene only"
	_menu_visible = false
	_update_menu()
	if _splat_node != null:
		_splat_node.queue_free()
		_splat_node = null
		_point_count = 0
	_set_progress("Opening selected file", 0.01)
	if _loading_path.begins_with("res://"):
		var err := ResourceLoader.load_threaded_request(_loading_path)
		if err != OK:
			_finish_with_error("Cannot schedule resource: %d" % err)
		else:
			_resource_loading = true
		return
	_loader_thread = Thread.new()
	var start_error := _loader_thread.start(_worker_load.bind(_loading_path))
	if start_error != OK:
		_loader_thread = null
		_finish_with_error("Thread start error: %d" % start_error)

func _worker_load(path: String) -> Dictionary:
	# File, array, and resource preparation only; no scene-tree changes.
	_set_progress("Reading / decoding selected file", 0.05)
	var decoded: Dictionary = _decode_source(path)
	if not decoded.get("ok", false):
		return {"ok": false, "message": decoded.get("message", "Decode error")}
	_set_progress("Building Gaussian resource", 0.60)
	var built: Dictionary = GaussianResourceBuilder.build(decoded["canonical"], Callable(self, "_on_build_progress"))
	if not built.get("ok", false):
		return {"ok": false, "message": built.get("message", "Build error")}
	_set_progress("Ready to activate", 0.98)
	return built

func _on_decode_progress(fraction: float) -> void:
	_set_progress("Decoding splats", 0.05 + clampf(fraction, 0.0, 1.0) * 0.53)

func _on_build_progress(fraction: float) -> void:
	_set_progress("Building Gaussian arrays", 0.60 + clampf(fraction, 0.0, 1.0) * 0.37)

func _set_progress(phase: String, fraction: float) -> void:
	_loader_mutex.lock()
	_loader_phase = phase
	_loader_fraction = clampf(fraction, 0.0, 1.0)
	_loader_mutex.unlock()

func _progress_snapshot() -> Dictionary:
	_loader_mutex.lock()
	var snapshot := {"phase": _loader_phase, "fraction": _loader_fraction}
	_loader_mutex.unlock()
	return snapshot

func _poll_loader() -> void:
	if not _loading:
		return
	if _resource_loading:
		var progress: Array = [0.0]
		var state := ResourceLoader.load_threaded_get_status(_loading_path, progress)
		if state == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			_set_progress("Loading bundled resource", float(progress[0]))
			return
		_resource_loading = false
		if state != ResourceLoader.THREAD_LOAD_LOADED:
			_finish_with_error("Bundled resource failed")
			return
		var res := ResourceLoader.load_threaded_get(_loading_path)
		_complete_load({"ok": res != null, "resource": res, "message": "Invalid resource"})
		return
	if _loader_thread != null and not _loader_thread.is_alive():
		var result: Dictionary = _loader_thread.wait_to_finish()
		_loader_thread = null
		_complete_load(result)

func _complete_load(result: Dictionary) -> void:
	_loading = false
	if _queued_index >= 0:
		var next_index := _queued_index
		_queued_index = -1
		_load_index(next_index)
		return
	if not result.get("ok", false):
		_finish_with_error(String(result.get("message", "Unknown error")))
		return
	var gaussian: Resource = result.get("resource")
	if gaussian == null:
		_finish_with_error("Missing Gaussian resource")
		return
	_show_gaussian(gaussian, _loading_path.get_file())
	_message = "Ready. Y: browser, A: reset, X/B: switch"

func _finish_with_error(message: String) -> void:
	_loading = false
	_resource_loading = false
	_message = "Load failed: %s" % message
	_menu_visible = true
	_update_menu()

func _decode_source(path: String) -> Dictionary:
	var lower := path.to_lower()
	if lower.ends_with(".splat"):
		return SplatDecoder.decode(path, Callable(self, "_on_decode_progress"))
	if lower.ends_with(".sog"):
		return SogDecoder.decode(path)
	if lower.ends_with(".ply"):
		var header: Dictionary = BinaryPlyReader.read(path, false)
		if not header.get("ok", false):
			return header
		var chunk: Dictionary = BinaryPlyReader.get_element(header, "chunk")
		if lower.ends_with(".compressed.ply") or not chunk.is_empty():
			return CompressedPlyDecoder.decode(path, Callable(self, "_on_decode_progress"))
		return StandardPlyDecoder.decode(path, Callable(self, "_on_decode_progress"))
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
