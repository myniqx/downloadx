import type { Chunk } from './chunk.js';

export interface PlanOptions {
  totalSize: number;
  targetChunkCount: number;
  minChunkSize: number;
  /** Bytes already placed on disk per offset-sorted plan index (for resume). */
  resumeFrom?: ReadonlyArray<{ offset: number; length: number; downloadedBytes: number }>;
}

export interface ChunkPlan {
  offset: number;
  length: number;
  downloadedBytes: number;
}

/**
 * Divides a `totalSize` byte file into at most `targetChunkCount` contiguous
 * chunks, each no smaller than `minChunkSize` (except the last, which gets
 * the remainder). Single-chunk fallback when the file is smaller than
 * `minChunkSize`.
 */
export function planChunks(opts: PlanOptions): ChunkPlan[] {
  if (opts.resumeFrom && opts.resumeFrom.length > 0) {
    // Preserve the historical plan on resume so offsets line up with what's
    // already on disk.
    return opts.resumeFrom.map((c) => ({ ...c }));
  }
  if (opts.totalSize <= 0) {
    return [{ offset: 0, length: 0, downloadedBytes: 0 }];
  }
  if (opts.totalSize <= opts.minChunkSize || opts.targetChunkCount <= 1) {
    return [{ offset: 0, length: opts.totalSize, downloadedBytes: 0 }];
  }
  const count = Math.min(
    opts.targetChunkCount,
    Math.max(1, Math.floor(opts.totalSize / opts.minChunkSize)),
  );
  const base = Math.floor(opts.totalSize / count);
  const plans: ChunkPlan[] = [];
  let offset = 0;
  for (let i = 0; i < count; i += 1) {
    const last = i === count - 1;
    const length = last ? opts.totalSize - offset : base;
    plans.push({ offset, length, downloadedBytes: 0 });
    offset += length;
  }
  return plans;
}

export interface SplitCandidate {
  chunk: Chunk;
  /** The slice taken from `chunk`'s tail, to be issued as a new chunk. */
  newRange: { offset: number; length: number };
  reason: 'slow' | 'failed' | 'completed-reassign';
}

export interface FindSplitOptions {
  /** All non-completed chunks currently part of the download. */
  activeChunks: readonly Chunk[];
  /** Upper bound (inclusive) on live chunk count. */
  maxChunks: number;
  /** Minimum bytes we'll leave on either side of a split. */
  minChunkSize: number;
  /** Why we're looking for a split (drives the `reason` field on the result). */
  trigger: 'slow' | 'failed' | 'completed-reassign';
}

/**
 * Picks the chunk best suited to donate its tail to a new worker.
 *
 * Scoring:
 *   1. Prefer `stalled` over `poor` over `good` (slower chunks lose more bytes).
 *   2. Among equal quality tiers, prefer the one with the most remaining bytes
 *      — that's the one we'll shave the most time off by parallelising.
 *
 * Returns `null` when:
 *   - we're already at max chunk count
 *   - no chunk has enough remaining bytes to split
 */
export function findSplitCandidate(opts: FindSplitOptions): SplitCandidate | null {
  if (opts.activeChunks.length >= opts.maxChunks) return null;

  const eligible = opts.activeChunks.filter(
    (c) =>
      c.status === 'downloading' &&
      c.remainingBytes >= opts.minChunkSize * 2,
  );
  if (eligible.length === 0) return null;

  const scored = eligible
    .map((chunk) => ({ chunk, score: scoreChunk(chunk) }))
    .sort((a, b) => b.score - a.score);

  const pick = scored[0];
  if (pick === undefined) return null;

  const newRange = pick.chunk.truncateTail(opts.minChunkSize);
  if (newRange === null) return null;

  return {
    chunk: pick.chunk,
    newRange,
    reason: opts.trigger,
  };
}

function scoreChunk(chunk: Chunk): number {
  const qualityWeight =
    chunk.quality === 'stalled' ? 3 : chunk.quality === 'poor' ? 2 : 1;
  // Remaining bytes normalised to MiB so the quality multiplier dominates
  // for comparable remainders, but size still breaks ties.
  const remainingMiB = chunk.remainingBytes / (1024 * 1024);
  return qualityWeight * 1000 + remainingMiB;
}
