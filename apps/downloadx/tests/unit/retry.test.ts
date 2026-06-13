import { describe, expect, it, vi } from 'vitest';

import { HttpStatusError, withRetry } from '../../src/retry.js';

describe('withRetry', () => {
  it('returns the value on first attempt when execute resolves', async () => {
    const result = await withRetry(async () => 42, {
      maxRetries: 3,
      retryDelay: 1,
      retryBackoff: 2,
      sleep: async () => undefined,
    });
    expect(result).toBe(42);
  });

  it('retries on network error up to maxRetries then throws', async () => {
    const exec = vi.fn(async () => {
      throw new Error('ECONNRESET');
    });
    await expect(
      withRetry(exec, {
        maxRetries: 3,
        retryDelay: 0,
        retryBackoff: 1,
        sleep: async () => undefined,
      }),
    ).rejects.toThrow('ECONNRESET');
    // Initial attempt + 3 retries = 4 calls.
    expect(exec).toHaveBeenCalledTimes(4);
  });

  it('retries on 5xx HttpStatusError', async () => {
    let attempt = 0;
    const result = await withRetry(
      async () => {
        attempt += 1;
        if (attempt < 3) throw new HttpStatusError(503, 'Service Unavailable');
        return 'ok';
      },
      { maxRetries: 5, retryDelay: 0, retryBackoff: 1, sleep: async () => undefined },
    );
    expect(result).toBe('ok');
    expect(attempt).toBe(3);
  });

  it('does not retry on 4xx permanent HttpStatusError', async () => {
    const exec = vi.fn(async () => {
      throw new HttpStatusError(404, 'Not Found');
    });
    await expect(
      withRetry(exec, {
        maxRetries: 5,
        retryDelay: 0,
        retryBackoff: 1,
        sleep: async () => undefined,
      }),
    ).rejects.toBeInstanceOf(HttpStatusError);
    expect(exec).toHaveBeenCalledTimes(1);
  });

  it('retries on transient 4xx codes like 408/425/429', async () => {
    for (const status of [408, 425, 429]) {
      let attempt = 0;
      const result = await withRetry(
        async () => {
          attempt += 1;
          if (attempt < 2) throw new HttpStatusError(status, 'Transient');
          return 'ok';
        },
        { maxRetries: 2, retryDelay: 0, retryBackoff: 1, sleep: async () => undefined },
      );
      expect(result).toBe('ok');
      expect(attempt).toBe(2);
    }
  });

  it('invokes onRetry before each retry with attempt number and error', async () => {
    const onRetry = vi.fn();
    let attempt = 0;
    await withRetry(
      async () => {
        attempt += 1;
        if (attempt < 3) throw new Error('temp');
        return 'ok';
      },
      {
        maxRetries: 5,
        retryDelay: 0,
        retryBackoff: 1,
        sleep: async () => undefined,
        onRetry,
      },
    );
    expect(onRetry).toHaveBeenCalledTimes(2);
    expect(onRetry.mock.calls[0]?.[0]).toMatchObject({ attempt: 1 });
    expect(onRetry.mock.calls[1]?.[0]).toMatchObject({ attempt: 2 });
  });

  it('respects AbortSignal — rejects immediately when already aborted', async () => {
    const ctrl = new AbortController();
    ctrl.abort();
    await expect(
      withRetry(async () => 1, {
        maxRetries: 3,
        retryDelay: 0,
        retryBackoff: 1,
        signal: ctrl.signal,
        sleep: async () => undefined,
      }),
    ).rejects.toThrow();
  });

  it('does not retry AbortError', async () => {
    const exec = vi.fn(async () => {
      const err = new Error('abort');
      err.name = 'AbortError';
      throw err;
    });
    await expect(
      withRetry(exec, {
        maxRetries: 5,
        retryDelay: 0,
        retryBackoff: 1,
        sleep: async () => undefined,
      }),
    ).rejects.toThrow('abort');
    expect(exec).toHaveBeenCalledTimes(1);
  });

  it('backoff delay scales with attempt index (ceiling = base * backoff^attempt)', async () => {
    const delays: number[] = [];
    let attempt = 0;
    await withRetry(
      async () => {
        attempt += 1;
        if (attempt < 4) throw new Error('retry');
        return 'ok';
      },
      {
        maxRetries: 5,
        retryDelay: 100,
        retryBackoff: 2,
        sleep: async (ms) => {
          delays.push(ms);
        },
      },
    );
    // Attempt 0 → delay in [50, 100], 1 → [100, 200], 2 → [200, 400].
    expect(delays).toHaveLength(3);
    expect(delays[0]).toBeGreaterThanOrEqual(50);
    expect(delays[0]).toBeLessThanOrEqual(100);
    expect(delays[1]).toBeGreaterThanOrEqual(100);
    expect(delays[1]).toBeLessThanOrEqual(200);
    expect(delays[2]).toBeGreaterThanOrEqual(200);
    expect(delays[2]).toBeLessThanOrEqual(400);
  });
});
