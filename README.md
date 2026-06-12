# downloadx

An IDM-style, runtime-agnostic download manager for TypeScript. Zero runtime
dependencies — `downloadx` only uses the I/O primitives you inject (fetch,
file system functions, path joiner), so it runs unchanged in Node, Bun, Deno,
or any edge environment where you can provide those primitives.

## Features

- Chunked parallel downloads with random-access disk writes (no temp-file
  reshuffling at the end).
- Automatic range-support detection (HEAD then ranged GET fallback).
- Dynamic chunk splitting — slow chunks donate their tail to new workers so
  the fast ones don't idle after the first one finishes.
- Resume across process restarts (`.downloadx.json` sidecar, atomic writes,
  ETag/Last-Modified validation).
- Token-bucket speed limiting with live capacity changes.
- Exponential-backoff retries with jitter, retryable vs. permanent HTTP
  status distinction.
- Strictly-typed `EventEmitter` exposing `progress`, `chunkProgress`,
  `chunkLifecycle`, `chunkSplit`, `chunkQuality`, `stateChange`, `error`,
  and `completed` events on both the `Download` and the `DownloadX` manager.

## Install

```bash
npm install downloadx
```

## Quick start (Node)

```ts
import { mkdir, rename, unlink, writeFile, readFile, stat, open } from 'node:fs/promises';
import { join } from 'node:path';
import { createDownloadX } from 'downloadx';

const manager = createDownloadX({
  io: {
    fetch: globalThis.fetch,
    mkdir: async (p) => { await mkdir(p, { recursive: true }); },
    exists: async (p) => { try { await stat(p); return true; } catch { return false; } },
    readFile: async (p) => new Uint8Array(await readFile(p)),
    writeFile: async (p, buf) => { await writeFile(p, buf); },
    writeChunk: async (p, offset, buf) => {
      const fh = await open(p, 'r+').catch(async () => open(p, 'w+'));
      try { await fh.write(buf, 0, buf.length, offset); } finally { await fh.close(); }
    },
    rename: async (from, to) => { await rename(from, to); },
    unlink: async (p) => { await unlink(p).catch(() => undefined); },
    joinPath: (...segs) => join(...segs),
  },
  targetPath: './downloads',
  maxParallel: 3,
  targetChunkCount: 4,
});

const dl = manager.addUrl('https://example.com/big.iso');
dl.emitter.on('progress', (p) => {
  console.log(`${p.percent?.toFixed(1)}% @ ${(p.totalSpeed / 1e6).toFixed(2)} MB/s`);
});
await dl.start();
```

## API

### `createDownloadX(config)`

Create a manager. Config fields:

| Field | Default | Description |
|-------|---------|-------------|
| `io` | required | Injected I/O primitives (see below). |
| `targetPath` | required | Directory where finished files land. |
| `cachePath` | `targetPath` | Directory for in-flight meta/part files. |
| `maxParallel` | `3` | Max concurrent active downloads. |
| `targetChunkCount` | `4` | Upper bound on chunks per download. |
| `minChunkSize` | `1 MiB` | Smaller ranges won't be split further. |
| `maxRetries` | `5` | Per-chunk HTTP retries. |
| `retryDelay` | `1000` | Base backoff delay (ms). |
| `retryBackoff` | `2` | Exponential backoff multiplier. |
| `speedSampleWindow` | `3000` | Moving-average window (ms) for quality. |
| `speedLimit` | `0` | Bytes/sec per download. `0` = unlimited. |
| `requestTimeout` | `30000` | Network **idle** timeout (ms): aborts and retries an attempt only when no bytes arrive for this long. Long downloads are unaffected while data flows. |
| `headers` | `{}` | Default HTTP headers. |
| `journal` | `false` | Write an NDJSON event journal (`{filename}.downloadx.log`) next to the meta file. Requires `io.appendFile`. |

### Manager methods

- `addUrl(url, options?)` → `Download`
- `start(id?)` / `pause(id?)` / `clear(id?)`
- `list()` / `get(id)`
- `describeAll()` — compact status reports for every download
- `setMaxParallel(n)` / `setTargetPath(p)` / `setCachePath(p)`
- `setSpeedLimit(bytesPerSec)` — manager-wide cap **shared by all downloads**
  (per-download `speedLimit` still applies on top); 0 = unlimited

### `Download` methods

- `start()` / `pause()` / `cancel()` / `clear()`
- `speedLimit(bytesPerSec)` — 0 disables the cap live
- `alloc()` — pre-allocate the part file to its final size (automatic at
  start when `io.truncate` is provided)
