# downloadx

An IDM-style, runtime-agnostic download manager for TypeScript — distributed
as a library and a daemon-based CLI.

This repository is a Bun monorepo containing two packages, each with its own
README:

| Package                                                        | Path             | Description                                                                                                                          |
| -------------------------------------------------------------- | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| [`@downloadx/core`](./apps/downloadx/README.md)                | `apps/downloadx` | The core library — parallel chunked downloads, dynamic splitting, resume across restarts, injected I/O so it runs in any runtime.    |
| [`@downloadx/cli`](./apps/cli/README.md)                       | `apps/cli`       | A daemon-based CLI built on the library — keeps downloads running in the background, talks to the daemon over a Unix domain socket. |

Both are also published to npm:

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
