/**
 * Core type definitions for downloadx.
 *
 * All I/O primitives are injected via {@link InjectedFunctions} so the package
 * can run in Node, Bun, Deno, edge runtimes, or any custom storage backend.
 */

// ---------------------------------------------------------------------------
// Injected I/O primitives
// ---------------------------------------------------------------------------

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
  /** Final URL after redirects (WHATWG `Response.url`). Optional for custom fetchers. */
  readonly url?: string;
  arrayBuffer(): Promise<ArrayBuffer>;
  text(): Promise<string>;
}

export interface FetchHeaders {
  get(name: string): string | null;
  has(name: string): boolean;
  forEach(cb: (value: string, name: string) => void): void;
}

/**
 * Full set of functions the package needs from the host environment.
 *
 * Consumers inject these once when creating the DownloadX instance. This allows
 * the package to run anywhere — Node, Bun, Deno, Workers, or a custom backend
 * (S3, Postgres, etc.) — without any runtime dependency.
 */
export interface InjectedFunctions {
  fetch: (input: string | URL, init?: FetchInit) => Promise<FetchResponse>;
  /** Random access write — writes `buffer` to `path` starting at `offset`. */
  writeChunk: (path: string, offset: number, buffer: Uint8Array) => Promise<void>;
  /** Read a file fully (used for meta JSON). */
  readFile: (path: string) => Promise<Uint8Array>;
  /** Write a file fully (used for meta JSON, atomic write is caller's job). */
  writeFile: (path: string, buffer: Uint8Array) => Promise<void>;
  /** Create directory recursively. Must not throw if directory already exists. */
  mkdir: (path: string) => Promise<void>;
  /** Check whether a file or directory exists. */
  exists: (path: string) => Promise<boolean>;
  /** Rename (move) a file from `from` to `to`. */
  rename: (from: string, to: string) => Promise<void>;
  /** Delete a file. Must not throw if file does not exist. */
  unlink: (path: string) => Promise<void>;
  /** Join path segments using the target platform separator. */
  joinPath: (...segments: string[]) => string;
  /** List entries inside a directory. Returns plain names, no paths. */
  listDir: (path: string) => Promise<string[]>;
  /** Optional: enables disk pre-allocation (`Download.alloc`). */
  truncate?: (path: string, size: number) => Promise<void>;
  /** Optional: enables the NDJSON event journal sidecar. */
  appendFile?: (path: string, buffer: Uint8Array) => Promise<void>;
  /** Optional: enables final size verification before rename. */
  fileSize?: (path: string) => Promise<number>;
  /** Optional: concatenates HLS segment files into a single output file. Falls back to binary concat if absent. */
  concatSegments?: (segments: string[], output: string) => Promise<void>;
}

// ---------------------------------------------------------------------------
// Global config interface — implemented by DownloadX, injected into Download
// to avoid snapshot copies and circular imports.
// ---------------------------------------------------------------------------

export interface DownloadConfig {
  readonly maxRetries: number;
  readonly retryDelay: number;
  readonly retryBackoff: number;
  readonly speedSampleWindow: number;
  readonly requestTimeout: number;
  readonly headers: Record<string, string>;
  readonly io: InjectedFunctions;
}

export interface GlobalConfig extends DownloadConfig {
  readonly targetPath: string;
  readonly cachePath: string;
  readonly maxParallel: number;
  readonly speedLimit: number;
  readonly targetChunkCount: number;
  readonly minChunkSize: number;
  readonly journal: boolean;
  readonly sharedThrottle: { consume: (bytes: number, signal?: AbortSignal) => Promise<void> };
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

  /**
   * Network idle timeout in ms: a chunk request is aborted (and retried) when
   * no bytes arrive for this long. Undefined = no timeout. This is NOT a cap
   * on total request duration — long downloads are unaffected while data flows.
   */
  requestTimeout?: number;

  /**
   * Write an NDJSON journal sidecar (`{filename}.downloadx.log`) recording
   * retries, splits, timeouts, and state changes. Requires `io.appendFile`.
   */
  journal?: boolean;
}

/** Minimal interface for the download manager — passed to HlsSession so it can
 *  register additional downloads (e.g. multi-stream HLS) without importing DownloadX. */
export interface DlxContext extends GlobalConfig {
  addUrl(url: string, options?: DownloadOptions): Promise<unknown>;
}

/** Per-download overrides passed to {@link DownloadX.addUrl}. */
export interface DownloadOptions {
  /** Override filename. Defaults to one inferred from URL / Content-Disposition. */
  filename?: string;

  /** Override target directory for this download's final file. Defaults to manager's targetPath. */
  targetPath?: string;

