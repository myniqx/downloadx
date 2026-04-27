import { describe, expect, it } from 'vitest';
import { AggregateSpeed, SpeedTracker } from '../../src/speedTracker.js';
import { FakeClock } from '../helpers/clock.js';

describe('SpeedTracker', () => {
  it('rejects a non-positive window', () => {
    expect(() => new SpeedTracker(0)).toThrow();
    expect(() => new SpeedTracker(-1)).toThrow();
  });

  it('rejects negative deltas', () => {
    const clock = new FakeClock();
    const t = new SpeedTracker(1_000, clock.now);
    expect(() => t.record(-1)).toThrow();
  });

  it('computes instantSpeed between successive samples', async () => {
    const clock = new FakeClock();
    const t = new SpeedTracker(1_000, clock.now);
    t.record(100); // anchor
    await clock.advance(100);
    t.record(50); // 50 bytes in 100ms → 500 B/s
    expect(t.instantSpeed).toBeCloseTo(500, 5);
  });

  it('windowedSpeed averages over the rolling window and evicts old samples', async () => {
    const clock = new FakeClock();
    const t = new SpeedTracker(1_000, clock.now);
    t.record(100);
    await clock.advance(500);
    t.record(100);
    // ~200 bytes over 500ms → 400 B/s.
    expect(t.windowedSpeed).toBeGreaterThan(350);
    expect(t.windowedSpeed).toBeLessThan(500);
    // After two full windows elapse, samples evict and speed drops to 0.
    await clock.advance(2_000);
    expect(t.windowedSpeed).toBe(0);
  });

  it('hasWarmedUp flips after the configured grace period', async () => {
    const clock = new FakeClock();
    const t = new SpeedTracker(1_000, clock.now);
    expect(t.hasWarmedUp(500)).toBe(false);
    await clock.advance(600);
    expect(t.hasWarmedUp(500)).toBe(true);
  });

  it('averageSpeed tracks total throughput since construction', async () => {
    const clock = new FakeClock();
    const t = new SpeedTracker(1_000, clock.now);
    await clock.advance(1_000);
    t.record(500);
    expect(t.averageSpeed).toBeCloseTo(500, 5);
  });

  it('reset clears samples', async () => {
    const clock = new FakeClock();
    const t = new SpeedTracker(1_000, clock.now);
    t.record(100);
    await clock.advance(200);
    t.record(100);
    expect(t.windowedSpeed).toBeGreaterThan(0);
    t.reset();
    expect(t.instantSpeed).toBe(0);
  });
});

describe('AggregateSpeed', () => {
  it('sums instant speed across children and returns 0 when empty', () => {
    const agg = new AggregateSpeed();
    expect(agg.totalSpeed).toBe(0);
  });

  it('tracks child add/remove and total bytes', async () => {
    const clock = new FakeClock();
    const t1 = new SpeedTracker(1_000, clock.now);
    const t2 = new SpeedTracker(1_000, clock.now);
    const agg = new AggregateSpeed();
    agg.add('a', t1);
    agg.add('b', t2);
    t1.record(100);
    await clock.advance(100);
    t1.record(100);
    t2.record(50);
    expect(agg.totalSpeed).toBeGreaterThan(0);
    expect(agg.totalBytes).toBe(250);
    agg.remove('b');
    expect(agg.totalBytes).toBe(200);
  });

  it('medianWindowedSpeed needs at least two active trackers', async () => {
    const clock = new FakeClock();
    const t1 = new SpeedTracker(1_000, clock.now);
    const agg = new AggregateSpeed();
    agg.add('a', t1);
    t1.record(100);
    await clock.advance(100);
    t1.record(100);
    expect(agg.medianWindowedSpeed()).toBe(0);
  });

  it('medianWindowedSpeed returns the middle speed for odd count', async () => {
    const clock = new FakeClock();
    const trackers = [
      new SpeedTracker(10_000, clock.now),
      new SpeedTracker(10_000, clock.now),
      new SpeedTracker(10_000, clock.now),
    ];
    const agg = new AggregateSpeed();
    trackers.forEach((t, i) => agg.add(String(i), t));
    // Anchor sample each tracker then advance; record again so the windowed
    // speed reflects the most recent 1s of traffic for each one.
    trackers[0]?.record(1);
    trackers[1]?.record(1);
    trackers[2]?.record(1);
    await clock.advance(1_000);
    trackers[0]?.record(100);
    trackers[1]?.record(500);
    trackers[2]?.record(1000);
    const speeds = trackers.map((t) => t.windowedSpeed).sort((a, b) => a - b);
    // Middle tracker should be the median.
    expect(agg.medianWindowedSpeed()).toBeCloseTo(speeds[1]!, 5);
  });
});
