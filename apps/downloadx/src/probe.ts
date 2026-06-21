import type { FetchInit, FetchResponse, ProbeResult } from './types.js';

export interface ProbeOptions {
  fetch: (input: string | URL, init?: FetchInit) => Promise<FetchResponse>;
  url: string;
  headers?: Record<string, string>;
  signal?: AbortSignal;
  /** Optional filename override; if given it takes precedence over inference. */
  filenameHint?: string;
}

/**
 * Probes a URL to determine size, range support, validators, and filename.
 *
 * Strategy:
 *   1. Try a HEAD request. Many CDNs respond correctly and it's cheap.
 *   2. If HEAD fails or returns 405/501 or lacks useful headers, fall back to
 *      a `Range: bytes=0-0` GET, which every range-capable server understands.
 *   3. The GET body is intentionally not consumed — we only need the headers.
 */
export async function probeUrl(opts: ProbeOptions): Promise<ProbeResult> {
  const headResult = await tryHead(opts);
  if (headResult && headResult.usable) {
    return finalize(opts, headResult);
  }

  const rangeResult = await tryRangeGet(opts);
  return finalize(opts, rangeResult);
}

interface ProbeRaw {
  status: number;
  finalUrl: string;
  totalSize: number | null;
  acceptsRanges: boolean;
  etag: string | null;
  lastModified: string | null;
  contentType: string | null;
  contentDisposition: string | null;
  usable: boolean;
}

async function tryHead(opts: ProbeOptions): Promise<ProbeRaw | null> {
  try {
    const headerInit: Record<string, string> = { ...(opts.headers ?? {}) };
    const init: FetchInit = {
      method: 'HEAD',
      headers: headerInit,
    };
    if (opts.signal !== undefined) init.signal = opts.signal;
    const res = await opts.fetch(opts.url, init);
    if (!res.ok) return { ...extract(opts.url, res), usable: false };
    const raw = extract(opts.url, res);
    // HEAD is trusted only if it tells us the size; otherwise fall through to
    // a ranged GET which forces the origin to commit.
    raw.usable = raw.totalSize !== null;
    return raw;
  } catch {
    return null;
  }
}

async function tryRangeGet(opts: ProbeOptions): Promise<ProbeRaw> {
  const headerInit: Record<string, string> = {
    ...(opts.headers ?? {}),
    Range: 'bytes=0-0',
  };
  const init: FetchInit = { method: 'GET', headers: headerInit };
  if (opts.signal !== undefined) init.signal = opts.signal;
  const res = await opts.fetch(opts.url, init);
  // Drain body so connection can be reused — if the runtime returns a stream
  // we cancel it to avoid buffering the whole payload.
  if (res.body && typeof res.body.cancel === 'function') {
    await res.body.cancel().catch(() => undefined);
  }
  // Probe must refuse to produce a result for failed responses. 416 is a
  // special case: the server rejected our range but the resource itself is
  // reachable, so treat it as "no range support" rather than a hard failure.
  if (!res.ok && res.status !== 206 && res.status !== 416) {
    throw new Error(
      `probe: HTTP ${res.status} ${'statusText' in res ? (res as { statusText: string }).statusText : ''}`,
    );
  }
  const raw = extract(opts.url, res);
  raw.acceptsRanges = raw.acceptsRanges || res.status === 206;
  raw.usable = true;
  return raw;
}

function extract(
  url: string,
  res: { status: number; headers: { get(n: string): string | null }; url?: string },
): ProbeRaw {
  const contentLength = parseIntHeader(res.headers.get('content-length'));
  const contentRange = res.headers.get('content-range');
  const totalSize = contentRange ? parseContentRangeTotal(contentRange) : contentLength;
  const acceptRanges = res.headers.get('accept-ranges');
  const acceptsRanges = acceptRanges !== null && acceptRanges.toLowerCase().includes('bytes');

  return {
    status: res.status,
    // Post-redirect URL when the fetch implementation exposes it — chunk
    // requests then skip the redirect chain entirely.
    finalUrl: typeof res.url === 'string' && res.url.length > 0 ? res.url : url,
    totalSize,
    acceptsRanges,
    etag: res.headers.get('etag'),
    lastModified: res.headers.get('last-modified'),
    contentType: res.headers.get('content-type'),
    contentDisposition: res.headers.get('content-disposition'),
    usable: false,
  };
}

function finalize(opts: ProbeOptions, raw: ProbeRaw): ProbeResult {
  const filename =
    opts.filenameHint ??
    filenameFromDisposition(raw.contentDisposition) ??
    filenameFromUrl(opts.url) ??
    `download-${Date.now()}`;

  const ct = raw.contentType?.toLowerCase() ?? '';
  const isHls =
    ct.includes('mpegurl') ||
    ct.includes('x-m3u8') ||
    (opts.url.split('?')[0] ?? '').toLowerCase().endsWith('.m3u8');

  return {
    url: opts.url,
    finalUrl: raw.finalUrl,
    totalSize: raw.totalSize,
    acceptsRanges: raw.acceptsRanges,
    etag: raw.etag,
    lastModified: raw.lastModified,
    contentType: raw.contentType,
    filename,
    isHls,
  };
}

function parseIntHeader(value: string | null): number | null {
  if (value === null) return null;
  const n = Number.parseInt(value, 10);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

/** Parses the "total" segment of a `Content-Range: bytes 0-0/12345` header. */
function parseContentRangeTotal(value: string): number | null {
  const match = /\/(\d+|\*)$/.exec(value.trim());
  if (!match) return null;
  const total = match[1];
  if (total === undefined || total === '*') return null;
  const n = Number.parseInt(total, 10);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

/** Extracts filename from `Content-Disposition`, honouring RFC 5987 `filename*`. */
export function filenameFromDisposition(value: string | null): string | null {
  if (value === null) return null;
  // RFC 5987: filename*=UTF-8''encoded — takes precedence.
  const star = /filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)/i.exec(value);
  if (star?.[1]) {
    try {
      return decodeURIComponent(star[1].trim());
    } catch {
      /* fall through */
    }
  }
  const plain = /filename\s*=\s*("([^"]+)"|([^;]+))/i.exec(value);
  const picked = plain?.[2] ?? plain?.[3];
  if (picked === undefined) return null;
  return picked.trim();
}

/** Last path segment of the URL, URL-decoded. Returns null if not derivable. */
export function filenameFromUrl(url: string): string | null {
  try {
    const parsed = new URL(url);
    const segments = parsed.pathname.split('/').filter((s) => s.length > 0);
    const last = segments[segments.length - 1];
    if (last === undefined) return null;
    return decodeURIComponent(last);
  } catch {
    return null;
  }
}
