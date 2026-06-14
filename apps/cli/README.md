# @downloadx/cli

A daemon-based command-line download manager built on
[`@downloadx/core`](https://npmjs.com/package/@downloadx/core).

`downloadx` keeps downloads running in the background through a small daemon
that the CLI talks to over a Unix domain socket. You add a URL once, log out,
log back in days later, and the download is still progressing — or already
sitting in your target directory. Live progress is available via a TUI or
NDJSON stream suitable for scripts and LLM/agent consumers.

> Need the library itself (to embed downloads in your own app)? See
> [`@downloadx/core`](https://npmjs.com/package/@downloadx/core).

> **Platform:** Linux and macOS only. The daemon relies on Unix domain sockets
> and is not supported on Windows.

## Install

```bash
npm install -g @downloadx/cli
```

This puts the `downloadx` command on your `PATH`. The daemon is spawned
automatically on the first command and shuts down with `downloadx stop`.

## Commands

```
downloadx add --url <url> [--path <dir>]              Add and start a download
downloadx list                                        List all downloads
downloadx status --id <#|id> [--json]                 Detailed status for a download
downloadx pause  --id <#|id> | --all                  Pause one or all downloads
downloadx resume --id <#|id> | --all                  Resume one or all downloads
downloadx restart --id <#|id> [--force] | --all       Restart from scratch, keeps list position
downloadx cancel --id <#|id> | --all                  Cancel one or all downloads
downloadx clear  --id <#|id> [--force]                Remove from list (confirms if incomplete)
downloadx clear  --all [--force]                      Remove all (confirms incomplete ones)
downloadx clear  --completed                          Remove only completed downloads
downloadx watch [--simple|--json]                     Live progress view
downloadx stop                                        Shut down the daemon

downloadx set <key> <value> [--id <#|id>] [--override]   Set a config value
downloadx get [key] [--id <#|id>]                        Get one or all config values
```

`<#>` refers to the index shown by `list` (e.g. `1`, `2`, `#1`, `#2`).

`restart` deletes `.part` files and restarts from byte zero. It always asks
for confirmation unless `--force` is passed. The download keeps its position
in the list and its original `addedAt` timestamp.

`clear` only removes the entry from the list and deletes in-progress `.part`,
`.meta`, and `.journal` files — it never touches the finished file in the
target directory.

`watch --json` emits one self-contained JSON event per line (progress, chunk
progress, state changes, diagnostics) — a stable interface for scripts and
LLM/agent consumers. `status --json` prints the full `describe()` report.

## Configuration

Config is stored in `~/.local/share/downloadx/config.json` and applied live
without restarting the daemon.

| Key                | Default                              | Description                                                                                                        |
| ------------------ | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| `maxParallel`      | `3`                                  | Max concurrent active downloads                                                                                    |
| `speedLimit`       | `0`                                  | Global speed cap shared by all downloads. `0` = unlimited. Accepts `500kb`, `3mb`, `1.5gb` or raw bytes            |
| `targetPath`       | `~/.local/share/downloadx/downloads` | Default directory for completed files                                                                              |
| `targetChunkCount` | `4`                                  | Target number of parallel chunks per download. Takes effect on the next split decision for active downloads        |
| `minChunkSize`     | `1mb`                                | Minimum chunk size before splitting stops. Accepts `500kb`, `1mb`, etc. Takes effect on the next split decision    |
| `journal`          | `true`                               | Write an NDJSON diagnostic log (`.downloadx.log`) next to each download. Takes effect on the next diagnostic event |

Per-download overrides (via `--id`): `speedLimit`, `targetPath`,
`targetChunkCount`, `minChunkSize`, `journal`.

The daemon's cache directory (`~/.local/share/downloadx/cache`) is fixed at
daemon startup and is not a runtime-configurable key.

When you change a global key like `targetChunkCount` or `minChunkSize`,
existing downloads that still carry the old global value pick up the new
value on their next split decision. Downloads that already have a
per-download override are left alone unless you pass `--override`, which
forces the new value onto every download.

```bash
downloadx set maxParallel 5
downloadx set speedLimit 3mb
downloadx set targetPath ~/Downloads
downloadx set speedLimit 1mb --id 2       # limit only download #2
downloadx set minChunkSize 2mb --override # force onto every download
downloadx get                              # show all config values
downloadx get speedLimit                   # show one value
downloadx get speedLimit --id 2           # per-download override value
```

## Development

```bash
bun install
bun run --filter @downloadx/cli test       # vitest integration suite
bun run --filter @downloadx/cli typecheck
bun run --filter @downloadx/cli build
```

The integration tests spin up a real daemon process per test against a
temporary working directory, so they exercise the full IPC path, persistence,
and command surface.

## License

MIT
