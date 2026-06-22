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
import { HlsSession } from './hls/session.js';
import {
  applyProbeToMeta,
  canResumeAgainst,
  createEmptyMeta,
  deleteMeta,
  deleteLog,
  dehydrateState,
  persistLogs,
  persistMeta,
  updateMeta,
  type PersistedLogEntry,
} from './meta.js';
import { renderLog } from './key2log.js';
import { probeUrl } from './probe.js';
import { AggregateSpeed } from './speedTracker.js';
import { Throttle } from './throttle.js';
import type {
  ChunkSnapshot,
  DiagnosticPayload,
  DlxContext,
  DownloadDescription,
  DownloadEventMap,
  DownloadOptions,
  DownloadState,
  GlobalConfig,
  InjectedFunctions,
  LogEntry,
  MetaFile,
  ProbeResult,
} from './types.js';

export class Download implements GlobalConfig {
  readonly id: string;
  readonly url: string;
  readonly emitter = new TypedEventEmitter<DownloadEventMap>();
  readonly options: DownloadOptions;
  private readonly _context: DlxContext;

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
  private readonly _logs: PersistedLogEntry[] = [];

  // ---------------------------------------------------------------------------
  // GlobalConfig implementation — delegates to _global, with per-download
  // meta overrides for fields that support them.
  // ---------------------------------------------------------------------------

  get io(): InjectedFunctions { return this._context.io; }
  get cachePath(): string { return this._context.cachePath; }
  get maxParallel(): number { return this._context.maxParallel; }
  get speedLimit(): number { return this._meta.speedLimit ?? this._context.speedLimit; }
  get sharedThrottle(): GlobalConfig['sharedThrottle'] { return this._context.sharedThrottle; }

  get maxRetries(): number { return this._context.maxRetries; }
  get retryDelay(): number { return this._context.retryDelay; }
  get retryBackoff(): number { return this._context.retryBackoff; }
  get speedSampleWindow(): number { return this._context.speedSampleWindow; }
  get requestTimeout(): number { return this._context.requestTimeout; }
  get headers(): Record<string, string> {
    if (this._meta.headers === null) return this._context.headers;
    return { ...this._context.headers, ...this._meta.headers };
  }

  get targetChunkCount(): number {
    return this._meta.targetChunkCount ?? this._context.targetChunkCount;
  }
  get targetPath(): string {
    return this._meta.targetPath ?? this._context.targetPath;
  }
  get minChunkSize(): number {
    return this._meta.minChunkSize ?? this._context.minChunkSize;
  }
  get journal(): boolean {
    return this._meta.journal ?? this._context.journal;
  }

  // ---------------------------------------------------------------------------

  static fromMeta(meta: MetaFile, context: DlxContext, logs: PersistedLogEntry[] = []): Download {
    return new Download(meta.id, meta.url, {}, context, meta, logs);
  }

