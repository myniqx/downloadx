## 0.1.0

- Initial release.
- Chunked parallel downloads with dynamic splitting and resume support.
- HLS (m3u8) support: master/media playlist parsing, parallel segment download, optional ffmpeg concat via `concatSegments` hook.
- `DownloadOptions` supports `minChunkSize` and `journal` per-download overrides.
- Zero third-party dependencies.
