import { DEFAULT_CONFIG } from './constants.js';
import { Download } from './download.js';
import { TypedEventEmitter } from './events.js';
import { listMetaFiles, persistMeta } from './meta.js';
import { Throttle } from './throttle.js';
import type {
  DownloadDescription,
  DownloadEventMap,
  DownloadEventName,
  DownloadOptions,
  DownloadXConfig,
  GlobalConfig,
} from './types.js';

const RELAYED_EVENTS: readonly DownloadEventName[] = [
  'progress',
  'chunkProgress',
  'chunkLifecycle',
  'chunkSplit',
  'chunkQuality',
  'stateChange',
  'error',
  'completed',
  'diagnostic',
];

export class DownloadX implements GlobalConfig {
  readonly emitter = new TypedEventEmitter<DownloadEventMap>();

  private readonly downloads = new Map<string, Download>();
  private readonly unrelay = new Map<string, () => void>();
  private readonly queue: Download[] = [];
  private _maxParallel: number;
  private _targetPath: string;
  private _cachePath: string;
  private readonly baseConfig: DownloadXConfig;
  /**
   * Manager-wide bandwidth cap shared by ALL downloads (capacity 0 =
   * unlimited). Per-download `speedLimit` still applies on top.
   */
  private readonly _sharedThrottle = new Throttle(0);

  constructor(config: DownloadXConfig) {
    this.baseConfig = config;
    this._maxParallel = config.maxParallel ?? DEFAULT_CONFIG.maxParallel;
    this._targetPath = config.targetPath;
    this._cachePath = config.cachePath ?? config.targetPath;
  }

  /**
   * Scans `cachePath` for persisted meta files and rebuilds the in-memory
   * download list. Called by {@link createDownloadX}; safe to invoke multiple
   * times — only metas whose id isn't already registered are added.
   */
  async restoreFromCache(): Promise<void> {
    const metas = await listMetaFiles(this.baseConfig.io, this._cachePath);
    for (const meta of metas) {
      if (this.downloads.has(meta.id)) continue;
      const download = Download.fromMeta(meta, this);
      const unrelay = download.emitter.pipeTo(this.emitter, RELAYED_EVENTS);
      this.downloads.set(meta.id, download);
      this.unrelay.set(meta.id, unrelay);
    }
  }

  /**
   * Register a new download. Returns the {@link Download} handle for imperative
   * control. Pass `autoStart: true` in options to begin immediately; otherwise
   * call `start()` on the handle or `DownloadX.start(id)`.
   *
   * Persists an early meta sidecar so the download survives a restart even if
   * it never reached the probe stage.
   */
  async addUrl(url: string, options: DownloadOptions = {}): Promise<Download> {
    const id = options.id ?? hashUrl(url);
    const existing = this.downloads.get(id);
    if (existing) return existing;
    const download = new Download(id, url, options, this);
    const unrelay = download.emitter.pipeTo(this.emitter, RELAYED_EVENTS);
    this.downloads.set(id, download);
    this.unrelay.set(id, unrelay);

    await this.baseConfig.io.mkdir(this._cachePath);
    await persistMeta(
      this.baseConfig.io,
      { dir: this._cachePath, id },
      download.meta,
    );

    // TODO: add cli global config autoStart...
    if (options.autoStart === true) {
      void this.start(id);
    }
    return download;
  }

  /** Begin a single download (honours maxParallel — queues if capacity is full). */
  async start(id?: string): Promise<void> {
    if (id === undefined) {
      for (const d of this.downloads.values()) this.enqueue(d);
    } else {
      const d = this.downloads.get(id);
      if (d === undefined) throw new Error(`DownloadX: unknown id ${id}`);
      this.enqueue(d);
    }
    this.pump();
  }

  /** Pause one (or all, when `id` omitted) downloads. */
  pause(id?: string): void {
    if (id === undefined) {
      for (const d of this.downloads.values()) d.pause();
      this.queue.length = 0;
      return;
    }
    const d = this.downloads.get(id);
    if (d === undefined) return;
    d.pause();
    // Remove from queue if it was waiting.
    const idx = this.queue.indexOf(d);
    if (idx !== -1) this.queue.splice(idx, 1);
  }

