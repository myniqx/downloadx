import { META_EXT, META_SCHEMA_VERSION } from './constants.js';
import type {
  ChunkSnapshot,
  DownloadState,
  InjectedFunctions,
  MetaFile,
  ProbeResult,
} from './types.js';

/**
 * Sidecar JSON persisted next to the download file:
 *   `{cachePath}/{filename}.downloadx.json`
 *
 * Written atomically: write-to-tmp then rename, so a crash in the middle of
 * `persist()` can't corrupt an existing valid meta file.
 */

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder('utf-8', { fatal: true });

export interface MetaLocator {
  /** Directory the meta JSON lives in (usually cachePath). */
  dir: string;
  /** Final filename of the download (without the `.downloadx.json` suffix). */
  filename: string;
}

export function metaPath(io: InjectedFunctions, locator: MetaLocator): string {
  return io.joinPath(locator.dir, `${locator.filename}${META_EXT}`);
}

function tmpPath(target: string): string {
  return `${target}.tmp`;
}

export interface CreateMetaInput {
  id: string;
  probe: ProbeResult;
  chunks: ChunkSnapshot[];
  now?: () => number;
}

export function createMeta(input: CreateMetaInput): MetaFile {
  const ts = (input.now ?? Date.now)();
  return {
    schemaVersion: META_SCHEMA_VERSION,
    id: input.id,
    url: input.probe.url,
    finalUrl: input.probe.finalUrl,
    filename: input.probe.filename,
    totalSize: input.probe.totalSize,
    acceptsRanges: input.probe.acceptsRanges,
    etag: input.probe.etag,
    lastModified: input.probe.lastModified,
    contentType: input.probe.contentType,
    createdAt: ts,
    updatedAt: ts,
    state: 'idle',
    chunks: input.chunks,
    speedLimit: null,
    targetChunkCount: null,
    targetPath: null,
  };
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
    Pick<MetaFile, 'state' | 'chunks' | 'speedLimit' | 'targetChunkCount' | 'targetPath'>
  >,
): MetaFile {
  if (patch.state !== undefined) meta.state = patch.state;
  if (patch.chunks !== undefined) meta.chunks = patch.chunks;
  if ('speedLimit' in patch) meta.speedLimit = patch.speedLimit ?? null;
  if ('targetChunkCount' in patch) meta.targetChunkCount = patch.targetChunkCount ?? null;
  if ('targetPath' in patch) meta.targetPath = patch.targetPath ?? null;
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
  assertString(v, 'finalUrl');
  assertString(v, 'filename');
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
  assertNullableNumber(v, 'speedLimit');
  assertNullableNumber(v, 'targetChunkCount');
  assertNullableString(v, 'targetPath');
  return { ...(v as unknown as MetaFile), chunks };
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
