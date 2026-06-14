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
  applyProbeToMeta,
  canResumeAgainst,
  createEmptyMeta,
  deleteMeta,
  dehydrateState,
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
  GlobalConfig,
  InjectedFunctions,
  MetaFile,
  ProbeResult,
} from './types.js';

export class Download implements GlobalConfig {
  readonly id: string;
  readonly url: string;
  readonly emitter = new TypedEventEmitter<DownloadEventMap>();
  readonly options: DownloadOptions;
  private readonly _global: GlobalConfig;

  private _state: DownloadState = 'idle';
  private _probe: ProbeResult | null = null;
  private _meta: MetaFile;
  private chunks: Chunk[] = [];
  private readonly aggregate = new AggregateSpeed();
  private throttle: Throttle;

  private runningPromise: Promise<void> | null = null;
  private pauseRequested = false;
  private cancelRequested = false;
  private progressTimer: ReturnType<typeof setInterval> | null = null;
  private startedAt = 0;
  private chunkSeq = 0;
  private rangeFallbackDone = false;
  private readonly stalledSince = new Map<string, number>();
  private readonly recentDiagnostics: DiagnosticPayload[] = [];

  // ---------------------------------------------------------------------------
  // GlobalConfig implementation — delegates to _global, with per-download
  // meta overrides for fields that support them.
  // ---------------------------------------------------------------------------

  get io(): InjectedFunctions { return this._global.io; }
  get cachePath(): string { return this._global.cachePath; }
  get sharedThrottle(): GlobalConfig['sharedThrottle'] { return this._global.sharedThrottle; }

  get maxRetries(): number { return this._global.maxRetries; }
  get retryDelay(): number { return this._global.retryDelay; }
  get retryBackoff(): number { return this._global.retryBackoff; }
  get speedSampleWindow(): number { return this._global.speedSampleWindow; }
  get requestTimeout(): number { return this._global.requestTimeout; }
  get headers(): Record<string, string> { return this._global.headers; }

  get targetChunkCount(): number {
    return this._meta.targetChunkCount ?? this._global.targetChunkCount;
  }
  get targetPath(): string {
    return this._meta.targetPath ?? this._global.targetPath;
  }
  get minChunkSize(): number {
    return this._meta.minChunkSize ?? this._global.minChunkSize;
  }
  get journal(): boolean {
    return this._meta.journal ?? this._global.journal;
  }

  // ---------------------------------------------------------------------------

  static fromMeta(meta: MetaFile, global: GlobalConfig): Download {
    return new Download(meta.id, meta.url, {}, global, meta);
  }