  constructor(
    id: string,
    url: string,
    options: DownloadOptions,
    context: DlxContext,
    initialMeta?: MetaFile,
    initialLogs: PersistedLogEntry[] = [],
  ) {
    this.id = id;
    this.url = url;
    this.options = options;
    this._context = context;
    this.throttle = new Throttle(options.speedLimit ?? 0);
    this._logs.push(...initialLogs);
    if (initialMeta !== undefined) {
      this._meta = initialMeta;
      if (initialMeta.speedLimit !== null) this.throttle.setCapacity(initialMeta.speedLimit);
      this._state = dehydrateState(initialMeta.state);
      initialMeta.state = this._state;
    } else {
      this._meta = createEmptyMeta({ id, url });
      if (options.filename !== undefined) this._meta.filename = options.filename;
      if (options.targetPath !== undefined) this._meta.targetPath = options.targetPath;
      if (options.speedLimit !== undefined) this._meta.speedLimit = options.speedLimit;
      if (options.minChunkSize !== undefined) this._meta.minChunkSize = options.minChunkSize;
      if (options.journal !== undefined) this._meta.journal = options.journal;
      if (options.description !== undefined) this._meta.description = options.description;
      if (options.metadata !== undefined) this._meta.metadata = options.metadata;
      if (options.headers !== undefined) this._meta.headers = options.headers;
      this.addLog({ code: 'download.created', params: { url, options: JSON.stringify(options) } });
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
    return this._meta.filename ?? this._probe?.filename ?? `download-${this.id}`;
  }

  get targetFilePath(): string {
    return this.io.joinPath(this.targetPath, this.filename);
  }

  get partFilePath(): string {
    return this.io.joinPath(this.cachePath, `${this.id}${TEMP_EXT}`);
  }

  get logs(): readonly PersistedLogEntry[] {
    return this._logs;
  }

  get renderedLogs(): readonly { timestamp: number; level: 'info' | 'warn' | 'error'; message: string }[] {
    return this._logs.map((e) => ({
      timestamp: e.timestamp,
      level: e.level ?? 'info',
      message: renderLog(e.code, e.params),
    }));
  }

  addLog(entry: LogEntry): void {
    const level = entry.level ?? 'info';
    const timestamp = Date.now();
    this._logs.push({ ...entry, level, timestamp });
    this.emitter.emit('log', {
      downloadId: this.id,
      timestamp,
      level,
      message: renderLog(entry.code, entry.params),
    });
  }

  /** Start (or resume) the download. Returns a promise that resolves on finish/pause/error. */
  start(): Promise<void> {
    if (this._state === 'completed') return Promise.resolve();

    if (this.runningPromise !== null) {
      return this.runningPromise;
    }

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
    await deleteLog(this.io, { dir: this.cachePath, id: this.id }).catch(() => undefined);
    await this.safeUnlink(this.journalPath());
    // HLS writes segments to {cachePath}/{id}-hls/ — clean up the directory.
    if (this._probe?.isHls === true || this._meta.isHls === true) {
      const session = new HlsSession(this.id, this._context);
      await session.cleanup(session.segDir());
    }
  }

  /** Change the speed limit mid-download. 0 = unlimited. null clears the per-download override. */
  setSpeedLimit(bytesPerSec: number | null): void {
    const old = this._meta.speedLimit;
    const effective = bytesPerSec ?? 0;
    this.throttle.setCapacity(effective);
    this._meta.speedLimit = bytesPerSec;
    this.addLog({ code: 'config.speedLimit', params: { old: old ?? 0, new: bytesPerSec ?? 0, scope: '' } });
  }

  /** Upper bound on live chunks; takes effect on the next split decision. */
  setTargetChunkCount(n: number | null): void {
    const old = this._meta.targetChunkCount;
    this._meta.targetChunkCount = n;
    this.addLog({ code: 'config.targetChunkCount', params: { old: old ?? 0, new: n ?? 0, scope: '' } });
  }

  /** Override the target directory for this download's final file. null clears the override. */
  setTargetPath(path: string | null): void {
    const old = this._meta.targetPath;
    this._meta.targetPath = path;
    this.addLog({ code: 'config.targetPath', params: { old: old ?? '', new: path ?? '', scope: ' (overridden)' } });
  }

  /** Minimum bytes remaining before a chunk can be split; takes effect on the next split decision. */
  setMinChunkSize(bytes: number | null): void {
    const old = this._meta.minChunkSize;
    this._meta.minChunkSize = bytes;
    this.addLog({ code: 'config.minChunkSize', params: { old: old ?? 0, new: bytes ?? 0, scope: '' } });
  }

  /** Toggle NDJSON journal writing; takes effect on the next diagnostic event. */
  setJournal(enabled: boolean | null): void {
    const old = this._meta.journal;
    this._meta.journal = enabled;
    this.addLog({ code: 'config.journal', params: { old: String(old ?? false), new: String(enabled ?? false), scope: '' } });
  }

  /** Override the filename. null clears the override (falls back to probe then URL). */
  setFilename(name: string | null): void {
    const old = this._meta.filename;
    this._meta.filename = name;
    this.addLog({ code: 'config.filename', params: { old: old ?? '', new: name ?? '' } });
  }

  /** Set or clear the free-form description. */
  setDescription(text: string | null): void {
    const old = this._meta.description;
    this._meta.description = text;
    this.addLog({ code: 'config.description', params: { old: old ?? '', new: text ?? '' } });
  }

  /**
   * Merge key/value pairs into per-download metadata. null clears all metadata.
   * To remove a single key, pass { key: null } — null values are deleted from the map.
   */
  setMetadata(patch: Record<string, string | null> | null): void {
    if (patch === null) {
      this._meta.metadata = null;
      this.addLog({ code: 'config.metadata', params: { patch: 'cleared' } });
      return;
    }
    const current = this._meta.metadata ?? {};
    for (const [k, v] of Object.entries(patch)) {
      if (v === null) delete current[k];
      else current[k] = v;
    }
    this._meta.metadata = Object.keys(current).length > 0 ? current : null;
    this.addLog({ code: 'config.metadata', params: { patch: JSON.stringify(patch) } });
  }

  /**
   * Merge HTTP headers into per-download headers (merged on top of global).
   * null clears the local override entirely (reverts to global headers).
   * To remove a single header, pass { Key: null } — null values are deleted.
   */
  setHeaders(patch: Record<string, string | null> | null): void {
    if (patch === null) {
      this._meta.headers = null;
      this.addLog({ code: 'config.headers', params: { patch: 'cleared' } });
      return;
    }
    const current = this._meta.headers ?? {};
    for (const [k, v] of Object.entries(patch)) {
      if (v === null) delete current[k];
      else current[k] = v;
    }
    this._meta.headers = Object.keys(current).length > 0 ? current : null;
    this.addLog({ code: 'config.headers', params: { patch: JSON.stringify(patch) } });
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
      this.addLog({ code: 'alloc.completed', params: { bytes: total } });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.addLog({ level: 'warn', code: 'alloc.failed', params: { message } });
      this.diag('warn', 'prealloc-failed', `disk pre-allocation failed: ${message}`);
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

    // HLS: percent/ETA are segment-based since total bytes are unknown.
    if (this.isSegmentMode) {
      const totalSegments = snaps.length;
      const doneSegments = snaps.filter(
        (s) => s.status === 'completed' || s.status === 'reassigned',
      ).length;
      const elapsed = this.startedAt === 0 ? 0 : Date.now() - this.startedAt;
      return {
        id: this.id,
        url: this.url,
        filename: this.filename,
        targetPath: this.meta.targetPath,
        addedAt: this.meta.addedAt,
        completedAt: this.meta.completedAt,
        errorMessage: this.meta.errorMessage,
        description: this.meta.description,
        metadata: this.meta.metadata,
        state: this._state,
        totalBytes: null,
        downloadedBytes: downloaded,
        percent: totalSegments > 0 ? Math.round((doneSegments / totalSegments) * 1000) / 10 : null,
        totalSpeedBps: Math.round(speed),
        etaMs:
          doneSegments > 0 && doneSegments < totalSegments
            ? Math.round((elapsed / doneSegments) * (totalSegments - doneSegments))
            : null,
        elapsedMs: elapsed,
        activeChunks: snaps.filter((s) => s.status === 'downloading').length,
        totalChunks: totalSegments,
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
        hlsSegmentsDone: doneSegments,
        hlsTotalSegments: totalSegments,
      };
    }

    return {
      id: this.id,
      url: this.url,
      filename: this.filename,
      targetPath: this.meta.targetPath,
      addedAt: this.meta.addedAt,
      completedAt: this.meta.completedAt,
      errorMessage: this.meta.errorMessage,
      description: this.meta.description,
      metadata: this.meta.metadata,
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
        this.addLog({ code: 'probe.started', params: { url: this.url } });
        let probe: ProbeResult;
        try {
          probe = await probeUrl({
            fetch: this.io.fetch,
            url: this.url,
            headers: this.headers,
            ...(this._meta.filename !== null ? { filenameHint: this._meta.filename } : {}),
          });
        } catch (err) {
          this.addLog({ level: 'error', code: 'probe.error', params: { message: err instanceof Error ? err.message : String(err) } });
          throw err;
        }
        this._probe = probe;
        this.addLog({
          code: 'probe.completed',
          params: {
            size: probe.totalSize ?? -1,
            ranges: probe.acceptsRanges ? 'yes' : 'no',
            filename: probe.filename ?? '',
          },
        });
      }

      if (this._probe.isHls) {
        await this.runHls();
        return;
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
          this.addLog({ level: 'warn', code: 'range.fallback' });
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
    // Segment chunks (HLS) download their own URI into their own file from
    // byte 0, never split, and don't use Range (optimistic resume restarts).
    const isSegment = snap.isSegment === true;
    return new Chunk({
      id: snap.id,
      downloadId: this.id,
      url: isSegment ? (snap.uri ?? this.url) : (this._probe?.finalUrl ?? this.url),
      targetFilePath: isSegment ? (snap.targetFilePath ?? this.partFilePath) : this.partFilePath,
      offset: snap.offset,
      length: snap.length,
      initialDownloadedBytes: snap.downloadedBytes,
      acceptsRanges: isSegment ? false : acceptsRanges,
      ...(isSegment ? { isSegment: true } : {}),
      ...(isSegment && snap.uri !== undefined ? { uri: snap.uri } : {}),
      ...(isSegment && snap.durationSec !== undefined ? { durationSec: snap.durationSec } : {}),
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

    // HLS segment downloads can have hundreds of chunks; cap how many run at
    // once so we don't fire one request per segment. The cap is the configured
    // target chunk count. Normal (non-segment) downloads keep their existing
    // behaviour — every planned chunk launches immediately and the dynamic
    // splitter grows them up to targetChunkCount.
    const segmentMode = this.chunks.some((c) => c.isSegment);
    const concurrency = segmentMode
      ? Math.max(1, this.options.targetChunkCount ?? this.targetChunkCount)
      : Infinity;

    // Launch up to `concurrency` chunks; the rest wait until a slot frees up.
    // A chunk is launchable when it isn't finished and isn't already running.
    // (On resume, chunks may be `paused`, not `pending`, so don't filter on
    // `pending` alone — that would skip resumable chunks.)
    const launchPending = (): void => {
      for (const c of this.chunks) {
        if (runners.size >= concurrency) break;
        if (
          c.status === 'completed' ||
          c.status === 'reassigned' ||
          c.status === 'failed' ||
          runners.has(c.id)
        ) {
          continue;
        }
        launch(c);
      }
    };
    launchPending();

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
        this.addLog({
          code: 'chunk.split',
          params: {
            source: candidate.chunk.id,
            id: newChunk.id,
            offset: candidate.newRange.offset,
            end: candidate.newRange.offset + candidate.newRange.length,
          },
        });
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

      // Fill any freed slots with still-pending chunks (segment mode). No-op
      // for normal downloads, where every chunk launched up front.
      launchPending();

      await this.persistCurrentMeta().catch(() => undefined);
    }
  }

  /**
   * HLS download via the unified chunk pipeline. Each segment is an isSegment
   * Chunk written to its own file; segments download through driveChunks (with
   * concurrency capped at targetChunkCount), then are concatenated into the
   * final output. The playlist is re-resolved every run so resume picks up
   * fresh segment URIs and skips already-downloaded segment files.
   */
  private async runHls(): Promise<void> {
    const baseFilename = this.filename;
    const outputPath = this.targetFilePath;
    const session = new HlsSession(this.id, this._context);

    try {
      await this.ensureTargetDirs();
      const resolution = await session.resolve(this.url);

      if (resolution.type === 'multi-stream') {
        this.addLog({ code: 'hls.multi-stream', params: { count: resolution.streams.length } });
        await session.registerStreams(resolution.streams, baseFilename, outputPath);
        this.addLog({ code: 'hls.streams-registered', params: { count: resolution.streams.length } });
        this.setState('completed');
        this._meta.completedAt = Date.now();
        await this.persistCurrentMeta().catch(() => undefined);
        return;
      }

      const segments = resolution.playlist.segments;
      const segDir = session.segDir();
      await this.io.mkdir(segDir);

      // Plan each segment as an isSegment chunk. Already-downloaded segment
      // files (present + non-empty) are marked completed so resume skips them.
      const fileSize = this.io.fileSize;
      const snapshots: ChunkSnapshot[] = [];
      for (let i = 0; i < segments.length; i++) {
        const seg = segments[i]!;
        const segPath = session.segPath(i);
        let done = 0;
        let status: ChunkSnapshot['status'] = 'pending';
        if (await this.io.exists(segPath)) {
          const size = fileSize ? await fileSize(segPath).catch(() => 0) : 0;
          if (size !== null && size > 0) {
            done = size;
            status = 'completed';
          }
        }
        snapshots.push({
          id: `${this.id}-c${i}`,
          offset: 0,
          length: status === 'completed' ? done : UNKNOWN_SIZE_LENGTH,
          downloadedBytes: done,
          status,
          quality: 'good',
          retries: 0,
          isSegment: true,
          targetFilePath: segPath,
          uri: seg.uri,
          durationSec: seg.durationSec,
        });
      }

      const alreadyDone = snapshots.filter((s) => s.status === 'completed').length;
      this.addLog({
        code: 'hls.segments-planned',
        params: { total: segments.length, done: alreadyDone },
      });
      this._meta.isHls = true;
      if (this._probe !== null) applyProbeToMeta(this._meta, this._probe, snapshots);
      else this._meta.chunks = snapshots;
      this.chunkSeq = Math.max(this.chunkSeq, snapshots.length);
      this.chunks = snapshots.map((snap) => this.buildChunk(snap, false));
      await this.persistCurrentMeta().catch(() => undefined);

      if (this.cancelRequested) {
        this.setState('cancelled');
        await this.persistCurrentMeta().catch(() => undefined);
        return;
      }

      this.setState('downloading');
      this.startedAt = Date.now();
      this.startProgressTimer();
      await this.driveChunks();
      this.stopProgressTimer();

      if (this.cancelRequested) {
        this.setState('cancelled');
        await this.persistCurrentMeta().catch(() => undefined);
        return;
      }
      if (this.pauseRequested) {
        this.setState('paused');
        await this.persistCurrentMeta().catch(() => undefined);
        return;
      }
      const failed = this.chunks.find((c) => c.status === 'failed');
      if (failed) {
        this.setState('error');
        this._meta.errorMessage = failed.lastError ?? 'segment download failed';
        await this.persistCurrentMeta().catch(() => undefined);
        this.emitter.emit('error', {
          downloadId: this.id,
          error: new Error(this._meta.errorMessage),
          fatal: true,
        });
        return;
      }

      // All segments downloaded — concat into the final output and clean up.
      const segmentPaths = this.chunks.map((_, i) => session.segPath(i));
      this.addLog({ code: 'hls.concat-started', params: { segments: segmentPaths.length, output: outputPath } });
      await session.concat(segmentPaths, outputPath);
      await session.cleanup(segDir);
      this.addLog({ code: 'hls.concat-completed', params: { output: outputPath } });

      this.setState('completed');
      this._meta.completedAt = Date.now();
      await this.persistCurrentMeta().catch(() => undefined);
      this.emitter.emit('completed', {
        downloadId: this.id,
        filename: this.filename,
        totalBytes: this.downloadedBytes,
        durationMs: this.startedAt === 0 ? 0 : Date.now() - this.startedAt,
      });
    } catch (err) {
      this.stopProgressTimer();
      if (this.cancelRequested) {
        this.setState('cancelled');
        await this.persistCurrentMeta().catch(() => undefined);
        return;
      }
      if (this.pauseRequested) {
        this.setState('paused');
        await this.persistCurrentMeta().catch(() => undefined);
        return;
      }
      const error = err instanceof Error ? err : new Error(String(err));
      this.setState('error');
      this._meta.errorMessage = error.message;
      this.emitter.emit('error', { downloadId: this.id, error, fatal: true });
      await this.persistCurrentMeta().catch(() => undefined);
    } finally {
      this.stopProgressTimer();
    }
  }

  private async finalize(): Promise<void> {
    const expected = this._probe?.totalSize ?? null;
    const fileSize = this.io.fileSize;
    if (expected !== null && expected > 0 && fileSize !== undefined) {
      const actual = await fileSize(this.partFilePath).catch(() => null);
      if (actual !== null && actual !== expected) {
        this.addLog({ level: 'error', code: 'finalize.size-mismatch', params: { expected, actual } });
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
    this.addLog({ code: 'finalize.completed', params: { path: this.targetFilePath } });
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
    if (next === 'downloading' && prev === 'paused') {
      this.addLog({ code: 'download.resumed' });
    } else if (next === 'downloading') {
      this.addLog({ code: 'download.started' });
    } else if (next === 'paused') {
      this.addLog({ code: 'download.paused' });
    } else if (next === 'cancelled') {
      this.addLog({ code: 'download.cancelled' });
    } else if (next === 'error') {
      this.addLog({ level: 'error', code: 'download.error', params: { message: this._meta.errorMessage ?? 'unknown error' } });
    }
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
          this.addLog({ level: 'warn', code: 'chunk.stall', params: { id: c.id, duration: now - since } });
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

  /** True when this download is running in HLS segment mode. */
  private get isSegmentMode(): boolean {
    return this.chunks.length > 0 && this.chunks.some((c) => c.isSegment);
  }

  private emitProgress(): void {
    const downloaded = this.downloadedBytes;
    const speed = this.aggregate.totalSpeed;

    if (this.isSegmentMode) {
      // HLS: progress is segment-based, not byte-based (total size unknown).
      const totalSegments = this.chunks.length;
      const doneSegments = this.chunks.filter(
        (c) => c.status === 'completed' || c.status === 'reassigned',
      ).length;
      // ETA = remaining segments × average elapsed per completed segment.
      const elapsed = this.startedAt === 0 ? 0 : Date.now() - this.startedAt;
      const etaMs =
        doneSegments > 0 && doneSegments < totalSegments
          ? Math.round((elapsed / doneSegments) * (totalSegments - doneSegments))
          : null;
      this.emitter.emit('progress', {
        downloadId: this.id,
        totalBytes: null,
        downloadedBytes: downloaded,
        totalSpeed: speed,
        activeChunks: this.chunks.filter((c) => c.status === 'downloading').length,
        percent: totalSegments > 0 ? (doneSegments / totalSegments) * 100 : null,
        etaMs,
        hlsSegmentsDone: doneSegments,
        hlsTotalSegments: totalSegments,
      });
      return;
    }

    const total = this.totalBytes;
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
    const locator = { dir: this.cachePath, id: this.id };
    updateMeta(this._meta, {
      state: dehydrateState(this._state),
      chunks: this.chunks.length > 0 ? this.getChunkSnapshots() : this._meta.chunks,
    });
    await persistMeta(this.io, locator, this._meta);
    await persistLogs(this.io, locator, this._logs).catch(() => undefined);
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