  /** Override chunk mode for this download. */
  chunkMode?: ChunkMode;

  /** Override target chunk count for this download. */
  targetChunkCount?: number;

  /** Override per-download speed limit (bytes/sec). 0 = unlimited. */
  speedLimit?: number;

  /** Override minimum chunk size for this download. */
  minChunkSize?: number;

  /** Write NDJSON diagnostic journal for this download. */
  journal?: boolean;

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

  /** Free-form note attached to this download. Persisted and returned in
   *  `describe()`; has no behavioural effect. */
  description?: string;

  /** Arbitrary key/value data attached to this download (e.g. sourceLink,
   *  fromExtension). Persisted and returned in `describe()`; has no
   *  behavioural effect. Intended for apps consuming the core. */
  metadata?: Record<string, string>;
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
  /** HLS segment mode: chunk writes from byte 0 into its own file rather than
   *  at an offset within a shared part file. Undefined for normal chunks. */
  isSegment?: boolean;
  /** HLS segment: the dedicated file this segment is written to. */
  targetFilePath?: string;
  /** HLS segment: source segment URI (resolved). */
  uri?: string;
  /** HLS segment: segment duration in seconds (from #EXTINF), for ETA. */
  durationSec?: number;
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
  isHls: boolean;
}

/** JSON shape persisted as `{id}.downloadx.json`. */
export interface MetaFile {
  readonly schemaVersion: number;
  readonly id: string;
  readonly url: string;
  finalUrl: string | null;
  filename: string | null;
  totalSize: number | null;
  acceptsRanges: boolean;
  etag: string | null;
  lastModified: string | null;
  contentType: string | null;
  readonly createdAt: number;
  updatedAt: number;
  state: DownloadState;
  chunks: ChunkSnapshot[];
  readonly addedAt: number;
  completedAt: number | null;
  errorMessage: string | null;
  speedLimit: number | null;
  targetChunkCount: number | null;
  targetPath: string | null;
  minChunkSize: number | null;
  journal: boolean | null;
  /** Whether the resolved resource is an HLS playlist. Persisted so resume can
   *  reconstruct segment chunks without re-probing. */
  isHls: boolean;
  /** Free-form note (see DownloadOptions.description). */
  description: string | null;
  /** Arbitrary key/value data (see DownloadOptions.metadata). */
  metadata: Record<string, string> | null;
  /** Per-download HTTP headers merged on top of global headers. */
  headers: Record<string, string> | null;
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
  /** Estimated remaining time in ms, or null when size/speed is unknown. */
  etaMs: number | null;
  /** Number of HLS segments downloaded so far. Undefined for non-HLS downloads. */
  hlsSegmentsDone?: number;
  /** Total HLS segment count. Undefined for non-HLS downloads. */
  hlsTotalSegments?: number;
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

/**
 * Machine-readable diagnostic record. Mirrors what the NDJSON journal stores,
 * so log consumers and event consumers see identical data.
 */
export interface DiagnosticPayload {
  downloadId: string;
  chunkId?: string;
  level: 'info' | 'warn' | 'error';
  /** Stable machine-readable code, e.g. `idle-timeout`, `chunk-split`, `range-not-honored`. */
  code: string;
  message: string;
  timestamp: number;
  data?: Record<string, unknown>;
}

/**
 * Compact, serialisable status report aimed at dashboards and LLM/agent
 * consumers. Produced by {@link Download.describe}.
 */
export interface DownloadDescription {
  id: string;
  url: string;
  filename: string | null;
  targetPath: string | null;
  addedAt: number;
  completedAt: number | null;
  errorMessage: string | null;
  description: string | null;
  metadata: Record<string, string> | null;
  state: DownloadState;
  totalBytes: number | null;
  downloadedBytes: number;
  percent: number | null;
  totalSpeedBps: number;
  etaMs: number | null;
  elapsedMs: number;
  activeChunks: number;
  totalChunks: number;
  chunks: Array<{
    id: string;
    status: ChunkStatus;
    quality: ChunkQuality;
    offset: number;
    length: number;
    downloadedBytes: number;
    retries: number;
  }>;
  recentDiagnostics: DiagnosticPayload[];
  /** Number of HLS segments downloaded so far. Undefined for non-HLS downloads. */
  hlsSegmentsDone?: number;
  /** Total HLS segment count. Undefined for non-HLS downloads. */
  hlsTotalSegments?: number;
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
  diagnostic: DiagnosticPayload;
}

export type DownloadEventName = keyof DownloadEventMap;

export type DownloadEventListener<E extends DownloadEventName> = (
  payload: DownloadEventMap[E],
) => void;
