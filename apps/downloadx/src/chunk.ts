import { QUALITY_POOR_RATIO, QUALITY_STALLED_RATIO, QUALITY_WARMUP_MS } from './constants.js';
import { TypedEventEmitter } from './events.js';
import { HttpStatusError, withRetry } from './retry.js';
import { SpeedTracker } from './speedTracker.js';
import type {
  ChunkLifecyclePayload,
  ChunkProgressPayload,
  ChunkQuality,
  ChunkSnapshot,
  ChunkStatus,
  DownloadEventMap,
  FetchFn,
  FetchResponse,
  WriteChunkFn,
} from './types.js';

export interface ChunkParams {
  id: string;
  downloadId: string;
  url: string;
  targetFilePath: string;
  offset: number;
  length: number;
  /** Bytes already written from a previous session (resume). */
  initialDownloadedBytes: number;
  acceptsRanges: boolean;
  headers: Record<string, string>;
  maxRetries: number;
  retryDelay: number;
  retryBackoff: number;
  speedSampleWindow: number;
  requestTimeout?: number;
  fetch: FetchFn;
  writeChunk: WriteChunkFn;
  emitter: TypedEventEmitter<DownloadEventMap>;
  /** Optional throttle hook — called with bytes-just-read before write. */
  throttle?: (bytes: number) => Promise<void>;
  /** Reference speed for quality classification (bytes/sec). */
  medianSpeedRef: () => number;
  /** Clock, overridable for deterministic tests. */
  now?: () => number;
}

/**
 * A single byte range being downloaded. Chunks are independent; a Download
 * owns many of them and orchestrates splits/reassignments.
 *
 * Each chunk:
 *   - issues one HTTP request per `run()` attempt
 *   - streams the body, writing to `targetFilePath` at `offset + progress`
 *   - emits progress / lifecycle / quality events
 *   - supports abort via {@link pause}, with resume honouring bytes written
 *
 * Chunks are NOT reused — a fresh instance is constructed for every attempt
 * (including after split or reassign), so state stays straightforward.
 */
export class Chunk {
  readonly id: string;
  readonly downloadId: string;
  readonly offset: number;
  /** Mutable: a chunk's length shrinks when part of it is reassigned. */
  private _length: number;

  private _status: ChunkStatus = 'pending';
  private _downloadedBytes: number;
  private _quality: ChunkQuality = 'good';
  private _retries = 0;
  private _lastError: string | undefined;

  private readonly tracker: SpeedTracker;
  private abortController: AbortController | null = null;
  private readonly params: ChunkParams;
  private readonly now: () => number;

  constructor(params: ChunkParams) {
    this.params = params;
    this.id = params.id;
    this.downloadId = params.downloadId;
    this.offset = params.offset;
    this._length = params.length;
    this._downloadedBytes = params.initialDownloadedBytes;
    this.now = params.now ?? Date.now;
    this.tracker = new SpeedTracker(params.speedSampleWindow, this.now);
  }

  get length(): number {
    return this._length;
  }

  get status(): ChunkStatus {
    return this._status;
  }

  get downloadedBytes(): number {
    return this._downloadedBytes;
  }

  get remainingBytes(): number {
    return Math.max(0, this._length - this._downloadedBytes);
  }

  get quality(): ChunkQuality {
    return this._quality;
  }

  get speedTracker(): SpeedTracker {
    return this.tracker;
  }

  snapshot(): ChunkSnapshot {
    const snap: ChunkSnapshot = {
      id: this.id,
      offset: this.offset,
      length: this._length,
      downloadedBytes: this._downloadedBytes,
      status: this._status,
      quality: this._quality,
      retries: this._retries,
    };
    if (this._lastError !== undefined) snap.lastError = this._lastError;
    return snap;
  }

  /**
   * Shrink this chunk so the tail portion can be given to another chunk.
   * Returns the byte range that was removed, or null if the chunk is too
   * close to completion to split safely.
   */
  truncateTail(minRemaining: number): { offset: number; length: number } | null {
    const remaining = this.remainingBytes;
    if (remaining < minRemaining * 2) return null;
    // Cut the unclaimed half — leave at least `minRemaining` for ourselves.
    const keepFromEnd = Math.floor(remaining / 2);
    const newLength = this._length - keepFromEnd;
    const removedOffset = this.offset + newLength;
    const removedLength = keepFromEnd;
    this._length = newLength;
    return { offset: removedOffset, length: removedLength };
  }

  /** Fires abort; resume is possible if `run()` is called again afterwards. */
  pause(): void {
    if (this._status === 'completed' || this._status === 'failed') return;
    this.setStatus('paused');
    this.abortController?.abort();
  }

  /** Permanent stop — status becomes `failed` with reason. */
  fail(reason: string): void {
    this._lastError = reason;
    this.setStatus('failed');
    this.abortController?.abort();
  }

