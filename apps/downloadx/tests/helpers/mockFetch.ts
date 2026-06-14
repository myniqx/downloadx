import type { FetchHeaders, FetchInit, FetchResponse, InjectedFunctions } from '../../src/types.js';

export interface MockRouteInit {
  /** Payload the route serves to full-body and range requests. */
  body: Uint8Array;
  /** Status code for unranged GET. Defaults to 200. */
  status?: number;
  /** Accept-Ranges header — `false` forces non-resumable mode. */
  acceptsRanges?: boolean;
  /** If given, attach an ETag header to every response. */
  etag?: string;
  lastModified?: string;
  contentType?: string;
  /** HEAD behaviour: 'ok' (default), 'missing' (405), 'no-size' (200 w/o content-length). */
  head?: 'ok' | 'missing' | 'no-size';
  /** Content-Disposition header to echo on probe responses. */
  contentDisposition?: string;
  /** Extra response headers. */
  extraHeaders?: Record<string, string>;
  /** Artificial per-request delay (ms). */
  delayMs?: number;
  /** Fail the first N GETs (Range or unranged). 0 means never. */
  failTimes?: number;
  /** Fail the first N HEAD requests. Defaults to matching failTimes. */
  failHeadTimes?: number;
  /** HTTP status to respond with for the first `failTimes` GETs. Defaults to 503. */
  failStatus?: number;
  /** Chunks the body into these slice sizes when streaming. Default: whole body. */
  streamChunks?: number[];
}

interface RouteState extends MockRouteInit {
  failsSeen: number;
  headFailsSeen: number;
}

/**
 * Programmable mock fetch. Routes are registered per-URL. Every call records
 * the inbound request so tests can assert on Range headers, retries, etc.
 */
export class MockFetch {
  private readonly routes = new Map<string, RouteState>();
  readonly calls: Array<{ url: string; init: FetchInit | undefined }> = [];
  /** Artificial latency added to every response (ms). */
  globalDelayMs = 0;

  route(url: string, init: MockRouteInit): void {
    this.routes.set(url, { ...init, failsSeen: 0, headFailsSeen: 0 });
  }

  updateRoute(url: string, patch: Partial<MockRouteInit>): void {
    const cur = this.routes.get(url);
    if (cur === undefined) throw new Error(`MockFetch: no route for ${url}`);
    Object.assign(cur, patch);
  }

  fetch: InjectedFunctions['fetch'] = async (input, init) => {
    const url = typeof input === 'string' ? input : input.toString();
    this.calls.push({ url, init });
    const route = this.routes.get(url);
    if (route === undefined) {
      return makeResponse({ status: 404, statusText: 'Not Found', body: new Uint8Array() });
    }

    const method = (init?.method ?? 'GET').toUpperCase();
    const signal = init?.signal;

    if (route.delayMs !== undefined || this.globalDelayMs > 0) {
      await delay(Math.max(route.delayMs ?? 0, this.globalDelayMs), signal);
    }

    if (method === 'HEAD') return this.respondHead(route);
    return this.respondGet(route, init);
  };

  private respondHead(route: RouteState): FetchResponse {
    if (route.head === 'missing') {
      return makeResponse({
        status: 405,
        statusText: 'Method Not Allowed',
        body: new Uint8Array(),
      });
    }
    // If `failHeadTimes` is set, fail HEAD that many times before turning
    // cooperative. This lets tests model a "permanently 404" resource (set
    // both fail counts to a large number) without mutating GET semantics.
    const headBudget = route.failHeadTimes;
    if (headBudget !== undefined && route.headFailsSeen < headBudget) {
      route.headFailsSeen += 1;
      return makeResponse({
        status: route.failStatus ?? 503,
        statusText: 'Service Unavailable',
        body: new Uint8Array(),
      });
    }
    const headers = this.baseHeaders(route);
    if (route.head !== 'no-size') headers['content-length'] = String(route.body.length);
    return makeResponse({ status: 200, statusText: 'OK', body: new Uint8Array(), headers });
  }

