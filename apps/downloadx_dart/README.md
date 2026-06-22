# downloadx (Dart / Flutter)

An IDM-style download manager for Dart and Flutter — a faithful port of
[`@downloadx/core`](../downloadx).

It downloads files in parallel chunks with random-access disk writes, splits
slow chunks dynamically so fast connections never idle, survives process
restarts, and recovers from misbehaving servers — with **zero third-party
dependencies** (only the Dart SDK).

Unlike the TypeScript core, the Dart port ships a built-in `dart:io`
implementation ([`NativeIo`](lib/src/native_io.dart)) for both the file system
**and** the network, so a Flutter or Dart app gets working downloads with no
wiring. The I/O layer is still pluggable — pass your own [`DownloadxIo`] for
tests (an in-memory mock), web/IndexedDB, or a custom backend such as S3.

## Feature parity with the core

Everything the TypeScript core supports is supported here:

- **Chunked parallel downloads** — byte ranges download concurrently and write
  directly to their final offsets. No temp-file stitching.
- **Dynamic chunk splitting** — when a chunk finishes, the slowest/largest
  remaining chunk donates its tail to a fresh worker, bounded by
  `targetChunkCount`.
- **Resume across restarts** — an atomically-written `.downloadx.json` sidecar
  records the exact chunk layout; resume is validated with ETag →
  Last-Modified → size, and ranged requests carry `If-Range`.
- **Misbehaving-server recovery** — a ranged request answered with `200 OK`
  (server ignored `Range`) restarts once as a single full-body download.
- **Network idle timeout** — an attempt is aborted and retried only when no
  bytes arrive for `requestTimeout` ms. Long downloads run for hours as long
  as data flows.
- **Stall auto-recovery** — chunks stuck below ~15% of the median speed for
  ~15 s get their request reissued automatically.
- **Speed limiting** — token-bucket throttling per download plus an optional
  manager-wide cap shared by all downloads; both adjustable live.
- **Retries done right** — exponential backoff with full jitter, and a
  retryable vs. permanent HTTP status distinction.
- **Integrity** — optional disk pre-allocation and a final size verification
  before the part file is renamed into place.
- **HLS (m3u8) support** — master and media playlists are parsed and segments
  downloaded in parallel. A master playlist with multiple quality streams
  registers each as a separate idle download so the caller picks the one to
  start. Segment concatenation is handled by the optional `concatSegments` hook
  on `DownloadxIo` (ffmpeg recommended); without it a binary fallback produces
  a raw `.ts`.
- **Observability** — a synchronous typed event API, an NDJSON diagnostic
  journal sidecar, and `describe()` / `describeText()` reports.
- **Unknown sizes handled** — downloads with no `Content-Length` stream to EOF
  in a single chunk.

The meta sidecar (`schemaVersion`, field names, the `unknownSize` sentinel, the
URL→id hash) is byte-compatible with the TypeScript implementation, so a
download started by one can be resumed by the other.

## Quick start

```dart
import 'package:downloadx/downloadx.dart';

final manager = await createDownloadX(DownloadXConfig(
  targetPath: './downloads',
  maxParallel: 3,
  targetChunkCount: 4,
  journal: true,
));

final dl = await manager.addUrl('https://example.com/big.iso');

dl.emitter.onType<ProgressEvent>((p) {
  print('${p.percent?.toStringAsFixed(1)}% @ '
      '${(p.totalSpeed / 1e6).toStringAsFixed(2)} MB/s');
});

await dl.start();
```

## API

### `createDownloadX(config)`

Builds a `DownloadX` and rehydrates any persisted downloads found in
`cachePath`. Restored downloads stay in their last persisted state (no
autostart).

`DownloadXConfig` fields (all optional except `targetPath`):

| Field               | Default        | Description                                                       |
| ------------------- | -------------- | ----------------------------------------------------------------- |
| `io`                | `NativeIo()`   | Injected I/O. Defaults to a `dart:io` disk + `HttpClient` backend.|
| `targetPath`        | required       | Directory where finished files land.                              |
| `cachePath`         | `targetPath`   | Directory for in-flight meta/part files. Fixed at construction.   |
| `maxParallel`       | `3`            | Max concurrent active downloads.                                  |
| `targetChunkCount`  | `4`            | Upper bound on live chunks per download.                          |
| `minChunkSize`      | `1 MiB`        | Smaller ranges won't be split further.                            |
| `maxRetries`        | `5`            | Per-chunk HTTP retries.                                           |
| `retryDelay`        | `1000`         | Base backoff delay (ms).                                          |
| `retryBackoff`      | `2`            | Exponential backoff multiplier.                                   |
| `speedSampleWindow` | `3000`         | Moving-average window (ms) for quality.                           |
| `speedLimit`        | `0`            | Manager-wide bytes/sec cap shared by all downloads. `0` = off.    |
| `requestTimeout`    | `30000`        | Network **idle** timeout (ms).                                    |
| `headers`           | `{}`           | Default HTTP headers.                                             |
| `journal`           | `false`        | Write an NDJSON event journal next to the meta file.              |

### Manager (`DownloadX`)

- `addUrl(url, [options])` → `Future<Download>` — options include `filename`,
  `description`, `metadata`, `headers`, `targetPath`, `speedLimit`,
  `targetChunkCount`, `minChunkSize`, `journal`, `id`, `autoStart`