  /** Marks this chunk as reassigned (its range was moved to another chunk). */
  markReassigned(): void {
    this.setStatus('reassigned');
    this.abortController?.abort();
  }

  /**
   * Runs the download. Resolves when the chunk completes, fails permanently,
   * or is paused / reassigned (in which case status reflects the reason).
   */
  async run(): Promise<void> {
    if (this._status === 'completed') return;
    if (this._downloadedBytes >= this._length) {
      this.setStatus('completed');
      return;
    }

    this.setStatus('downloading');

    try {
      await withRetry(
        async (attempt) => {
          this._retries = attempt;
          await this.executeOnce();
        },
        {
          maxRetries: this.params.maxRetries,
          retryDelay: this.params.retryDelay,
          retryBackoff: this.params.retryBackoff,
          onRetry: (info) => {
            this._lastError = toMessage(info.error);
          },
        },
      );
      if (this._status === 'downloading') {
        this.setStatus('completed');
      }
    } catch (err) {
      if (this._status === 'paused' || this._status === 'reassigned') return;
      this._lastError = toMessage(err);
      this.setStatus('failed');
      this.params.emitter.emit('error', {
        downloadId: this.downloadId,
        chunkId: this.id,
        error: err instanceof Error ? err : new Error(this._lastError),
        fatal: false,
      });
    }
  }

  private async executeOnce(): Promise<void> {
    this.abortController = new AbortController();
    const controller = this.abortController;
    const timeoutTimer = this.params.requestTimeout !== undefined
      ? setTimeout(() => controller.abort(new Error('Request timeout')), this.params.requestTimeout)
      : null;

    try {
      const rangeStart = this.offset + this._downloadedBytes;
      const rangeEnd = this.offset + this._length - 1;
      const headers: Record<string, string> = { ...this.params.headers };
      if (this.params.acceptsRanges) {
        headers.Range = `bytes=${rangeStart}-${rangeEnd}`;
      }
      const res = await this.params.fetch(this.params.url, {
        method: 'GET',
        headers,
        signal: controller.signal,
      });
      if (!res.ok) {
        throw new HttpStatusError(res.status, res.statusText);
      }
      await this.consumeBody(res);
    } finally {
      if (timeoutTimer !== null) clearTimeout(timeoutTimer);
    }
  }

  private async consumeBody(res: FetchResponse): Promise<void> {
    if (res.body === null) {
      // No stream — read whole body. Acceptable fallback for tiny chunks.
      const buf = new Uint8Array(await res.arrayBuffer());
      if (buf.length > 0) await this.writeBytes(buf);
      return;
    }
    const reader = res.body.getReader();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        if (value && value.length > 0) {
          if (this.params.throttle) await this.params.throttle(value.length);
          await this.writeBytes(value);
          // Status may have flipped during await (pause / reassign) — bail out
          // so we don't keep writing a stale stream.
          if (this._status !== 'downloading') {
            try {
              await reader.cancel();
            } catch {
              /* ignore */
            }
            return;
          }
        }
      }
    } finally {
      try {
        reader.releaseLock();
      } catch {
        /* ignore */
      }
    }
  }

  private async writeBytes(buf: Uint8Array): Promise<void> {
    const writeOffset = this.offset + this._downloadedBytes;
    await this.params.writeChunk(this.params.targetFilePath, writeOffset, buf);
    this._downloadedBytes += buf.length;
    this.tracker.record(buf.length);
    this.updateQuality();
    const progress = this.progressPayload();
    this.params.emitter.emit('chunkProgress', progress);
    this.params.emitter.emit('chunkQuality', progress);
  }

  private updateQuality(): void {
    if (!this.tracker.hasWarmedUp(QUALITY_WARMUP_MS)) {
      this._quality = 'good';
      return;
    }
    const median = this.params.medianSpeedRef();
    const mine = this.tracker.windowedSpeed;
    if (median <= 0 || mine <= 0) {
      this._quality = 'good';
      return;
    }
    const ratio = mine / median;
    if (ratio < QUALITY_STALLED_RATIO) this._quality = 'stalled';
    else if (ratio < QUALITY_POOR_RATIO) this._quality = 'poor';
    else this._quality = 'good';
  }

  private progressPayload(): ChunkProgressPayload {
    return {
      downloadId: this.downloadId,
      chunkId: this.id,
      offset: this.offset,
      length: this._length,
      downloadedBytes: this._downloadedBytes,
      instantSpeed: this.tracker.instantSpeed,
      windowedSpeed: this.tracker.windowedSpeed,
      quality: this._quality,
    };
  }

  private setStatus(next: ChunkStatus): void {
    if (this._status === next) return;
    this._status = next;
    const payload: ChunkLifecyclePayload = {
      downloadId: this.downloadId,
      chunkId: this.id,
      status: next,
    };
    this.params.emitter.emit('chunkLifecycle', payload);
  }
}

function toMessage(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}
