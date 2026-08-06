# godot-quest3-gs-viewer

A 3D Gaussian Splatting viewer for **standalone Meta Quest 3** and desktop, built with Godot 4.7.

- Rendering: [godot-gaussian-splatting (gdgs)](https://github.com/ReconWorldLab/godot-gaussian-splatting) (MIT, bundled in `addons/`)
- Quest support: [Godot OpenXR Vendors](https://github.com/GodotVR/godot_openxr_vendors) (bundled)
- Supported formats: `.ply` / `.compressed.ply` / `.splat` / `.sog`

## Controls

**Desktop** (`main.tscn`): left drag = orbit / right drag = pan / wheel = zoom / drag & drop a file to load it / `O` = file dialog / `N`/`P` = switch sample / `R` = reset

**Quest 3** (`main_xr.tscn`, auto-selected on Android): grip or trigger = grab to move/rotate (both hands = scale) / left stick = move / right stick = snap turn & up/down / right A = reset / right B & left X = switch scene

To add files on Quest: copy them via USB into `Android/data/<package name>/files/splats/` and restart the app.

## Getting started

1. Open the project with Godot 4.7.x
2. Put a `.ply` into `samples/` (not included in this repo), or just drag & drop one at runtime
3. Run `main.tscn`

**Quest build**: set up JDK 17 + Android SDK in the editor settings, then export with the bundled "Android Quest" preset (run `Project > Install Android Build Template` first — the OpenXR vendors plugin requires Gradle builds).

**Rule of thumb**: standalone Quest 3 handles roughly 0.5–1M splats. A model *trained* with a splat cap (e.g. `--max-cap`) looks dramatically better than a large model subsampled down to the same count.

## Local patches to the gdgs addon (v3.3.0)

- `gaussian_backend_selector.gd`: backend auto-detection now uses `RenderingServer.get_current_rendering_method()`. The raw project setting ignores platform overrides like `rendering_method.mobile`, which made Quest builds silently pick the desktop-only Compute backend and render nothing. (Submitted upstream: [PR #27](https://github.com/ReconWorldLab/godot-gaussian-splatting/pull/27))
- `raster_render_backend.gd`: re-sort camera threshold relaxed from ~1° to ~5° to reduce hitching during head turns on mobile.

## Credits

This project is built on:

- **[godot-gaussian-splatting (gdgs)](https://github.com/ReconWorldLab/godot-gaussian-splatting)** by ReconWorldLab — the Gaussian Splatting renderer. MIT License ([addons/gdgs/LICENSE](addons/gdgs/LICENSE))
- **[Godot OpenXR Vendors](https://github.com/GodotVR/godot_openxr_vendors)** by the Godot XR contributors — OpenXR loader / vendor extensions for Meta Quest. MIT License ([addons/godotopenxrvendors/](addons/godotopenxrvendors/))
- **[Godot Engine](https://godotengine.org/)** — MIT License

## License

The project itself is [MIT licensed](LICENSE). Bundled plugins in `addons/` keep their own licenses listed above.
