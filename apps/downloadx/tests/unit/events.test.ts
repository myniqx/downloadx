import { describe, expect, it, vi } from 'vitest';

import { TypedEventEmitter } from '../../src/events.js';

interface TestMap {
  tick: { n: number };
  boom: { reason: string };
}

describe('TypedEventEmitter', () => {
  it('delivers payloads to registered listeners in order', () => {
    const e = new TypedEventEmitter<TestMap>();
    const log: number[] = [];
    e.on('tick', (p) => log.push(p.n * 10));
    e.on('tick', (p) => log.push(p.n * 100));
    e.emit('tick', { n: 1 });
    expect(log).toEqual([10, 100]);
  });

  it('off() removes a listener and future emits skip it', () => {
    const e = new TypedEventEmitter<TestMap>();
    const spy = vi.fn();
    const off = e.on('tick', spy);
    e.emit('tick', { n: 1 });
    off();
    e.emit('tick', { n: 2 });
    expect(spy).toHaveBeenCalledTimes(1);
    expect(spy).toHaveBeenCalledWith({ n: 1 });
  });

  it('once() fires exactly once then detaches', () => {
    const e = new TypedEventEmitter<TestMap>();
    const spy = vi.fn();
    e.once('tick', spy);
    e.emit('tick', { n: 1 });
    e.emit('tick', { n: 2 });
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it('snapshots listeners so one removing itself does not skip peers', () => {
    const e = new TypedEventEmitter<TestMap>();
    const calls: string[] = [];
    const a = (): void => {
      calls.push('a');
      e.off('tick', a);
    };
    e.on('tick', a);
    e.on('tick', () => calls.push('b'));
    e.emit('tick', { n: 1 });
    expect(calls).toEqual(['a', 'b']);
  });

  it('swallows listener errors and routes them to onError', () => {
    const e = new TypedEventEmitter<TestMap>();
    const errors: Array<{ err: unknown; event: keyof TestMap }> = [];
    e.onError = (err, event): void => {
      errors.push({ err, event });
    };
    e.on('tick', () => {
      throw new Error('boom');
    });
    const ok = vi.fn();
    e.on('tick', ok);
    e.emit('tick', { n: 1 });
    expect(ok).toHaveBeenCalledOnce();
    expect(errors).toHaveLength(1);
    expect(errors[0]?.event).toBe('tick');
    expect((errors[0]?.err as Error).message).toBe('boom');
  });

  it('listenerCount reflects add/remove', () => {
    const e = new TypedEventEmitter<TestMap>();
    expect(e.listenerCount('tick')).toBe(0);
    const off = e.on('tick', () => undefined);
    expect(e.listenerCount('tick')).toBe(1);
    off();
    expect(e.listenerCount('tick')).toBe(0);
  });

  it('removeAllListeners clears a specific event or everything', () => {
    const e = new TypedEventEmitter<TestMap>();
    e.on('tick', () => undefined);
    e.on('boom', () => undefined);
    e.removeAllListeners('tick');
    expect(e.listenerCount('tick')).toBe(0);
    expect(e.listenerCount('boom')).toBe(1);
    e.removeAllListeners();
    expect(e.listenerCount('boom')).toBe(0);
  });

  it('pipeTo relays every configured event to the target', () => {
    const src = new TypedEventEmitter<TestMap>();
    const dst = new TypedEventEmitter<TestMap>();
    const tickSpy = vi.fn();
    const boomSpy = vi.fn();
    dst.on('tick', tickSpy);
    dst.on('boom', boomSpy);
    const stop = src.pipeTo(dst, ['tick', 'boom']);
    src.emit('tick', { n: 5 });
    src.emit('boom', { reason: 'x' });
    expect(tickSpy).toHaveBeenCalledWith({ n: 5 });
    expect(boomSpy).toHaveBeenCalledWith({ reason: 'x' });
    stop();
    src.emit('tick', { n: 6 });
    expect(tickSpy).toHaveBeenCalledTimes(1);
  });
});
