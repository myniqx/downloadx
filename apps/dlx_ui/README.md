# dlx — graphical download manager

A cross-platform (Linux / Windows / Android) Flutter UI built on the
[`downloadx`](../downloadx_dart) engine — the graphical counterpart of what the
TypeScript CLI offers from the terminal.

It is wired to the engine as a **path dependency** (`downloadx: { path:
../downloadx_dart }`), so it always tracks the local engine.

## Features

- **Download list** with live rows: progress bar, %, size, speed, ETA, and
  active/total chunk counts — each row repaints independently.
- **Add dialog** with optional per-download config (filename, chunk mode,
  target chunk count, speed limit).
- **Global settings** (the GUI form of the CLI `set`): download folder, global
  speed limit, max parallel, target chunk count, min chunk size, max retries,
  idle timeout, journal. Persisted to a JSON file in the app support dir.
- **Detail / watch screen** — a graphical, upgraded `watch`:
  - **Segment bar** (`ChunkBlocks`): the file drawn as one track, each chunk a
    region scaled to its byte range, filled proportionally and tinted by health
    (good / poor / stalled, green when complete).
  - **Stacked speed chart** (`StackedSpeedChart`): each chunk's speed is a band
    stacked on the next, so the stack top is the download's total throughput;
    the Y axis auto-scales to the rolling peak and a dashed line marks the
    speed limit.
  - Chunk table and recent diagnostics.
- A **global stacked speed chart** on the home screen where each *download* is a
  band (total height = combined throughput, dashed line = manager-wide limit).

All charts are hand-drawn with `CustomPainter` — no charting dependency.

## Architecture

- `services/download_service.dart` — the single source of truth. Wraps the
  `DownloadX` manager, exposes `DownloadVm`s, and drives a steady UI cadence:
  structural changes notify the service (list rebuild), per-download data
  notifies the matching VM (tile/detail repaint), and a ~2.5 Hz tick advances
  the speed charts via a `ValueNotifier` + ring-buffer history.
- `models/download_vm.dart` — per-download `ChangeNotifier` caching the latest
  `DownloadDescription`, chunk snapshots, and a per-chunk speed history.
- State management is built-in `ChangeNotifier` / `ValueNotifier` — no extra
  packages. The only non-Flutter dependency is `path_provider` (writable dirs).

## Run

```bash
flutter pub get
flutter run -d linux      # or -d windows, or an Android device/emulator
```

> Android needs the `INTERNET` permission (already in the manifest). Downloads
> go to the app documents dir on Android and the OS Downloads dir on desktop;
> change the folder in Settings.

## Develop

```bash
flutter analyze
flutter test          # pure-Dart helper tests
flutter build linux   # verify the native build
```
