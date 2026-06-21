import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const base = 'https://cdn.example.com/hls/stream/';

const masterAbsolute = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2"
https://cdn.example.com/hls/1080p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
https://cdn.example.com/hls/720p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=640x360
https://cdn.example.com/hls/360p/index.m3u8
''';

const masterRelative = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=1280x720
720p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1920x1080
1080p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=640x360
360p/index.m3u8
''';

const mediaBasic = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:9.009,
seg-0.ts
#EXTINF:9.009,
seg-1.ts
#EXTINF:3.003,
seg-2.ts
#EXT-X-ENDLIST
''';

const mediaLive = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
seg-100.ts
#EXTINF:6.0,
seg-101.ts
''';

const mediaByteRange = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-BYTERANGE:500000@0
#EXTINF:10.0,
main.ts
#EXT-X-BYTERANGE:500000
#EXTINF:10.0,
main.ts
#EXT-X-ENDLIST
''';

const mediaRelative = '''
#EXTM3U
#EXT-X-TARGETDURATION:8
#EXTINF:8.0,
../segments/seg-0.ts
#EXTINF:8.0,
/absolute/seg-1.ts
#EXTINF:4.0,
https://other.cdn.com/seg-2.ts
#EXT-X-ENDLIST
''';

const mediaCrlf = '#EXTM3U\r\n#EXT-X-TARGETDURATION:5\r\n#EXTINF:5.0,\r\nseg-0.ts\r\n#EXT-X-ENDLIST\r\n';

void main() {
  // -------------------------------------------------------------------------
  // Master playlist
  // -------------------------------------------------------------------------

  group('parseMasterPlaylist', () {
    test('sorts streams by bandwidth descending', () {
      final pl = parseMasterPlaylist(masterAbsolute, base);
      expect(pl.streams, hasLength(3));
      expect(pl.streams[0].bandwidth, 2800000);
      expect(pl.streams[1].bandwidth, 1400000);
      expect(pl.streams[2].bandwidth, 600000);
    });

    test('parses resolution and codecs', () {
      final pl = parseMasterPlaylist(masterAbsolute, base);
      expect(pl.streams[0].resolution, '1920x1080');
      expect(pl.streams[0].codecs, 'avc1.640028,mp4a.40.2');
    });

    test('keeps absolute URIs unchanged', () {
      final pl = parseMasterPlaylist(masterAbsolute, base);
      expect(pl.streams[0].uri, 'https://cdn.example.com/hls/1080p/index.m3u8');
    });

    test('resolves relative URIs against base URL', () {
      final pl = parseMasterPlaylist(masterRelative, base);
      expect(pl.streams[0].uri, 'https://cdn.example.com/hls/stream/1080p/index.m3u8');
      expect(pl.streams[1].uri, 'https://cdn.example.com/hls/stream/720p/index.m3u8');
    });

    test('returns null codecs when attribute is absent', () {
      final pl = parseMasterPlaylist(masterRelative, base);
      expect(pl.streams[0].codecs, isNull);
    });

    test('selectBestStream returns highest bandwidth', () {
      final master = parseMasterPlaylist(masterAbsolute, base);
      final best = selectBestStream(master);
      expect(best?.bandwidth, 2800000);
      expect(best?.resolution, '1920x1080');
    });

    test('selectBestStream returns null for empty playlist', () {
      expect(selectBestStream(HlsMasterPlaylist(streams: [])), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Media playlist
  // -------------------------------------------------------------------------

  group('parseMediaPlaylist', () {
    test('parses segment count and durations', () {
      final pl = parseMediaPlaylist(mediaBasic, base);
      expect(pl.segments, hasLength(3));
      expect(pl.segments[0].durationSec, closeTo(9.009, 0.001));
      expect(pl.segments[2].durationSec, closeTo(3.003, 0.001));
    });

    test('sums total duration', () {
      final pl = parseMediaPlaylist(mediaBasic, base);
      expect(pl.totalDurationSec, closeTo(21.021, 0.001));
    });

    test('reads targetDuration', () {
      final pl = parseMediaPlaylist(mediaBasic, base);
      expect(pl.targetDuration, 10);
    });

    test('sets isLive=false when #EXT-X-ENDLIST present', () {
      final pl = parseMediaPlaylist(mediaBasic, base);
      expect(pl.isLive, isFalse);
    });

    test('sets isLive=true when #EXT-X-ENDLIST absent', () {
      final pl = parseMediaPlaylist(mediaLive, base);
      expect(pl.isLive, isTrue);
    });

    test('resolves relative segment URIs', () {
      final pl = parseMediaPlaylist(mediaBasic, base);
      expect(pl.segments[0].uri, 'https://cdn.example.com/hls/stream/seg-0.ts');
    });

    test('resolves parent-dir relative URIs', () {
      final pl = parseMediaPlaylist(mediaRelative, base);
      expect(pl.segments[0].uri, 'https://cdn.example.com/hls/segments/seg-0.ts');
    });

    test('resolves root-relative URIs', () {
      final pl = parseMediaPlaylist(mediaRelative, base);
      expect(pl.segments[1].uri, 'https://cdn.example.com/absolute/seg-1.ts');
    });

    test('keeps absolute URIs unchanged', () {
      final pl = parseMediaPlaylist(mediaRelative, base);
      expect(pl.segments[2].uri, 'https://other.cdn.com/seg-2.ts');
    });

    test('parses byte ranges with explicit offset', () {
      final pl = parseMediaPlaylist(mediaByteRange, base);
      expect(pl.segments[0].byteRange?.offset, 0);
      expect(pl.segments[0].byteRange?.length, 500000);
    });

    test('accumulates byte range offset when not specified', () {
      final pl = parseMediaPlaylist(mediaByteRange, base);
      expect(pl.segments[1].byteRange?.offset, 500000);
      expect(pl.segments[1].byteRange?.length, 500000);
    });

    test('handles CRLF line endings', () {
      final pl = parseMediaPlaylist(mediaCrlf, base);
      expect(pl.segments, hasLength(1));
      expect(pl.isLive, isFalse);
    });

    test('sets byteRange=null when absent', () {
      final pl = parseMediaPlaylist(mediaBasic, base);
      expect(pl.segments[0].byteRange, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // parsePlaylist auto-detect
  // -------------------------------------------------------------------------

  group('parsePlaylist', () {
    test('detects master playlist', () {
      final result = parsePlaylist(masterAbsolute, base);
      expect(result, isA<HlsMasterResult>());
    });

    test('detects media playlist', () {
      final result = parsePlaylist(mediaBasic, base);
      expect(result, isA<HlsMediaResult>());
    });

    test('master result has streams', () {
      final result = parsePlaylist(masterAbsolute, base) as HlsMasterResult;
      expect(result.playlist.streams, isNotEmpty);
    });

    test('media result has segments', () {
      final result = parsePlaylist(mediaBasic, base) as HlsMediaResult;
      expect(result.playlist.segments, isNotEmpty);
    });
  });
}