- `start([id])` / `pause([id])` / `clear([id])`
- `list()` / `getDownload(id)` / `describeAll()`
- `setMaxParallel(n)` / `setTargetPath(p)`
- `setSpeedLimit(int?)` — manager-wide cap shared by all downloads; `null` or
  `0` = unlimited
- `setTargetChunkCount(int?, {override})` / `setMinChunkSize(int?, {override})` /
  `setJournal(bool?, {override})` — `null` resets to the built-in default;
  `override: true` forces the value onto every download regardless of their
  current per-download setting
- `setHeaders(Map<String, String?>?)` — merge HTTP headers into the global
  config; `null` values in the map remove that key; pass `null` to clear all

### `Download`

- `start()` / `pause()` / `cancel()` / `clear()`
- `setSpeedLimit(int?)` / `setTargetPath(String?)` /
  `setTargetChunkCount(int?)` / `setMinChunkSize(int?)` / `setJournal(bool?)` —
  `null` clears the per-download override and reverts to the global value
- `setFilename(String?)` — override the final filename; `null` reverts to the
  probe/URL-derived name
- `setDescription(String?)` — attach a free-form note; `null` clears it
- `setMetadata(Map<String, String?>)` — merge key/value pairs; `null` values
  remove individual keys. Use `clearMetadata()` to remove all metadata.
- `setHeaders(Map<String, String?>)` — merge HTTP headers on top of global
  (`effective = {...global, ...local}`); `null` values remove individual keys.
  Use `clearHeaders()` to remove all local overrides. Only the local portion is
  persisted — global header changes are reflected automatically on the next request.
- `alloc()` — pre-allocate the part file (automatic at start when
  `io.truncate` is available)
- `describe()` / `describeText()`
- `emitter` — the typed event API

> **Part file location:** the in-progress `.part` file is written to
> `{cachePath}/{id}.part`. Changing the filename mid-download never loses
> the downloaded bytes. The file is moved to `{targetPath}/{filename}` only
> on successful completion.

### Events

Listen with `emitter.onType<T>(...)` for a specific event, or `emitter.on(...)`
for everything. All events are also relayed on the manager's `emitter`.

| Event                 | Notable fields                                                            |
| --------------------- | ------------------------------------------------------------------------- |
| `ProgressEvent`       | `totalBytes, downloadedBytes, totalSpeed, activeChunks, percent, etaMs, hlsSegmentsDone?, hlsTotalSegments?` |
| `ChunkProgressEvent`  | `chunkId, offset, length, downloadedBytes, instantSpeed, windowedSpeed`   |
| `ChunkQualityEvent`   | same shape as `ChunkProgressEvent`; `quality ∈ good/poor/stalled`         |
| `ChunkLifecycleEvent` | `chunkId, status`                                                         |
| `ChunkSplitEvent`     | `sourceChunkId, newChunkId, splitOffset, reason`                          |
| `StateChangeEvent`    | `previous, current`                                                       |
| `ErrorEvent`          | `chunkId?, error, fatal`                                                  |
| `CompletedEvent`      | `filename, totalBytes, durationMs`                                        |
| `DiagnosticEvent`     | `payload` (a `DiagnosticPayload`: level, code, message, timestamp, data?) |

### Custom I/O

Implement `DownloadxIo` to target a different backend (web, S3, a database, an
in-memory mock for tests). `writeChunk` must support random-access offset
writes **without truncating**. The optional `truncate` / `appendFile` /
`fileSize` / `concatSegments` getters each unlock a feature when non-null:
pre-allocation / journal / size verification / HLS concat.

#### `concatSegments` — HLS segment concatenation

When provided, this hook is called after all `.ts` segments are downloaded.
Without it the core falls back to a binary concat, producing a raw `.ts` file.

**ffmpeg example — remux to `.mp4` (no re-encode, fast):**

```dart
import 'dart:io';

class MyIo extends NativeIo {
  @override
  Future<void> Function(List<String> segments, String output)?
      get concatSegments => (segments, output) async {
        final listPath = '$output.ffconcat';
        final content = StringBuffer('ffconcat version 1.0\n');
        for (final s in segments) {
          content.writeln("file '$s'");
        }
        await File(listPath).writeAsString(content.toString());

        final result = await Process.run('ffmpeg', [
          '-f', 'concat', '-safe', '0', '-i', listPath,
          '-c', 'copy',        // remux only — no re-encode
          '-movflags', '+faststart',
          '-y', output,
        ]);
        await File(listPath).delete().catchError((_) => File(listPath));
        if (result.exitCode != 0) {
          throw Exception('ffmpeg exited ${result.exitCode}:\n${result.stderr}');
        }
      };
}
```

**ffmpeg example — transcode `.ts` segments to `.mp4` (H.264 + AAC):**

```dart
get concatSegments => (segments, output) async {
  final input = segments.join('|');
  final result = await Process.run('ffmpeg', [
    '-i', 'concat:$input',
    '-c:v', 'libx264', '-preset', 'fast', '-crf', '22',
    '-c:a', 'aac', '-b:a', '128k',
    '-y', output,
  ]);
  if (result.exitCode != 0) {
    throw Exception('ffmpeg exited ${result.exitCode}:\n${result.stderr}');
  }
};
```

> Without `concatSegments`, the core binary-concatenates the segments into a
> `.ts` file. This is valid for most streams but skips container conversion and
> metadata — use ffmpeg when you need `.mp4` / `.mkv` output or chapter marks.

## Development

```bash
dart pub get
dart analyze
dart test
```

Tests use an in-memory `DownloadxIo` and a programmable mock fetcher — no
network, no real filesystem.

## License

MIT
