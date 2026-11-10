extends SceneTree
## Verify cooperative cancellation, menu reappearance and time estimates.
const Viewer = preload("res://main_xr.gd")
var viewer: Node3D

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		push_error("Usage -- /absolute/500k.ply 499710")
		quit(2)
		return
	var path := String(args[0])
	var expected := int(args[1])
	viewer = Viewer.new()
	root.add_child(viewer)
	await process_frame
	viewer._files = PackedStringArray([path])
	viewer._selected_index = 0
	viewer._menu_visible = true
	viewer._update_menu()
	var before: String = viewer._load_time_display(path)
	if not before.contains("Rough:") and not before.contains("Previous") and not before.contains("Estimated:"):
		push_error("Missing load time estimate: " + before)
		quit(3)
		return
	viewer._load_index(0)
	if not viewer._loading or viewer._menu_visible:
		push_error("Load did not start correctly")
		quit(4)
		return
	var start := Time.get_ticks_msec()
	var frames := 0
	var reported_progress := 0.0
	while viewer._loading and Time.get_ticks_msec() - start < 30000:
		await process_frame
		frames += 1
		reported_progress = float(viewer._progress_snapshot()["fraction"])
		if reported_progress > 0.15:
			break
	if not viewer._loading:
		push_error("Test fixture finished before cancellation")
		quit(5)
		return
	var cancelled_at := Time.get_ticks_msec()
	viewer._on_left_button("by_button")
	if not viewer._is_cancel_requested() or not viewer._menu_visible:
		push_error("Y failed to cancel and show browser")
		quit(6)
		return
	while viewer._loading and Time.get_ticks_msec() - cancelled_at < 20000:
		await process_frame
		frames += 1
	if viewer._loading:
		push_error("Cancellation did not stop loader in reasonable time")
		quit(7)
		return
	if viewer._splat_node != null:
		push_error("Cancelled load unexpectedly activated scene")
		quit(8)
		return
	if not viewer._message.contains("cancelled"):
		push_error("Cancellation feedback missing: " + viewer._message)
		quit(9)
		return
	print("PASS cancellation | frames %d | progress at cancel %.3f | completed cancellation %dms" % [frames, reported_progress, Time.get_ticks_msec() - cancelled_at])
	# In-memory measured-duration test; no side effects to Quest and no fixture needs changing.
	var key: String = viewer._timing_key(path)
	viewer._timings.set_value("measured", key, 8.25)
	var measured: String = viewer._load_time_display(path)
	if not measured.contains("8.2s") and not measured.contains("8.3s"):
		push_error("Measured time display wrong: " + measured)
		quit(10)
		return
	print("PASS loading time estimate: " + measured)
	viewer.queue_free()
	await process_frame
	quit(0)
