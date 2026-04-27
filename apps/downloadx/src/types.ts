/**
 * Core type definitions for downloadx.
 *
 * All I/O primitives are injected via {@link InjectedFunctions} so the package
 * can run in Node, Bun, Deno, edge runtimes, or any custom storage backend.
 */

// ---------------------------------------------------------------------------
// Injected I/O primitives
// ---------------------------------------------------------------------------

/** Minimal fetch signature, compatible with WHATWG fetch. */
export type FetchFn = (
  input: string | URL,
  init?: FetchInit,
) => Promise<FetchResponse>;

export interface FetchInit {
  method?: string;
  headers?: Record<string, string>;
  signal?: AbortSignal;
  body?: Uint8Array | string | null;
}

export interface FetchResponse {
  readonly status: number;
  readonly statusText: string;
  readonly ok: boolean;
  readonly headers: FetchHeaders;
  readonly body: ReadableStream<Uint8Array> | null;
  arrayBuffer(): Promise<ArrayBuffer>;
  text(): Promise<string>;
}

export interface FetchHeaders {
  get(name: string): string | null;
  has(name: string): boolean;
  forEach(cb: (value: string, name: string) => void): void;
}

/** Random access write — writes `buffer` to `path` starting at `offset`. */
export type WriteChunkFn = (
  path: string,
  offset: number,
  buffer: Uint8Array,
) => Promise<void>;

/** Read a file fully (used for meta JSON). */
export type ReadFileFn = (path: string) => Promise<Uint8Array>;

/** Write a file fully (used for meta JSON, atomic write is caller's job). */
export type WriteFileFn = (path: string, buffer: Uint8Array) => Promise<void>;

/** Create directory recursively. Must not throw if directory already exists. */
export type MkdirFn = (path: string) => Promise<void>;

/** Check whether a file or directory exists. */
export type ExistsFn = (path: string) => Promise<boolean>;

/** Rename (move) a file from `from` to `to`. */
export type RenameFn = (from: string, to: string) => Promise<void>;

/** Delete a file. Must not throw if file does not exist. */
export type UnlinkFn = (path: string) => Promise<void>;

/** Join path segments using the target platform separator. */
export type JoinPathFn = (...segments: string[]) => string;

/**
 * Full set of functions the package needs from the host environment.
 *
 * Consumers inject these once when creating the DownloadX instance. This allows
 * the package to run anywhere — Node, Bun, Deno, Workers, or a custom backend
 * (S3, Postgres, etc.) — without any runtime dependency.
 */
export interface InjectedFunctions {
  fetch: FetchFn;
  writeChunk: WriteChunkFn;
  readFile: ReadFileFn;
  writeFile: WriteFileFn;
  mkdir: MkdirFn;
  exists: ExistsFn;
  rename: RenameFn;
  unlink: UnlinkFn;
  joinPath: JoinPathFn;
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/** Strategy for splitting a download into chunks. */
export type ChunkMode = 'auto' | 'single' | 'fixed';

/**
 * Global configuration for a DownloadX manager instance.
 * All fields (except `io`) have sensible defaults; see `constants.ts`.
 */
export interface DownloadXConfig {
  /** Injected I/O functions. Required. */
  io: InjectedFunctions;

  /** Directory where finished files are written. */
  targetPath: string;

  /** Directory where in-progress meta files are written. Defaults to `targetPath`. */
  cachePath?: string;

  /** Max number of downloads running concurrently at the manager level. */
  maxParallel?: number;

  /** Default chunking strategy for new downloads. */
  chunkMode?: ChunkMode;

  /** Target number of chunks per download (upper bound, including splits). */
  targetChunkCount?: number;

  /** Minimum bytes remaining in a chunk before it can be split again. */
  minChunkSize?: number;

  /** Max HTTP retries per chunk before giving up. */
  maxRetries?: number;

  /** Base delay (ms) between retries. */
  retryDelay?: number;

  /** Exponential backoff multiplier applied per retry attempt. */
  retryBackoff?: number;

  /** Moving-average window (ms) used for chunk-quality decisions. */
  speedSampleWindow?: number;

  /** Global bandwidth limit in bytes/sec. 0 = unlimited. */
  speedLimit?: number;

  /** Extra HTTP headers sent on every probe/chunk request. */
  headers?: Record<string, string>;

