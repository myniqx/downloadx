import { Chunk } from './chunk.js';
import { findSplitCandidate, planChunks } from './chunkScheduler.js';
import { DEFAULT_CONFIG, TEMP_EXT } from './constants.js';
import { TypedEventEmitter } from './events.js';
import {
  canResumeAgainst,
  createMeta,
  deleteMeta,
  dehydrateState,
  loadMeta,
  persistMeta,
  updateMeta,
} from './meta.js';
import { probeUrl } from './probe.js';
import { AggregateSpeed } from './speedTracker.js';
import { Throttle } from './throttle.js';
import type {
  ChunkSnapshot,
  DownloadEventMap,
  DownloadOptions,
  DownloadState,
  InjectedFunctions,
  MetaFile,
  ProbeResult,
} from './types.js';

export interface DownloadInternalConfig {
  io: InjectedFunctions;
  targetPath: string;
  cachePath: string;
  maxParallel: number;
  targetChunkCount: number;
  minChunkSize: number;
  maxRetries: number;
  retryDelay: number;
  retryBackoff: number;
  speedSampleWindow: number;
  speedLimit: number;
  requestTimeout: number;
  headers: Record<string, string>;
}

export class Download {
  readonly id: string;
  readonly url: string;
  readonly emitter = new TypedEventEmitter<DownloadEventMap>();
  readonly options: DownloadOptions;
  readonly config: DownloadInternalConfig;

  private _state: DownloadState = 'idle';
  private _probe: ProbeResult | null = null;
  private _meta: MetaFile | null = null;
  private chunks: Chunk[] = [];
  private readonly aggregate = new AggregateSpeed();
  private throttle: Throttle;

  private runningPromise: Promise<void> | null = null;
  private pauseRequested = false;
  private cancelRequested = false;
  private progressTimer: ReturnType<typeof setInterval> | null = null;
  private startedAt = 0;

  constructor(id: string, url: string, options: DownloadOptions, config: DownloadInternalConfig) {
    this.id = id;
    this.url = url;
    this.options = options;
    this.config = config;
    this.throttle = new Throttle(effectiveSpeedLimit(options, config));
    this.emitter.on('chunkLifecycle', (payload) => {
      if (payload.status === 'completed' || payload.status === 'failed' || payload.status === 'reassigned') {
        this.aggregate.remove(payload.chunkId);
      }
    });
  }

  get state(): DownloadState {
    return this._state;
  }

  get probe(): ProbeResult | null {
    return this._probe;
  }

  get meta(): MetaFile | null {
    return this._meta;
  }

  get totalBytes(): number | null {
    return this._probe?.totalSize ?? null;
  }

  get downloadedBytes(): number {
    let sum = 0;
    for (const c of this.chunks) sum += c.downloadedBytes;
    return sum;
  }

  get filename(): string {
    return this._probe?.filename ?? (this.options.filename ?? `download-${this.id}`);
  }

  get targetFilePath(): string {
    return this.config.io.joinPath(this.config.targetPath, this.filename);
  }

  get partFilePath(): string {
    return `${this.targetFilePath}${TEMP_EXT}`;
  }

  /** Start (or resume) the download. Returns a promise that resolves on finish/pause/error. */
  start(): Promise<void> {
    if (this.runningPromise) return this.runningPromise;
    if (this._state === 'completed') return Promise.resolve();
    this.pauseRequested = false;
    this.cancelRequested = false;
    this.runningPromise = this.execute().finally(() => {
      this.runningPromise = null;
    });
    return this.runningPromise;
  }

  pause(): void {
    if (this._state !== 'downloading' && this._state !== 'probing') return;
    this.pauseRequested = true;
    for (const c of this.chunks) c.pause();
  }

  cancel(): void {
    this.cancelRequested = true;
    this.pauseRequested = true;
    for (const c of this.chunks) c.pause();
  }

  /**
   * Delete the downloaded file and its meta sidecar. Also cancels if running.
   * After clear() the Download object should be considered disposed.
   */
  async clear(): Promise<void> {
    this.cancel();
    if (this.runningPromise) {
      try {
        await this.runningPromise;
      } catch {
        /* ignore */
      }
    }
    await this.safeUnlink(this.partFilePath);
    await this.safeUnlink(this.targetFilePath);
    if (this._probe) {
      await deleteMeta(this.config.io, {
        dir: this.config.cachePath,
        filename: this.filename,
      }).catch(() => undefined);
    }
  }

  /** Change the speed limit mid-download. 0 = unlimited. */
  speedLimit(bytesPerSec: number): void {
    this.throttle.setCapacity(bytesPerSec);
  }

  /** Compatibility with the user-facing API (`alloc`). Currently a no-op hook. */
  alloc(): void {
    // Reserved for future disk pre-allocation (e.g. fallocate). Injected I/O
    // doesn't expose truncate today, so this is deliberately a stub.
  }

  getChunkSnapshots(): ChunkSnapshot[] {
    return this.chunks.map((c) => c.snapshot());
  }

