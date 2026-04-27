import type { ChunkMode } from './types.js';

/**
 * Package identity. Kept in one place so it can be changed if the npm name
 * ever collides; the value is used in meta-file extension, temp-file suffix,
 * and public-facing strings.
 */
export const APP_NAME = 'downloadx' as const;

/** Extension appended to produce the sidecar meta file. */
export const META_EXT = '.downloadx.json' as const;

/** Extension used for in-progress downloads (renamed away on completion). */
export const TEMP_EXT = '.downloadx.part' as const;

/** Current meta-file schema version. Bump when breaking persisted shape. */
export const META_SCHEMA_VERSION = 1 as const;

/** Config defaults applied when a field is omitted by the consumer. */
export const DEFAULT_CONFIG = {
  maxParallel: 3,
  chunkMode: 'auto' as ChunkMode,
  targetChunkCount: 4,
  minChunkSize: 1024 * 1024, // 1 MiB — smaller than this is not worth splitting
  maxRetries: 5,
  retryDelay: 1_000,
  retryBackoff: 2,
  speedSampleWindow: 3_000, // ms used by the moving-average hot/slow detector
  speedLimit: 0, // bytes/sec; 0 disables throttling
  requestTimeout: 30_000,
} as const;

/**
 * Threshold ratios used by the chunk-quality classifier.
 *
 * A chunk is considered `poor` when its windowed speed is below
 * {@link QUALITY_POOR_RATIO} × the manager's median chunk speed, and
 * `stalled` when it drops below {@link QUALITY_STALLED_RATIO} × median.
 * These are intentionally not user-configurable yet — tune here first, expose
 * as config fields only once the heuristic is proven in real workloads.
 */
export const QUALITY_POOR_RATIO = 0.5;
export const QUALITY_STALLED_RATIO = 0.15;

/** Grace period (ms) before quality is evaluated after a chunk starts. */
export const QUALITY_WARMUP_MS = 1_500;

/** HTTP status codes that should never be retried (client errors). */
export const NON_RETRYABLE_STATUS = new Set<number>([
  400, 401, 403, 404, 405, 406, 409, 410, 414, 415, 416, 422, 451,
]);

/** HTTP status codes we treat as transient and worth retrying. */
export const RETRYABLE_STATUS = new Set<number>([
  408, 425, 429, 500, 502, 503, 504,
]);
