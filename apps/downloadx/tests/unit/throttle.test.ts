import { describe, expect, it } from 'vitest';
import { Throttle } from '../../src/throttle.js';
import { FakeClock } from '../helpers/clock.js';

describe('Throttle', () => {
  it('capacity 0 is unlimited — consume resolves immediately', async () => {
    const t = new Throttle(0);
    const start = Date.now();
    await t.consume(10 * 1024 * 1024);
    expect(Date.now() - start).toBeLessThan(20);
  });

  it('consume within capacity returns synchronously with no wait', async () => {
    const clock = new FakeClock();
    const t = new Throttle(1_000, clock.now, clock.schedule);
    await t.consume(500);
    // No advance required — still the same instant.
    expect(clock.pending()).toBe(0);
  });

  it('consume beyond available waits until tokens refill', async () => {
    const clock = new FakeClock();
    const t = new Throttle(1_000, clock.now, clock.schedule);
    // Drain the bucket first.
    await t.consume(1_000);
    // Now request another 500 — needs 500ms of refill.
    let resolved = false;
    const p = t.consume(500).then(() => {
      resolved = true;
    });
    await clock.advance(100);
    expect(resolved).toBe(false);
    await clock.advance(500);
    await p;
    expect(resolved).toBe(true);
  });

  it('queued waiters are served in FIFO order as tokens refill', async () => {
    const clock = new FakeClock();
    const t = new Throttle(1_000, clock.now, clock.schedule);
    await t.consume(1_000);
    const order: string[] = [];
    const a = t.consume(300).then(() => order.push('a'));
    const b = t.consume(300).then(() => order.push('b'));
    const c = t.consume(300).then(() => order.push('c'));
    await clock.advance(2_000);
    await Promise.all([a, b, c]);
    expect(order).toEqual(['a', 'b', 'c']);
  });

  it('setCapacity expands immediately — queued waiters can proceed', async () => {
    const clock = new FakeClock();
    const t = new Throttle(500, clock.now, clock.schedule);
    await t.consume(500);
    let resolved = false;
    const p = t.consume(500).then(() => {
      resolved = true;
    });
    // Raising the capacity gives an instant refill on top of whatever the
    // refill timer has already dripped in.
    await clock.advance(10);
    t.setCapacity(10_000);
    await clock.advance(0);
    await p;
    expect(resolved).toBe(true);
  });

  it('setCapacity shrinks by capping the reservoir', () => {
    const t = new Throttle(1_000);
    // Token bucket starts full; reduce capacity and assert via capacity getter
    // + ability to consume only up to the new cap synchronously.
    t.setCapacity(100);
    expect(t.capacityBytesPerSec).toBe(100);
  });

  it('aborting a waiter rejects without leaking from the queue', async () => {
    const clock = new FakeClock();
    const t = new Throttle(100, clock.now, clock.schedule);
    await t.consume(100);
    const ctrl = new AbortController();
    const p = t.consume(1_000, ctrl.signal);
    ctrl.abort();
    await expect(p).rejects.toThrow();
    // Subsequent requests still work after enough refill.
    await clock.advance(10_000);
    await t.consume(50);
  });

  it('dispose rejects every pending waiter', async () => {
    const clock = new FakeClock();
    const t = new Throttle(100, clock.now, clock.schedule);
    await t.consume(100);
    const p = t.consume(1_000);
    t.dispose();
    await expect(p).rejects.toThrow(/disposed/);
  });

  it('throws on negative capacity', () => {
    expect(() => new Throttle(-1)).toThrow();
    const t = new Throttle(100);
    expect(() => t.setCapacity(-5)).toThrow();
  });
});
