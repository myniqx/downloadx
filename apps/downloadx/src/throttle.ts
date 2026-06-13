/**
 * Token-bucket bandwidth limiter.
 *
 * Usage: each chunk calls `consume(bytes)` right before it writes the data it
 * just read. If the bucket has enough tokens, resolves immediately; otherwise
 * resolves after the shortage has refilled.
 *
 * A single instance is shared by all chunks of a download, so the cap applies
 * to the aggregate bandwidth rather than per-chunk.
 *
 * `capacityBytesPerSec === 0` disables throttling — `consume` becomes a no-op.
 */
export class Throttle {
  private tokens: number;
  private lastRefillAt: number;
  private readonly queue: Array<{
    need: number;
    resolve: () => void;
    reject: (err: Error) => void;
    signal?: AbortSignal;
    onAbort?: () => void;
  }> = [];
  private disposed = false;

  constructor(
    private capacity: number,
    private readonly now: () => number = Date.now,
    private readonly schedule: (ms: number, cb: () => void) => void = (ms, cb) => {
      setTimeout(cb, ms);
    },
  ) {
    if (capacity < 0) throw new Error(`Throttle: capacity must be >= 0 (got ${capacity})`);
    this.tokens = capacity;
    this.lastRefillAt = now();
  }

  /** Change the cap live (e.g. user toggles speedLimit mid-download). */
  setCapacity(capacity: number): void {
    if (capacity < 0) throw new Error(`Throttle: capacity must be >= 0 (got ${capacity})`);
    this.refill();
    const previous = this.capacity;
    this.capacity = capacity;
    if (capacity === 0) {
      // Switching to unlimited — release everything in-flight immediately.
      this.tokens = 0;
      for (const entry of this.queue.splice(0)) {
        entry.signal?.removeEventListener('abort', entry.onAbort!);
        entry.resolve();
      }
      return;
    }
    if (capacity > previous) {
      // On raise, top the bucket up to the new ceiling so queued waiters can
      // make progress right away instead of having to wait for a drip refill.
      this.tokens = capacity;
    } else if (this.tokens > capacity) {
      // Shrink reservoir to fit the new cap.
      this.tokens = capacity;
    }
    this.drainQueue();
  }

  get capacityBytesPerSec(): number {
    return this.capacity;
  }

  /**
   * Wait until `bytes` tokens are available, then deduct them. Resolves
   * immediately when `capacity === 0` (unlimited).
   *
   * If `bytes > capacity`, the request is satisfied in a single shot after
   * waiting `bytes / capacity` seconds — we don't partition the request so
   * the caller can treat consume() as atomic.
   */
  consume(bytes: number, signal?: AbortSignal): Promise<void> {
    if (bytes <= 0) return Promise.resolve();
    if (this.capacity === 0) return Promise.resolve();
    if (this.disposed) return Promise.reject(new Error('Throttle disposed'));

    this.refill();
    if (this.tokens >= bytes) {
      this.tokens -= bytes;
      return Promise.resolve();
    }

    return new Promise<void>((resolve, reject) => {
      if (signal?.aborted) {
        reject(toAbortError(signal.reason));
        return;
      }
      const entry: (typeof this.queue)[number] = { need: bytes, resolve, reject };
      if (signal !== undefined) {
        entry.signal = signal;
        entry.onAbort = (): void => {
          const idx = this.queue.indexOf(entry);
          if (idx !== -1) this.queue.splice(idx, 1);
          reject(toAbortError(signal.reason));
        };
        signal.addEventListener('abort', entry.onAbort, { once: true });
      }
      this.queue.push(entry);
      this.scheduleDrain();
    });
  }

  dispose(): void {
    this.disposed = true;
    for (const entry of this.queue) {
      entry.signal?.removeEventListener('abort', entry.onAbort!);
      entry.reject(new Error('Throttle disposed'));
    }
    this.queue.length = 0;
  }

  private refill(): void {
    if (this.capacity === 0) return;
    const now = this.now();
    const elapsed = now - this.lastRefillAt;
    if (elapsed <= 0) return;
    this.tokens = Math.min(this.capacity, this.tokens + (elapsed * this.capacity) / 1000);
    this.lastRefillAt = now;
  }

  private drainQueue(): void {
    this.refill();
    while (this.queue.length > 0) {
      const head = this.queue[0];
      if (head === undefined) break;
      if (this.tokens < head.need) break;
      this.tokens -= head.need;
      this.queue.shift();
      head.signal?.removeEventListener('abort', head.onAbort!);
      head.resolve();
    }
    if (this.queue.length > 0) this.scheduleDrain();
  }

  private scheduleDrain(): void {
    const head = this.queue[0];
    if (head === undefined || this.capacity === 0) return;
    const missing = head.need - this.tokens;
    if (missing <= 0) {
      this.drainQueue();
      return;
    }
    const waitMs = Math.max(5, Math.ceil((missing * 1000) / this.capacity));
    this.schedule(waitMs, () => this.drainQueue());
  }
}

function toAbortError(reason: unknown): Error {
  if (reason instanceof Error) return reason;
  const err = new Error('Aborted');
  err.name = 'AbortError';
  return err;
}
