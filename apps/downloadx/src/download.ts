import { Chunk } from './chunk.js';
import { findSplitCandidate, planChunks } from './chunkScheduler.js';
import {
  DEFAULT_CONFIG,
  RECENT_DIAGNOSTICS_LIMIT,
  STALL_RECOVERY_MS,
  TEMP_EXT,
  UNKNOWN_SIZE_LENGTH,
} from './constants.js';
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
  DiagnosticPayload,
  DownloadDescription,
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
  /** Manager-wide bandwidth bucket shared across downloads (optional). */
  sharedThrottle?: Throttle;
  /** Write an NDJSON journal sidecar next to the meta file. */
  journal?: boolean;
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
  /** Monotonic id source for chunks created by splits — never reuses an index. */
  private chunkSeq = 0;
  /** One-shot guard for the 200-instead-of-206 single-chunk fallback. */
  private rangeFallbackDone = false;
  /** chunkId → epoch ms since the chunk has been continuously `stalled`. */
  private readonly stalledSince = new Map<string, number>();
  private readonly recentDiagnostics: DiagnosticPayload[] = [];

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
    this.emitter.on('diagnostic', (payload) => {
      this.recentDiagnostics.push(payload);
      if (this.recentDiagnostics.length > RECENT_DIAGNOSTICS_LIMIT) {
        this.recentDiagnostics.shift();
      }
      this.journalWrite(payload);
    });
    this.emitter.on('stateChange', (payload) => {
      this.journalWrite({
        downloadId: this.id,
        level: 'info',
        code: 'state-change',
        message: `${payload.previous} -> ${payload.current}`,
        timestamp: Date.now(),
      });
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
    if (this._probe) {
      await deleteMeta(this.config.io, {
        dir: this.config.cachePath,
        filename: this.filename,
      }).catch(() => undefined);
      await this.safeUnlink(this.journalPath());
    }
  }

  /** Change the speed limit mid-download. 0 = unlimited. */
  speedLimit(bytesPerSec: number): void {
    this.throttle.setCapacity(bytesPerSec);
  }

  /**
   * Pre-allocate the part file to its final size. Requires `io.truncate` and
   * a known total size; silently no-ops otherwise. Called automatically at
   * download start, exposed for callers that want to allocate earlier.
   */
  async alloc(): Promise<void> {
    const truncate = this.config.io.truncate;
    const total = this._probe?.totalSize ?? null;
    if (truncate === undefined || total === null || total <= 0) return;
    try {
      await truncate(this.partFilePath, total);
    } catch (err) {
      this.diag('warn', 'prealloc-failed', `disk pre-allocation failed: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  getChunkSnapshots(): ChunkSnapshot[] {
    return this.chunks.map((c) => c.snapshot());
  }

  /** Compact machine-readable status report (see {@link DownloadDescription}). */
  describe(): DownloadDescription {
    const total = this.totalBytes;
    const downloaded = this.downloadedBytes;
    const speed = this.aggregate.totalSpeed;
    const snaps = this.getChunkSnapshots();
    const live = snaps.filter(
      (s) => s.status !== 'completed' && s.status !== 'reassigned',
    );
    return {
      id: this.id,
      url: this.url,
      filename: this.filename,
      state: this._state,
      totalBytes: total,
      downloadedBytes: downloaded,
      percent: total !== null && total > 0 ? Math.round((downloaded / total) * 1000) / 10 : null,
      totalSpeedBps: Math.round(speed),
      etaMs: total !== null && speed > 0 ? Math.round(((total - downloaded) / speed) * 1000) : null,
      elapsedMs: this.startedAt === 0 ? 0 : Date.now() - this.startedAt,
      activeChunks: snaps.filter((s) => s.status === 'downloading').length,
      totalChunks: snaps.length,
      chunks: live.map((s) => ({
        id: s.id,
        status: s.status,
        quality: s.quality,
        offset: s.offset,
        length: s.length,
        downloadedBytes: s.downloadedBytes,
        retries: s.retries,
      })),
      recentDiagnostics: [...this.recentDiagnostics],
    };
  }

  /**
   * Human/LLM-friendly one-screen summary of {@link describe}. Stable line
   * format, no ANSI codes — safe to paste into a prompt or a log.
   */
  describeText(): string {
    const d = this.describe();
    const lines: string[] = [];
    const size = d.totalBytes === null ? 'unknown size' : `${formatBytes(d.downloadedBytes)} / ${formatBytes(d.totalBytes)}`;
    const pct = d.percent === null ? '' : ` (${d.percent}%)`;
    lines.push(`${d.filename} [${d.state}] ${size}${pct}`);
    if (d.state === 'downloading') {
      const eta = d.etaMs === null ? 'unknown' : formatDuration(d.etaMs);
      lines.push(`speed ${formatBytes(d.totalSpeedBps)}/s, ETA ${eta}, chunks ${d.activeChunks} active / ${d.totalChunks} total`);
    }
    for (const c of d.chunks) {
      const chunkPct = c.length > 0 && c.length !== Number.MAX_SAFE_INTEGER
        ? `${Math.round((c.downloadedBytes / c.length) * 100)}%`
        : `${formatBytes(c.downloadedBytes)}`;
      const retries = c.retries > 0 ? `, retries ${c.retries}` : '';
      lines.push(`  ${c.id}: ${c.status}/${c.quality} ${chunkPct}${retries}`);
    }
    for (const diag of d.recentDiagnostics.slice(-3)) {
      lines.push(`  ${diag.level}: [${diag.code}] ${diag.message}`);
    }
    return lines.join('\n');
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

      for (;;) {
        await this.alloc();
        this.startProgressTimer();
        await this.driveChunks();
        this.stopProgressTimer();

        if (this.cancelRequested || this.pauseRequested) break;

        // Server ignored our Range header (200 instead of 206): chunked
        // bytes would be garbage, so restart once as a single full-body
        // download with range support disabled.
        const rangeNotHonored = this.chunks.some(
          (c) => c.status === 'failed' && c.failureCode === 'range-not-honored',
        );
        if (rangeNotHonored && !this.rangeFallbackDone && this._probe !== null) {
          this.rangeFallbackDone = true;
          this.diag('warn', 'range-fallback', 'server ignored Range header — restarting as a single-chunk download');
          this._probe = { ...this._probe, acceptsRanges: false };
          this.chunks = [];
          this._meta = null;
          await this.safeUnlink(this.partFilePath);
          await this.loadOrInitMeta(true);
          this.instantiateChunksFromMeta();
          continue;
        }
        break;
      }

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

  private async loadOrInitMeta(forceFresh = false): Promise<void> {
    if (this._probe === null) throw new Error('Probe missing — unreachable');
    const locator = { dir: this.config.cachePath, filename: this._probe.filename };
    const existing = forceFresh ? null : await loadMeta(this.config.io, locator);
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
    // Unknown total size: a single open-ended chunk that streams until EOF.
    // The sentinel length keeps `downloadedBytes < length` true throughout, so
    // completion is decided by the stream ending rather than byte accounting.
    const plans = this._probe.totalSize === null
      ? [{ offset: 0, length: UNKNOWN_SIZE_LENGTH, downloadedBytes: 0 }]
      : planChunks({
          totalSize: this._probe.totalSize,
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
    this.chunkSeq = Math.max(this.chunkSeq, this.chunks.length);
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
      etag: this._probe?.etag ?? null,
      lastModified: this._probe?.lastModified ?? null,
      headers: this.config.headers,
      maxRetries: this.config.maxRetries,
      retryDelay: this.config.retryDelay,
      retryBackoff: this.config.retryBackoff,
      speedSampleWindow: this.config.speedSampleWindow,
      requestTimeout: this.config.requestTimeout,
      fetch: this.config.io.fetch,
      writeChunk: this.config.io.writeChunk,
      emitter: this.emitter,
      throttle: async (bytes, signal) => {
        if (this.config.sharedThrottle !== undefined) {
          await this.config.sharedThrottle.consume(bytes, signal);
        }
        await this.throttle.consume(bytes, signal);
      },
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
      // Splits require range support and a known size, and are pointless once
      // any chunk has failed permanently (the download cannot complete).
      const splitAllowed =
        (this._probe?.acceptsRanges ?? false) &&
        this._probe?.totalSize !== null &&
        !this.chunks.some((c) => c.status === 'failed');
      const candidate = splitAllowed
        ? findSplitCandidate({
            activeChunks: this.chunks.filter((c) => c.status !== 'completed' && c.status !== 'failed' && c.status !== 'reassigned'),
            maxChunks: this.options.targetChunkCount ?? this.config.targetChunkCount,
            minChunkSize: this.config.minChunkSize,
            trigger: 'completed-reassign',
          })
        : null;
      if (candidate !== null) {
        const newSnap: ChunkSnapshot = {
          id: `${this.id}-c${this.chunkSeq}`,
          offset: candidate.newRange.offset,
          length: candidate.newRange.length,
          downloadedBytes: 0,
          status: 'pending',
          quality: 'good',
          retries: 0,
        };
        this.chunkSeq += 1;
        const newChunk = this.buildChunk(newSnap, this._probe?.acceptsRanges ?? false);
        this.chunks.push(newChunk);
        this.emitter.emit('chunkSplit', {
          downloadId: this.id,
          sourceChunkId: candidate.chunk.id,
          newChunkId: newChunk.id,
          splitOffset: candidate.newRange.offset,
          reason: candidate.reason,
        });
        this.diag('info', 'chunk-split', `${candidate.chunk.id} donated ${candidate.newRange.length} bytes at ${candidate.newRange.offset} to ${newChunk.id}`, newChunk.id);
        launch(newChunk);
      }

      // Persist a snapshot so a crash here is recoverable.
      await this.persistCurrentMeta().catch(() => undefined);
    }
  }

  private async finalize(): Promise<void> {
    // Verify the assembled size before committing the rename — catches silent
    // corruption (bad server, truncated writes) instead of shipping it.
    const expected = this._probe?.totalSize ?? null;
    const fileSize = this.config.io.fileSize;
    if (expected !== null && expected > 0 && fileSize !== undefined) {
      const actual = await fileSize(this.partFilePath).catch(() => null);
      if (actual !== null && actual !== expected) {
        this.diag('error', 'size-mismatch', `assembled file is ${actual} bytes, expected ${expected}`);
        this.setState('error');
        this.emitter.emit('error', {
          downloadId: this.id,
          error: new Error(`size mismatch after download: expected ${expected} bytes, found ${actual}`),
          fatal: true,
        });
        await this.persistCurrentMeta().catch(() => undefined);
        return;
      }
    }
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
    this.progressTimer = setInterval(() => {
      this.emitProgress();
      this.recoverStalledChunks();
    }, 500);
  }

  /**
   * Aborts and reissues requests for chunks that have been classified
   * `stalled` continuously for {@link STALL_RECOVERY_MS}. The retry budget
   * still applies, so a chunk can't loop forever.
   */
  private recoverStalledChunks(): void {
    const now = Date.now();
    for (const c of this.chunks) {
      if (c.status === 'downloading' && c.quality === 'stalled') {
        const since = this.stalledSince.get(c.id);
        if (since === undefined) {
          this.stalledSince.set(c.id, now);
        } else if (now - since >= STALL_RECOVERY_MS) {
          this.stalledSince.delete(c.id);
          this.diag('warn', 'stall-recovery', `chunk stalled for ${now - since}ms — reissuing request`, c.id);
          c.restart('stalled');
        }
      } else {
        this.stalledSince.delete(c.id);
      }
    }
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
    const speed = this.aggregate.totalSpeed;
    this.emitter.emit('progress', {
      downloadId: this.id,
      totalBytes: total,
      downloadedBytes: downloaded,
      totalSpeed: speed,
      activeChunks: this.chunks.filter((c) => c.status === 'downloading').length,
      percent: total !== null && total > 0 ? (downloaded / total) * 100 : null,
      etaMs: total !== null && speed > 0 && total >= downloaded
        ? Math.round(((total - downloaded) / speed) * 1000)
        : null,
    });
  }

  private diag(
    level: DiagnosticPayload['level'],
    code: string,
    message: string,
    chunkId?: string,
    data?: Record<string, unknown>,
  ): void {
    const payload: DiagnosticPayload = {
      downloadId: this.id,
      level,
      code,
      message,
      timestamp: Date.now(),
    };
    if (chunkId !== undefined) payload.chunkId = chunkId;
    if (data !== undefined) payload.data = data;
    this.emitter.emit('diagnostic', payload);
  }

  private journalPath(): string {
    return this.config.io.joinPath(
      this.config.cachePath,
      `${this._probe?.filename ?? `download-${this.id}`}.downloadx.log`,
    );
  }

  /** Fire-and-forget NDJSON append; journal problems never affect the download. */
  private journalWrite(payload: DiagnosticPayload): void {
    if (this.config.journal !== true) return;
    const append = this.config.io.appendFile;
    if (append === undefined || this._probe === null) return;
    const line = new TextEncoder().encode(`${JSON.stringify(payload)}\n`);
    void append(this.journalPath(), line).catch(() => undefined);
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

function formatBytes(n: number): string {
  if (n >= 1e9) return `${(n / 1e9).toFixed(2)} GB`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)} MB`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)} KB`;
  return `${Math.round(n)} B`;
}

function formatDuration(ms: number): string {
  const secs = Math.round(ms / 1000);
  if (secs < 60) return `${secs}s`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ${secs % 60}s`;
  return `${Math.floor(mins / 60)}h ${mins % 60}m`;
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
