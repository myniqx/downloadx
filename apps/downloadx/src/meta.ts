import { META_EXT, META_SCHEMA_VERSION } from './constants.js';
import type {
  ChunkSnapshot,
  DownloadState,
  InjectedFunctions,
  MetaFile,
  ProbeResult,
} from './types.js';

/**
 * Sidecar JSON persisted under the cache directory:
 *   `{cachePath}/{id}.downloadx.json`
 *
 * The file is keyed by download id (not filename) so it can be written before
 * the probe completes — that lets `createDownloadX` rebuild its in-memory list
 * from disk on next startup, even for downloads that never started.
 *
 * Written atomically: write-to-tmp then rename, so a crash in the middle of
 * `persistMeta()` can't corrupt an existing valid meta file.
 */

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder('utf-8', { fatal: true });

export interface MetaLocator {
  /** Directory the meta JSON lives in (usually cachePath). */
  dir: string;
  /** Download id — the meta filename is `{id}.downloadx.json`. */
  id: string;
}

export function metaPath(io: InjectedFunctions, locator: MetaLocator): string {
  return io.joinPath(locator.dir, `${locator.id}${META_EXT}`);
}

function tmpPath(target: string): string {
  return `${target}.tmp`;
}

export interface CreateEmptyMetaInput {
  id: string;
  url: string;
  now?: () => number;
}

/**
 * Meta for a download that has been registered but not probed yet. Fields that
 * depend on the probe (filename, finalUrl, totalSize, etc.) start as null/zero
 * and are filled in by {@link applyProbeToMeta} once the probe completes.
 */
export function createEmptyMeta(input: CreateEmptyMetaInput): MetaFile {
  const ts = (input.now ?? Date.now)();
  return {
    schemaVersion: META_SCHEMA_VERSION,
    id: input.id,
    url: input.url,
    finalUrl: null,
    filename: null,
    totalSize: null,
    acceptsRanges: false,
    etag: null,
    lastModified: null,
    contentType: null,
    createdAt: ts,
    updatedAt: ts,
    state: 'idle',
    chunks: [],
    addedAt: ts,
    completedAt: null,
    errorMessage: null,
    speedLimit: null,
    targetChunkCount: null,
    targetPath: null,
    minChunkSize: null,
    journal: null,
  };
}

export interface CreateMetaInput {
  id: string;
  url: string;
  probe: ProbeResult;
  chunks: ChunkSnapshot[];
  now?: () => number;
}

/** Builds a fresh meta directly from a probe result (used when no prior meta exists). */
export function createMeta(input: CreateMetaInput): MetaFile {
  const meta = createEmptyMeta(
    input.now !== undefined
      ? { id: input.id, url: input.url, now: input.now }
      : { id: input.id, url: input.url },
  );
  return applyProbeToMeta(meta, input.probe, input.chunks);
}

/** Merges a probe result into an existing meta, returning the same object. */
export function applyProbeToMeta(
  meta: MetaFile,
  probe: ProbeResult,
  chunks: ChunkSnapshot[],
): MetaFile {
  meta.finalUrl = probe.finalUrl;
  meta.filename = probe.filename;
  meta.totalSize = probe.totalSize;
  meta.acceptsRanges = probe.acceptsRanges;
  meta.etag = probe.etag;
  meta.lastModified = probe.lastModified;
  meta.contentType = probe.contentType;
  meta.chunks = chunks;
  meta.updatedAt = Date.now();
  return meta;
}

export async function loadMeta(
  io: InjectedFunctions,
  locator: MetaLocator,
): Promise<MetaFile | null> {
  const path = metaPath(io, locator);
  if (!(await io.exists(path))) return null;
  try {
    const buf = await io.readFile(path);
    const text = textDecoder.decode(buf);
    const parsed: unknown = JSON.parse(text);
    const validated = validate(parsed);
    return validated;
  } catch {
    // Corrupt meta → treat as missing so a fresh download can start. The old
    // file is left on disk so the user can inspect it if needed.
    return null;
  }
}

/**
 * Scans `dir` for `*.downloadx.json` files and loads each one sequentially.
 * Corrupt or schema-mismatched files are skipped (left on disk). Sequential
 * instead of parallel because some injected I/O backends may not handle high
 * concurrency, and restore happens once at startup — latency isn't critical.
 */
export async function listMetaFiles(io: InjectedFunctions, dir: string): Promise<MetaFile[]> {
  if (!(await io.exists(dir))) return [];
  const entries = await io.listDir(dir);
  const out: MetaFile[] = [];
  for (const name of entries) {
    if (!name.endsWith(META_EXT)) continue;
    const id = name.slice(0, -META_EXT.length);
    const meta = await loadMeta(io, { dir, id });
    if (meta !== null) out.push(meta);
  }
  return out;
}

export async function persistMeta(
  io: InjectedFunctions,
  locator: MetaLocator,
  meta: MetaFile,
): Promise<void> {
  await io.mkdir(locator.dir);
  const target = metaPath(io, locator);
  const tmp = tmpPath(target);
  const payload: MetaFile = { ...meta, updatedAt: Date.now() };
  const encoded = textEncoder.encode(JSON.stringify(payload, null, 2));
  await io.writeFile(tmp, encoded);
  await io.rename(tmp, target);
}