  /**
   * Cancel and delete the part file, meta sidecar, and journal for one (or
   * all) downloads. Works on completed downloads too — that's how the caller
   * removes a finished entry from the list.
   */
  async clear(id?: string): Promise<void> {
    if (id === undefined) {
      await Promise.all(Array.from(this.downloads.values()).map((d) => d.clear()));
      for (const unrelay of this.unrelay.values()) unrelay();
      this.unrelay.clear();
      this.downloads.clear();
      this.queue.length = 0;
      return;
    }
    const d = this.downloads.get(id);
    if (d === undefined) return;
    await d.clear();
    this.unrelay.get(id)?.();
    this.unrelay.delete(id);
    this.downloads.delete(id);
    const idx = this.queue.indexOf(d);
    if (idx !== -1) this.queue.splice(idx, 1);
  }

  get(id: string): Download | undefined {
    return this.downloads.get(id);
  }

  list(): Download[] {
    return Array.from(this.downloads.values());
  }

  /** Compact status reports for every registered download. */
  describeAll(): DownloadDescription[] {
    return this.list().map((d) => d.describe());
  }

  /** Manager-wide bandwidth cap in bytes/sec shared by all downloads. 0 = unlimited. */
  setSpeedLimit(bytesPerSec: number): void {
    this._sharedThrottle.setCapacity(bytesPerSec);
  }

  get speedLimit(): number {
    return this._sharedThrottle.capacityBytesPerSec;
  }

  setMaxParallel(n: number): void {
    if (n < 1) throw new Error('maxParallel must be >= 1');
    this._maxParallel = n;
    this.pump();
  }

  get maxParallel(): number {
    return this._maxParallel;
  }

  setTargetPath(path: string): void {
    this._targetPath = path;
  }

  get targetPath(): string {
    return this._targetPath;
  }

  setCachePath(path: string): void {
    this._cachePath = path;
  }

  get cachePath(): string {
    return this._cachePath;
  }

  /** Upper bound on live chunks per download; takes effect on the next split decision.
   *  Only updates downloads that still carry the old global value; pass `override` to force all. */
  setTargetChunkCount(n: number, override = false): void {
    const old = this.baseConfig.targetChunkCount ?? DEFAULT_CONFIG.targetChunkCount;
    this.baseConfig.targetChunkCount = n;
    for (const dl of this.downloads.values()) {
      if (override || dl.targetChunkCount === old) dl.setTargetChunkCount(n);
    }
  }

  get targetChunkCount(): number {
    return this.baseConfig.targetChunkCount ?? DEFAULT_CONFIG.targetChunkCount;
  }

  /** Minimum bytes remaining before a chunk can be split; takes effect on the next split decision.
   *  Only updates downloads that still carry the old global value; pass `override` to force all. */
  setMinChunkSize(bytes: number, override = false): void {
    const old = this.baseConfig.minChunkSize ?? DEFAULT_CONFIG.minChunkSize;
    this.baseConfig.minChunkSize = bytes;
    for (const dl of this.downloads.values()) {
      if (override || dl.minChunkSize === old) dl.setMinChunkSize(bytes);
    }
  }

  get minChunkSize(): number {
    return this.baseConfig.minChunkSize ?? DEFAULT_CONFIG.minChunkSize;
  }

  /** Toggle NDJSON journal writing; takes effect on the next diagnostic event.
   *  Only updates downloads that still carry the old global value; pass `override` to force all. */
  setJournal(enabled: boolean, override = false): void {
    const old = this.baseConfig.journal ?? false;
    this.baseConfig.journal = enabled;
    for (const dl of this.downloads.values()) {
      if (override || dl.journal === old) dl.setJournal(enabled);
    }
  }

  get journal(): boolean {
    return this.baseConfig.journal ?? false;
  }

  get io() {
    return this.baseConfig.io;
  }

  get headers(): Record<string, string> {
    return this.baseConfig.headers ?? {};
  }

