import { describe, expect, it } from 'vitest';
import { parseMasterPlaylist, parseMediaPlaylist, parsePlaylist, selectBestStream } from '../../../src/hls/parser.js';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const BASE = 'https://cdn.example.com/hls/stream/';

const MASTER_ABSOLUTE = `#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
https://cdn.example.com/hls/1080p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
https://cdn.example.com/hls/720p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=640x360
https://cdn.example.com/hls/360p/index.m3u8`;

const MASTER_RELATIVE = `#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=1280x720
720p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1920x1080
1080p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=640x360
360p/index.m3u8`;

const MEDIA_BASIC = `#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:9.009,
seg-0.ts
#EXTINF:9.009,
seg-1.ts
#EXTINF:3.003,
seg-2.ts
#EXT-X-ENDLIST`;

const MEDIA_LIVE = `#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
seg-100.ts
#EXTINF:6.0,
seg-101.ts`;

const MEDIA_BYTERANGE = `#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-BYTERANGE:500000@0
#EXTINF:10.0,
main.ts
#EXT-X-BYTERANGE:500000
#EXTINF:10.0,
main.ts
#EXT-X-ENDLIST`;

const MEDIA_RELATIVE = `#EXTM3U
#EXT-X-TARGETDURATION:8
#EXTINF:8.0,
../segments/seg-0.ts
#EXTINF:8.0,
/absolute/seg-1.ts
#EXTINF:4.0,
https://other.cdn.com/seg-2.ts
#EXT-X-ENDLIST`;

const MEDIA_CRLF = `#EXTM3U\r\n#EXT-X-TARGETDURATION:5\r\n#EXTINF:5.0,\r\nseg-0.ts\r\n#EXT-X-ENDLIST\r\n`;

// ---------------------------------------------------------------------------
// Master playlist
// ---------------------------------------------------------------------------

