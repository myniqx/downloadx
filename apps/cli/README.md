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
downloadx add --url <url> [--filename <name>] [--description <text>]
              [--speedLimit <n>] [--targetPath <dir>]
              [--targetChunkCount <n>] [--minChunkSize <n>] [--journal true|false]
              [--metadata.key <val>] [--headers.Key <val>]
downloadx list [--json]                               List all downloads
downloadx status  --id <#|id> [--json]                Detailed status for a download
downloadx pause   --id <#|id> | --all                 Pause one or all downloads
downloadx resume  --id <#|id> | --all                 Resume one or all downloads
downloadx restart --id <#|id> [--force] | --all       Restart from scratch, keeps list position
downloadx cancel  --id <#|id> | --all                 Cancel one or all downloads
downloadx clear   --id <#|id> [--force]               Remove from list (confirms if incomplete)
downloadx clear   --all [--force]                     Remove all (confirms incomplete ones)
downloadx clear   --completed                         Remove only completed downloads
downloadx watch [--simple|--json]                     Live progress view
downloadx stop                                        Shut down the daemon

downloadx set <key> <value> [--id <#|id>] [--override]   Set a config value
downloadx get [key] [--id <#|id>] [--json]               Get one or all config values
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

### Global keys

| Key                | Default                              | Description                                                                                                        |
| ------------------ | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| `maxParallel`      | `3`                                  | Max concurrent active downloads                                                                                    |
| `speedLimit`       | `0`                                  | Global speed cap shared by all downloads. `0` = unlimited. Accepts `500kb`, `3mb`, `1.5gb` or raw bytes            |
| `targetPath`       | `~/.local/share/downloadx/downloads` | Default directory for completed files                                                                              |
| `targetChunkCount` | `4`                                  | Target number of parallel chunks per download                                                                      |
| `minChunkSize`     | `1mb`                                | Minimum chunk size before splitting stops. Accepts `500kb`, `1mb`, etc.                                            |
| `journal`          | `true`                               | Write an NDJSON diagnostic log (`.downloadx.log`) next to each download                                            |
| `headers`          | `{}`                                 | Default HTTP headers sent with every request. Use dot-notation: `set headers.Authorization "Bearer x"`             |

### Per-download keys (`set --id`)

The following keys can be overridden per download. Set at add time as flags or
later via `set --id`. Setting a key to `null` clears the override and reverts
to the global value.

| Key                | Description                                                                                           |
| ------------------ | ----------------------------------------------------------------------------------------------------- |
| `speedLimit`       | Per-download speed cap. `null` = follow global                                                        |
| `targetPath`       | Override the destination directory for this download. `null` = follow global                          |
| `targetChunkCount` | Override chunk count. `null` = follow global                                                          |
| `minChunkSize`     | Override minimum chunk size. `null` = follow global                                                   |
| `journal`          | Override journal setting. `null` = follow global                                                      |
| `filename`         | Override the final filename. `null` = use probe/URL-derived name                                      |
| `description`      | Free-form note attached to this download. `null` = clear                                              |
| `metadata`         | Arbitrary key/value data. Use dot-notation: `set metadata.tag anime --id #1`. `null` = clear all     |
| `headers`          | Per-download HTTP headers merged on top of global (`effective = {...global, ...local}`). Use dot-notation. `null` = clear local overrides |

### Global propagation

When you change a global key like `targetChunkCount` or `minChunkSize`,
downloads that still carry the old global value pick up the new value. Downloads
with a per-download override are left alone unless you pass `--override`, which
forces the new value onto every download.

When `get --id` is used, the returned value is the **effective** value (global
fallback when no override is set). Use `get --id --json` for machine-readable output.

### JSON output

`list`, `get`, and `set` (when listing keys) all support `--json` to emit
raw JSON instead of formatted text — useful for scripts and agent consumers.

```bash
downloadx set maxParallel 5
downloadx set speedLimit 3mb
downloadx set targetPath ~/Downloads
downloadx set headers.Authorization "Bearer token"     # global header
downloadx set speedLimit 1mb --id 2                    # limit only download #2
downloadx set headers.X-Custom myval --id 2            # per-download header
downloadx set speedLimit null --id 2                   # clear override → follow global
downloadx set minChunkSize 2mb --override              # force onto every download
downloadx get                                          # show all config values
downloadx get --json                                   # machine-readable
downloadx get speedLimit                               # show one value
downloadx get --id 2 --json                            # per-download effective values
```

The daemon's cache directory (`~/.local/share/downloadx/cache`) is fixed at
daemon startup and is not a runtime-configurable key. In-progress `.part`
files are stored there as `{id}.part` — independent of the filename — so
renaming a download mid-flight never loses progress.

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
