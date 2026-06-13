import { describe, expect, it } from 'vitest';

import { filenameFromDisposition, filenameFromUrl, probeUrl } from '../../src/probe.js';
import { makeBytes } from '../helpers/fixtures.js';
import { MockFetch } from '../helpers/mockFetch.js';

describe('probeUrl', () => {
  it('uses HEAD when it returns a usable content-length', async () => {
    const fetch = new MockFetch();
    fetch.route('https://x/y.bin', {
      body: makeBytes(1024),
      etag: 'W/"abc"',
      lastModified: 'Wed, 21 Oct 2020 07:28:00 GMT',
      contentType: 'application/octet-stream',
    });
    const result = await probeUrl({ fetch: fetch.fetch, url: 'https://x/y.bin' });
    expect(result.totalSize).toBe(1024);
    expect(result.acceptsRanges).toBe(true);
    expect(result.etag).toBe('W/"abc"');
    expect(result.lastModified).toBe('Wed, 21 Oct 2020 07:28:00 GMT');
    expect(result.contentType).toBe('application/octet-stream');
    expect(result.filename).toBe('y.bin');
    expect(fetch.calls[0]?.init?.method).toBe('HEAD');
  });

  it('falls back to a ranged GET when HEAD returns no size', async () => {
    const fetch = new MockFetch();
    fetch.route('https://x/no-size', { body: makeBytes(2048), head: 'no-size' });
    const result = await probeUrl({ fetch: fetch.fetch, url: 'https://x/no-size' });
    expect(result.totalSize).toBe(2048);
    expect(result.acceptsRanges).toBe(true);
    const methods = fetch.calls.map((c) => c.init?.method);
    expect(methods).toEqual(['HEAD', 'GET']);
    const rangeHeader = fetch.calls[1]?.init?.headers?.['Range'];
    expect(rangeHeader).toBe('bytes=0-0');
  });

  it('falls back to GET when HEAD returns 405', async () => {
    const fetch = new MockFetch();
    fetch.route('https://x/nohead', { body: makeBytes(100), head: 'missing' });
    const result = await probeUrl({ fetch: fetch.fetch, url: 'https://x/nohead' });
    expect(result.totalSize).toBe(100);
    expect(fetch.calls.map((c) => c.init?.method)).toEqual(['HEAD', 'GET']);
  });

  it('detects missing range support', async () => {
    const fetch = new MockFetch();
    fetch.route('https://x/full', {
      body: makeBytes(512),
      acceptsRanges: false,
      head: 'no-size', // force fallback to range GET, which will return 200
    });
    const result = await probeUrl({ fetch: fetch.fetch, url: 'https://x/full' });
    expect(result.acceptsRanges).toBe(false);
  });

  it('uses filename hint when provided', async () => {
    const fetch = new MockFetch();
    fetch.route('https://x/stream', { body: makeBytes(10) });
    const result = await probeUrl({
      fetch: fetch.fetch,
      url: 'https://x/stream',
      filenameHint: 'custom-name.bin',
    });
    expect(result.filename).toBe('custom-name.bin');
  });

  it('extracts filename from Content-Disposition', async () => {
    const fetch = new MockFetch();
    fetch.route('https://x/stream', {
      body: makeBytes(10),
      contentDisposition: 'attachment; filename="report.pdf"',
    });
    const result = await probeUrl({ fetch: fetch.fetch, url: 'https://x/stream' });
    expect(result.filename).toBe('report.pdf');
  });
});

describe('filenameFromDisposition', () => {
  it('prefers RFC 5987 filename* when present', () => {
    expect(
      filenameFromDisposition('attachment; filename="ascii.bin"; filename*=UTF-8\'\'%E2%98%83.bin'),
    ).toBe('☃.bin');
  });

  it('handles quoted and unquoted plain filename=', () => {
    expect(filenameFromDisposition('attachment; filename="a b.zip"')).toBe('a b.zip');
    expect(filenameFromDisposition('attachment; filename=plain.bin')).toBe('plain.bin');
  });

  it('returns null when no filename is present', () => {
    expect(filenameFromDisposition('inline')).toBeNull();
    expect(filenameFromDisposition(null)).toBeNull();
  });
});

describe('filenameFromUrl', () => {
  it('pulls the last path segment and decodes it', () => {
    expect(filenameFromUrl('https://example.com/a/b/%E2%98%83.bin')).toBe('☃.bin');
  });

  it('returns null for malformed URLs or empty paths', () => {
    expect(filenameFromUrl('not-a-url')).toBeNull();
    expect(filenameFromUrl('https://example.com/')).toBeNull();
  });
});