  private respondGet(route: RouteState, init: FetchInit | undefined): FetchResponse {
    if (route.failTimes !== undefined && route.failsSeen < route.failTimes) {
      route.failsSeen += 1;
      return makeResponse({
        status: route.failStatus ?? 503,
        statusText: 'Service Unavailable',
        body: new Uint8Array(),
      });
    }

    const range =
      init?.headers && init.headers['Range'] !== undefined
        ? init.headers['Range']
        : init?.headers && init.headers['range'] !== undefined
          ? init.headers['range']
          : undefined;

    const full = route.body;
    if (range !== undefined && route.acceptsRanges !== false) {
      const parsed = parseRange(range, full.length);
      if (parsed === null) {
        return makeResponse({
          status: 416,
          statusText: 'Range Not Satisfiable',
          body: new Uint8Array(),
        });
      }
      const slice = full.slice(parsed.start, parsed.end + 1);
      const headers = this.baseHeaders(route);
      headers['content-length'] = String(slice.length);
      headers['content-range'] = `bytes ${parsed.start}-${parsed.end}/${full.length}`;
      const partial: MakeResponseInit = {
        status: 206,
        statusText: 'Partial Content',
        body: slice,
        headers,
      };
      if (route.streamChunks !== undefined) partial.streamChunks = route.streamChunks;
      return makeResponse(partial);
    }

    const headers = this.baseHeaders(route);
    headers['content-length'] = String(full.length);
    const whole: MakeResponseInit = {
      status: route.status ?? 200,
      statusText: 'OK',
      body: full,
      headers,
    };
    if (route.streamChunks !== undefined) whole.streamChunks = route.streamChunks;
    return makeResponse(whole);
  }

  private baseHeaders(route: RouteState): Record<string, string> {
    const headers: Record<string, string> = {};
    if (route.acceptsRanges !== false) headers['accept-ranges'] = 'bytes';
    if (route.etag !== undefined) headers['etag'] = route.etag;
    if (route.lastModified !== undefined) headers['last-modified'] = route.lastModified;
    if (route.contentType !== undefined) headers['content-type'] = route.contentType;
    if (route.contentDisposition !== undefined)
      headers['content-disposition'] = route.contentDisposition;
    if (route.extraHeaders !== undefined) {
      for (const [k, v] of Object.entries(route.extraHeaders)) headers[k.toLowerCase()] = v;
    }
    return headers;
  }
}

interface MakeResponseInit {
  status: number;
  statusText: string;
  body: Uint8Array;
  headers?: Record<string, string>;
  streamChunks?: number[];
}

function makeResponse(init: MakeResponseInit): FetchResponse {
  const headerMap = new Map<string, string>(
    Object.entries(init.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v]),
  );
  const headers: FetchHeaders = {
    get: (name: string): string | null => headerMap.get(name.toLowerCase()) ?? null,
    has: (name: string): boolean => headerMap.has(name.toLowerCase()),
    forEach: (cb: (value: string, name: string) => void): void => {
      for (const [k, v] of headerMap.entries()) cb(v, k);
    },
  };
  const body =
    init.status === 204 || init.body.length === 0
      ? null
      : buildStream(init.body, init.streamChunks);

  return {
    status: init.status,
    statusText: init.statusText,
    ok: init.status >= 200 && init.status < 300,
    headers,
    body,
    arrayBuffer: async () => {
      const ab = new ArrayBuffer(init.body.length);
      new Uint8Array(ab).set(init.body);
      return ab;
    },
    text: async () => new TextDecoder().decode(init.body),
  };
}

function buildStream(body: Uint8Array, chunkSizes?: number[]): ReadableStream<Uint8Array> {
  const pieces: Uint8Array[] = [];
  if (chunkSizes === undefined || chunkSizes.length === 0) {
    pieces.push(body);
  } else {
    let offset = 0;
    for (const size of chunkSizes) {
      if (offset >= body.length) break;
      const end = Math.min(body.length, offset + size);
      pieces.push(body.slice(offset, end));
      offset = end;
    }
    if (offset < body.length) pieces.push(body.slice(offset));
  }
  let i = 0;
  return new ReadableStream<Uint8Array>({
    pull(controller): void {
      if (i >= pieces.length) {
        controller.close();
        return;
      }
      const piece = pieces[i];
      i += 1;
      if (piece !== undefined) controller.enqueue(piece);
      if (i >= pieces.length) controller.close();
    },
  });
}

function parseRange(header: string, totalSize: number): { start: number; end: number } | null {
  const match = /^bytes=(\d+)-(\d*)$/.exec(header.trim());
  if (!match) return null;
  const startRaw = match[1];
  const endRaw = match[2];
  if (startRaw === undefined) return null;
  const start = Number.parseInt(startRaw, 10);
  const end = endRaw === undefined || endRaw === '' ? totalSize - 1 : Number.parseInt(endRaw, 10);
  if (!Number.isFinite(start) || !Number.isFinite(end)) return null;
  if (start < 0 || end < start || start >= totalSize) return null;
  return { start, end: Math.min(end, totalSize - 1) };
}

function delay(ms: number, signal?: AbortSignal): Promise<void> {
  if (ms <= 0) return Promise.resolve();
  return new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    const onAbort = (): void => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
      const err = new Error('Aborted');
      err.name = 'AbortError';
      reject(err);
    };
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}
