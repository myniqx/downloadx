import { describe, expect, it } from 'vitest';

import { Download } from '../../src/download.js';
import type { DlxContext, DownloadOptions } from '../../src/types.js';
import { makeHarness } from '../helpers/config.js';

// ---------------------------------------------------------------------------
// HLS integration — exercises the unified chunk pipeline: each segment is an
// isSegment Chunk, downloaded via driveChunks, then concatenated.
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
`;

const SEG_BODY = new Uint8Array([0xaa, 0xbb, 0xcc, 0xdd]);

function makeCtx(
  harness: ReturnType<typeof makeHarness>,
  addedUrls?: Array<{ url: string; options?: DownloadOptions }>,
): DlxContext {
  return {
    ...harness.global,
    async addUrl(url: string, options?: DownloadOptions) {
      addedUrls?.push({ url, options });
      return undefined;
    },
  };
}

function routeMedia(harness: ReturnType<typeof makeHarness>, url: string, body = MEDIA_M3U8): void {
  harness.fetch.route(url, {
    body: new TextEncoder().encode(body),
    contentType: 'application/vnd.apple.mpegurl',
    acceptsRanges: false,
  });
}

function routeSegments(harness: ReturnType<typeof makeHarness>, count: number): void {
  for (let i = 1; i <= count; i++) {
    harness.fetch.route(`https://cdn.example.com/seg-${String(i).padStart(6, '0')}.ts`, {
      body: SEG_BODY,
      contentType: 'video/mp2t',
      acceptsRanges: false,
    });
  }
}

