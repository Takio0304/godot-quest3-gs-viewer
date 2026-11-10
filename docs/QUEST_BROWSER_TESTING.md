# Quest scene browser and responsive loading

This contribution changes the Quest scene-selection flow while retaining the original grip, fly, reset, and snap-turn controls.

## Startup

- The user://splats directory is scanned for **filenames only**; model payloads are not decoded.
- The browser opens instead of automatically loading the first scene.
- The sorted list displays seven entries at a time and shows the selected file's size and Gaussian count when cheaply available from the PLY header or SPLAT file length.
- Bundled resource entries follow user-provided files.

## Controls

With the browser open, left X / right B move selection, right A loads, and left Y closes the browser.

With the browser closed, X/B cycle scenes, A resets the scene pivot, and Y opens the browser. Grip, two-hand scaling, fly movement, and snap-turn are unchanged.

## Loading pipeline

- Runtime PLY, compressed PLY, legacy SPLAT, and SOG files have their decode and Gaussian resource preparation performed on a worker Thread.
- Shared progress is guarded by a Mutex. Live scene-tree changes and resource activation happen on the main thread.
- The standard/compressed PLY and legacy SPLAT decoders plus Gaussian resource builder have optional progress callbacks, throttled every 8192 splats. Existing callers work unchanged.
- SOG shows coarse stage progress because its decoder does not expose per-splat progress. The progress bar is phase-weighted, NOT a time-remaining estimate.
- Bundled res:// resources use ResourceLoader.load_threaded_request.
- A selection made during a load is queued; the most recent request starts after the previous worker finishes. True mid-decode cancellation is NOT implemented.
- GPU resource activation runs on the main thread and might still produce a short hitch.

The menu and progress bar/label are head-relative to remain visible with controllers lowered; the compact status readout remains on the left controller.

## Validation on AI-Beast with Godot 4.7.2

- Editor import and XR script check-only: passed.
- Headless XR scene startup: passed, with expected no-OpenXR-runtime warning.
- tools/test_browser_smoke.gd: verifies no auto-load, menu navigation, file size and cheap point counts, and Y toggle.
- tools/test_loader_smoke.gd: verifies that main-loop frames continue during worker decode, count matches expected, and progress reaches activation.
- Android debug export: succeeded.

For optional external PLY/SPLAT test cases:

    godot --headless --path . --script res://tools/test_loader_smoke.gd -- /absolute/file.ply 199884 /absolute/file.splat 199884

## Quest hardware QA still required

1. Test full 200K/500K SH3 PLY and compact SPLAT.
2. Confirm progress visibility and frame responsiveness on headset.
3. Verify menu navigation, queued loads, switching and failure recovery.
4. Record memory consumption with 1M+ splats.
5. Test SOG and compressed PLY paths.
6. Measure GPU activation hitch and FPS.

The test APK has not been installed; the original Quest app and user assets remain unchanged.

Upstream discussion: https://github.com/Takio0304/godot-quest3-gs-viewer/issues/1
