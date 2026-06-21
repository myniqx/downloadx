import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:downloadx/src/hls/session.dart';
import 'package:downloadx/src/throttle.dart';
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
// Helper
// ---------------------------------------------------------------------------

({HlsSession session, List<(int, int)> progress}) makeSession(
  Harness h, {
  bool Function()? isCancelled,
  bool Function()? isPaused,
}) {
  final progress = <(int, int)>[];
  final session = HlsSession(
    id: 'test-id',
    global: h.manager,
    throttle: Throttle(0),
    onProgress: (done, total) => progress.add((done, total)),
    isCancelled: isCancelled ?? () => false,
    isPaused: isPaused ?? () => false,
  );
  return (session: session, progress: progress);
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

  test('resolves master → selects highest bandwidth → downloads segments', () async {
    h.io.fetcher.route(
      'https://example.com/master.m3u8',
      MockRoute(body: _utf8(_masterM3u8), contentType: 'application/vnd.apple.mpegurl'),
    );
    h.io.fetcher.route(
      'https://cdn.example.com/720p.m3u8',
      MockRoute(body: _utf8(_mediaM3u8), contentType: 'application/vnd.apple.mpegurl'),
    );
    _routeSegments(h.io, 3);

    final (:session, :progress) = makeSession(h);
    final result = await session.run('https://example.com/master.m3u8', '/dl/output.ts');

    expect(result.segmentPaths, hasLength(3));
    expect(result.segmentPaths[0], '/cache/test-id-hls/seg-000000.ts');
    expect(result.segmentPaths[1], '/cache/test-id-hls/seg-000001.ts');
    expect(result.segmentPaths[2], '/cache/test-id-hls/seg-000002.ts');

    final urls = h.io.fetcher.requests.map((r) => r.url).toList();
    expect(urls, contains('https://cdn.example.com/720p.m3u8'));
    expect(urls, isNot(contains('https://cdn.example.com/360p.m3u8')));

    expect(progress, equals([(3, 3)]));
  });

  test('works with direct media playlist (no master)', () async {
    h.io.fetcher.route(
      'https://example.com/media.m3u8',
      MockRoute(body: _utf8(_mediaM3u8), contentType: 'application/vnd.apple.mpegurl'),
    );
    _routeSegments(h.io, 3);

    final (:session, progress: _) = makeSession(h);
    final result = await session.run('https://example.com/media.m3u8', '/dl/output.ts');

    expect(result.segmentPaths, hasLength(3));
    expect(result.playlist.totalDurationSec, closeTo(28.5, 0.01));
  });

  test('writes segment file contents to disk and binary-concats them', () async {
    h.io.fetcher.route(
      'https://example.com/media.m3u8',
      MockRoute(body: _utf8(_mediaM3u8), contentType: 'application/vnd.apple.mpegurl'),
    );
    _routeSegments(h.io, 3);

    final (:session, progress: _) = makeSession(h);
    final result = await session.run('https://example.com/media.m3u8', '/dl/output.ts');

    for (final p in result.segmentPaths) {
      final data = await h.io.readFile(p);
      expect(Uint8List.fromList(data), equals(_segBody));
    }

    // Binary concat: output should be 3 × _segBody.
    final expected = Uint8List.fromList([..._segBody, ..._segBody, ..._segBody]);
    final output = Uint8List.fromList(await h.io.readFile('/dl/output.ts'));
    expect(output, equals(expected));
    expect(result.outputPath, equals('/dl/output.ts'));
  });

  test('throws on live stream', () async {
    h.io.fetcher.route(
      'https://example.com/live.m3u8',
      MockRoute(body: _utf8(_liveM3u8), contentType: 'application/vnd.apple.mpegurl'),
    );

    final (:session, progress: _) = makeSession(h);
    expect(
      () => session.run('https://example.com/live.m3u8', '/dl/output.ts'),
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

    final (:session, progress: _) = makeSession(h);
    final result = await session.run('https://example.com/media.m3u8', '/dl/output.ts');
    expect(result.segmentPaths, hasLength(1));

    final segCalls = h.io.fetcher.requests
        .where((r) => r.url.contains('seg-000001'))
        .toList();
    expect(segCalls, hasLength(2));
  });

  test('throws on cancel', () async {
    h.io.fetcher.route(
      'https://example.com/media.m3u8',
      MockRoute(body: _utf8(_mediaM3u8), contentType: 'application/vnd.apple.mpegurl'),
    );
    _routeSegments(h.io, 3);

    final (:session, progress: _) = makeSession(h, isCancelled: () => true);
    expect(
      () => session.run('https://example.com/media.m3u8', '/dl/output.ts'),
      throwsA(isA<HlsCancelledException>()),
    );
  });
}