describe('parseMasterPlaylist', () => {
  it('sorts streams by bandwidth descending', () => {
    const { streams } = parseMasterPlaylist(MASTER_ABSOLUTE, BASE);
    expect(streams).toHaveLength(3);
    expect(streams[0].bandwidth).toBe(2800000);
    expect(streams[1].bandwidth).toBe(1400000);
    expect(streams[2].bandwidth).toBe(600000);
  });

  it('parses resolution and codecs', () => {
    const { streams } = parseMasterPlaylist(MASTER_ABSOLUTE, BASE);
    expect(streams[0].resolution).toBe('1920x1080');
    expect(streams[0].codecs).toBe('avc1.640028,mp4a.40.2');
  });

  it('keeps absolute URIs unchanged', () => {
    const { streams } = parseMasterPlaylist(MASTER_ABSOLUTE, BASE);
    expect(streams[0].uri).toBe('https://cdn.example.com/hls/1080p/index.m3u8');
  });

  it('resolves relative URIs against base URL', () => {
    const { streams } = parseMasterPlaylist(MASTER_RELATIVE, BASE);
    expect(streams[0].uri).toBe('https://cdn.example.com/hls/stream/1080p/index.m3u8');
    expect(streams[1].uri).toBe('https://cdn.example.com/hls/stream/720p/index.m3u8');
  });

  it('returns null codecs when attribute is absent', () => {
    const { streams } = parseMasterPlaylist(MASTER_RELATIVE, BASE);
    expect(streams[0].codecs).toBeNull();
  });

  it('selectBestStream returns highest bandwidth', () => {
    const master = parseMasterPlaylist(MASTER_ABSOLUTE, BASE);
    const best = selectBestStream(master);
    expect(best?.bandwidth).toBe(2800000);
    expect(best?.resolution).toBe('1920x1080');
  });

  it('selectBestStream returns null for empty playlist', () => {
    expect(selectBestStream({ streams: [] })).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// Media playlist
// ---------------------------------------------------------------------------

describe('parseMediaPlaylist', () => {
  it('parses segment count and durations', () => {
    const pl = parseMediaPlaylist(MEDIA_BASIC, BASE);
    expect(pl.segments).toHaveLength(3);
    expect(pl.segments[0].durationSec).toBeCloseTo(9.009);
    expect(pl.segments[2].durationSec).toBeCloseTo(3.003);
  });

  it('sums total duration', () => {
    const pl = parseMediaPlaylist(MEDIA_BASIC, BASE);
    expect(pl.totalDurationSec).toBeCloseTo(21.021);
  });

  it('reads targetDuration', () => {
    const pl = parseMediaPlaylist(MEDIA_BASIC, BASE);
    expect(pl.targetDuration).toBe(10);
  });

  it('sets isLive=false when #EXT-X-ENDLIST present', () => {
    const pl = parseMediaPlaylist(MEDIA_BASIC, BASE);
    expect(pl.isLive).toBe(false);
  });

  it('sets isLive=true when #EXT-X-ENDLIST absent', () => {
    const pl = parseMediaPlaylist(MEDIA_LIVE, BASE);
    expect(pl.isLive).toBe(true);
  });

  it('resolves relative segment URIs', () => {
    const pl = parseMediaPlaylist(MEDIA_BASIC, BASE);
    expect(pl.segments[0].uri).toBe('https://cdn.example.com/hls/stream/seg-0.ts');
  });

  it('resolves parent-dir relative URIs', () => {
    const pl = parseMediaPlaylist(MEDIA_RELATIVE, BASE);
    expect(pl.segments[0].uri).toBe('https://cdn.example.com/hls/segments/seg-0.ts');
  });

  it('resolves root-relative URIs', () => {
    const pl = parseMediaPlaylist(MEDIA_RELATIVE, BASE);
    expect(pl.segments[1].uri).toBe('https://cdn.example.com/absolute/seg-1.ts');
  });

  it('keeps absolute URIs unchanged', () => {
    const pl = parseMediaPlaylist(MEDIA_RELATIVE, BASE);
    expect(pl.segments[2].uri).toBe('https://other.cdn.com/seg-2.ts');
  });

  it('parses byte ranges with explicit offset', () => {
    const pl = parseMediaPlaylist(MEDIA_BYTERANGE, BASE);
    expect(pl.segments[0].byteRange).toEqual({ offset: 0, length: 500000 });
  });

  it('accumulates byte range offset when not specified', () => {
    const pl = parseMediaPlaylist(MEDIA_BYTERANGE, BASE);
    expect(pl.segments[1].byteRange).toEqual({ offset: 500000, length: 500000 });
  });

  it('handles CRLF line endings', () => {
    const pl = parseMediaPlaylist(MEDIA_CRLF, BASE);
    expect(pl.segments).toHaveLength(1);
    expect(pl.isLive).toBe(false);
  });

  it('sets byteRange=null when absent', () => {
    const pl = parseMediaPlaylist(MEDIA_BASIC, BASE);
    expect(pl.segments[0].byteRange).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// parsePlaylist auto-detect
// ---------------------------------------------------------------------------

describe('parsePlaylist', () => {
  it('detects master playlist', () => {
    const result = parsePlaylist(MASTER_ABSOLUTE, BASE);
    expect(result.type).toBe('master');
  });

  it('detects media playlist', () => {
    const result = parsePlaylist(MEDIA_BASIC, BASE);
    expect(result.type).toBe('media');
  });

  it('master result has streams', () => {
    const result = parsePlaylist(MASTER_ABSOLUTE, BASE);
    if (result.type !== 'master') throw new Error('expected master');
    expect(result.playlist.streams.length).toBeGreaterThan(0);
  });

  it('media result has segments', () => {
    const result = parsePlaylist(MEDIA_BASIC, BASE);
    if (result.type !== 'media') throw new Error('expected media');
    expect(result.playlist.segments.length).toBeGreaterThan(0);
  });
});
