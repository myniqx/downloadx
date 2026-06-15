# Project Guide

A file-by-file map of the codebase, how the pieces fit together, and the
rules to follow when making changes. Read this before touching the code.

## Overview

The repository is a Bun workspace monorepo:

```
downloadx/
├── apps/downloadx/   # the core library (published npm package "downloadx")
└── apps/cli/         # daemon-based CLI built on top of the library
```

The library is **runtime-agnostic**: it never imports `node:*` modules. All
I/O (fetch, file system, path joining) arrives through the
`InjectedFunctions` interface, which is why the same code runs in Node, Bun,
Deno, or edge runtimes. The CLI is where Node-specific I/O lives.

### Lifecycle of a download

```
addUrl() ──► probe (HEAD → ranged GET fallback)        probe.ts
        ──► load or create meta sidecar               meta.ts
        ──► plan chunks                               chunkScheduler.ts
        ──► pre-allocate part file (optional)         download.ts → io.truncate
        ──► drive chunks in parallel                  download.ts ⇄ chunk.ts
        │     ├─ each chunk: ranged GET, stream,      chunk.ts
        │     │  random-access write, retry           retry.ts
        │     ├─ throttling                           throttle.ts
        │     ├─ speed/quality tracking               speedTracker.ts
        │     ├─ dynamic splits on completion         chunkScheduler.ts
        │     └─ persist meta after every settle      meta.ts
        ──► verify size, rename .part → final         download.ts
        ──► delete meta sidecar, emit `completed`
```

Two sidecar files live next to the download (in `cachePath`):

- `{filename}.downloadx.json` — resume state (chunk layout, validators).
  Deleted on successful completion.
- `{filename}.downloadx.log` — NDJSON diagnostic journal (when `journal:
true`). Kept after completion; deleted by `clear()`.

The in-progress file is `{filename}.downloadx.part`, renamed into place on
completion.

## Library — `apps/downloadx/src/`

| File                | Responsibility                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `index.ts`          | Public API surface. Everything exported from the package goes through here — keep it the single export point.                                                                                                                                                                                                                                                                                    |
| `types.ts`          | All shared type definitions: `InjectedFunctions`, config/options, states, event payloads, `MetaFile`, `DownloadDescription`. No logic.                                                                                                                                                                                                                                                           |
| `constants.ts`      | Defaults (`DEFAULT_CONFIG`), sidecar extensions, retryable/non-retryable status sets, quality thresholds, `UNKNOWN_SIZE_LENGTH` sentinel, stall-recovery timing. Tune heuristics here first; expose as config only once proven.                                                                                                                                                                  |
| `downloadX.ts`      | `DownloadX` manager: registry of `Download`s, `maxParallel` queue/pump, event relay (`pipeTo`), manager-wide shared `Throttle`, `describeAll()`, URL→id hashing.                                                                                                                                                                                                                                 |
| `download.ts`       | `Download` orchestrator — the most complex file. Owns the probe/meta/chunk lifecycle, the drive loop (launch, settle, split, persist), the 200-instead-of-206 single-chunk fallback, stall recovery, pre-allocation, size verification, finalize/rename, progress + ETA emission, `describe()`/`describeText()`, the diagnostic buffer, and the journal writer.                                  |
| `chunk.ts`          | `Chunk` — one byte range, one HTTP request per attempt. Builds Range/If-Range headers, validates 206, streams the body with the network-idle timer, clamps every write to its current length, resets progress when the server lacks range support, classifies its own quality, and emits per-chunk events. `truncateTail()` is how splits shrink it; `restart()` is how stall recovery kicks it. |
| `chunkScheduler.ts` | Pure functions: `planChunks` (initial division of `totalSize` into ranges) and `findSplitCandidate` (which downloading chunk donates its tail, scored by quality then remaining bytes). No side effects — keep it that way; it's the easiest part to unit-test.                                                                                                                                  |
| `probe.ts`          | URL probing: HEAD first, `Range: bytes=0-0` GET fallback. Extracts size, range support, validators (ETag/Last-Modified), final URL after redirects, and the filename (Content-Disposition → URL path → generated).                                                                                                                                                                               |
| `retry.ts`          | `withRetry` loop with exponential backoff + full jitter, `HttpStatusError`, `RangeNotHonoredError`, and the retryable/permanent classification. AbortError is never retried.                                                                                                                                                                                                                     |
| `throttle.ts`       | Token-bucket bandwidth limiter with a FIFO waiter queue, live `setCapacity`, and abort-signal support. One instance per download plus an optional shared one at the manager level.                                                                                                                                                                                                               |
| `speedTracker.ts`   | `SpeedTracker` (per-chunk instant + windowed speed from a sample ring) and `AggregateSpeed` (download-wide totals and the median used for quality classification).                                                                                                                                                                                                                               |
| `events.ts`         | `TypedEventEmitter` — minimal, synchronous, strictly typed, listener errors contained. Not Node's EventEmitter on purpose.                                                                                                                                                                                                                                                                       |
| `meta.ts`           | Meta sidecar persistence: atomic write (tmp + rename), schema validation on load, resume validation (`canResumeAgainst`: ETag → Last-Modified → size), state dehydration.                                                                                                                                                                                                                        |