  get maxRetries(): number {
    return this.baseConfig.maxRetries ?? DEFAULT_CONFIG.maxRetries;
  }

  get retryDelay(): number {
    return this.baseConfig.retryDelay ?? DEFAULT_CONFIG.retryDelay;
  }

  get retryBackoff(): number {
    return this.baseConfig.retryBackoff ?? DEFAULT_CONFIG.retryBackoff;
  }

  get speedSampleWindow(): number {
    return this.baseConfig.speedSampleWindow ?? DEFAULT_CONFIG.speedSampleWindow;
  }

  get requestTimeout(): number {
    return this.baseConfig.requestTimeout ?? DEFAULT_CONFIG.requestTimeout;
  }

  /** Returns the shared throttle instance used by all downloads. */
  get sharedThrottle() {
    return this._sharedThrottle;
  }

  /** Returns the current effective global config — live values from setters, not the frozen constructor input. */
  getConfig(): Required<Omit<DownloadXConfig, 'io' | 'headers'>> & {
    headers: Record<string, string>;
  } {
    return {
      targetPath: this._targetPath,
      cachePath: this._cachePath,
      maxParallel: this._maxParallel,
      speedLimit: this.sharedThrottle.capacityBytesPerSec,
      targetChunkCount: this.baseConfig.targetChunkCount ?? DEFAULT_CONFIG.targetChunkCount,
      minChunkSize: this.baseConfig.minChunkSize ?? DEFAULT_CONFIG.minChunkSize,
      maxRetries: this.baseConfig.maxRetries ?? DEFAULT_CONFIG.maxRetries,
      retryDelay: this.baseConfig.retryDelay ?? DEFAULT_CONFIG.retryDelay,
      retryBackoff: this.baseConfig.retryBackoff ?? DEFAULT_CONFIG.retryBackoff,
      speedSampleWindow: this.baseConfig.speedSampleWindow ?? DEFAULT_CONFIG.speedSampleWindow,
      requestTimeout: this.baseConfig.requestTimeout ?? DEFAULT_CONFIG.requestTimeout,
      chunkMode: this.baseConfig.chunkMode ?? DEFAULT_CONFIG.chunkMode,
      journal: this.baseConfig.journal ?? false,
      headers: this.baseConfig.headers ?? {},
    };
  }

  private enqueue(download: Download): void {
    if (download.state === 'completed' || download.state === 'downloading') return;
    if (this.queue.includes(download)) return;
    this.queue.push(download);
  }

  private pump(): void {
    const active = Array.from(this.downloads.values()).filter(
      (d) => d.state === 'downloading' || d.state === 'probing',
    );
    let slots = Math.max(0, this._maxParallel - active.length);
    while (slots > 0 && this.queue.length > 0) {
      const next = this.queue.shift();
      if (next === undefined) break;
      slots -= 1;
      void next.start().finally(() => {
        // A slot just freed up — wake up anyone else in the queue.
        this.pump();
      });
    }
  }

}

/**
 * Build a {@link DownloadX} and rehydrate any persisted downloads found in
 * `cachePath`. Restored downloads are left in their last persisted state (no
 * autostart) — the caller decides what to resume.
 */
export async function createDownloadX(config: DownloadXConfig): Promise<DownloadX> {
  const dx = new DownloadX(config);
  await dx.restoreFromCache();
  return dx;
}

/**
 * Deterministic 16-char id from a URL. Not cryptographically strong — just
 * distinct enough that two different URLs very rarely collide. Uses FNV-1a
 * folded into a hex string so we stay dependency-free (no crypto.subtle in
 * every target runtime).
 */
function hashUrl(url: string): string {
  let h1 = 0x811c9dc5;
  let h2 = 0x01000193;
  for (let i = 0; i < url.length; i += 1) {
    const code = url.charCodeAt(i);
    h1 = Math.imul(h1 ^ code, 0x01000193) >>> 0;
    h2 = Math.imul(h2 + code, 0x85ebca6b) >>> 0;
  }
  return (h1.toString(16).padStart(8, '0') + h2.toString(16).padStart(8, '0')).slice(0, 16);
}