export async function deleteMeta(io: InjectedFunctions, locator: MetaLocator): Promise<void> {
  const target = metaPath(io, locator);
  await io.unlink(target);
}

/** Updates an existing meta object in place and returns it for chaining. */
export function updateMeta(
  meta: MetaFile,
  patch: Partial<
    Pick<
      MetaFile,
      | 'state'
      | 'chunks'
      | 'speedLimit'
      | 'targetChunkCount'
      | 'targetPath'
      | 'completedAt'
      | 'errorMessage'
    >
  >,
): MetaFile {
  if (patch.state !== undefined) meta.state = patch.state;
  if (patch.chunks !== undefined) meta.chunks = patch.chunks;
  if ('speedLimit' in patch) meta.speedLimit = patch.speedLimit ?? null;
  if ('targetChunkCount' in patch) meta.targetChunkCount = patch.targetChunkCount ?? null;
  if ('targetPath' in patch) meta.targetPath = patch.targetPath ?? null;
  if ('completedAt' in patch) meta.completedAt = patch.completedAt ?? null;
  if ('errorMessage' in patch) meta.errorMessage = patch.errorMessage ?? null;
  meta.updatedAt = Date.now();
  return meta;
}

/**
 * Decides whether a meta file represents the same remote resource a fresh
 * probe describes. Compares ETag first (strong), then Last-Modified, then
 * total size. If none match confidently, we can't trust resume → return false.
 */
export function canResumeAgainst(meta: MetaFile, probe: ProbeResult): boolean {
  if (meta.schemaVersion !== META_SCHEMA_VERSION) return false;
  if (meta.totalSize !== probe.totalSize) return false;
  if (meta.etag !== null && probe.etag !== null) {
    return meta.etag === probe.etag;
  }
  if (meta.lastModified !== null && probe.lastModified !== null) {
    return meta.lastModified === probe.lastModified;
  }
  // No validators — size match is the only signal we have. It's weak, but
  // better than forcing a restart every time.
  return true;
}

/** Maps a raw download state onto what should be persisted on pause/crash. */
export function dehydrateState(state: DownloadState): DownloadState {
  // `downloading` is never durable — if we crashed we were paused.
  if (state === 'downloading' || state === 'probing') return 'paused';
  return state;
}

function validate(value: unknown): MetaFile {
  if (typeof value !== 'object' || value === null) throw new Error('meta: not an object');
  const v = value as Record<string, unknown>;
  if (v['schemaVersion'] !== META_SCHEMA_VERSION) {
    throw new Error(`meta: unsupported schemaVersion ${String(v['schemaVersion'])}`);
  }
  assertString(v, 'id');
  assertString(v, 'url');
  assertNullableString(v, 'finalUrl');
  assertNullableString(v, 'filename');
  assertNullableNumber(v, 'totalSize');
  assertBoolean(v, 'acceptsRanges');
  assertNullableString(v, 'etag');
  assertNullableString(v, 'lastModified');
  assertNullableString(v, 'contentType');
  assertNumber(v, 'createdAt');
  assertNumber(v, 'updatedAt');
  assertString(v, 'state');
  if (!Array.isArray(v['chunks'])) throw new Error('meta: chunks must be array');
  const chunks = v['chunks'].map((c, i) => validateChunk(c, i));
  assertNumber(v, 'addedAt');
  assertNullableNumber(v, 'completedAt');
  assertNullableString(v, 'errorMessage');
  assertNullableNumber(v, 'speedLimit');
  assertNullableNumber(v, 'targetChunkCount');
  assertNullableString(v, 'targetPath');
  const minChunkSize = 'minChunkSize' in v ? v['minChunkSize'] : null;
  const journal = 'journal' in v ? v['journal'] : null;
  return {
    ...(v as unknown as MetaFile),
    chunks,
    minChunkSize: typeof minChunkSize === 'number' ? minChunkSize : null,
    journal: typeof journal === 'boolean' ? journal : null,
  };
}

function validateChunk(value: unknown, index: number): ChunkSnapshot {
  if (typeof value !== 'object' || value === null) {
    throw new Error(`meta: chunk[${index}] not an object`);
  }
  const c = value as Record<string, unknown>;
  assertString(c, 'id');
  assertNumber(c, 'offset');
  assertNumber(c, 'length');
  assertNumber(c, 'downloadedBytes');
  assertString(c, 'status');
  assertString(c, 'quality');
  assertNumber(c, 'retries');
  return value as ChunkSnapshot;
}

function assertString(obj: Record<string, unknown>, key: string): void {
  if (typeof obj[key] !== 'string') throw new Error(`meta: ${key} must be string`);
}
function assertNullableString(obj: Record<string, unknown>, key: string): void {
  const v = obj[key];
  if (v !== null && typeof v !== 'string') throw new Error(`meta: ${key} must be string|null`);
}
function assertNumber(obj: Record<string, unknown>, key: string): void {
  if (typeof obj[key] !== 'number') throw new Error(`meta: ${key} must be number`);
}
function assertNullableNumber(obj: Record<string, unknown>, key: string): void {
  const v = obj[key];
  if (v !== null && typeof v !== 'number') throw new Error(`meta: ${key} must be number|null`);
}
function assertBoolean(obj: Record<string, unknown>, key: string): void {
  if (typeof obj[key] !== 'boolean') throw new Error(`meta: ${key} must be boolean`);
}