## Library tests — `apps/downloadx/tests/`

| Path                                                           | What it covers                                                                                                                                                                      |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `helpers/mockFs.ts`                                            | In-memory file system implementing `InjectedFunctions` (including optional `truncate`/`appendFile`/`fileSize`).                                                                     |
| `helpers/mockFetch.ts`                                         | Programmable mock server: per-URL routes, range handling (returns proper 206), failure injection, streamed bodies, artificial delays. Records every request for assertions.         |
| `helpers/config.ts`                                            | `makeHarness()` — fresh fs + fetch + config per test. Tests use small chunk sizes / fast retries so behaviour surfaces quickly.                                                     |
| `helpers/clock.ts`, `helpers/events.ts`, `helpers/fixtures.ts` | Fake clock, `waitForEvent`, deterministic byte buffers.                                                                                                                             |
| `unit/*`                                                       | One file per module, pure-logic tests.                                                                                                                                              |
| `integration/download.test.ts`                                 | End-to-end happy paths, pause/resume (same and cross instance), cancel, speed limit, manager relay/queueing, error propagation.                                                     |
| `integration/regressions.test.ts`                              | Pinned bugs: in-flight split clamping, 200-instead-of-206 fallback, no-range restart-from-zero, idle-timeout retry, unknown-size streaming, journal/describe/prealloc/ETA features. |
| `edge/edge.test.ts`                                            | Transient failures, validator changes, scheduler sizing, fs edge cases.                                                                                                             |
| `events/events.test.ts`                                        | Event ordering/payload contracts.                                                                                                                                                   |

## CLI — `apps/cli/src/`