  /** HTTP request timeout in ms. Undefined = no timeout. */
  requestTimeout?: number;
}

/** Per-download overrides passed to {@link DownloadX.addUrl}. */
export interface DownloadOptions {
  /** Override filename. Defaults to one inferred from URL / Content-Disposition. */
  filename?: string;

  /** Override chunk mode for this download. */
  chunkMode?: ChunkMode;

  /** Override target chunk count for this download. */
  targetChunkCount?: number;

  /** Override per-download speed limit (bytes/sec). 0 = unlimited. */
  speedLimit?: number;

  /** Override retry behaviour. */
  maxRetries?: number;
  retryDelay?: number;
  retryBackoff?: number;

  /** Extra HTTP headers merged with manager headers. */
  headers?: Record<string, string>;

  /** Override the download id. Defaults to sha256(url).slice(0, 16). */
  id?: string;

  /** Start the download immediately after addUrl. */
  autoStart?: boolean;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

export type DownloadState =
  | 'idle'
  | 'probing'
  | 'downloading'
  | 'paused'
  | 'completed'
  | 'error'
  | 'cancelled';

export type ChunkStatus =
  | 'pending'
  | 'downloading'
  | 'paused'
  | 'completed'
  | 'failed'
  | 'reassigned';

/** Qualitative health of a chunk, used by the dynamic splitter. */
export type ChunkQuality = 'good' | 'poor' | 'stalled';

/** Snapshot of a chunk, persisted to the meta file for resume. */
export interface ChunkSnapshot {
  id: string;
  offset: number;
  length: number;
  downloadedBytes: number;
  status: ChunkStatus;
  quality: ChunkQuality;
  retries: number;
  lastError?: string;
}

/** Result of the initial HTTP probe. */
export interface ProbeResult {
  url: string;
  finalUrl: string;
  totalSize: number | null;
  acceptsRanges: boolean;
  etag: string | null;
  lastModified: string | null;
  contentType: string | null;
  filename: string;
}

/** JSON shape persisted as `{filename}.downloadx.json`. */
export interface MetaFile {
  readonly schemaVersion: 1;
  readonly id: string;
  readonly url: string;
  readonly finalUrl: string;
  readonly filename: string;
  readonly totalSize: number | null;
  readonly acceptsRanges: boolean;
  readonly etag: string | null;
  readonly lastModified: string | null;
  readonly contentType: string | null;
  readonly createdAt: number;
  updatedAt: number;
  state: DownloadState;
  chunks: ChunkSnapshot[];
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

export interface ChunkProgressPayload {
  downloadId: string;
  chunkId: string;
  offset: number;
  length: number;
  downloadedBytes: number;
  instantSpeed: number;
  windowedSpeed: number;
  quality: ChunkQuality;
}

export interface ChunkLifecyclePayload {
  downloadId: string;
  chunkId: string;
  status: ChunkStatus;
}

export interface ChunkSplitPayload {
  downloadId: string;
  sourceChunkId: string;
  newChunkId: string;
  splitOffset: number;
  reason: 'slow' | 'failed' | 'completed-reassign';
}

export interface DownloadProgressPayload {
  downloadId: string;
  totalBytes: number | null;
  downloadedBytes: number;
  totalSpeed: number;
  activeChunks: number;
  percent: number | null;
}

export interface DownloadStatePayload {
  downloadId: string;
  previous: DownloadState;
  current: DownloadState;
}

export interface DownloadErrorPayload {
  downloadId: string;
  chunkId?: string;
  error: Error;
  fatal: boolean;
}

export interface DownloadCompletedPayload {
  downloadId: string;
  filename: string;
  totalBytes: number;
  durationMs: number;
}

/** Strict event map shared by Download and DownloadX emitters. */
export interface DownloadEventMap {
  progress: DownloadProgressPayload;
  chunkProgress: ChunkProgressPayload;
  chunkLifecycle: ChunkLifecyclePayload;
  chunkSplit: ChunkSplitPayload;
  chunkQuality: ChunkProgressPayload;
  stateChange: DownloadStatePayload;
  error: DownloadErrorPayload;
  completed: DownloadCompletedPayload;
}

export type DownloadEventName = keyof DownloadEventMap;

export type DownloadEventListener<E extends DownloadEventName> = (
  payload: DownloadEventMap[E],
) => void;
