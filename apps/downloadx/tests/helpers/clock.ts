/**
 * Deterministic clock + scheduler used by every test.
 *
 * Using real timers inside SpeedTracker / Throttle would make tests flaky and
 * slow; instead we inject `now()` and `schedule()` so time only advances when
 * a test explicitly calls `advance()`.
 */
export class FakeClock {
  private current: number;
  private readonly timers: Array<{ fireAt: number; id: number; cb: () => void }> = [];
  private nextId = 1;

  constructor(start = 0) {
    this.current = start;
  }

  now = (): number => this.current;

  schedule = (ms: number, cb: () => void): number => {
    const id = this.nextId;
    this.nextId += 1;
    this.timers.push({ fireAt: this.current + ms, id, cb });
    this.timers.sort((a, b) => a.fireAt - b.fireAt);
    return id;
  };

  /** Fires every timer due at or before `current + ms`, in order. */
  async advance(ms: number): Promise<void> {
    const target = this.current + ms;
    while (true) {
      const next = this.timers[0];
      if (next === undefined || next.fireAt > target) break;
      this.timers.shift();
      this.current = next.fireAt;
      next.cb();
      // Let any promise callbacks settle between timer fires.
      await flushMicrotasks();
    }
    this.current = target;
  }

  pending(): number {
    return this.timers.length;
  }
}

export function flushMicrotasks(): Promise<void> {
  return new Promise<void>((resolve) => {
    // Two turns so promise chains created inside the first tick also settle.
    Promise.resolve().then(() => Promise.resolve().then(resolve));
  });
}
