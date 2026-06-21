import { describe, it, expect, beforeEach } from 'vitest';
import { HlsSession } from '../../../src/hls/session.js';
import { Throttle } from '../../../src/throttle.js';
import type { DlxContext, DownloadOptions } from '../../../src/types.js';
import { makeHarness } from '../../helpers/config.js';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const MASTER_M3U8 = `#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
https://cdn.example.com/720p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360
https://cdn.example.com/360p.m3u8
`;

const MEDIA_M3U8 = `#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
https://cdn.example.com/seg-000001.ts
#EXTINF:10.0,
https://cdn.example.com/seg-000002.ts
#EXTINF:8.5,
https://cdn.example.com/seg-000003.ts
#EXT-X-ENDLIST
`;

const LIVE_MEDIA_M3U8 = `#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
https://cdn.example.com/seg-000001.ts
#EXTINF:10.0,
https://cdn.example.com/seg-000002.ts
`;

const SEG_BODY = new Uint8Array([0xAA, 0xBB, 0xCC, 0xDD]);

function makeContext(
  harness: ReturnType<typeof makeHarness>,
  addedUrls?: Array<{ url: string; options?: DownloadOptions }>,
): DlxContext {
  return {
    ...harness.global,
    async addUrl(url: string, options?: DownloadOptions) {
      addedUrls?.push({ url, options });
    },
  };
}

