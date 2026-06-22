# @downloadx/core

An IDM-style, runtime-agnostic download manager for TypeScript.

`@downloadx/core` downloads files in parallel chunks with random-access disk
writes, splits slow chunks dynamically so fast connections never idle,
survives process restarts, and recovers from misbehaving servers — all with
**zero runtime dependencies**. Every I/O primitive (fetch, file system, path
joining) is injected by you, so the same package runs unchanged in Node, Bun,
Deno, edge runtimes, or against a custom storage backend such as S3.

> Looking for a ready-made command-line tool instead? See
> [`@downloadx/cli`](https://npmjs.com/package/@downloadx/cli) — a
> daemon-based CLI built on this library.

## Features

- **Chunked parallel downloads** — the file is divided into byte ranges that
  download concurrently and write directly to their final offsets. No
  temp-file stitching at the end.
- **Dynamic chunk splitting** — chunk throughput is compared against the
  median; when a chunk finishes, the slowest/largest remaining chunk donates
  its tail to a fresh worker, bounded by `targetChunkCount`.
- **Resume across restarts** — a `.downloadx.json` sidecar (written
  atomically) records the exact chunk layout; resume is validated with
  ETag → Last-Modified → size, and ranged requests carry `If-Range` so a
  changed resource can never be spliced into stale bytes.
- **Misbehaving-server recovery** — a ranged request answered with `200 OK`
  (server ignored `Range`) is detected and the download restarts once as a
  single full-body request instead of corrupting the file.
- **Network idle timeout** — an attempt is aborted and retried only when no
  bytes arrive for `requestTimeout` ms. Long downloads run for hours as long
  as data flows.
- **Stall auto-recovery** — chunks stuck below ~15% of the median speed for
  ~15 s get their HTTP request reissued automatically.
- **Speed limiting** — token-bucket throttling per download plus an optional
  manager-wide cap shared by all downloads; both adjustable live.
- **Retries done right** — exponential backoff with full jitter, and a
  retryable vs. permanent HTTP status distinction (a 404 fails fast, a 503
  retries).
- **Integrity** — optional disk pre-allocation before the first write and a
  final size verification before the part file is renamed into place.
- **HLS (m3u8) support** — master and media playlists are parsed and segments
  downloaded in parallel. A master playlist with multiple quality streams
  registers each as a separate idle download so the caller picks the one to
  start. Segment concatenation is handled by an optional `concatSegments` I/O
  hook (ffmpeg recommended); without it a binary fallback produces a raw `.ts`.
- **Observability** — a strictly-typed event emitter, an NDJSON diagnostic
  journal sidecar, and `describe()` / `describeText()` reports compact enough
  to paste into a dashboard, a log line, or an LLM prompt.
- **Unknown sizes handled** — downloads with no `Content-Length` stream to
  EOF in a single chunk instead of failing.

## Install

```bash
npm install @downloadx/core
```

## Quick start (Node)

```ts
import {
  appendFile,
  mkdir,
  open,
  readFile,
  rename,
  stat,
  unlink,
  writeFile,
} from 'node:fs/promises';
import { join } from 'node:path';
import { createDownloadX } from '@downloadx/core';

// Open for random-access writing without ever truncating: 'r+' needs the
// file to exist, 'wx' creates it atomically and fails (instead of
// truncating) when a concurrent writer won the creation race.
async function openRw(p: string) {
  try {
    return await open(p, 'r+');
  } catch {
    try {
      return await open(p, 'wx');
    } catch {
      return open(p, 'r+');
    }
  }
}

const manager = await createDownloadX({
  io: {
    fetch: globalThis.fetch,
    mkdir: async (p) => {
      await mkdir(p, { recursive: true });
    },
    exists: async (p) => {
      try {
        await stat(p);
        return true;
      } catch {
        return false;
      }
    },
    readFile: async (p) => new Uint8Array(await readFile(p)),
    writeFile: async (p, buf) => {
      await writeFile(p, buf);
    },
    writeChunk: async (p, offset, buf) => {
      const fh = await openRw(p);
      try {
        await fh.write(buf, 0, buf.length, offset);
      } finally {
        await fh.close();
      }
    },
    rename: async (from, to) => {
      await rename(from, to);
    },
    unlink: async (p) => {
      await unlink(p).catch(() => undefined);
    },
    joinPath: (...segs) => join(...segs),
    // Optional — each one unlocks a feature:
    truncate: async (p, size) => {
      const fh = await openRw(p);
      try {
        await fh.truncate(size);
      } finally {
        await fh.close();
      }
    },
    appendFile: async (p, buf) => {
      await appendFile(p, buf);
    },
    fileSize: async (p) => (await stat(p)).size,
  },
  targetPath: './downloads',
  maxParallel: 3,
  targetChunkCount: 4,
  journal: true,
});

const dl = await manager.addUrl('https://example.com/big.iso');

dl.emitter.on('progress', (p) => {
  const eta = p.etaMs === null ? '?' : `${Math.round(p.etaMs / 1000)}s`;
  console.log(`${p.percent?.toFixed(1)}% @ ${(p.totalSpeed / 1e6).toFixed(2)} MB/s, ETA ${eta}`);
});

await dl.start();
```

## API

### `createDownloadX(config)`

Create a manager and rehydrate any persisted downloads found in `cachePath`.
Restored downloads stay in their last persisted state (no autostart) — the
caller decides what to resume.

Config fields:

| Field               | Default      | Description                                                                                                                                           |
| ------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `io`                | required     | Injected I/O primitives (see below).                                                                                                                  |
| `targetPath`        | required     | Directory where finished files land.                                                                                                                  |
| `cachePath`         | `targetPath` | Directory for in-flight meta/part files. Fixed at construction.                                                                                       |
| `maxParallel`       | `3`          | Max concurrent active downloads.                                                                                                                      |
| `targetChunkCount`  | `4`          | Upper bound on live chunks per download.                                                                                                              |
| `minChunkSize`      | `1 MiB`      | Smaller ranges won't be split further.                                                                                                                |
| `maxRetries`        | `5`          | Per-chunk HTTP retries.                                                                                                                               |
| `retryDelay`        | `1000`       | Base backoff delay (ms).                                                                                                                              |
| `retryBackoff`      | `2`          | Exponential backoff multiplier.                                                                                                                       |
| `speedSampleWindow` | `3000`       | Moving-average window (ms) for quality.                                                                                                               |
| `speedLimit`        | `0`          | Manager-wide bytes/sec cap shared by all downloads. `0` = unlimited.                                                                                  |
| `requestTimeout`    | `30000`      | Network **idle** timeout (ms): aborts and retries an attempt only when no bytes arrive for this long. Long downloads are unaffected while data flows. |
| `headers`           | `{}`         | Default HTTP headers.                                                                                                                                 |
| `journal`           | `false`      | Write an NDJSON event journal (`{filename}.downloadx.log`) next to the meta file. Requires `io.appendFile`.                                           |

`cachePath` is fixed at construction (defaults to `targetPath` when omitted)
and cannot be changed afterwards — part files and meta sidecars stay where
they were first written.

### Manager methods

- `addUrl(url, options?)` → `Promise<Download>` — `options.targetPath`
  overrides the manager's `targetPath` for this download only; other
  per-download overrides include `filename`, `description`, `metadata`,
  `headers`, `chunkMode`, `targetChunkCount`, `speedLimit`, `id`, `autoStart`.
- `start(id?)` / `pause(id?)` / `clear(id?)`
- `list()` / `get(id)`
- `describeAll()` — compact status reports for every download
- `setMaxParallel(n)` / `setTargetPath(p)`
- `setSpeedLimit(bytesPerSec | null)` — manager-wide cap **shared by all
  downloads** (per-download `speedLimit` still applies on top); `0` or `null`
  = unlimited
- `setTargetChunkCount(n | null, override?)` / `setMinChunkSize(bytes | null, override?)` /
  `setJournal(enabled | null, override?)` — pass `override: true` to force the
  new value onto every download; `null` resets to the built-in default. Without
  `override`, only downloads still carrying the old global value are updated.
- `setHeaders(patch | null)` — merge HTTP headers into the global config;
  `null` values in the patch remove that key; pass `null` to clear all global headers

### `Download` methods

- `start()` / `pause()` / `cancel()` / `clear()`
- `setSpeedLimit(bytesPerSec | null)` — `null` clears the per-download
  override and falls back to the manager value; `0` disables the cap
- `setTargetPath(path | null)` — `null` clears the override and falls back to
  the manager value
- `setTargetChunkCount(n | null)` / `setMinChunkSize(bytes | null)` /
  `setJournal(enabled | null)` — per-download overrides; `null` clears and
  reverts to the global value
- `setFilename(name | null)` — override the final filename; `null` reverts to
  the probe/URL-derived name
- `setDescription(text | null)` — attach a free-form note to this download
- `setMetadata(patch | null)` — merge arbitrary key/value pairs; `null` values
  in the patch remove individual keys; pass `null` to clear all metadata
- `setHeaders(patch | null)` — merge HTTP headers for this download on top of
  the global headers (`effective = {...global, ...local}`); `null` values in
  the patch remove individual keys; pass `null` to clear all local overrides.
  Only the local portion is persisted — global header changes are reflected
  automatically on the next request.
- `alloc()` — pre-allocate the part file to its final size (automatic at
  start when `io.truncate` is provided)
- `getChunkSnapshots()` — the exact state persisted to disk
- `describe()` — compact JSON status report (state, percent, speed, ETA,
  live chunk table, recent diagnostics); `describeText()` renders the same
  as a short plain-text block, safe to paste into a prompt or log
- `.emitter` — typed EventEmitter for this download

> **Part file location:** the in-progress `.part` file is always written to
> `{cachePath}/{id}.part`, not next to the final target. This means renaming
> or changing the filename mid-download never loses the downloaded bytes.
> The file is only moved to `{targetPath}/{filename}` on successful completion.

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
  listDir: (path) => Promise<string[]>;
  // Optional — enable extra features when provided:
  truncate?: (path, size) => Promise<void>; // disk pre-allocation
  appendFile?: (path, bytes) => Promise<void>; // NDJSON journal
  fileSize?: (path) => Promise<number>; // final size verification
  concatSegments?: (segments: string[], output: string) => Promise<void>; // HLS concat
}
```

The `fetch` must match the WHATWG `fetch` shape (streaming body and
`AbortSignal` support). Everything else maps directly to your chosen storage
backend — disk, S3, IndexedDB, or a database — as long as `writeChunk`
supports random-access offset writes **without truncating the file**.

#### `concatSegments` — HLS segment concatenation

When provided, this hook is called after all `.ts` segments are downloaded.
Without it the core falls back to a binary concat, producing a raw `.ts` file.

**ffmpeg example — remux to `.mp4` (no re-encode, fast):**

```ts
import { spawn } from 'node:child_process';