  constructor(
    id: string,
    url: string,
    options: DownloadOptions,
    global: GlobalConfig,
    initialMeta?: MetaFile,
  ) {
    this.id = id;
    this.url = url;
    this.options = options;
    this._global = global;
    this.throttle = new Throttle(options.speedLimit ?? 0);
    if (initialMeta !== undefined) {
      this._meta = initialMeta;
      if (initialMeta.speedLimit !== null) this.throttle.setCapacity(initialMeta.speedLimit);
      this._state = dehydrateState(initialMeta.state);
      initialMeta.state = this._state;
    } else {
      this._meta = createEmptyMeta({ id, url });
    }
    this.emitter.on('chunkLifecycle', (payload) => {
      if (
        payload.status === 'completed' ||
        payload.status === 'failed' ||
        payload.status === 'reassigned'
      ) {
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

  get meta(): MetaFile {
    return this._meta;
  }

  get totalBytes(): number | null {
    return this._probe?.totalSize ?? this._meta.totalSize;
  }

  get downloadedBytes(): number {
    if (this.chunks.length === 0) {
      let sum = 0;
      for (const c of this._meta.chunks) sum += c.downloadedBytes;
      return sum;
    }
    let sum = 0;
    for (const c of this.chunks) sum += c.downloadedBytes;
    return sum;
  }

  get filename(): string {
    return (
      this._probe?.filename ?? this._meta.filename ?? this.options.filename ?? `download-${this.id}`
    );
  }

  get targetFilePath(): string {
    return this.io.joinPath(this.targetPath, this.filename);
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
    this._meta.errorMessage = null;
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
    await deleteMeta(this.io, {
      dir: this.cachePath,
      id: this.id,
    }).catch(() => undefined);
    await this.safeUnlink(this.journalPath());
  }

  /** Change the speed limit mid-download. 0 = unlimited. null clears the per-download override. */
  setSpeedLimit(bytesPerSec: number | null): void {
    const effective = bytesPerSec ?? 0;
    this.throttle.setCapacity(effective);
    this._meta.speedLimit = bytesPerSec;
  }

  /** Upper bound on live chunks; takes effect on the next split decision. */
  setTargetChunkCount(n: number | null): void {
    this._meta.targetChunkCount = n;
  }

  /** Override the target directory for this download's final file. null clears the override. */
  setTargetPath(path: string | null): void {
    this._meta.targetPath = path;
  }

  /** Minimum bytes remaining before a chunk can be split; takes effect on the next split decision. */
  setMinChunkSize(bytes: number | null): void {
    this._meta.minChunkSize = bytes;
  }

  /** Toggle NDJSON journal writing; takes effect on the next diagnostic event. */
  setJournal(enabled: boolean | null): void {
    this._meta.journal = enabled;
  }

  /**
   * Generic key/value setter for live-configurable fields. Returns false if the
   * key is unknown (caller should report the error); true on success.
   * Value must already be the correct type — parse/validate before calling.
   */
  set(key: string, value: unknown): boolean {
    switch (key) {
      case 'speedLimit':
        this.setSpeedLimit(value as number | null);
        return true;
      case 'targetPath':
        this.setTargetPath(value as string | null);
        return true;
      case 'targetChunkCount':
        this.setTargetChunkCount(value as number | null);
        return true;
      case 'minChunkSize':
        this.setMinChunkSize(value as number);
        return true;
      case 'journal':
        this.setJournal(value as boolean);
        return true;
      default:
        return false;
    }
  }

  /**
   * Generic key/value getter for live-configurable fields. Returns undefined if
   * the key is unknown.
   */
  get<T>(key: string): T | undefined {
    switch (key) {
      case 'speedLimit':
        return this._meta.speedLimit as T;
      case 'targetPath':
        return this.targetPath as T;
      case 'targetChunkCount':
        return (this._meta.targetChunkCount ?? null) as T;
      case 'minChunkSize':
        return this.minChunkSize as T;
      case 'journal':
        return this.journal as T;
      default:
        return undefined;
    }
  }


  /**
   * Pre-allocate the part file to its final size. Requires `io.truncate` and
   * a known total size; silently no-ops otherwise. Called automatically at
   * download start, exposed for callers that want to allocate earlier.
   */
  async alloc(): Promise<void> {
    const truncate = this.io.truncate;
    const total = this._probe?.totalSize ?? null;
    if (truncate === undefined || total === null || total <= 0) return;
    try {
      await truncate(this.partFilePath, total);
    } catch (err) {
      this.diag(
        'warn',
        'prealloc-failed',
        `disk pre-allocation failed: ${err instanceof Error ? err.message : String(err)}`,
      );
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
    const live = snaps.filter((s) => s.status !== 'completed' && s.status !== 'reassigned');
    return {
      id: this.id,
      url: this.url,
      filename: this.meta.filename,
      targetPath: this.meta.targetPath,
      addedAt: this.meta.addedAt,
      completedAt: this.meta.completedAt,
      errorMessage: this.meta.errorMessage,
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
    const size =
      d.totalBytes === null
        ? 'unknown size'
        : `${formatBytes(d.downloadedBytes)} / ${formatBytes(d.totalBytes)}`;
    const pct = d.percent === null ? '' : ` (${d.percent}%)`;
    lines.push(`${d.filename} [${d.state}] ${size}${pct}`);
    if (d.state === 'downloading') {
      const eta = d.etaMs === null ? 'unknown' : formatDuration(d.etaMs);
      lines.push(
        `speed ${formatBytes(d.totalSpeedBps)}/s, ETA ${eta}, chunks ${d.activeChunks} active / ${d.totalChunks} total`,
      );
    }
    for (const c of d.chunks) {
      const chunkPct =
        c.length > 0 && c.length !== Number.MAX_SAFE_INTEGER
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
          fetch: this.io.fetch,
          url: this.url,
          headers: this.headers,
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
        await this.io.writeFile(this.partFilePath, new Uint8Array(0));
        await this.finalize();
        return;
      }
      if (this.isAllComplete()) {
        await this.finalize();
        return;
      }

      this.setState('downloading');
      this.startedAt = Date.now();

      for (; ;) {
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
          this.diag(
            'warn',
            'range-fallback',
            'server ignored Range header — restarting as a single-chunk download',
          );
          this._probe = { ...this._probe, acceptsRanges: false };
          this.chunks = [];
          this._meta.chunks = [];
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
      this._meta.errorMessage = error.message;
      this.emitter.emit('error', {
        downloadId: this.id,
        error,
        fatal: true,
      });
      await this.persistCurrentMeta().catch(() => undefined);
    }
  }

  private async ensureTargetDirs(): Promise<void> {
    await this.io.mkdir(this.targetPath);
    if (this.cachePath !== this.targetPath) {
      await this.io.mkdir(this.cachePath);
    }
  }

  /**
   * Reconciles the in-memory meta with a fresh probe result. If the existing
   * chunks can be resumed against the probe, they're kept; otherwise the chunk
   * plan is rebuilt and any leftover part file is discarded.
   */
  private async loadOrInitMeta(forceFresh = false): Promise<void> {
    if (this._probe === null) throw new Error('Probe missing — unreachable');
    const locator = { dir: this.cachePath, id: this.id };
    const hasResumableChunks =
      !forceFresh &&
      this._meta.chunks.length > 0 &&
      canResumeAgainst(this._meta, this._probe);

    if (hasResumableChunks) {
      applyProbeToMeta(this._meta, this._probe, this._meta.chunks);
      await persistMeta(this.io, locator, this._meta);
      return;
    }

    // Fresh chunks needed — any partial file can't be trusted.
    if (this._meta.chunks.length > 0) {
      await this.safeUnlink(this.partFilePath);
    }
    const mode = this.options.chunkMode ?? DEFAULT_CONFIG.chunkMode;
    const chunkCount =
      mode === 'single' || !this._probe.acceptsRanges || this._probe.totalSize === null
        ? 1
        : (this.options.targetChunkCount ?? this.targetChunkCount);
    // Unknown total size: a single open-ended chunk that streams until EOF.
    const plans =
      this._probe.totalSize === null
        ? [{ offset: 0, length: UNKNOWN_SIZE_LENGTH, downloadedBytes: 0 }]
        : planChunks({
          totalSize: this._probe.totalSize,
          targetChunkCount: chunkCount,
          minChunkSize: this.minChunkSize,
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
    applyProbeToMeta(this._meta, this._probe, snapshots);
    await persistMeta(this.io, locator, this._meta);
  }

  private instantiateChunksFromMeta(): void {
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
      global: this,
      emitter: this.emitter,
      throttle: async (bytes, signal) => {
        await this.sharedThrottle.consume(bytes, signal);
        await this.throttle.consume(bytes, signal);
      },
      medianSpeedRef: () => this.aggregate.medianWindowedSpeed(),
    });
  }

  private async driveChunks(): Promise<void> {
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
      for (const [id, p] of entries) {
        const settled = await raceSettled(p);
        if (settled) runners.delete(id);
      }

      if (this.pauseRequested || this.cancelRequested) {
        await Promise.allSettled(runners.values());
        runners.clear();
        break;
      }

      const splitAllowed =
        (this._probe?.acceptsRanges ?? false) &&
        this._probe?.totalSize !== null &&
        !this.chunks.some((c) => c.status === 'failed');
      const candidate = splitAllowed
        ? findSplitCandidate({
          activeChunks: this.chunks.filter(
            (c) => c.status !== 'completed' && c.status !== 'failed' && c.status !== 'reassigned',
          ),
          maxChunks: this.options.targetChunkCount ?? this.targetChunkCount,
          minChunkSize: this.minChunkSize,
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
        this.diag(
          'info',
          'chunk-split',
          `${candidate.chunk.id} donated ${candidate.newRange.length} bytes at ${candidate.newRange.offset} to ${newChunk.id}`,
          newChunk.id,
        );
        launch(newChunk);
      }

      await this.persistCurrentMeta().catch(() => undefined);
    }
  }

  private async finalize(): Promise<void> {
    const expected = this._probe?.totalSize ?? null;
    const fileSize = this.io.fileSize;
    if (expected !== null && expected > 0 && fileSize !== undefined) {
      const actual = await fileSize(this.partFilePath).catch(() => null);
      if (actual !== null && actual !== expected) {
        this.diag(
          'error',
          'size-mismatch',
          `assembled file is ${actual} bytes, expected ${expected}`,
        );
        const msg = `size mismatch after download: expected ${expected} bytes, found ${actual}`;
        this.setState('error');
        this._meta.errorMessage = msg;
        this.emitter.emit('error', {
          downloadId: this.id,
          error: new Error(msg),
          fatal: true,
        });
        await this.persistCurrentMeta().catch(() => undefined);
        return;
      }
    }
    await this.io.rename(this.partFilePath, this.targetFilePath);
    this.setState('completed');
    this._meta.completedAt = Date.now();
    await this.persistCurrentMeta().catch(() => undefined);
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
    this._meta.state = dehydrateState(next);
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

  private recoverStalledChunks(): void {
    const now = Date.now();
    for (const c of this.chunks) {
      if (c.status === 'downloading' && c.quality === 'stalled') {
        const since = this.stalledSince.get(c.id);
        if (since === undefined) {
          this.stalledSince.set(c.id, now);
        } else if (now - since >= STALL_RECOVERY_MS) {
          this.stalledSince.delete(c.id);
          this.diag(
            'warn',
            'stall-recovery',
            `chunk stalled for ${now - since}ms — reissuing request`,
            c.id,
          );
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
      etaMs:
        total !== null && speed > 0 && total >= downloaded
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
    return this.io.joinPath(this.cachePath, `${this.id}.downloadx.log`);
  }

  private journalWrite(payload: DiagnosticPayload): void {
    if (this.journal !== true) return;
    const append = this.io.appendFile;
    if (append === undefined) return;
    const line = new TextEncoder().encode(`${JSON.stringify(payload)}\n`);
    void append(this.journalPath(), line).catch(() => undefined);
  }

  private async persistCurrentMeta(): Promise<void> {
    updateMeta(this._meta, {
      state: dehydrateState(this._state),
      chunks: this.chunks.length > 0 ? this.getChunkSnapshots() : this._meta.chunks,
    });
    await persistMeta(
      this.io,
      {
        dir: this.cachePath,
        id: this.id,
      },
      this._meta,
    );
  }

  private async safeUnlink(path: string): Promise<void> {
    try {
      if (await this.io.exists(path)) await this.io.unlink(path);
    } catch {
      /* ignore */
    }
  }
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
