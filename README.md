# GS Viewer

Godot 4.7 製の 3D Gaussian Splatting ビューアー。デスクトップと **Meta Quest 3 (単体動作)** に対応。

A 3D Gaussian Splatting viewer for desktop and standalone Meta Quest 3, built with Godot 4.7.

- レンダリング: [godot-gaussian-splatting (gdgs)](https://github.com/ReconWorldLab/godot-gaussian-splatting) (MIT, `addons/` に同梱)
- Quest対応: [Godot OpenXR Vendors](https://github.com/GodotVR/godot_openxr_vendors) (同梱)
- 対応形式: `.ply` / `.compressed.ply` / `.splat` / `.sog`

## 操作

**デスクトップ** (`main.tscn`): 左ドラッグ=回転 / 右ドラッグ=パン / ホイール=ズーム / ファイルをドラッグ&ドロップで読込 / `O`=ファイル選択 / `N`/`P`=サンプル切替 / `R`=リセット

**Quest 3** (`main_xr.tscn`, Androidで自動選択): グリップ/トリガー=掴んで移動・回転(両手で拡縮) / 左スティック=移動 / 右スティック=スナップ回転・上下 / 右A=リセット / 右B・左X=シーン切替

Questへのファイル追加: USBで `Android/data/<パッケージ名>/files/splats/` に置いて再起動。

## 使い方

1. Godot 4.7.x でプロジェクトを開く
2. `.ply` を `samples/` に置く(リポジトリには含まれません)か、実行後にドラッグ&ドロップ
3. `main.tscn` を実行

**Quest向けビルド**: JDK 17 + Android SDK を設定し、同梱の「Android Quest」プリセットでエクスポート(gradleビルド使用のため、事前に Project > Install Android Build Template が必要)。

**目安**: Quest 3 単体では50万〜100万スプラット程度。学習時に `--max-cap` で数を絞ったモデルの方が、間引いたモデルより同じ数で圧倒的に綺麗です。

## gdgs への局所パッチ (v3.3.0)

- `gaussian_backend_selector.gd`: バックエンド自動判定を `RenderingServer.get_current_rendering_method()` 基準に修正(モバイル用オーバーライドが無視され、QuestでCompute(非対応)が選ばれて真っ黒になるバグの修正)
- `raster_render_backend.gd`: 再ソート閾値を1°→5°に緩和(Questで頭を振った時のカクつき対策)

## Credits

このプロジェクトは以下のOSSの上に成り立っています:

- **[godot-gaussian-splatting (gdgs)](https://github.com/ReconWorldLab/godot-gaussian-splatting)** by ReconWorldLab — Gaussian Splattingのレンダリング本体。MIT License ([addons/gdgs/LICENSE](addons/gdgs/LICENSE))
- **[Godot OpenXR Vendors](https://github.com/GodotVR/godot_openxr_vendors)** by Godot XR contributors — Meta Quest向けOpenXRローダー/ベンダー拡張。MIT License ([addons/godotopenxrvendors/](addons/godotopenxrvendors/))
- **[Godot Engine](https://godotengine.org/)** — MIT License

## License

`addons/` 内の各プラグインは上記の同梱ライセンスに従います。プロジェクト本体のコード(`main.gd` / `main_xr.gd` / シーン)のライセンスは未指定です。