const io = {
  // ...other fields,
  concatSegments: (segments, output) =>
    new Promise((resolve, reject) => {
      // Write a concat list file so ffmpeg doesn't hit ARG_MAX on large playlists.
      const listPath = output + '.ffconcat';
      const content = 'ffconcat version 1.0\n' +
        segments.map(s => `file '${s}'`).join('\n');
      await writeFile(listPath, Buffer.from(content));

      const ff = spawn('ffmpeg', [
        '-f', 'concat', '-safe', '0', '-i', listPath,
        '-c', 'copy',   // remux only — no re-encode
        '-movflags', '+faststart',
        '-y', output,
      ]);
      ff.on('close', (code) => {
        unlink(listPath).catch(() => undefined);
        code === 0 ? resolve() : reject(new Error(`ffmpeg exited ${code}`));
      });
    }),
};
```

**ffmpeg example — transcode `.ts` segments to `.mp4` (H.264 + AAC):**

```ts
concatSegments: (segments, output) =>
  new Promise((resolve, reject) => {
    const ff = spawn('ffmpeg', [
      '-i', `concat:${segments.join('|')}`,
      '-c:v', 'libx264', '-preset', 'fast', '-crf', '22',
      '-c:a', 'aac', '-b:a', '128k',
      '-y', output,
    ]);
    ff.on('close', (code) =>
      code === 0 ? resolve() : reject(new Error(`ffmpeg exited ${code}`))
    );
  }),
