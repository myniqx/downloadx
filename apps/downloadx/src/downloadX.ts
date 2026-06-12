import { DEFAULT_CONFIG } from './constants.js';
import { Download, type DownloadInternalConfig } from './download.js';
import { TypedEventEmitter } from './events.js';
import { Throttle } from './throttle.js';
import type {
  DownloadDescription,
  DownloadEventMap,
  DownloadEventName,
  DownloadOptions,
  DownloadXConfig,
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

export class DownloadX {
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
  private readonly sharedThrottle = new Throttle(0);

  constructor(config: DownloadXConfig) {
    this.baseConfig = config;
    this._maxParallel = config.maxParallel ?? DEFAULT_CONFIG.maxParallel;
    this._targetPath = config.targetPath;
    this._cachePath = config.cachePath ?? config.targetPath;
  }

  /**
   * Register a new download. Returns the {@link Download} handle for imperative
   * control. Pass `autoStart: true` in options to begin immediately; otherwise
   * call `start()` on the handle or `DownloadX.start(id)`.
   */
  addUrl(url: string, options: DownloadOptions = {}): Download {
    const id = options.id ?? hashUrl(url);
    const existing = this.downloads.get(id);
    if (existing) return existing;
    const download = new Download(id, url, options, this.internalConfigFor(options));
    const unrelay = download.emitter.pipeTo(this.emitter, RELAYED_EVENTS);
    this.downloads.set(id, download);
    this.unrelay.set(id, unrelay);

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

  /** Cancel and delete data for one (or all) downloads. */
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
    this.sharedThrottle.setCapacity(bytesPerSec);
  }

  get speedLimit(): number {
    return this.sharedThrottle.capacityBytesPerSec;
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

  private internalConfigFor(options: DownloadOptions): DownloadInternalConfig {
    const cfg = this.baseConfig;
    const headers: Record<string, string> = {
      ...(cfg.headers ?? {}),
      ...(options.headers ?? {}),
    };
    return {
      io: cfg.io,
      targetPath: this._targetPath,
      cachePath: this._cachePath,
      maxParallel: this._maxParallel,
      targetChunkCount: options.targetChunkCount ?? cfg.targetChunkCount ?? DEFAULT_CONFIG.targetChunkCount,
      minChunkSize: cfg.minChunkSize ?? DEFAULT_CONFIG.minChunkSize,
      maxRetries: options.maxRetries ?? cfg.maxRetries ?? DEFAULT_CONFIG.maxRetries,
      retryDelay: options.retryDelay ?? cfg.retryDelay ?? DEFAULT_CONFIG.retryDelay,
      retryBackoff: options.retryBackoff ?? cfg.retryBackoff ?? DEFAULT_CONFIG.retryBackoff,
      speedSampleWindow: cfg.speedSampleWindow ?? DEFAULT_CONFIG.speedSampleWindow,
      speedLimit: options.speedLimit ?? cfg.speedLimit ?? DEFAULT_CONFIG.speedLimit,
      requestTimeout: cfg.requestTimeout ?? DEFAULT_CONFIG.requestTimeout,
      headers,
      sharedThrottle: this.sharedThrottle,
      ...(cfg.journal !== undefined ? { journal: cfg.journal } : {}),
    };
  }
}

export function createDownloadX(config: DownloadXConfig): DownloadX {
  return new DownloadX(config);
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