  private async execute(): Promise<void> {
    try {
      if (this._probe === null) {
        this.setState('probing');
        const probe = await probeUrl({
          fetch: this.config.io.fetch,
          url: this.url,
          headers: this.config.headers,
          ...(this.options.filename !== undefined ? { filenameHint: this.options.filename } : {}),
        });
        this._probe = probe;
      }

      await this.ensureTargetDirs();
      await this.loadOrInitMeta();

      if (this.cancelRequested) {
        this.setState('cancelled');
        return;
      }

      if (this.chunks.length === 0) this.instantiateChunksFromMeta();
      // Zero-byte downloads: ensure the .part file exists so rename() has
      // something to move on finalize, then short-circuit.
      if (this._probe?.totalSize === 0) {
        await this.config.io.writeFile(this.partFilePath, new Uint8Array(0));
        await this.finalize();
        return;
      }
      if (this.isAllComplete()) {
        await this.finalize();
        return;
      }

      this.setState('downloading');
      this.startedAt = Date.now();
      this.startProgressTimer();

      await this.driveChunks();

      this.stopProgressTimer();

      if (this.cancelRequested) {
        this.setState('cancelled');
        await this.persistCurrentMeta();
        return;
      }
      if (this.pauseRequested) {
        this.setState('paused');
        await this.persistCurrentMeta();
        return;
      }
      if (this.isAllComplete()) {
        await this.finalize();
        return;
      }
      // Any chunk failed permanently → mark error.
      const failed = this.chunks.find((c) => c.status === 'failed');
      if (failed) {
        this.setState('error');
        await this.persistCurrentMeta();
        return;
      }
      // Shouldn't happen, but be defensive.
      this.setState('paused');
      await this.persistCurrentMeta();
    } catch (err) {
      this.stopProgressTimer();
      const error = err instanceof Error ? err : new Error(String(err));
      this.setState('error');
      this.emitter.emit('error', {
        downloadId: this.id,
        error,
        fatal: true,
      });
      await this.persistCurrentMeta().catch(() => undefined);
    }
  }

  private async ensureTargetDirs(): Promise<void> {
    await this.config.io.mkdir(this.config.targetPath);
    if (this.config.cachePath !== this.config.targetPath) {
      await this.config.io.mkdir(this.config.cachePath);
    }
  }

  private async loadOrInitMeta(): Promise<void> {
    if (this._probe === null) throw new Error('Probe missing — unreachable');
    const locator = { dir: this.config.cachePath, filename: this._probe.filename };
    const existing = await loadMeta(this.config.io, locator);
    if (existing !== null && canResumeAgainst(existing, this._probe)) {
      this._meta = existing;
      return;
    }
    // Fresh meta — throw away any partial file, we can't trust it.
    if (existing !== null) {
      await this.safeUnlink(this.partFilePath);
    }
    const mode = this.options.chunkMode ?? DEFAULT_CONFIG.chunkMode;
    const chunkCount =
      mode === 'single' || !this._probe.acceptsRanges || this._probe.totalSize === null
        ? 1
        : (this.options.targetChunkCount ?? this.config.targetChunkCount);
    const totalSize = this._probe.totalSize ?? 0;
    const plans = planChunks({
      totalSize,
      targetChunkCount: chunkCount,
      minChunkSize: this.config.minChunkSize,
    });
    const snapshots: ChunkSnapshot[] = plans.map((p, i) => ({
      id: `${this.id}-c${i}`,
      offset: p.offset,
      length: p.length,
      downloadedBytes: p.downloadedBytes,
      status: 'pending',
      quality: 'good',
      retries: 0,
    }));
    this._meta = createMeta({ id: this.id, probe: this._probe, chunks: snapshots });
    await persistMeta(this.config.io, locator, this._meta);
  }

  private instantiateChunksFromMeta(): void {
    if (this._meta === null) throw new Error('Meta missing — unreachable');
    if (this._probe === null) throw new Error('Probe missing — unreachable');
    const acceptsRanges = this._probe.acceptsRanges;
    this.chunks = this._meta.chunks.map((snap) => this.buildChunk(snap, acceptsRanges));
  }

  private buildChunk(snap: ChunkSnapshot, acceptsRanges: boolean): Chunk {
    return new Chunk({
      id: snap.id,
      downloadId: this.id,
      url: this._probe?.finalUrl ?? this.url,
      targetFilePath: this.partFilePath,
      offset: snap.offset,
      length: snap.length,
      initialDownloadedBytes: snap.downloadedBytes,
      acceptsRanges,
      headers: this.config.headers,
      maxRetries: this.config.maxRetries,
      retryDelay: this.config.retryDelay,
      retryBackoff: this.config.retryBackoff,
      speedSampleWindow: this.config.speedSampleWindow,
      requestTimeout: this.config.requestTimeout,
      fetch: this.config.io.fetch,
      writeChunk: this.config.io.writeChunk,
      emitter: this.emitter,
      throttle: (bytes) => this.throttle.consume(bytes),
      medianSpeedRef: () => this.aggregate.medianWindowedSpeed(),
    });
  }

