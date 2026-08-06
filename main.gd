extends Node3D
## Gaussian Splatting viewer built on the gdgs plugin.
##
## - Loads res://samples/demo.compressed.ply on startup.
## - Drag & drop a .ply / .compressed.ply / .splat / .sog file onto the
##   window (or press O) to view any splat file on disk.
## - Left drag: orbit / Right drag: pan / Wheel: zoom / R: reset camera.

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
	"res://samples/h2a_desktop.ply",
	"res://samples/h2a_quest_1m.ply",
	"res://samples/demo.compressed.ply",
]

const ORBIT_SPEED := 0.008
const PAN_SPEED := 0.0015
const ZOOM_FACTOR := 1.12
const MIN_DISTANCE := 0.3
const MAX_DISTANCE := 60.0

var _splat_node: Node3D
var _camera: Camera3D
var _status: Label
var _file_dialog: FileDialog

var _files: PackedStringArray = []
var _file_index := 0

var _target := Vector3.ZERO
var _yaw := 0.6
var _pitch := 0.25
var _distance := 4.0
var _point_count := 0
var _current_name := "(none)"
var _message := ""

func _ready() -> void:
	_setup_environment()
	_setup_camera()
	_setup_ui()
	get_viewport().files_dropped.connect(_on_files_dropped)
	for candidate in SAMPLE_CANDIDATES:
		if ResourceLoader.exists(candidate):
			_files.append(candidate)
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_load_external(args[0])
	elif not _files.is_empty():
		_load_index(0)
	else:
		_message = "No sample found. Drop a .ply file to view it."

func _load_index(index: int) -> void:
	if _files.is_empty():
		return
	_file_index = posmod(index, _files.size())
	var path := _files[_file_index]
	_message = "Loading %s ..." % path.get_file()
	await get_tree().process_frame
	var res: Resource = load(path)
	if res != null:
		_show_gaussian(res, "%s (%d/%d)" % [path.get_file(), _file_index + 1, _files.size()])
	else:
		_message = "Failed to load %s" % path.get_file()

func _setup_environment() -> void:
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.09, 0.11)
	world_env.environment = env
	var compositor := Compositor.new()
	compositor.compositor_effects = [COMPOSITOR_EFFECT_SCRIPT.new()]
	world_env.compositor = compositor
	add_child(world_env)

func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.near = 0.05
	_camera.far = 500.0
	add_child(_camera)
	_update_camera()

func _setup_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_status = Label.new()
	_status.position = Vector2(12, 10)
	_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	_status.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_status.add_theme_constant_override("shadow_offset_x", 1)
	_status.add_theme_constant_override("shadow_offset_y", 1)
	layer.add_child(_status)

	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.filters = PackedStringArray([
		"*.ply ; Gaussian Splat PLY",
		"*.splat ; Splat",
		"*.sog ; SOG",
	])
	_file_dialog.size = Vector2i(800, 500)
	_file_dialog.file_selected.connect(_load_external)
	layer.add_child(_file_dialog)

func _process(_delta: float) -> void:
	_status.text = "%s  |  %s splats  |  %d fps\n%s\nLeft drag: orbit   Right drag: pan   Wheel: zoom   R: reset   O: open file   N/P: switch sample" % [
		_current_name,
		_format_count(_point_count),
		int(Engine.get_frames_per_second()),
		_message,
	]

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var buttons: int = event.button_mask
		if buttons & MOUSE_BUTTON_MASK_LEFT:
			_yaw -= event.relative.x * ORBIT_SPEED
			_pitch = clampf(_pitch + event.relative.y * ORBIT_SPEED, -1.5, 1.5)
			_update_camera()
		elif buttons & MOUSE_BUTTON_MASK_RIGHT:
			var basis := _camera.global_transform.basis
			_target += (-basis.x * event.relative.x + basis.y * event.relative.y) * _distance * PAN_SPEED
			_update_camera()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = clampf(_distance / ZOOM_FACTOR, MIN_DISTANCE, MAX_DISTANCE)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = clampf(_distance * ZOOM_FACTOR, MIN_DISTANCE, MAX_DISTANCE)
			_update_camera()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			_reset_camera()
		elif event.keycode == KEY_O:
			_file_dialog.popup_centered()
		elif event.keycode == KEY_N:
			_load_index(_file_index + 1)
		elif event.keycode == KEY_P:
			_load_index(_file_index - 1)

func _update_camera() -> void:
	var offset := Vector3(
		cos(_pitch) * sin(_yaw),
		sin(_pitch),
		cos(_pitch) * cos(_yaw)
	) * _distance
	_camera.position = _target + offset
	_camera.look_at(_target, Vector3.UP)

func _reset_camera() -> void:
	_target = Vector3.ZERO
	_yaw = 0.6
	_pitch = 0.25
	_distance = 4.0
	_update_camera()

func _on_files_dropped(files: PackedStringArray) -> void:
	if files.size() > 0:
		_load_external(files[0])

func _load_external(path: String) -> void:
	if path.begins_with("res://"):
		var res: Resource = load(path)
		if res != null:
			_show_gaussian(res, path.get_file())
		else:
			_message = "Failed to load %s" % path.get_file()
		return
	_message = "Loading %s ..." % path.get_file()
	# Let the label repaint before the (blocking) decode starts.
	await get_tree().process_frame
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
	add_child(_splat_node)
	_current_name = display_name
	_point_count = int(gaussian.get("point_count"))
	_message = ""
	_reset_camera()
	print("[viewer] showing %s (%d splats)" % [display_name, _point_count])

func _format_count(count: int) -> String:
	if count >= 1_000_000:
		return "%.2fM" % (count / 1_000_000.0)
	if count >= 1_000:
		return "%.1fk" % (count / 1_000.0)
	return str(count)
