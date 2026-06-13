import type { TypedEventEmitter } from '../../src/events.js';

/**
 * Resolve the next emission of `event`, or reject after `timeoutMs`.
 * Tests prefer this over polling-based waits because it tolerates jittery
 * timing without hardcoding sleeps.
 */
export function waitForEvent<E extends object, K extends keyof E>(
  emitter: TypedEventEmitter<E>,
  event: K,
  timeoutMs = 2_000,
): Promise<E[K]> {
  return new Promise<E[K]>((resolve, reject) => {
    const off = emitter.on(event, (payload) => {
      clearTimeout(timer);
      off();
      resolve(payload);
    });
    const timer = setTimeout(() => {
      off();
      reject(new Error(`waitForEvent(${String(event)}): timeout after ${timeoutMs}ms`));
    }, timeoutMs);
  });
}

export function collectEvents<E extends object, K extends keyof E>(
  emitter: TypedEventEmitter<E>,
  event: K,
): { stop: () => E[K][]; all: () => E[K][] } {
  const collected: E[K][] = [];
  const off = emitter.on(event, (payload) => {
    collected.push(payload);
  });
  return {
    stop: (): E[K][] => {
      off();
      return collected;
    },
    all: (): E[K][] => collected.slice(),
  };
}
