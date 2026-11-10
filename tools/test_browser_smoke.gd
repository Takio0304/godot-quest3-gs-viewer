extends SceneTree
## Menu smoke test without XR headset or any attached Android device.
const Viewer = preload("res://main_xr.gd")
var _viewer: Node3D

func _initialize() -> void:
	call_deferred("_test")

func _test() -> void:
	_viewer = Viewer.new()
	root.add_child(_viewer)
	await process_frame
	if not _viewer._menu_visible:
		push_error("Browser did not open on startup")
		quit(2)
		return
	if _viewer._loading:
		push_error("Startup incorrectly loads a scene")
		quit(3)
		return
	var total: int = int(_viewer._files.size())
	print("PASS startup: browser visible, %d filenames, zero loads" % total)
	# Create temporary catalog-only files; never read full payloads here.
	var path_splat := OS.get_user_data_dir().path_join("gsv-browser-smoke.splat")
	var path_ply := OS.get_user_data_dir().path_join("gsv-browser-smoke.ply")
	var tiny := PackedByteArray()
	tiny.resize(5 * 32)
	var test_splat := FileAccess.open(path_splat, FileAccess.WRITE)
	test_splat.store_buffer(tiny)
	test_splat.close()
	var test_ply := FileAccess.open(path_ply, FileAccess.WRITE)
	test_ply.store_string("ply\nformat binary_little_endian 1.0\nelement vertex 17\nproperty float x\nend_header\n")
	test_ply.close()
	_viewer._files = PackedStringArray([path_splat, path_ply])
	_viewer._selected_index = 0
	_viewer._update_menu()
	if not _viewer._menu.text.contains("5 splats"):
		push_error("200k FAST count missing in scene browser: " + _viewer._menu.text)
		quit(4)
		return
	if not _viewer._menu.text.contains("MiB"):
		push_error("File sizes missing")
		quit(5)
		return
	_viewer._on_right_button("by_button")
	if _viewer._selected_index != 1:
		push_error("B did not move browser selection")
		quit(6)
		return
	_viewer._update_menu()
	if not _viewer._menu.text.contains("17 splats"):
		push_error("500K SH3 PLY count missing")
		quit(7)
		return
	_viewer._on_left_button("ax_button")
	if _viewer._selected_index != 0:
		push_error("X did not move backwards")
		quit(8)
		return
	_viewer._on_left_button("by_button")
	if _viewer._menu_visible:
		push_error("Y did not close the browser")
		quit(9)
		return
	print("PASS browser: filenames, size, splat counts, X/B navigation and Y toggle")
	_viewer.queue_free()
	await process_frame
	DirAccess.remove_absolute(path_splat)
	DirAccess.remove_absolute(path_ply)
	quit(0)