| File                | Responsibility                                                                                                                                                                                                                                                  |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cli.ts`            | Entry point: dispatches to daemon mode or CLI mode.                                                                                                                                                                                                             |
| `constants.ts`      | Socket path, pid/log/data locations, downloads dir.                                                                                                                                                                                                             |
| `ipc.ts`            | The wire protocol: request/response/event types shared by daemon and client. Newline-delimited JSON over a Unix socket.                                                                                                                                         |
| `daemon/index.ts`   | Socket server, request routing, daemon lifecycle (pid file, auto-shutdown when idle).                                                                                                                                                                           |
| `daemon/manager.ts` | Bridges the library to the daemon: builds the Node `InjectedFunctions` (`makeIo` — note `openRw`, which never truncates), creates `DownloadX` instances per target path (with `journal: true`), relays library events to IPC sinks, exposes `describeDownload`. |
| `daemon/store.ts`   | Persistent registry of download entries (survives daemon restarts; `restoreDownloads` re-attaches on boot).                                                                                                                                                     |
| `cli/index.ts`      | Argument parsing and command dispatch; help text.                                                                                                                                                                                                               |
| `cli/client.ts`     | Socket client: `ensureDaemon` (spawn if missing), `sendRequest`, `openWatchStream`.                                                                                                                                                                             |
| `cli/commands/*.ts` | One file per command. `watch.ts` has the TUI renderer plus `--simple` and `--json` (NDJSON) modes; `status.ts` renders `describe()` as text or JSON.                                                                                                            |

## Rules

### Invariants — do not break these

1. **Chunk ranges must tile the file.** At any persisted moment, the chunk
   snapshots' `[offset, offset+length)` ranges must cover the file exactly,
   with no gaps and no overlaps. Splits preserve this (`truncateTail` shrinks
   the donor by exactly the donated range). Resume depends on it.
2. **`downloadedBytes <= length`, always.** Writes are clamped in
   `Chunk.clampToRemaining`. Never remove the clamp: lengths can shrink while
   a stream is in flight, and servers can send more than the requested range.
   A negative remaining size is the canary for this class of bug.
3. **Never truncate the part file once writes have started.** Random-access
   writers race; any I/O implementation must create-or-open without
   truncation (`r+` → `wx` → `r+`, see `openRw` in the CLI manager and the
   README quick start). Pre-allocation (`io.truncate`) runs only before the
   drive loop.
4. **A ranged response must be `206`.** If a Range header was sent and `200`
   comes back, the body is the whole file — it must never be consumed at a
   chunk offset. Throw `RangeNotHonoredError`; the Download falls back to a
   single-chunk restart (once — guarded by `rangeFallbackDone`).
5. **No range support ⇒ restart from zero.** A server without range support
   restarts the body from byte 0 on every attempt; resuming a partial chunk
   would misalign the file. `executeOnce` resets progress — keep it.
6. **`requestTimeout` is a network _idle_ timeout.** The timer is armed only
   while awaiting the network (fetch, `reader.read()`) and cleared before
   throttle waits and disk writes. Never reintroduce a cap on total request
   duration — that is exactly the bug that broke >1 GB downloads.
7. **The library never imports runtime modules.** No `node:fs`, no
   `node:path`, nothing platform-specific in `apps/downloadx/src`. New I/O
   needs go through optional fields on `InjectedFunctions` (optional = the
   feature silently no-ops when absent, existing integrations keep working).
8. **Meta schema changes require a version bump.** If you change the
   persisted `MetaFile`/`ChunkSnapshot` shape, bump `META_SCHEMA_VERSION` and
   update `validate()` in `meta.ts`. Old sidecars are then discarded safely
   instead of misread.
9. **Abort semantics.** `AbortError` (named) = user intent (pause/cancel) —
   never retried. Plain `Error` abort reasons (idle timeout, `restart:`) =
   transient — retried within the budget. When aborting with intent to retry,
   abort with a plain `Error` reason.
10. **Journal and diagnostics must never affect the download.** Journal
    writes are fire-and-forget with swallowed errors; listener exceptions are
    contained by `TypedEventEmitter`. Keep diagnostics side-effect-free.
11. **Splits are forbidden when** ranges are unsupported, total size is
    unknown, or any chunk has failed permanently. The guard lives in
    `driveChunks`; new scheduling logic must respect it.
12. **Chunk ids come from `chunkSeq`** (monotonic), never from array length —
    array length reuses ids after restructuring.

### Configuration mutability rule

A config field must be either **constructor-only** or **fully live** — never
in between:

- **Constructor-only**: the value is consumed once (e.g. initial chunk
  planning, sidecar paths) and cannot be meaningfully changed mid-download.
  Accept it only in the constructor / `DownloadXConfig`. Do not add a setter.
- **Fully live**: the value is read on every decision point (e.g. per-chunk
  split logic, throttle capacity). It must be accepted in the constructor
  **and** exposed via a `setX()` method on both `Download` and `DownloadX`.
  The CLI `set` command must also support it.

If you are unsure, grep for every read site of the field. If all reads happen
after a single initialisation moment (probe, meta load, `planChunks`) it is
constructor-only. If any read happens inside the drive loop or a recurring
callback it is fully live and needs a setter.

### Code style and typing

- TypeScript `strict` plus `noUncheckedIndexedAccess` and
  `exactOptionalPropertyTypes` are on. Consequences: indexed access yields
  `T | undefined` (guard it), and you cannot assign `undefined` to an
  optional property — build objects conditionally
  (`...(x !== undefined ? { x } : {})`).
- `noUnusedLocals` / `noUnusedParameters` are errors — remove dead code
  rather than underscore-prefixing in the library.
- Public API changes go through `index.ts` and get documented in the README
  tables. Event payload changes must update `types.ts`, the README events
  table, and (if relayed) `apps/cli/src/ipc.ts` + `daemon/manager.ts`.
- Comments explain _why_ (constraints, protocol quirks), not _what_ the next
  line does. Match the existing JSDoc style on exported symbols.

### Testing rules

- Every bug fix gets a pinned regression test
  (`tests/integration/regressions.test.ts`) that fails on the old behaviour.
- No real network, no real filesystem, no real clock dependence. Use
  `makeHarness()`; for timing-sensitive logic inject `now` (Chunk,
  SpeedTracker, Throttle all accept one).
- Mind the mock-vs-reality gaps when testing abort paths: `MockFetch` rejects
  with a generic `AbortError` regardless of the abort _reason_, and mock
  `ReadableStream`s don't reject in-flight `read()`s on abort. WHATWG fetch
  rejects with `signal.reason`. Tests that depend on the reason must use a
  small custom fetch (see the idle-timeout regression test).
- Keep tests deterministic: pause/resume tests already tolerate the
  "raced to completion" case — follow that pattern instead of sleeping.
- Run before pushing: `bun run typecheck && bun run test` at the repo root
  (tests live in the library package; typecheck covers both).

### Workflow

- Build order matters for the CLI: `apps/cli` resolves the `downloadx` types
  from `apps/downloadx/dist`, so run `bun run build` in `apps/downloadx`
  before `bun run typecheck` in `apps/cli` on a fresh clone.
- Commits: imperative subject, body explains the why. Group mechanical
  renames separately from behaviour changes.
- `DEFAULT_CONFIG` changes are user-visible behaviour changes — call them out
  explicitly in the commit message and README.
- New chunk-quality / scheduling heuristics: tune via `constants.ts` first,
  promote to a config field only after it has proven itself (see the note on
  `QUALITY_*` ratios).

## Glossary

| Term                 | Meaning                                                                                              |
| -------------------- | ---------------------------------------------------------------------------------------------------- |
| **probe**            | The initial HEAD/ranged-GET that discovers size, range support, validators, and filename.            |
| **chunk**            | One contiguous byte range with its own HTTP request lifecycle.                                       |
| **split / reassign** | Shrinking a downloading chunk's tail and giving the freed range to a new chunk.                      |
| **part file**        | `{filename}.downloadx.part` — the random-access in-progress file.                                    |
| **meta sidecar**     | `{filename}.downloadx.json` — resume state, written atomically.                                      |
| **journal**          | `{filename}.downloadx.log` — NDJSON diagnostic event log.                                            |
| **quality**          | `good` / `poor` / `stalled` — chunk speed relative to the median of active chunks.                   |
| **idle timeout**     | Abort-and-retry when no bytes arrive for `requestTimeout` ms; not a total-duration cap.              |
| **sentinel length**  | `UNKNOWN_SIZE_LENGTH` (`Number.MAX_SAFE_INTEGER`) — marks an unknown-size chunk that streams to EOF. |

## Dart / Flutter port — `apps/downloadx_dart/`

A standalone Dart package mirroring the core 1:1. It is **not** part of the Bun
workspace and has its own toolchain (`dart pub get`, `dart analyze`,
`dart test`). The module layout maps directly onto the TypeScript source:

| Dart file                  | Mirrors                  | Notes                                                                                       |
| -------------------------- | ------------------------ | ------------------------------------------------------------------------------------------- |
| `lib/src/types.dart`       | `types.ts`               | Enums, config, snapshots, `MetaFile` (+ `toJson`/`fromJson`), event/description payloads.   |
| `lib/src/io.dart`          | `InjectedFunctions`      | `DownloadxIo` abstract interface + `FetchResponse`/`CancelToken` (AbortSignal analogue).    |
| `lib/src/native_io.dart`   | (new — README quickstart)| Default `dart:io` backend: `HttpClient` + non-truncating `FileMode.append` random writes.   |
| `lib/src/events.dart`      | `events.ts`              | Sealed `DownloadEvent` hierarchy + synchronous, error-contained `EventEmitter`.             |
| `lib/src/{retry,throttle,speed_tracker,chunk_scheduler,probe,meta,chunk,download,download_x}.dart` | same basenames | Same responsibilities and invariants. |

Key porting decisions:

- **I/O is still pluggable but no longer mandatory.** A Flutter/Dart consumer
  just passes `targetPath`; `io` defaults to `NativeIo`. Tests inject an
  in-memory `DownloadxIo`.
- **Abort semantics** map onto `CancelToken`: `AbortError` = user intent (never
  retried), `TransientAbort` = idle-timeout / stall-restart (retried) — same
  classification as invariant 9.
- **Random-access writes** use `FileMode.append` (which, despite the name, is
  seekable on every Dart target and never truncates) — the Dart equivalent of
  the README's `r+ → wx` `openRw`. Pre-allocation uses `truncate()` on an
  append handle so it preserves a resumed part file (invariant 3).
- The meta sidecar (`schemaVersion 3`, field names, the unknown-size sentinel
  `9007199254740991` = `2^53 - 1`, the FNV-1a URL→id hash) is byte-compatible,
  so a download is interchangeable between the TS and Dart implementations.

The same invariants in this document apply. Run `dart analyze && dart test`
(from `apps/downloadx_dart`) before pushing.
