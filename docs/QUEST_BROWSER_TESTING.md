# Quest scene browser and responsive loading

This contribution changes the Quest scene-selection flow while retaining the original grip, fly, reset, and snap-turn controls.

## Startup

- The user://splats directory is scanned for **filenames only**; model payloads are not decoded.
- The browser opens instead of automatically loading the first scene.
- A solid dark panel sits behind the menu. When the menu is open, the currently rendered splat is temporarily hidden and restored on closing, preventing compositor bleed-through.
- The sorted list displays seven entries at a time and shows the selected file's size and Gaussian count when cheaply available from the PLY header or SPLAT file length.
- Bundled resource entries follow user-provided files.

## Controls

With the browser open, **either thumbstick up/down** scrolls with held-repeat; left X / right B also move selection, right A loads, and left Y closes the browser. Navigation sticks do not move the VR scene while browsing.

With the browser closed, X/B cycle scenes, A resets the scene pivot, and Y opens the browser. Grip, two-hand scaling, fly movement, and snap-turn are unchanged.

## Loading pipeline

- Runtime PLY, compressed PLY, legacy SPLAT, and SOG files have their decode and Gaussian resource preparation performed on a worker Thread.
- Shared progress is guarded by a Mutex. Live scene-tree changes and resource activation happen on the main thread.
- The standard/compressed PLY and legacy SPLAT decoders plus Gaussian resource builder have optional progress callbacks, throttled every 8192 splats. Existing callers work unchanged.
- SOG shows coarse stage progress because its decoder does not expose per-splat progress. The progress bar is phase-weighted, NOT a time-remaining estimate.
- Bundled res:// resources use ResourceLoader.load_threaded_request.
- A selection made during a load is queued; the most recent request starts after the previous worker finishes.
- Pressing **Y while loading** opens the browser and requests **cooperative cancellation**. A mutex-protected flag is checked during decoder/builder loops at 8192-splat intervals, and at stage boundaries. The active thread must finish its current file read/chunk before it can stop. Cancelled results are discarded and the previous scene is NOT automatically reloaded.
- SOG decoding now also checks cancellation during its per-Gaussian loop. ZIP resources are closed when cancelled.
- The selected scene's previous successful load duration is stored in the application's user data, keyed by path/size/modification time. For untested scenes, the browser extrapolates from the closest previously measured file of the same format and size. With no same-format measurements it shows a broad, explicitly *uncalibrated* estimate; the estimate must not be treated as a promised ETA. Estimates mainly cover CPU parsing/building plus activation request, not delayed GPU upload or shader compilation.
- GPU resource activation runs on the main thread and might still produce a short hitch.

The menu and progress bar/label are head-relative to remain visible with controllers lowered; the compact status readout remains on the left controller.

## Validation on AI-Beast with Godot 4.7.2

- Editor import and XR script check-only: passed.
- Headless XR scene startup: passed, with expected no-OpenXR-runtime warning.
- tools/test_browser_smoke.gd: verifies no auto-load, buttons and held thumbstick scroll, file size and cheap point counts, Y toggle, opaque panel visibility, and suppression/restoration of rendered splat.
- tools/test_loader_smoke.gd: verifies that main-loop frames continue during worker decode, count matches expected, and progress reaches activation.
- tools/test_cancel_and_timing.gd: requests cancellation during 500K SH3 PLY decoding; checks that no cancelled scene is shown and that the measured time UI is correct.
- Android debug export: succeeded. Tested v2 APK installed with adb install -r on Quest 3; all eight existing scene files survived the update and the app launched without immediate script/crash logs. Actual VR readability/gesture QA of the revised panel, ETA, and cancel flow is still awaiting user testing.

For optional external PLY/SPLAT test cases:

    godot --headless --path . --script res://tools/test_loader_smoke.gd -- /absolute/file.ply 199884 /absolute/file.splat 199884

## Quest hardware QA still required

1. Test full 200K/500K SH3 PLY and compact SPLAT.
2. Confirm progress visibility and frame responsiveness on headset.
3. Verify thumbstick navigation, queued loads, cooperative Y cancellation, switching, and failure recovery.
4. Confirm first-load time ranges are understandable; test subsequent measured times and estimates for similarly sized models.
5. Record memory consumption with 1M+ splats.
6. Test SOG and compressed PLY paths.
7. Measure GPU activation hitch and FPS.
8. Future follow-up (not part of this PR): persistent per-scene pose (position, rotation and scale), with A resetting to the saved pose.

The v2 debug APK was installed as an in-place update without uninstalling and without deleting user assets. The previous test and original APKs are retained locally as rollback copies. This is not yet a complete Quest hardware regression test.

Upstream discussion: https://github.com/Takio0304/godot-quest3-gs-viewer/issues/1
