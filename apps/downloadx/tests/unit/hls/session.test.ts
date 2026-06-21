import { describe, it, expect, beforeEach } from 'vitest';
import { HlsSession } from '../../../src/hls/session.js';
import { Throttle } from '../../../src/throttle.js';
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

function makeSession(
  harness: ReturnType<typeof makeHarness>,
  overrides?: {
    isCancelled?: () => boolean;
    isPaused?: () => boolean;
  },
) {
  const progress: Array<[number, number]> = [];
  const session = new HlsSession(
    'test-id',
    harness.global,
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

  it('resolves master playlist → selects highest bandwidth stream → downloads segments', async () => {
    harness.fetch.route('https://example.com/master.m3u8', {
      body: new TextEncoder().encode(MASTER_M3U8),
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
    const result = await session.run('https://example.com/master.m3u8');

    expect(result.segmentPaths).toHaveLength(3);
    expect(result.segmentPaths[0]).toBe('/cache/test-id-hls/seg-000000.ts');
    expect(result.segmentPaths[1]).toBe('/cache/test-id-hls/seg-000001.ts');
    expect(result.segmentPaths[2]).toBe('/cache/test-id-hls/seg-000002.ts');

    // Highest bandwidth (720p) selected — 360p.m3u8 never fetched.
    const urls = harness.fetch.calls.map((c) => c.url);
    expect(urls).toContain('https://cdn.example.com/720p.m3u8');
    expect(urls).not.toContain('https://cdn.example.com/360p.m3u8');

    // Progress reported once per batch (3 segments, all in one batch of 4).
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
    const result = await session.run('https://example.com/media.m3u8');

    expect(result.segmentPaths).toHaveLength(3);
    expect(result.playlist.totalDurationSec).toBeCloseTo(28.5);
  });

  it('writes segment file contents to disk', async () => {
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
    const result = await session.run('https://example.com/media.m3u8');

    for (const p of result.segmentPaths) {
      const data = await harness.io.readFile(p);
      expect(data).toEqual(SEG_BODY);
    }
  });

  it('throws on live stream', async () => {
    harness.fetch.route('https://example.com/live.m3u8', {
      body: new TextEncoder().encode(LIVE_MEDIA_M3U8),
      acceptsRanges: false,
    });

    const { session } = makeSession(harness);
    await expect(session.run('https://example.com/live.m3u8')).rejects.toThrow(
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
    const result = await session.run('https://example.com/media.m3u8');
    expect(result.segmentPaths).toHaveLength(1);

    // 2 calls: 1 fail + 1 success
    const segCalls = harness.fetch.calls.filter((c) =>
      c.url.includes('seg-000001'),
    );
    expect(segCalls).toHaveLength(2);
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
    await expect(session.run('https://example.com/media.m3u8')).rejects.toThrow('cancelled');
  });
});