function makeSession(
  harness: ReturnType<typeof makeHarness>,
  overrides?: {
    isCancelled?: () => boolean;
    isPaused?: () => boolean;
    addedUrls?: Array<{ url: string; options?: DownloadOptions }>;
  },
) {
  const progress: Array<[number, number]> = [];
  const context = makeContext(harness, overrides?.addedUrls);
  const session = new HlsSession(
    'test-id',
    context,
    new Throttle(0),
    {
      onProgress: (done, total) => progress.push([done, total]),
      onError: () => {},
      isCancelled: overrides?.isCancelled ?? (() => false),
      isPaused: overrides?.isPaused ?? (() => false),
    },
  );
  return { session, progress };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('HlsSession', () => {
  let harness: ReturnType<typeof makeHarness>;

  beforeEach(() => {
    harness = makeHarness({ cachePath: '/cache', targetPath: '/dl' });
  });

  it('master playlist with multiple streams → registers idle downloads, returns multi-stream', async () => {
    harness.fetch.route('https://example.com/master.m3u8', {
      body: new TextEncoder().encode(MASTER_M3U8),
      contentType: 'application/vnd.apple.mpegurl',
      acceptsRanges: false,
    });

    const addedUrls: Array<{ url: string; options?: DownloadOptions }> = [];
    const { session } = makeSession(harness, { addedUrls });
    const result = await session.run('https://example.com/master.m3u8', '/dl/output.ts', 'output.ts');

    expect(result).toMatchObject({ type: 'multi-stream' });
    expect(addedUrls).toHaveLength(2);
    expect(addedUrls[0]!.url).toBe('https://cdn.example.com/720p.m3u8');
    expect(addedUrls[0]!.options?.filename).toBe('output 1280x720.ts');
    expect(addedUrls[0]!.options?.autoStart).toBe(false);
    expect(addedUrls[1]!.url).toBe('https://cdn.example.com/360p.m3u8');
    expect(addedUrls[1]!.options?.filename).toBe('output 640x360.ts');
  });

  it('master playlist with single stream → downloads segments directly', async () => {
    const SINGLE_STREAM_MASTER = `#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
https://cdn.example.com/720p.m3u8
`;
    harness.fetch.route('https://example.com/master.m3u8', {
      body: new TextEncoder().encode(SINGLE_STREAM_MASTER),
      contentType: 'application/vnd.apple.mpegurl',
      acceptsRanges: false,
    });
    harness.fetch.route('https://cdn.example.com/720p.m3u8', {
      body: new TextEncoder().encode(MEDIA_M3U8),
      contentType: 'application/vnd.apple.mpegurl',
      acceptsRanges: false,
    });
    for (let i = 1; i <= 3; i++) {
      harness.fetch.route(`https://cdn.example.com/seg-${String(i).padStart(6, '0')}.ts`, {
        body: SEG_BODY,
        contentType: 'video/mp2t',
        acceptsRanges: false,
      });
    }

    const { session, progress } = makeSession(harness);
    const result = await session.run('https://example.com/master.m3u8', '/dl/output.ts', 'output.ts');

    expect(result).toMatchObject({ segmentPaths: expect.any(Array) });
    if (!('segmentPaths' in result)) return;
    expect(result.segmentPaths).toHaveLength(3);
    expect(result.segmentPaths[0]).toBe('/cache/test-id-hls/seg-000000.ts');

    const urls = harness.fetch.calls.map((c) => c.url);
    expect(urls).toContain('https://cdn.example.com/720p.m3u8');
    expect(progress).toEqual([[3, 3]]);
  });

  it('works with a direct media playlist (no master)', async () => {
    harness.fetch.route('https://example.com/media.m3u8', {
      body: new TextEncoder().encode(MEDIA_M3U8),
      contentType: 'application/vnd.apple.mpegurl',
      acceptsRanges: false,
    });
    for (let i = 1; i <= 3; i++) {
      harness.fetch.route(`https://cdn.example.com/seg-${String(i).padStart(6, '0')}.ts`, {
        body: SEG_BODY,
        acceptsRanges: false,
      });
    }

    const { session } = makeSession(harness);
    const result = await session.run('https://example.com/media.m3u8', '/dl/output.ts', 'output.ts');

    expect(result.segmentPaths).toHaveLength(3);
    expect(result.playlist.totalDurationSec).toBeCloseTo(28.5);
  });

  it('writes segment file contents to disk and binary-concats them', async () => {
    harness.fetch.route('https://example.com/media.m3u8', {
      body: new TextEncoder().encode(MEDIA_M3U8),
      acceptsRanges: false,
    });
    for (let i = 1; i <= 3; i++) {
      harness.fetch.route(`https://cdn.example.com/seg-${String(i).padStart(6, '0')}.ts`, {
        body: SEG_BODY,
        acceptsRanges: false,
      });
    }

    const { session } = makeSession(harness);
    const result = await session.run('https://example.com/media.m3u8', '/dl/output.ts', 'output.ts');

    for (const p of result.segmentPaths) {
      const data = await harness.io.readFile(p);
      expect(data).toEqual(SEG_BODY);
    }

    // Binary concat: output should be 3 × SEG_BODY.
    const expected = new Uint8Array([...SEG_BODY, ...SEG_BODY, ...SEG_BODY]);
    const output = await harness.io.readFile('/dl/output.ts');
    expect(output).toEqual(expected);
    expect(result.outputPath).toBe('/dl/output.ts');
  });

  it('throws on live stream', async () => {
    harness.fetch.route('https://example.com/live.m3u8', {
      body: new TextEncoder().encode(LIVE_MEDIA_M3U8),
      acceptsRanges: false,
    });

    const { session } = makeSession(harness);
    await expect(session.run('https://example.com/live.m3u8', '/dl/output.ts', 'output.ts')).rejects.toThrow(
      'Live HLS streams are not supported',
    );
  });

  it('retries a failing segment', async () => {
    harness = makeHarness({ cachePath: '/cache', maxRetries: 2, retryDelay: 1 });

    harness.fetch.route('https://example.com/media.m3u8', {
      body: new TextEncoder().encode(`#EXTM3U
#EXT-X-TARGETDURATION:5
#EXTINF:5.0,
https://cdn.example.com/seg-000001.ts
#EXT-X-ENDLIST
`),
      acceptsRanges: false,
    });
    harness.fetch.route('https://cdn.example.com/seg-000001.ts', {
      body: SEG_BODY,
      failTimes: 1,
      failStatus: 503,
      acceptsRanges: false,
    });

    const { session } = makeSession(harness);
    const result = await session.run('https://example.com/media.m3u8', '/dl/output.ts', 'output.ts');
    expect(result.segmentPaths).toHaveLength(1);

    // 2 calls: 1 fail + 1 success
    const segCalls = harness.fetch.calls.filter((c) =>
      c.url.includes('seg-000001'),
    );
    expect(segCalls).toHaveLength(2);
  });

  it('multi-stream: bandwidth fallback filename when no resolution', async () => {
    const MASTER_NO_RES = `#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=5000000
https://cdn.example.com/hi.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1000000
https://cdn.example.com/lo.m3u8
`;
    harness.fetch.route('https://example.com/master.m3u8', {
      body: new TextEncoder().encode(MASTER_NO_RES),
      acceptsRanges: false,
    });

    const addedUrls: Array<{ url: string; options?: DownloadOptions }> = [];
    const { session } = makeSession(harness, { addedUrls });
    await session.run('https://example.com/master.m3u8', '/dl/film.mkv', 'film.mkv');

    expect(addedUrls[0]!.options?.filename).toBe('film 5000kbps.mkv');
    expect(addedUrls[1]!.options?.filename).toBe('film 1000kbps.mkv');
  });

  it('multi-stream: stream-N fallback filename when no resolution or bandwidth', async () => {
    const MASTER_NO_META = `#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=0
https://cdn.example.com/a.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=0
https://cdn.example.com/b.m3u8
`;
    harness.fetch.route('https://example.com/master.m3u8', {
      body: new TextEncoder().encode(MASTER_NO_META),
      acceptsRanges: false,
    });

    const addedUrls: Array<{ url: string; options?: DownloadOptions }> = [];
    const { session } = makeSession(harness, { addedUrls });
    await session.run('https://example.com/master.m3u8', '/dl/film.mkv', 'film.mkv');

    expect(addedUrls[0]!.options?.filename).toBe('film stream-1.mkv');
    expect(addedUrls[1]!.options?.filename).toBe('film stream-2.mkv');
  });

  it('multi-stream: targetPath from outputPath is forwarded to addUrl', async () => {
    harness.fetch.route('https://example.com/master.m3u8', {
      body: new TextEncoder().encode(MASTER_M3U8),
      acceptsRanges: false,
    });

    const addedUrls: Array<{ url: string; options?: DownloadOptions }> = [];
    const { session } = makeSession(harness, { addedUrls });
    await session.run('https://example.com/master.m3u8', '/downloads/movies/output.ts', 'output.ts');

    for (const entry of addedUrls) {
      expect(entry.options?.targetPath).toBe('/downloads/movies');
    }
  });

  it('uses injected concatSegments callback instead of binary fallback', async () => {
    const concatCalls: Array<{ segments: string[]; output: string }> = [];
    harness.fs.concatSegments = async (segments, output) => {
      concatCalls.push({ segments, output });
    };

    harness.fetch.route('https://example.com/media.m3u8', {
      body: new TextEncoder().encode(MEDIA_M3U8),
      acceptsRanges: false,
    });
    for (let i = 1; i <= 3; i++) {
      harness.fetch.route(`https://cdn.example.com/seg-${String(i).padStart(6, '0')}.ts`, {
        body: SEG_BODY,
        acceptsRanges: false,
      });
    }

    const { session } = makeSession(harness);
    await session.run('https://example.com/media.m3u8', '/dl/output.ts', 'output.ts');

    expect(concatCalls).toHaveLength(1);
    expect(concatCalls[0]!.output).toBe('/dl/output.ts');
    expect(concatCalls[0]!.segments).toHaveLength(3);
  });

  it('throws on cancel', async () => {
    harness.fetch.route('https://example.com/media.m3u8', {
      body: new TextEncoder().encode(MEDIA_M3U8),
      acceptsRanges: false,
    });
    for (let i = 1; i <= 3; i++) {
      harness.fetch.route(`https://cdn.example.com/seg-${String(i).padStart(6, '0')}.ts`, {
        body: SEG_BODY,
        acceptsRanges: false,
      });
    }

    const { session } = makeSession(harness, { isCancelled: () => true });
    await expect(session.run('https://example.com/media.m3u8', '/dl/output.ts', 'output.ts')).rejects.toThrow('cancelled');
  });
});