describe('HLS download integration', () => {
  it('downloads a media playlist as segments and concatenates them', async () => {
    const harness = makeHarness({ cachePath: '/cache', targetPath: '/dl' });
    routeMedia(harness, 'https://example.com/media.m3u8');
    routeSegments(harness, 3);

    const dl = new Download('h1', 'https://example.com/media.m3u8', {}, makeCtx(harness));
    await dl.start();

    expect(dl.state).toBe('completed');
    const out = await harness.io.readFile('/dl/media.m3u8');
    // Output filename derives from URL; content is 3 × SEG_BODY.
    expect(out).toEqual(new Uint8Array([...SEG_BODY, ...SEG_BODY, ...SEG_BODY]));
  });

  it('resolves a single-stream master, then downloads its media segments', async () => {
    const harness = makeHarness({ cachePath: '/cache', targetPath: '/dl' });
    harness.fetch.route('https://example.com/master.m3u8', {
      body: new TextEncoder().encode(`#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
https://cdn.example.com/720p.m3u8
`),
      contentType: 'application/vnd.apple.mpegurl',
      acceptsRanges: false,
    });
    routeMedia(harness, 'https://cdn.example.com/720p.m3u8');
    routeSegments(harness, 3);

    const dl = new Download('h2', 'https://example.com/master.m3u8', {}, makeCtx(harness));
    await dl.start();

    expect(dl.state).toBe('completed');
  });

  it('master with multiple streams registers idle downloads and completes', async () => {
    const harness = makeHarness({ cachePath: '/cache', targetPath: '/dl' });
    harness.fetch.route('https://example.com/master.m3u8', {
      body: new TextEncoder().encode(MASTER_M3U8),
      contentType: 'application/vnd.apple.mpegurl',
      acceptsRanges: false,
    });

    const addedUrls: Array<{ url: string; options?: DownloadOptions }> = [];
    const dl = new Download('h3', 'https://example.com/master.m3u8', {}, makeCtx(harness, addedUrls));
    await dl.start();

    expect(dl.state).toBe('completed');
    expect(addedUrls).toHaveLength(2);
    expect(addedUrls[0]!.options?.autoStart).toBe(false);
  });

  it('errors on a live stream', async () => {
    const harness = makeHarness({ cachePath: '/cache', targetPath: '/dl' });
    routeMedia(harness, 'https://example.com/live.m3u8', LIVE_MEDIA_M3U8);

    const dl = new Download('h4', 'https://example.com/live.m3u8', {}, makeCtx(harness));
    await dl.start();

    expect(dl.state).toBe('error');
    expect(dl.meta.errorMessage).toContain('Live HLS');
  });

  it('retries a failing segment then completes', async () => {
    const harness = makeHarness({ cachePath: '/cache', targetPath: '/dl', maxRetries: 2, retryDelay: 1 });
    routeMedia(harness, 'https://example.com/media.m3u8', `#EXTM3U
#EXT-X-TARGETDURATION:5
#EXTINF:5.0,
https://cdn.example.com/seg-000001.ts
#EXT-X-ENDLIST
`);
    harness.fetch.route('https://cdn.example.com/seg-000001.ts', {
      body: SEG_BODY,
      failTimes: 1,
      failStatus: 503,
      acceptsRanges: false,
    });

    const dl = new Download('h5', 'https://example.com/media.m3u8', {}, makeCtx(harness));
    await dl.start();

    expect(dl.state).toBe('completed');
    const segCalls = harness.fetch.calls.filter((c) => c.url.includes('seg-000001'));
    expect(segCalls).toHaveLength(2);
  });

  it('caps concurrent segment downloads at targetChunkCount', async () => {
    const harness = makeHarness({ cachePath: '/cache', targetPath: '/dl', targetChunkCount: 2 });
    routeMedia(harness, 'https://example.com/media.m3u8', `#EXTM3U
#EXT-X-TARGETDURATION:5
#EXTINF:5.0,
https://cdn.example.com/seg-000001.ts
#EXTINF:5.0,
https://cdn.example.com/seg-000002.ts
#EXTINF:5.0,
https://cdn.example.com/seg-000003.ts
#EXTINF:5.0,
https://cdn.example.com/seg-000004.ts
#EXTINF:5.0,
https://cdn.example.com/seg-000005.ts
#EXT-X-ENDLIST
`);

    let live = 0;
    let maxLive = 0;
    const original = harness.fetch.fetch;
    harness.io.fetch = async (url, init) => {
      if (url.includes('seg-')) {
        live++;
        maxLive = Math.max(maxLive, live);
        // Yield so concurrent segment requests overlap.
        await new Promise((r) => setTimeout(r, 5));
        const res = await original(url, init);
        live--;
        return res;
      }
      return original(url, init);
    };
    routeSegments(harness, 5);

    const dl = new Download('h6', 'https://example.com/media.m3u8', {}, makeCtx(harness));
    await dl.start();

    expect(dl.state).toBe('completed');
    expect(maxLive).toBeLessThanOrEqual(2);
  });

  it('resume skips already-downloaded segment files', async () => {
    const harness = makeHarness({ cachePath: '/cache', targetPath: '/dl' });
    routeMedia(harness, 'https://example.com/media.m3u8');
    routeSegments(harness, 3);

    // Pre-place segment 0 as if a previous run downloaded it.
    await harness.io.mkdir('/cache/h7-hls');
    await harness.io.writeFile('/cache/h7-hls/seg-000000.ts', SEG_BODY);

    const dl = new Download('h7', 'https://example.com/media.m3u8', {}, makeCtx(harness));
    await dl.start();

    expect(dl.state).toBe('completed');
    // Only segments 2 and 3 should have been fetched (seg 1 was pre-placed).
    const segUrls = harness.fetch.calls.map((c) => c.url).filter((u) => u.includes('seg-'));
    expect(segUrls).not.toContain('https://cdn.example.com/seg-000001.ts');
    expect(segUrls).toContain('https://cdn.example.com/seg-000002.ts');
    expect(segUrls).toContain('https://cdn.example.com/seg-000003.ts');
  });

  it('reports segment-based progress (hlsSegmentsDone / total)', async () => {
    const harness = makeHarness({ cachePath: '/cache', targetPath: '/dl' });
    routeMedia(harness, 'https://example.com/media.m3u8');
    routeSegments(harness, 3);

    const dl = new Download('h8', 'https://example.com/media.m3u8', {}, makeCtx(harness));
    await dl.start();

    const d = dl.describe();
    expect(d.hlsTotalSegments).toBe(3);
    expect(d.hlsSegmentsDone).toBe(3);
    expect(d.percent).toBe(100);
  });
});
