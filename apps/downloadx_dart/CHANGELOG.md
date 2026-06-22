## 0.3.0

- **HLS unified into the chunk pipeline.** Each HLS segment is now downloaded as
  an `isSegment` `Chunk` through the normal `driveChunks` path (parallelism
  capped at `targetChunkCount`), then concatenated. HLS downloads now get speed
  tracking, resume, retry, throttle and the full event system for free.
  - `HlsSession` reduced to playlist resolution + concat + cleanup
    (`resolve` / `registerStreams` / `concat` / `cleanup` / `segDir` / `segPath`).
  - Segment-based progress: percent and ETA derived from completed segments;
    `hlsSegmentsDone` / `hlsTotalSegments` reported on progress events and
    `describe()`.
  - Resume re-resolves the playlist each run and skips already-downloaded
    segment files.
- `DownloadOptions` gained `description` and `metadata` — persisted and returned
  from `describe()`, with no behavioural effect (for host apps to attach notes,
  source links, etc.).

## 0.2.0

- Expanded dartdoc coverage across the full public API (100% of exported symbols).
- Added enum value documentation for `ChunkMode`, `DownloadState`, `ChunkStatus`, `ChunkQuality`, `SplitReason`, and `DiagnosticLevel`.

## 0.1.0

- Initial release.
- Chunked parallel downloads with dynamic splitting and resume support.
- HLS (m3u8) support: master/media playlist parsing, parallel segment download, optional ffmpeg concat via `concatSegments` hook.
- `DownloadOptions` supports `minChunkSize` and `journal` per-download overrides.
- Zero third-party dependencies.