  private async driveChunks(): Promise<void> {
    // Launch initial batch — capped by targetChunkCount so a single Download
    // can't saturate manager-level maxParallel on its own.
    const runners = new Map<string, Promise<void>>();

    const launch = (chunk: Chunk): void => {
      if (chunk.status === 'completed') return;
      this.aggregate.add(chunk.id, chunk.speedTracker);
      const p = chunk.run();
      runners.set(chunk.id, p);
    };

    for (const c of this.chunks) launch(c);

    while (runners.size > 0) {
      const entries = Array.from(runners.entries());
      await Promise.race(entries.map(([id, p]) => p.then(() => id)));
      // Collect everything that has settled this tick.
      for (const [id, p] of entries) {
        const settled = await raceSettled(p);
        if (settled) runners.delete(id);
      }

      if (this.pauseRequested || this.cancelRequested) {
        // Wait for remaining runners to acknowledge abort before returning.
        await Promise.allSettled(runners.values());
        runners.clear();
        break;
      }

      // After something settles, try to donate remaining range to a new chunk.
      const candidate = findSplitCandidate({
        activeChunks: this.chunks.filter((c) => c.status !== 'completed' && c.status !== 'failed' && c.status !== 'reassigned'),
        maxChunks: this.options.targetChunkCount ?? this.config.targetChunkCount,
        minChunkSize: this.config.minChunkSize,
        trigger: 'completed-reassign',
      });
      if (candidate !== null) {
        const newSnap: ChunkSnapshot = {
          id: `${this.id}-c${this.chunks.length}`,
          offset: candidate.newRange.offset,
          length: candidate.newRange.length,
          downloadedBytes: 0,
          status: 'pending',
          quality: 'good',
          retries: 0,
        };
        const newChunk = this.buildChunk(newSnap, this._probe?.acceptsRanges ?? false);
        this.chunks.push(newChunk);
        this.emitter.emit('chunkSplit', {
          downloadId: this.id,
          sourceChunkId: candidate.chunk.id,
          newChunkId: newChunk.id,
          splitOffset: candidate.newRange.offset,
          reason: candidate.reason,
        });
        launch(newChunk);
      }

      // Persist a snapshot so a crash here is recoverable.
      await this.persistCurrentMeta().catch(() => undefined);
    }
  }

  private async finalize(): Promise<void> {
    await this.config.io.rename(this.partFilePath, this.targetFilePath);
    if (this._probe !== null) {
      await deleteMeta(this.config.io, {
        dir: this.config.cachePath,
        filename: this._probe.filename,
      }).catch(() => undefined);
    }
    this.setState('completed');
    this.emitter.emit('completed', {
      downloadId: this.id,
      filename: this.filename,
      totalBytes: this.downloadedBytes,
      durationMs: this.startedAt === 0 ? 0 : Date.now() - this.startedAt,
    });
  }

  private isAllComplete(): boolean {
    if (this.chunks.length === 0) return false;
    return this.chunks.every((c) => c.status === 'completed' || c.status === 'reassigned');
  }

  private setState(next: DownloadState): void {
    if (this._state === next) return;
    const prev = this._state;
    this._state = next;
    if (this._meta !== null) this._meta.state = dehydrateState(next);
    this.emitter.emit('stateChange', {
      downloadId: this.id,
      previous: prev,
      current: next,
    });
  }

  private startProgressTimer(): void {
    if (this.progressTimer !== null) return;
    this.progressTimer = setInterval(() => this.emitProgress(), 500);
  }

  private stopProgressTimer(): void {
    if (this.progressTimer !== null) {
      clearInterval(this.progressTimer);
      this.progressTimer = null;
    }
    this.emitProgress();
  }

  private emitProgress(): void {
    const total = this.totalBytes;
    const downloaded = this.downloadedBytes;
    this.emitter.emit('progress', {
      downloadId: this.id,
      totalBytes: total,
      downloadedBytes: downloaded,
      totalSpeed: this.aggregate.totalSpeed,
      activeChunks: this.chunks.filter((c) => c.status === 'downloading').length,
      percent: total !== null && total > 0 ? (downloaded / total) * 100 : null,
    });
  }

  private async persistCurrentMeta(): Promise<void> {
    if (this._meta === null || this._probe === null) return;
    updateMeta(this._meta, {
      state: dehydrateState(this._state),
      chunks: this.getChunkSnapshots(),
    });
    await persistMeta(this.config.io, {
      dir: this.config.cachePath,
      filename: this._probe.filename,
    }, this._meta);
  }

  private async safeUnlink(path: string): Promise<void> {
    try {
      if (await this.config.io.exists(path)) await this.config.io.unlink(path);
    } catch {
      /* ignore */
    }
  }
}

function effectiveSpeedLimit(opts: DownloadOptions, config: DownloadInternalConfig): number {
  if (opts.speedLimit !== undefined) return opts.speedLimit;
  return config.speedLimit;
}

/**
 * Returns `true` when the given promise has settled (resolved or rejected).
 * Never throws — reflects the outcome so the caller can keep driving.
 */
async function raceSettled(p: Promise<void>): Promise<boolean> {
  let settled = false;
  await Promise.race([
    p.then(
      () => {
        settled = true;
      },
      () => {
        settled = true;
      },
    ),
    Promise.resolve(),
  ]);
  return settled;
}
