import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:downloadx/downloadx.dart';
import 'package:downloadx/src/config.dart';
import 'package:downloadx/src/hls/session.dart';
import '../../helpers/harness.dart';
import '../../helpers/mock_io.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const _masterM3u8 = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
https://cdn.example.com/720p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360
https://cdn.example.com/360p.m3u8
''';

const _mediaM3u8 = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
https://cdn.example.com/seg-000001.ts
#EXTINF:10.0,
https://cdn.example.com/seg-000002.ts
#EXTINF:8.5,
https://cdn.example.com/seg-000003.ts
#EXT-X-ENDLIST
''';

const _liveM3u8 = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
https://cdn.example.com/seg-000001.ts
#EXTINF:10.0,
https://cdn.example.com/seg-000002.ts
''';

Uint8List _utf8(String s) => Uint8List.fromList(s.codeUnits);

// ---------------------------------------------------------------------------
// Helper — DlxContext mock
// ---------------------------------------------------------------------------

class _MockContext implements DlxContext {
  final GlobalConfig _base;
  final List<({String url, DownloadOptions? options})> addedUrls = [];

  _MockContext(this._base);

  @override
  Future<void> addUrl(String url, [DownloadOptions? options]) async {
    addedUrls.add((url: url, options: options));
  }

  @override
  String get cachePath => _base.cachePath;
  @override
  String get targetPath => _base.targetPath;
  @override
  int get maxParallel => _base.maxParallel;
  @override
  num get speedLimit => _base.speedLimit;
  @override
  int get targetChunkCount => _base.targetChunkCount;
  @override
  int get minChunkSize => _base.minChunkSize;
  @override
  bool get journal => _base.journal;
  @override
  Throttle get sharedThrottle => _base.sharedThrottle;
  @override
  int get maxRetries => _base.maxRetries;
  @override
  int get retryDelay => _base.retryDelay;
  @override
  num get retryBackoff => _base.retryBackoff;
  @override
  int get speedSampleWindow => _base.speedSampleWindow;
  @override
  int get requestTimeout => _base.requestTimeout;
  @override
  Map<String, String> get headers => _base.headers;
  @override
  DownloadxIo get io => _base.io;
  @override
  void addLog({DiagnosticLevel level = DiagnosticLevel.info, required String code, Map<String, dynamic>? params}) {}
}

({HlsSession session, _MockContext ctx}) makeSession(Harness h) {
  final ctx = _MockContext(h.manager);
  return (session: HlsSession(id: 'test-id', context: ctx), ctx: ctx);
}

// ---------------------------------------------------------------------------
// Tests — the session only resolves playlists, concatenates and cleans up.
// Actual segment downloading is covered in test/integration/hls_test.dart.
// ---------------------------------------------------------------------------

void main() {
  late Harness h;

  setUp(() async {
    h = await Harness.create(maxRetries: 2, retryDelay: 1);
  });

  group('resolve', () {
    test('master with multiple streams → multi-stream result (no download)', () async {
      h.io.fetcher.route(
        'https://example.com/master.m3u8',
        MockRoute(body: _utf8(_masterM3u8), contentType: 'application/vnd.apple.mpegurl'),
      );

      final (:session, ctx: _) = makeSession(h);
      final result = await session.resolve('https://example.com/master.m3u8');

      expect(result, isA<HlsMultiStreamResult>());
      final streams = (result as HlsMultiStreamResult).streams;
      expect(streams, hasLength(2));
      expect(streams[0].uri, equals('https://cdn.example.com/720p.m3u8'));
    });

    test('master with single stream → resolves the media playlist', () async {
      const singleStreamMaster = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
https://cdn.example.com/720p.m3u8
''';
      h.io.fetcher.route(
        'https://example.com/master.m3u8',
        MockRoute(body: _utf8(singleStreamMaster), contentType: 'application/vnd.apple.mpegurl'),
      );
      h.io.fetcher.route(
        'https://cdn.example.com/720p.m3u8',
        MockRoute(body: _utf8(_mediaM3u8), contentType: 'application/vnd.apple.mpegurl'),
      );

      final (:session, ctx: _) = makeSession(h);
      final result = await session.resolve('https://example.com/master.m3u8');

      expect(result, isA<HlsMediaResolution>());
      expect((result as HlsMediaResolution).playlist.segments, hasLength(3));
    });

    test('direct media playlist (no master)', () async {
      h.io.fetcher.route(
        'https://example.com/media.m3u8',
        MockRoute(body: _utf8(_mediaM3u8), contentType: 'application/vnd.apple.mpegurl'),
      );

      final (:session, ctx: _) = makeSession(h);
      final result = await session.resolve('https://example.com/media.m3u8');

      expect(result, isA<HlsMediaResolution>());
      final playlist = (result as HlsMediaResolution).playlist;
      expect(playlist.segments, hasLength(3));
      expect(playlist.totalDurationSec, closeTo(28.5, 0.01));
    });

    test('throws on live stream', () async {
      h.io.fetcher.route(
        'https://example.com/live.m3u8',
        MockRoute(body: _utf8(_liveM3u8), contentType: 'application/vnd.apple.mpegurl'),
      );

      final (:session, ctx: _) = makeSession(h);
      expect(
        () => session.resolve('https://example.com/live.m3u8'),
        throwsA(predicate((e) => e.toString().contains('Live HLS'))),
      );
    });
  });

  group('registerStreams', () {
    test('registers each stream as an idle download with a resolution qualifier', () async {
      h.io.fetcher.route(
        'https://example.com/master.m3u8',
        MockRoute(body: _utf8(_masterM3u8), contentType: 'application/vnd.apple.mpegurl'),
      );
      final (:session, :ctx) = makeSession(h);
      final result = await session.resolve('https://example.com/master.m3u8');
      final streams = (result as HlsMultiStreamResult).streams;

      await session.registerStreams(streams, 'output.ts', '/dl/output.ts');

      expect(ctx.addedUrls, hasLength(2));
      expect(ctx.addedUrls[0].url, equals('https://cdn.example.com/720p.m3u8'));
      expect(ctx.addedUrls[0].options?.filename, equals('output 1280x720.ts'));
      expect(ctx.addedUrls[0].options?.autoStart, equals(false));
      expect(ctx.addedUrls[1].options?.filename, equals('output 640x360.ts'));
    });

    test('bandwidth fallback filename when no resolution', () async {
      final (:session, :ctx) = makeSession(h);
      final streams = [
        HlsStream(bandwidth: 5000000, resolution: null, codecs: null, uri: 'https://cdn.example.com/hi.m3u8'),
        HlsStream(bandwidth: 1000000, resolution: null, codecs: null, uri: 'https://cdn.example.com/lo.m3u8'),
      ];
      await session.registerStreams(streams, 'film.mkv', '/dl/film.mkv');

      expect(ctx.addedUrls[0].options?.filename, equals('film 5000kbps.mkv'));
      expect(ctx.addedUrls[1].options?.filename, equals('film 1000kbps.mkv'));
    });

    test('stream-N fallback filename when no resolution or bandwidth', () async {
      final (:session, :ctx) = makeSession(h);
      final streams = [
        HlsStream(bandwidth: 0, resolution: null, codecs: null, uri: 'https://cdn.example.com/a.m3u8'),
        HlsStream(bandwidth: 0, resolution: null, codecs: null, uri: 'https://cdn.example.com/b.m3u8'),
      ];
      await session.registerStreams(streams, 'film.mkv', '/dl/film.mkv');

      expect(ctx.addedUrls[0].options?.filename, equals('film stream-1.mkv'));
      expect(ctx.addedUrls[1].options?.filename, equals('film stream-2.mkv'));
    });

    test('targetPath from outputPath forwarded to addUrl', () async {
      final (:session, :ctx) = makeSession(h);
      final streams = [
        HlsStream(bandwidth: 2000000, resolution: '1280x720', codecs: null, uri: 'https://cdn.example.com/720p.m3u8'),
      ];
      await session.registerStreams(streams, 'output.ts', '/downloads/movies/output.ts');

      expect(ctx.addedUrls[0].options?.targetPath, equals('/downloads/movies'));
    });
  });

  group('concat / cleanup', () {
    test('binary-concats segment files into the output', () async {
      await h.io.writeFile('/cache/seg-a.ts', [1, 2, 3]);
      await h.io.writeFile('/cache/seg-b.ts', [4, 5]);

      final (:session, ctx: _) = makeSession(h);
      await session.concat(['/cache/seg-a.ts', '/cache/seg-b.ts'], '/dl/output.ts');

      final out = await h.io.readFile('/dl/output.ts');
      expect(out, equals([1, 2, 3, 4, 5]));
    });

    test('uses injected concatSegments callback instead of binary fallback', () async {
      final concatCalls = <({List<String> segments, String output})>[];
      h.io.concatSegmentsOverride = (segments, output) async {
        concatCalls.add((segments: segments, output: output));
      };

      final (:session, ctx: _) = makeSession(h);
      await session.concat(['/cache/seg-a.ts', '/cache/seg-b.ts'], '/dl/output.ts');

      expect(concatCalls, hasLength(1));
      expect(concatCalls[0].output, equals('/dl/output.ts'));
      expect(concatCalls[0].segments, hasLength(2));
    });

    test('cleanup unlinks sequential segment files until a gap', () async {
      final (:session, ctx: _) = makeSession(h);
      final segDir = session.segDir();
      await h.io.mkdir(segDir);
      await h.io.writeFile(session.segPath(0), [1]);
      await h.io.writeFile(session.segPath(1), [2]);

      await session.cleanup(segDir);

      expect(await h.io.exists(session.segPath(0)), isFalse);
      expect(await h.io.exists(session.segPath(1)), isFalse);
    });

    test('segPath produces zero-padded sequential names under segDir', () {
      final (:session, ctx: _) = makeSession(h);
      expect(session.segDir(), equals('/cache/test-id-hls'));
      expect(session.segPath(0), equals('/cache/test-id-hls/seg-000000.ts'));
      expect(session.segPath(12), equals('/cache/test-id-hls/seg-000012.ts'));
    });
  });
}
