import { NON_RETRYABLE_STATUS, RETRYABLE_STATUS } from './constants.js';

export interface RetryOptions {
  maxRetries: number;
  /** Base delay in ms for the first retry. */
  retryDelay: number;
  /** Multiplier applied per attempt: delay = retryDelay * backoff^attempt. */
  retryBackoff: number;
  /** Abort signal — when fired, retry loop exits immediately. */
  signal?: AbortSignal;
  /** Sleep implementation — overridable for deterministic tests. */
  sleep?: (ms: number, signal?: AbortSignal) => Promise<void>;
  /** Observer invoked before each retry; useful for logging / events. */
  onRetry?: (info: RetryInfo) => void;
}

export interface RetryInfo {
  attempt: number;
  delayMs: number;
  error: unknown;
}

/**
 * Marker error thrown (or returned from the `execute` callback) to signal that
 * the HTTP response itself reported a failure. The retry loop uses `status`
 * to decide whether the failure is transient or permanent.
 */
export class HttpStatusError extends Error {
  constructor(
    public readonly status: number,
    public readonly statusText: string,
    message?: string,
  ) {
    super(message ?? `HTTP ${status} ${statusText}`);
    this.name = 'HttpStatusError';
  }
}

/**
 * Thrown when a Range request came back `200 OK` instead of `206 Partial
 * Content` — the server ignored the Range header. Retrying won't help; the
 * download must fall back to a single full-body request. Status 200 is in
 * neither retry set, so the retry loop fails fast.
 */
export class RangeNotHonoredError extends HttpStatusError {
  constructor() {
    super(200, 'OK', 'Server ignored Range header (HTTP 200 instead of 206)');
    this.name = 'RangeNotHonoredError';
  }
}

/**
 * Runs `execute` with retry-on-failure. Retries only transient errors:
 *
 *   - network errors (anything thrown that is NOT an {@link HttpStatusError})
 *   - HTTP 408/425/429/5xx (see RETRYABLE_STATUS)
 *
 * Permanent errors (4xx other than retryable ones) fail fast — retrying a
 * 404 is wasted bandwidth.
 */
export async function withRetry<T>(
  execute: (attempt: number) => Promise<T>,
  options: RetryOptions,
): Promise<T> {
  const sleep = options.sleep ?? defaultSleep;
  let attempt = 0;
  let lastError: unknown;

  while (true) {
    if (options.signal?.aborted) {
      throw toAbortError(options.signal.reason);
    }
    try {
      return await execute(attempt);
    } catch (err) {
      lastError = err;
      if (!isRetryable(err) || attempt >= options.maxRetries) throw err;
      const delayMs = computeDelay(options, attempt);
      options.onRetry?.({ attempt: attempt + 1, delayMs, error: err });
      await sleep(delayMs, options.signal);
      attempt += 1;
    }
  }

  // Unreachable — the loop either returns or throws. Keeping a guard for the
  // type system in case the infinite-loop analysis is defeated.
  // eslint-disable-next-line @typescript-eslint/no-unreachable
  throw lastError;
}

function computeDelay(options: RetryOptions, attempt: number): number {
  const base = options.retryDelay;
  const factor = Math.pow(options.retryBackoff, attempt);
  // Full jitter within [base*factor/2, base*factor] so many retriers don't
  // rethunder the origin in lockstep.
  const ceiling = base * factor;
  const floor = ceiling / 2;
  return Math.round(floor + Math.random() * (ceiling - floor));
}

function isRetryable(err: unknown): boolean {
  if (err instanceof HttpStatusError) {
    if (NON_RETRYABLE_STATUS.has(err.status)) return false;
    if (RETRYABLE_STATUS.has(err.status)) return true;
    // Unknown 4xx → treat as permanent; unknown 5xx → retryable.
    return err.status >= 500;
  }
  // AbortError is never retried — the abort was explicit.
  if (isAbortError(err)) return false;
  // Anything else (network, timeout, DNS, TLS) is worth retrying.
  return true;
}

function isAbortError(err: unknown): boolean {
  if (err instanceof Error) {
    if (err.name === 'AbortError') return true;
  }
  return false;
}

function toAbortError(reason: unknown): Error {
  if (reason instanceof Error) return reason;
  const err = new Error('Aborted');
  err.name = 'AbortError';
  return err;
}

function defaultSleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    if (signal?.aborted) {
      reject(toAbortError(signal.reason));
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    const onAbort = (): void => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
      reject(toAbortError(signal?.reason));
    };
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}
