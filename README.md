# downloadx

An IDM-style, runtime-agnostic download manager for TypeScript — distributed
as a library and a daemon-based CLI.

This repository is a Bun monorepo. The TypeScript packages share an
`apps/` layout; a Dart/Flutter port of the core lives alongside them.

| Package                                                        | Path                  | Description                                                                                                                          |
| -------------------------------------------------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| [`@downloadx/core`](./apps/downloadx/README.md)                | `apps/downloadx`      | The core library — parallel chunked downloads, dynamic splitting, resume across restarts, injected I/O so it runs in any runtime.    |
| [`@downloadx/cli`](./apps/cli/README.md)                       | `apps/cli`            | A daemon-based CLI built on the library — keeps downloads running in the background, talks to the daemon over a Unix domain socket. |
| [`downloadx` (Dart/Flutter)](./apps/downloadx_dart/README.md)  | `apps/downloadx_dart` | A faithful Dart port of the core for Flutter and Dart apps — same feature set, with a built-in `dart:io` backend so no I/O wiring is needed and a meta sidecar that's interchangeable with the TypeScript core. |
| [`dlx` (Flutter UI)](./apps/dlx_ui/README.md)                  | `apps/dlx_ui`         | A cross-platform (Linux/Windows/Android) graphical download manager built on the Dart engine — live download list, global/per-download config, and a graphical "watch" with a segment bar and a live stacked speed chart. |

The TypeScript packages are published to npm:

- [`@downloadx/core`](https://npmjs.com/package/@downloadx/core)
- [`@downloadx/cli`](https://npmjs.com/package/@downloadx/cli)

## Development

```bash
bun install
bun run test        # vitest, both packages
bun run typecheck   # tsc, both packages
bun run build       # both packages
```

Each package's README documents its own test layout and commands. See
**[proje.md](./proje.md)** for a file-by-file guide to the codebase and the
rules to follow when making changes.

## License

MIT
