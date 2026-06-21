import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:downloadx/downloadx.dart';
import 'package:downloadx/src/config.dart';
import 'package:downloadx/src/hls/session.dart';
import 'package:downloadx/src/throttle.dart';
import 'package:downloadx/src/types.dart';
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

final _segBody = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]);

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
}

({HlsSession session, List<(int, int)> progress, _MockContext ctx}) makeSession(
  Harness h, {
  bool Function()? isCancelled,
  bool Function()? isPaused,
}) {
  final progress = <(int, int)>[];
  final ctx = _MockContext(h.manager);
  final session = HlsSession(
    id: 'test-id',
    context: ctx,
    throttle: Throttle(0),
    onProgress: (done, total) => progress.add((done, total)),
    isCancelled: isCancelled ?? () => false,
    isPaused: isPaused ?? () => false,
  );
  return (session: session, progress: progress, ctx: ctx);
}

void _routeSegments(MockIo io, int count) {
  for (var i = 1; i <= count; i++) {
    final idx = i.toString().padLeft(6, '0');
    io.fetcher.route(
      'https://cdn.example.com/seg-$idx.ts',
      MockRoute(body: _segBody, contentType: 'video/mp2t'),
    );
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late Harness h;

  setUp(() async {
    h = await Harness.create(maxRetries: 2, retryDelay: 1);
  });

  test('master playlist with multiple streams → registers idle downloads, returns multi-stream', () async {
    h.io.fetcher.route(
      'https://example.com/master.m3u8',
      MockRoute(body: _utf8(_masterM3u8), contentType: 'application/vnd.apple.mpegurl'),
    );

    final (:session, progress: _, :ctx) = makeSession(h);
    final result = await session.run('https://example.com/master.m3u8', '/dl/output.ts', 'output.ts');

    expect(result, isA<HlsMultiStreamResult>());
    expect(ctx.addedUrls, hasLength(2));
    expect(ctx.addedUrls[0].url, equals('https://cdn.example.com/720p.m3u8'));
    expect(ctx.addedUrls[0].options?.filename, equals('output 1280x720.ts'));
    expect(ctx.addedUrls[0].options?.autoStart, equals(false));
    expect(ctx.addedUrls[1].url, equals('https://cdn.example.com/360p.m3u8'));
    expect(ctx.addedUrls[1].options?.filename, equals('output 640x360.ts'));
  });

  test('master playlist with single stream → downloads segments directly', () async {
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
    _routeSegments(h.io, 3);

    final (:session, :progress, ctx: _) = makeSession(h);
    final result = await session.run('https://example.com/master.m3u8', '/dl/output.ts', 'output.ts');

    expect(result, isA<HlsSessionResult>());
    final r = result as HlsSessionResult;
    expect(r.segmentPaths, hasLength(3));
    expect(r.segmentPaths[0], '/cache/test-id-hls/seg-000000.ts');

    final urls = h.io.fetcher.requests.map((r) => r.url).toList();
    expect(urls, contains('https://cdn.example.com/720p.m3u8'));
    expect(progress, equals([(3, 3)]));
  });

  test('works with direct media playlist (no master)', () async {
    h.io.fetcher.route(
      'https://example.com/media.m3u8',
      MockRoute(body: _utf8(_mediaM3u8), contentType: 'application/vnd.apple.mpegurl'),
    );
    _routeSegments(h.io, 3);

    final (:session, progress: _, ctx: _) = makeSession(h);
    final result = await session.run('https://example.com/media.m3u8', '/dl/output.ts', 'output.ts');

    expect(result, isA<HlsSessionResult>());
    final r = result as HlsSessionResult;
    expect(r.segmentPaths, hasLength(3));
    expect(r.playlist.totalDurationSec, closeTo(28.5, 0.01));
  });

  test('writes segment file contents to disk and binary-concats them', () async {
    h.io.fetcher.route(
      'https://example.com/media.m3u8',
      MockRoute(body: _utf8(_mediaM3u8), contentType: 'application/vnd.apple.mpegurl'),
    );
    _routeSegments(h.io, 3);

    final (:session, progress: _, ctx: _) = makeSession(h);
    final result = await session.run('https://example.com/media.m3u8', '/dl/output.ts', 'output.ts');

    expect(result, isA<HlsSessionResult>());
    final r = result as HlsSessionResult;
    for (final p in r.segmentPaths) {
      final data = await h.io.readFile(p);
      expect(Uint8List.fromList(data), equals(_segBody));
    }

    final expected = Uint8List.fromList([..._segBody, ..._segBody, ..._segBody]);
    final output = Uint8List.fromList(await h.io.readFile('/dl/output.ts'));
    expect(output, equals(expected));
    expect(r.outputPath, equals('/dl/output.ts'));
  });

  test('throws on live stream', () async {
    h.io.fetcher.route(
      'https://example.com/live.m3u8',
      MockRoute(body: _utf8(_liveM3u8), contentType: 'application/vnd.apple.mpegurl'),
    );

    final (:session, progress: _, ctx: _) = makeSession(h);
    expect(
      () => session.run('https://example.com/live.m3u8', '/dl/output.ts', 'output.ts'),
      throwsA(predicate((e) => e.toString().contains('Live HLS'))),
    );
  });

  test('retries a failing segment', () async {
    h.io.fetcher.route(
      'https://example.com/media.m3u8',
      MockRoute(
        body: _utf8('''
#EXTM3U
#EXT-X-TARGETDURATION:5
#EXTINF:5.0,
https://cdn.example.com/seg-000001.ts
#EXT-X-ENDLIST
'''),
        contentType: 'application/vnd.apple.mpegurl',
      ),
    );
    h.io.fetcher.route(
      'https://cdn.example.com/seg-000001.ts',
      MockRoute(body: _segBody, failTimes: 1, failStatus: 503),
    );

    final (:session, progress: _, ctx: _) = makeSession(h);
    final result = await session.run('https://example.com/media.m3u8', '/dl/output.ts', 'output.ts');
    expect(result, isA<HlsSessionResult>());
    expect((result as HlsSessionResult).segmentPaths, hasLength(1));

    final segCalls = h.io.fetcher.requests
        .where((r) => r.url.contains('seg-000001'))
        .toList();
    expect(segCalls, hasLength(2));
  });

  test('multi-stream: bandwidth fallback filename when no resolution', () async {
    const masterNoRes = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=5000000
https://cdn.example.com/hi.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1000000
https://cdn.example.com/lo.m3u8
''';
    h.io.fetcher.route(
      'https://example.com/master.m3u8',
      MockRoute(body: _utf8(masterNoRes), contentType: 'application/vnd.apple.mpegurl'),
    );

    final (:session, progress: _, :ctx) = makeSession(h);
    await session.run('https://example.com/master.m3u8', '/dl/film.mkv', 'film.mkv');

    expect(ctx.addedUrls[0].options?.filename, equals('film 5000kbps.mkv'));
    expect(ctx.addedUrls[1].options?.filename, equals('film 1000kbps.mkv'));
  });

  test('multi-stream: stream-N fallback filename when no resolution or bandwidth', () async {
    const masterNoMeta = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=0
https://cdn.example.com/a.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=0
https://cdn.example.com/b.m3u8
''';
    h.io.fetcher.route(
      'https://example.com/master.m3u8',
      MockRoute(body: _utf8(masterNoMeta), contentType: 'application/vnd.apple.mpegurl'),
    );

    final (:session, progress: _, :ctx) = makeSession(h);
    await session.run('https://example.com/master.m3u8', '/dl/film.mkv', 'film.mkv');

    expect(ctx.addedUrls[0].options?.filename, equals('film stream-1.mkv'));
    expect(ctx.addedUrls[1].options?.filename, equals('film stream-2.mkv'));
  });

  test('multi-stream: targetPath forwarded to addUrl', () async {
    h.io.fetcher.route(
      'https://example.com/master.m3u8',
      MockRoute(body: _utf8(_masterM3u8), contentType: 'application/vnd.apple.mpegurl'),
    );

    final (:session, progress: _, :ctx) = makeSession(h);
    await session.run('https://example.com/master.m3u8', '/downloads/movies/output.ts', 'output.ts');

    for (final entry in ctx.addedUrls) {
      expect(entry.options?.targetPath, equals('/downloads/movies'));
    }
  });

  test('uses injected concatSegments callback instead of binary fallback', () async {
    final concatCalls = <({List<String> segments, String output})>[];
    h.io.concatSegmentsOverride = (segments, output) async {
      concatCalls.add((segments: segments, output: output));
    };

    h.io.fetcher.route(
      'https://example.com/media.m3u8',
      MockRoute(body: _utf8(_mediaM3u8), contentType: 'application/vnd.apple.mpegurl'),
    );
    _routeSegments(h.io, 3);

    final (:session, progress: _, ctx: _) = makeSession(h);
    await session.run('https://example.com/media.m3u8', '/dl/output.ts', 'output.ts');

    expect(concatCalls, hasLength(1));
    expect(concatCalls[0].output, equals('/dl/output.ts'));
    expect(concatCalls[0].segments, hasLength(3));
  });

  test('throws on cancel', () async {
    h.io.fetcher.route(
      'https://example.com/media.m3u8',
      MockRoute(body: _utf8(_mediaM3u8), contentType: 'application/vnd.apple.mpegurl'),
    );
    _routeSegments(h.io, 3);

    final (:session, progress: _, ctx: _) = makeSession(h, isCancelled: () => true);
    expect(
      () => session.run('https://example.com/media.m3u8', '/dl/output.ts', 'output.ts'),
      throwsA(isA<HlsCancelledException>()),
    );
  });
}
