import { describe, it, expect, beforeEach } from 'vitest';
import { HlsSession } from '../../../src/hls/session.js';
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
  addedUrls?: Array<{ url: string; options?: DownloadOptions }>,
) {
  const context = makeContext(harness, addedUrls);
  return new HlsSession('test-id', context);
}

// ---------------------------------------------------------------------------
// Tests — the session only resolves playlists, concatenates and cleans up.
// Actual segment downloading is covered in tests/integration/hls.test.ts.
// ---------------------------------------------------------------------------

describe('HlsSession.resolve', () => {
  let harness: ReturnType<typeof makeHarness>;

  beforeEach(() => {
    harness = makeHarness({ cachePath: '/cache', targetPath: '/dl' });
  });

  it('master playlist with multiple streams → multi-stream result (no download)', async () => {
    harness.fetch.route('https://example.com/master.m3u8', {
      body: new TextEncoder().encode(MASTER_M3U8),
      contentType: 'application/vnd.apple.mpegurl',
      acceptsRanges: false,
    });

    const session = makeSession(harness);
    const result = await session.resolve('https://example.com/master.m3u8');

    expect(result.type).toBe('multi-stream');
    if (result.type !== 'multi-stream') return;
    expect(result.streams).toHaveLength(2);
    expect(result.streams[0]!.uri).toBe('https://cdn.example.com/720p.m3u8');
  });

  it('master playlist with single stream → resolves the media playlist', async () => {
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

    const session = makeSession(harness);
    const result = await session.resolve('https://example.com/master.m3u8');

    expect(result.type).toBe('media');
    if (result.type !== 'media') return;
    expect(result.playlist.segments).toHaveLength(3);
  });

  it('direct media playlist (no master)', async () => {
    harness.fetch.route('https://example.com/media.m3u8', {
      body: new TextEncoder().encode(MEDIA_M3U8),
      contentType: 'application/vnd.apple.mpegurl',
      acceptsRanges: false,
    });

    const session = makeSession(harness);
    const result = await session.resolve('https://example.com/media.m3u8');

    expect(result.type).toBe('media');
    if (result.type !== 'media') return;
    expect(result.playlist.segments).toHaveLength(3);
    expect(result.playlist.totalDurationSec).toBeCloseTo(28.5);
  });

  it('throws on live stream', async () => {
    harness.fetch.route('https://example.com/live.m3u8', {
      body: new TextEncoder().encode(LIVE_MEDIA_M3U8),
      acceptsRanges: false,
    });

    const session = makeSession(harness);
    await expect(session.resolve('https://example.com/live.m3u8')).rejects.toThrow(
      'Live HLS streams are not supported',
    );
  });
});

