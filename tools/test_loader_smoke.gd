extends SceneTree
## Headless worker smoke test: checks that the worker finishes and the main
## frame loop continues while a real SH3 PLY or legacy .splat is decoded.
const Viewer := preload("res://main_xr.gd")
var _viewer: Node3D
var _worker: Thread

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_viewer = Viewer.new()
	var args := OS.get_cmdline_user_args()
	if args.size() < 2 or args.size() % 2 != 0:
		push_error("Usage: Godot --headless --path . --script res://tools/test_loader_smoke.gd -- /absolute/model.ply 199884 [/absolute/model.splat 199884 ...]")
		quit(2)
		return
	var files: Array = []
	for i in range(0, args.size(), 2):
		files.append([args[i], int(args[i + 1])])
	for entry in files:
		var path: String = entry[0]
		var expected: int = entry[1]
		if not FileAccess.file_exists(path):
			push_error("Missing fixture: " + path)
			quit(2)
			return
		_worker = Thread.new()
		var start := Time.get_ticks_msec()
		var launch := _worker.start(_viewer._worker_load.bind(path))
		if launch != OK:
			push_error("Cannot start thread: " + str(launch))
			quit(3)
			return
		var frames := 0
		while _worker.is_alive():
			await process_frame
			frames += 1
			if Time.get_ticks_msec() - start > 120000:
				push_error("Worker timeout for " + path)
				quit(4)
				return
		var result: Dictionary = _worker.wait_to_finish()
		_worker = null
		var duration := Time.get_ticks_msec() - start
		if not result.get("ok", false):
			push_error("Worker decode failed: " + str(result))
			quit(5)
			return
		var count := int(result["resource"].get("point_count"))
		if count != expected:
			push_error("Count mismatch: got %d expected %d" % [count, expected])
			quit(6)
			return
		var prog: Dictionary = _viewer._progress_snapshot()
		if float(prog["fraction"]) < 0.95:
			push_error("Unexpected progress: " + str(prog))
			quit(7)
			return
		print("PASS %s | %d splats | frames during decode %d | duration %dms" % [path.get_file(), count, frames, duration])
		if frames < 3:
			push_error("Not enough frames during background decode")
			quit(8)
			return
		result.clear()
		await process_frame
	print("PASS: all worker scenarios")
	_viewer.free()
	quit(0)
