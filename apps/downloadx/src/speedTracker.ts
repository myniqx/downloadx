/**
 * Per-chunk bandwidth tracker.
 *
 * Exposes two independent readings on every sample:
 *
 *   - `instantSpeed`  — throughput measured between the last two samples.
 *                       Good for UI (matches what a progress bar shows).
 *   - `windowedSpeed` — moving average over `windowMs`. Drives the dynamic
 *                       chunk splitter so decisions aren't whipsawed by
 *                       transient network jitter.
 *
 * Implemented as a ring buffer of `{ timestamp, bytes }` samples. Each call to
 * {@link record} drops samples older than `windowMs`.
 */
export class SpeedTracker {
  private readonly samples: Array<{ t: number; bytes: number }> = [];
  private lastSampleAt: number | null = null;
  private lastInstantSpeed = 0;
  private totalBytes = 0;
  private readonly startedAt: number;

  constructor(
    private readonly windowMs: number,
    private readonly now: () => number = Date.now,
  ) {
    if (windowMs <= 0) {
      throw new Error(`SpeedTracker: windowMs must be > 0 (got ${windowMs})`);
    }
    this.startedAt = this.now();
  }

  /**
   * Register `deltaBytes` newly downloaded. Call once per network read.
   * `deltaBytes` must be non-negative.
   */
  record(deltaBytes: number): void {
    if (deltaBytes < 0) {
      throw new Error(`SpeedTracker.record: deltaBytes must be >= 0 (got ${deltaBytes})`);
    }
    const t = this.now();
    this.totalBytes += deltaBytes;

    if (this.lastSampleAt !== null) {
      const dt = t - this.lastSampleAt;
      if (dt > 0) {
        this.lastInstantSpeed = (deltaBytes * 1000) / dt;
      }
    }
    this.lastSampleAt = t;

    this.samples.push({ t, bytes: deltaBytes });
    this.evict(t);
  }

  /** Bytes per second measured between the last two samples. */
  get instantSpeed(): number {
    return this.lastInstantSpeed;
  }

  /** Bytes per second averaged across the configured window. */
  get windowedSpeed(): number {
    const t = this.now();
    this.evict(t);
    if (this.samples.length === 0) return 0;
    const first = this.samples[0];
    if (first === undefined) return 0;
    const span = t - first.t;
    if (span <= 0) return 0;
    let bytes = 0;
    for (const s of this.samples) bytes += s.bytes;
    return (bytes * 1000) / span;
  }

  /** Overall average since the tracker was created. */
  get averageSpeed(): number {
    const span = this.now() - this.startedAt;
    if (span <= 0) return 0;
    return (this.totalBytes * 1000) / span;
  }

  get bytesRecorded(): number {
    return this.totalBytes;
  }

  get ageMs(): number {
    return this.now() - this.startedAt;
  }

  /**
   * Indicates whether enough time has passed since start to trust the
   * windowed speed for quality decisions. Used to avoid flagging a chunk
   * as `poor` during TCP warmup.
   */
  hasWarmedUp(warmupMs: number): boolean {
    return this.ageMs >= warmupMs;
  }

  reset(): void {
    this.samples.length = 0;
    this.lastSampleAt = null;
    this.lastInstantSpeed = 0;
  }

  private evict(now: number): void {
    const cutoff = now - this.windowMs;
    while (this.samples.length > 0) {
      const first = this.samples[0];
      if (first === undefined) break;
      if (first.t >= cutoff) break;
      this.samples.shift();
    }
  }
}

/**
 * Aggregates many {@link SpeedTracker} instances into a download-wide view.
 * Lightweight: no samples of its own; just sums over child trackers.
 */
export class AggregateSpeed {
  private readonly children = new Map<string, SpeedTracker>();

  add(id: string, tracker: SpeedTracker): void {
    this.children.set(id, tracker);
  }

  remove(id: string): void {
    this.children.delete(id);
  }

  get totalSpeed(): number {
    let sum = 0;
    for (const t of this.children.values()) sum += t.instantSpeed;
    return sum;
  }

  get totalBytes(): number {
    let sum = 0;
    for (const t of this.children.values()) sum += t.bytesRecorded;
    return sum;
  }

  /**
   * Median of windowed speeds across tracked chunks. Used as the reference
   * point for quality classification: a chunk is `poor` if significantly
   * below the median. Returns 0 when fewer than two chunks are active.
   */
  medianWindowedSpeed(): number {
    const speeds: number[] = [];
    for (const t of this.children.values()) {
      if (t.bytesRecorded > 0) speeds.push(t.windowedSpeed);
    }
    if (speeds.length < 2) return 0;
    speeds.sort((a, b) => a - b);
    const mid = Math.floor(speeds.length / 2);
    if (speeds.length % 2 === 0) {
      const a = speeds[mid - 1];
      const b = speeds[mid];
      if (a === undefined || b === undefined) return 0;
      return (a + b) / 2;
    }
    return speeds[mid] ?? 0;
  }
}