describe('HlsSession.registerStreams', () => {
  let harness: ReturnType<typeof makeHarness>;

  beforeEach(() => {
    harness = makeHarness({ cachePath: '/cache', targetPath: '/dl' });
  });

  it('registers each stream as an idle download with a resolution qualifier', async () => {
    const addedUrls: Array<{ url: string; options?: DownloadOptions }> = [];
    const session = makeSession(harness, addedUrls);
    const result = await (async () => {
      harness.fetch.route('https://example.com/master.m3u8', {
        body: new TextEncoder().encode(MASTER_M3U8),
        acceptsRanges: false,
      });
      return session.resolve('https://example.com/master.m3u8');
    })();
    if (result.type !== 'multi-stream') throw new Error('expected multi-stream');

    await session.registerStreams(result.streams, 'output.ts', '/dl/output.ts');

    expect(addedUrls).toHaveLength(2);
    expect(addedUrls[0]!.url).toBe('https://cdn.example.com/720p.m3u8');
    expect(addedUrls[0]!.options?.filename).toBe('output 1280x720.ts');
    expect(addedUrls[0]!.options?.autoStart).toBe(false);
    expect(addedUrls[1]!.options?.filename).toBe('output 640x360.ts');
  });

  it('bandwidth fallback filename when no resolution', async () => {
    const streams = [
      { bandwidth: 5000000, resolution: null, codecs: null, uri: 'https://cdn.example.com/hi.m3u8' },
      { bandwidth: 1000000, resolution: null, codecs: null, uri: 'https://cdn.example.com/lo.m3u8' },
    ];
    const addedUrls: Array<{ url: string; options?: DownloadOptions }> = [];
    const session = makeSession(harness, addedUrls);
    await session.registerStreams(streams, 'film.mkv', '/dl/film.mkv');

    expect(addedUrls[0]!.options?.filename).toBe('film 5000kbps.mkv');
    expect(addedUrls[1]!.options?.filename).toBe('film 1000kbps.mkv');
  });

  it('stream-N fallback filename when no resolution or bandwidth', async () => {
    const streams = [
      { bandwidth: 0, resolution: null, codecs: null, uri: 'https://cdn.example.com/a.m3u8' },
      { bandwidth: 0, resolution: null, codecs: null, uri: 'https://cdn.example.com/b.m3u8' },
    ];
    const addedUrls: Array<{ url: string; options?: DownloadOptions }> = [];
    const session = makeSession(harness, addedUrls);
    await session.registerStreams(streams, 'film.mkv', '/dl/film.mkv');

    expect(addedUrls[0]!.options?.filename).toBe('film stream-1.mkv');
    expect(addedUrls[1]!.options?.filename).toBe('film stream-2.mkv');
  });

  it('targetPath from outputPath is forwarded to addUrl', async () => {
    const streams = [
      { bandwidth: 2000000, resolution: '1280x720', codecs: null, uri: 'https://cdn.example.com/720p.m3u8' },
    ];
    const addedUrls: Array<{ url: string; options?: DownloadOptions }> = [];
    const session = makeSession(harness, addedUrls);
    await session.registerStreams(streams, 'output.ts', '/downloads/movies/output.ts');

    expect(addedUrls[0]!.options?.targetPath).toBe('/downloads/movies');
  });
});

describe('HlsSession.concat / cleanup', () => {
  let harness: ReturnType<typeof makeHarness>;

  beforeEach(() => {
    harness = makeHarness({ cachePath: '/cache', targetPath: '/dl' });
  });

  it('binary-concats segment files into the output', async () => {
    const a = new Uint8Array([1, 2, 3]);
    const b = new Uint8Array([4, 5]);
    await harness.io.writeFile('/cache/seg-a.ts', a);
    await harness.io.writeFile('/cache/seg-b.ts', b);

    const session = makeSession(harness);
    await session.concat(['/cache/seg-a.ts', '/cache/seg-b.ts'], '/dl/output.ts');

    const out = await harness.io.readFile('/dl/output.ts');
    expect(out).toEqual(new Uint8Array([1, 2, 3, 4, 5]));
  });

  it('uses injected concatSegments callback instead of binary fallback', async () => {
    const concatCalls: Array<{ segments: string[]; output: string }> = [];
    harness.fs.concatSegments = async (segments, output) => {
      concatCalls.push({ segments, output });
    };

    const session = makeSession(harness);
    await session.concat(['/cache/seg-a.ts', '/cache/seg-b.ts'], '/dl/output.ts');

    expect(concatCalls).toHaveLength(1);
    expect(concatCalls[0]!.output).toBe('/dl/output.ts');
    expect(concatCalls[0]!.segments).toHaveLength(2);
  });

  it('cleanup unlinks sequential segment files until a gap', async () => {
    const session = makeSession(harness);
    const segDir = session.segDir();
    await harness.io.mkdir(segDir);
    await harness.io.writeFile(session.segPath(0), new Uint8Array([1]));
    await harness.io.writeFile(session.segPath(1), new Uint8Array([2]));

    await session.cleanup(segDir);

    expect(await harness.io.exists(session.segPath(0))).toBe(false);
    expect(await harness.io.exists(session.segPath(1))).toBe(false);
  });

  it('segPath produces zero-padded sequential names under segDir', () => {
    const session = makeSession(harness);
    expect(session.segDir()).toBe('/cache/test-id-hls');
    expect(session.segPath(0)).toBe('/cache/test-id-hls/seg-000000.ts');
    expect(session.segPath(12)).toBe('/cache/test-id-hls/seg-000012.ts');
  });
});