```

> Without `concatSegments`, the core binary-concatenates the segments into a
> `.ts` file. This is valid for most streams but skips container conversion and
> metadata — use ffmpeg when you need `.mp4` / `.mkv` output or chapter marks.

### Events

All events are available on both `Download.emitter` and the parent
`DownloadX.emitter` (payloads are the same object reference — manager
listeners see exactly what the Download emitted).

| Event            | Payload                                                                                                                                   |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `progress`       | Aggregate: `{ downloadId, totalBytes, downloadedBytes, totalSpeed, activeChunks, percent, etaMs, hlsSegmentsDone?, hlsTotalSegments? }`    |
| `chunkProgress`  | Per-chunk: `{ downloadId, chunkId, offset, length, downloadedBytes, instantSpeed, windowedSpeed, quality }`                               |
| `chunkLifecycle` | `{ downloadId, chunkId, status }` — `pending`/`downloading`/`completed`/`failed`/`paused`/`reassigned`                                    |
| `chunkSplit`     | `{ downloadId, sourceChunkId, newChunkId, splitOffset, reason }`                                                                          |
| `chunkQuality`   | Same payload shape as `chunkProgress`; `quality ∈ 'good'\|'poor'\|'stalled'`                                                              |
| `stateChange`    | `{ downloadId, previous, current }`                                                                                                       |
| `error`          | `{ downloadId, chunkId?, error, fatal }`                                                                                                  |
| `completed`      | `{ downloadId, filename, totalBytes, durationMs }`                                                                                        |
| `diagnostic`     | `{ downloadId, chunkId?, level, code, message, timestamp, data? }` — retries, splits, timeouts, fallbacks; identical to the journal lines |

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
below ~15% it's `stalled`. When any chunk finishes, the scheduler picks the
slowest/largest remaining chunk, truncates its tail, and spawns a new chunk
from the freed range, bounded by `targetChunkCount`.

## Development

```bash
bun install
bun run --filter @downloadx/core test       # vitest
bun run --filter @downloadx/core typecheck
bun run --filter @downloadx/core build
```

Tests are split into `unit/`, `integration/`, `edge/`, and `events/`
directories under `tests/`. The suite uses an in-memory mock fs and a
programmable mock fetch, so there's no network or filesystem dependency.

## License

MIT
