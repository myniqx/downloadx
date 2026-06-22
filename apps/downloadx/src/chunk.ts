import {
  QUALITY_POOR_RATIO,
  QUALITY_STALLED_RATIO,
  QUALITY_WARMUP_MS,
  UNKNOWN_SIZE_LENGTH,
} from './constants.js';
import { TypedEventEmitter } from './events.js';
import { HttpStatusError, RangeNotHonoredError, withRetry } from './retry.js';
import { SpeedTracker } from './speedTracker.js';
import type {
  ChunkLifecyclePayload,
  ChunkProgressPayload,
  ChunkQuality,
  ChunkSnapshot,
  ChunkStatus,
  DownloadConfig,
  DownloadEventMap,
  FetchResponse,
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
  /** Validators sent as `If-Range` so a changed resource can't be spliced into stale bytes. */
  etag?: string | null;
  lastModified?: string | null;
  /** Live reference to download config — values read per-retry, not snapshotted. */
  global: DownloadConfig;
  /**
   * HLS segment mode. A segment chunk downloads a whole segment file from byte
   * 0 into its own `targetFilePath` (offset is always 0), is never split, and
   * — when the segment size is unknown — streams until EOF. Retry, throttle,
   * speed tracking and resume all behave exactly as for a normal chunk.
   */
  isSegment?: boolean;
  /** HLS segment: resolved source segment URI (for snapshot persistence). */
  uri?: string;
  /** HLS segment: segment duration in seconds (from #EXTINF), for ETA. */
  durationSec?: number;
  emitter: TypedEventEmitter<DownloadEventMap>;
  /** Optional throttle hook — called with bytes-just-read before write. */
  throttle?: (bytes: number, signal?: AbortSignal) => Promise<void>;
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
  /** Set when the failure carries scheduling meaning for the Download. */
  private _failureCode: 'range-not-honored' | null = null;

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
    this.tracker = new SpeedTracker(params.global.speedSampleWindow, this.now);
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

  get failureCode(): 'range-not-honored' | null {
    return this._failureCode;
  }

  /** True for HLS segment chunks — never split, written from byte 0. */
  get isSegment(): boolean {
    return this.params.isSegment ?? false;
  }

  get lastError(): string | undefined {
    return this._lastError;
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
    // Segment chunks carry extra fields so they can be rebuilt on resume.
    if (this.params.isSegment) {
      snap.isSegment = true;
      snap.targetFilePath = this.params.targetFilePath;
      if (this.params.uri !== undefined) snap.uri = this.params.uri;
      if (this.params.durationSec !== undefined) snap.durationSec = this.params.durationSec;
    }
    return snap;
  }

  /**
   * Shrink this chunk so the tail portion can be given to another chunk.
   * Returns the byte range that was removed, or null if the chunk is too
   * close to completion to split safely.
   */
  truncateTail(minRemaining: number): { offset: number; length: number } | null {
    // Segment chunks map 1:1 to a segment file and are never split.
    if (this.isSegment) return null;
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
   * Aborts the current attempt so the retry loop reissues the request from
   * the bytes already written. Used for stall recovery — the abort reason is
   * a plain Error (not AbortError), which the retry loop treats as transient.
   */
  restart(reason: string): void {
    if (this._status !== 'downloading') return;
    this.abortController?.abort(new Error(`restart: ${reason}`));
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
    this.params.global.addLog({
      code: 'chunk.initialized',
      params: { id: this.id, offset: this.offset, end: this.offset + this._length },
    });

    try {
      await withRetry(
        async () => {
          await this.executeOnce();
        },
        {
          maxRetries: this.params.global.maxRetries,
          retryDelay: this.params.global.retryDelay,
          retryBackoff: this.params.global.retryBackoff,
          onRetry: (info) => {
            this._retries += 1;
            this._lastError = toMessage(info.error);
            this.params.global.addLog({
              level: 'warn',
              code: 'chunk.retry',
              params: { id: this.id, attempt: info.attempt, message: this._lastError, delayMs: info.delayMs },
            });
          },
        },
      );
      if (this._status === 'downloading') {
        this.params.global.addLog({
          code: 'chunk.completed',
          params: { id: this.id, bytes: this._downloadedBytes },
        });
        this.setStatus('completed');
      }
    } catch (err) {
      if (this._status === 'paused' || this._status === 'reassigned') return;
      if (err instanceof RangeNotHonoredError) this._failureCode = 'range-not-honored';
      this._lastError = toMessage(err);
      this.params.global.addLog({
        level: 'error',
        code: 'chunk.failed',
        params: { id: this.id, message: this._lastError },
      });
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

    // Servers without range support always send the body from byte zero, so
    // partial progress cannot be resumed — discard it before re-requesting,
    // otherwise start-of-file bytes get written into the middle of the file.
    if (!this.params.acceptsRanges && this._downloadedBytes > 0) {
      this.params.global.addLog({
        level: 'warn',
        code: 'chunk.no-range-restart',
        params: { id: this.id, discarded: this._downloadedBytes },
      });
      this._downloadedBytes = 0;
    }

    // Idle timer: armed only while waiting on the network, so slow disks or
    // throttle waits can't trip it, and long downloads run as long as data
    // keeps arriving.
    let idleTimer: ReturnType<typeof setTimeout> | null = null;
    const clearIdle = (): void => {
      if (idleTimer !== null) {
        clearTimeout(idleTimer);
        idleTimer = null;
      }
    };
    const armIdle = (): void => {
      const ms = this.params.global.requestTimeout;
      if (ms === undefined) return;
      clearIdle();
      idleTimer = setTimeout(
        () => controller.abort(new Error(`idle timeout: no data received for ${ms}ms`)),
        ms,
      );
    };

    try {
      const rangeStart = this.offset + this._downloadedBytes;
      const headers: Record<string, string> = { ...this.params.global.headers };
      let rangeSent = false;
      const openEnded = this._length === UNKNOWN_SIZE_LENGTH;
      if (this.params.acceptsRanges) {
        headers.Range = openEnded
          ? `bytes=${rangeStart}-`
          : `bytes=${rangeStart}-${this.offset + this._length - 1}`;
        rangeSent = true;
        const validator = this.params.etag ?? this.params.lastModified;
        if (validator !== undefined && validator !== null) {
          headers['If-Range'] = validator;
        }
      }
      this.params.global.addLog({
        code: 'chunk.fetch.started',
        params: { id: this.id, url: this.params.url, range: headers.Range ?? 'none' },
      });
      armIdle();
      const res = await this.params.global.io.fetch(this.params.url, {
        method: 'GET',
        headers,
        signal: controller.signal,
      });
      clearIdle();
      if (!res.ok) {
        throw new HttpStatusError(res.status, res.statusText);
      }
      // A 200 on a ranged request means the server (or an If-Range mismatch)
      // ignored the range — consuming it would write the whole file at this
      // chunk's offset. The only safe 200 is an open-ended request from 0,
      // where the full body is byte-identical to what we asked for.
      if (rangeSent && res.status !== 206 && !(openEnded && rangeStart === 0)) {
        throw new RangeNotHonoredError();
      }
      await this.consumeBody(res, controller.signal, armIdle, clearIdle);
    } finally {
      clearIdle();
    }
  }

  private async consumeBody(
    res: FetchResponse,
    signal: AbortSignal,
    armIdle: () => void,
    clearIdle: () => void,
  ): Promise<void> {
    if (res.body === null) {
      // No stream — read whole body. Acceptable fallback for tiny chunks.
      armIdle();
      const buf = this.clampToRemaining(new Uint8Array(await res.arrayBuffer()));
      clearIdle();
      if (buf.length > 0) await this.writeBytes(buf);
      return;
    }
    const reader = res.body.getReader();
    try {
      while (true) {
        armIdle();
        const { done, value } = await reader.read();
        clearIdle();
        if (done) break;
        if (value === undefined || value.length === 0) continue;
        // Never write past our end: a split may have shrunk `_length` while
        // this stream was in flight, and a misbehaving server may send more
        // than the requested range.
        const slice = this.clampToRemaining(value);
        if (slice.length > 0) {
          if (this.params.throttle) await this.params.throttle(slice.length, signal);
          await this.writeBytes(slice);
        }
        // Stop once our (possibly shrunk) range is fully written, or when
        // status flipped during an await (pause / reassign).
        if (this._downloadedBytes >= this._length || this._status !== 'downloading') {
          try {
            await reader.cancel();
          } catch {
            /* ignore */
          }
          return;
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

  /** Slice `buf` so the write cannot exceed this chunk's current length. */
  private clampToRemaining(buf: Uint8Array): Uint8Array {
    const remaining = this._length - this._downloadedBytes;
    if (remaining <= 0) return buf.subarray(0, 0);
    return buf.length > remaining ? buf.subarray(0, remaining) : buf;
  }

  private async writeBytes(buf: Uint8Array): Promise<void> {
    const writeOffset = this.offset + this._downloadedBytes;
    await this.params.global.io.writeChunk(this.params.targetFilePath, writeOffset, buf);
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
