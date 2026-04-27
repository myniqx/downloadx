import type {
  ExistsFn,
  JoinPathFn,
  MkdirFn,
  ReadFileFn,
  RenameFn,
  UnlinkFn,
  WriteChunkFn,
  WriteFileFn,
} from '../../src/types.js';

/**
 * In-memory file system emulating the subset of POSIX semantics downloadx
 * needs: mkdir -p, random-access write, read, rename, unlink, existence.
 *
 * Each file is a single growing Uint8Array — writeChunk expands it as needed.
 * Directories are tracked as a flat Set of canonical paths.
 *
 * Used by every test, including concurrent writers (the underlying JS event
 * loop guarantees `writeChunk` resolves atomically per call).
 */
export class MockFs {
  private readonly files = new Map<string, Uint8Array>();
  private readonly dirs = new Set<string>();

  readonly joinPath: JoinPathFn = (...segments: string[]): string => {
    if (segments.length === 0) return '';
    const joined = segments
      .map((s, i) => (i === 0 ? s.replace(/\/+$/u, '') : s.replace(/^\/+|\/+$/gu, '')))
      .filter((s) => s.length > 0)
      .join('/');
    return joined.length === 0 ? segments[0] ?? '' : joined;
  };

  readonly mkdir: MkdirFn = async (path: string) => {
    const parts = path.split('/').filter((p) => p.length > 0);
    let cursor = path.startsWith('/') ? '/' : '';
    for (const part of parts) {
      cursor = cursor === '/' ? `/${part}` : cursor.length === 0 ? part : `${cursor}/${part}`;
      this.dirs.add(cursor);
    }
  };

  readonly exists: ExistsFn = async (path: string) =>
    this.files.has(path) || this.dirs.has(path);

  readonly writeChunk: WriteChunkFn = async (path, offset, buffer) => {
    const existing = this.files.get(path);
    const requiredSize = offset + buffer.length;
    const next = existing && existing.length >= requiredSize
      ? existing
      : growTo(existing, requiredSize);
    next.set(buffer, offset);
    this.files.set(path, next);
  };

  readonly readFile: ReadFileFn = async (path) => {
    const buf = this.files.get(path);
    if (buf === undefined) throw new Error(`MockFs: not found: ${path}`);
    // Return a copy so callers can't mutate the stored file accidentally.
    return new Uint8Array(buf);
  };

  readonly writeFile: WriteFileFn = async (path, buffer) => {
    this.files.set(path, new Uint8Array(buffer));
  };

  readonly rename: RenameFn = async (from, to) => {
    const buf = this.files.get(from);
    if (buf === undefined) throw new Error(`MockFs: rename source missing: ${from}`);
    this.files.set(to, buf);
    this.files.delete(from);
  };

  readonly unlink: UnlinkFn = async (path) => {
    this.files.delete(path);
  };

  // Test inspection helpers — not part of the InjectedFunctions surface.
  peek(path: string): Uint8Array | undefined {
    const b = this.files.get(path);
    return b === undefined ? undefined : new Uint8Array(b);
  }

  hasFile(path: string): boolean {
    return this.files.has(path);
  }

  hasDir(path: string): boolean {
    return this.dirs.has(path);
  }

  listFiles(): string[] {
    return Array.from(this.files.keys()).sort();
  }

  asIo(): {
    mkdir: MkdirFn;
    exists: ExistsFn;
    writeChunk: WriteChunkFn;
    readFile: ReadFileFn;
    writeFile: WriteFileFn;
    rename: RenameFn;
    unlink: UnlinkFn;
    joinPath: JoinPathFn;
  } {
    return {
      mkdir: this.mkdir,
      exists: this.exists,
      writeChunk: this.writeChunk,
      readFile: this.readFile,
      writeFile: this.writeFile,
      rename: this.rename,
      unlink: this.unlink,
      joinPath: this.joinPath,
    };
  }
}

function growTo(existing: Uint8Array | undefined, size: number): Uint8Array {
  const next = new Uint8Array(size);
  if (existing !== undefined) next.set(existing, 0);
  return next;
}