- `getChunkSnapshots()` — the exact state persisted to disk
- `describe()` — compact JSON status report (state, percent, speed, ETA,
  live chunk table, recent diagnostics); `describeText()` renders the same
  as a short plain-text block, safe to paste into a prompt or log
- `.emitter` — typed EventEmitter for this download

### Injected I/O

```ts
interface InjectedFunctions {
  fetch: (url, init?) => Promise<Response>;
  writeChunk: (path, offset, bytes) => Promise<void>;
  readFile: (path) => Promise<Uint8Array>;
  writeFile: (path, bytes) => Promise<void>;
  mkdir: (path) => Promise<void>;
  exists: (path) => Promise<boolean>;
  rename: (from, to) => Promise<void>;
  unlink: (path) => Promise<void>;
  joinPath: (...segments) => string;
  // Optional — enable extra features when provided:
  truncate?: (path, size) => Promise<void>;   // disk pre-allocation
  appendFile?: (path, bytes) => Promise<void>; // NDJSON journal
  fileSize?: (path) => Promise<number>;        // final size verification
}
```

The `fetch` must match WHATWG `fetch` shape (Request/Response with streaming
body and `AbortSignal`). Everything else maps directly to your chosen
storage backend — disk, S3, IndexedDB, or a database — as long as
`writeChunk` supports random-access offset writes.

### Events

All events are available on both `Download.emitter` and the parent
`DownloadX.emitter` (payloads are the same object reference — manager
listeners see exactly what the Download emitted).

| Event | Payload |
|-------|---------|
| `progress` | Aggregate: `{ downloadId, totalBytes, downloadedBytes, totalSpeed, activeChunks, percent }` |
| `chunkProgress` | Per-chunk: `{ downloadId, chunkId, offset, length, downloadedBytes, instantSpeed, windowedSpeed, quality }` |
| `chunkLifecycle` | `{ downloadId, chunkId, status }` — `pending`/`downloading`/`completed`/`failed`/`paused`/`reassigned` |
| `chunkSplit` | `{ downloadId, sourceChunkId, newChunkId, splitOffset, reason }` |
| `chunkQuality` | Same payload shape as `chunkProgress`; `quality ∈ 'good'\|'poor'\|'stalled'` |
| `stateChange` | `{ downloadId, previous, current }` |
| `error` | `{ downloadId, chunkId?, error, fatal }` |
| `completed` | `{ downloadId, filename, totalBytes, durationMs }` |
| `diagnostic` | `{ downloadId, chunkId?, level, code, message, timestamp, data? }` — retries, splits, timeouts, fallbacks; identical to the journal lines |

### Resume semantics

When a pause or crash leaves a `.downloadx.json` sidecar, the next `start()`
will:

1. Re-probe the URL.
2. Compare ETag → Last-Modified → size against the stored meta.
3. Resume from recorded chunk offsets if validators match; otherwise discard
   the old `.part` and start fresh.

Ranged requests also carry `If-Range` (ETag or Last-Modified), so a resource
that changes mid-download cannot be spliced into stale bytes — the server
answers `200`, which triggers a clean single-chunk restart.

### Robustness guarantees

- A ranged request answered with `200` (server ignored `Range`) is detected
  and the download restarts once as a single full-body request instead of
  corrupting the file.
- Servers without range support always restart interrupted chunks from byte
  zero — partial progress is discarded rather than misaligned.
- Chunk writes are clamped to the chunk's current range; a split that shrinks
  an in-flight chunk simply makes it finish earlier.
- Chunks stuck in `stalled` quality for ~15 s have their request reissued
  automatically (within the normal retry budget).
- Downloads with no `Content-Length` stream to EOF in a single chunk.
- When `io.fileSize` is provided, the assembled file's size is verified
  before the final rename.

### Dynamic chunking

A chunk's throughput is compared against the median of all active chunks on
a rolling window. If one falls below ~50% of the median it's marked `poor`;
below ~15% it's `stalled`. When any chunk finishes (or stalls), the
scheduler picks the slowest/largest remaining chunk, truncates its tail, and
spawns a new chunk from the freed range, bounded by `targetChunkCount`.

## Development

```bash
npm install
npm test            # vitest
npm run typecheck
npm run build
```

Tests are split into `unit/`, `integration/`, `edge/`, and `events/`
directories. The suite uses an in-memory mock fs and programmable mock
fetch, so there's no network or filesystem dependency.
