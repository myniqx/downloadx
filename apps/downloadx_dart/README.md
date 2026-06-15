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

- `addUrl(url, [options])` → `Future<Download>`
- `start([id])` / `pause([id])` / `clear([id])`
- `list()` / `getDownload(id)` / `describeAll()`
- `setMaxParallel(n)` / `setTargetPath(p)` / `setSpeedLimit(bytesPerSec)`
- `setTargetChunkCount(n, {override})` / `setMinChunkSize(bytes, {override})` /
  `setJournal(enabled, {override})`

### `Download`

- `start()` / `pause()` / `cancel()` / `clear()`
- `setSpeedLimit(int?)` / `setTargetPath(String?)` /
  `setTargetChunkCount(int?)` / `setMinChunkSize(int?)` / `setJournal(bool?)`
- `alloc()` — pre-allocate the part file (automatic at start when
  `io.truncate` is available)
- `describe()` / `describeText()`
- `emitter` — the typed event API

### Events

Listen with `emitter.onType<T>(...)` for a specific event, or `emitter.on(...)`
for everything. All events are also relayed on the manager's `emitter`.

| Event                 | Notable fields                                                            |
| --------------------- | ------------------------------------------------------------------------- |
| `ProgressEvent`       | `totalBytes, downloadedBytes, totalSpeed, activeChunks, percent, etaMs`   |
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
`fileSize` getters each unlock a feature (pre-allocation / journal / size
verification) when non-null.

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
