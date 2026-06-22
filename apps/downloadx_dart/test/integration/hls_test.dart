import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:downloadx/downloadx.dart';
import '../helpers/harness.dart';
import '../helpers/mock_io.dart';

// ---------------------------------------------------------------------------
// HLS integration — exercises the unified chunk pipeline: each segment is an
// isSegment Chunk, downloaded via driveChunks, then concatenated.
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
''';

final _segBody = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]);

Uint8List _utf8(String s) => Uint8List.fromList(s.codeUnits);

void _routeMedia(MockIo io, String url, [String body = _mediaM3u8]) {
  io.fetcher.route(
    url,
    MockRoute(body: _utf8(body), contentType: 'application/vnd.apple.mpegurl'),
  );
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

void main() {
  test('downloads a media playlist as segments and concatenates them', () async {
    final h = await Harness.create();
    _routeMedia(h.io, 'https://example.com/media.m3u8');
    _routeSegments(h.io, 3);

    final dl = await h.manager.addUrl('https://example.com/media.m3u8');
    await dl.start();

    expect(dl.state, DownloadState.completed);
    final out = Uint8List.fromList(await h.io.readFile('/downloads/media.m3u8'));
    expect(out, equals(Uint8List.fromList([..._segBody, ..._segBody, ..._segBody])));
  });

  test('resolves a single-stream master, then downloads its media segments', () async {
    final h = await Harness.create();
    h.io.fetcher.route(
      'https://example.com/master.m3u8',
      MockRoute(
        body: _utf8('''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
https://cdn.example.com/720p.m3u8
'''),
        contentType: 'application/vnd.apple.mpegurl',
      ),
    );
    _routeMedia(h.io, 'https://cdn.example.com/720p.m3u8');
    _routeSegments(h.io, 3);

    final dl = await h.manager.addUrl('https://example.com/master.m3u8');
    await dl.start();

    expect(dl.state, DownloadState.completed);
  });

  test('master with multiple streams registers idle downloads and completes', () async {
    final h = await Harness.create();
    h.io.fetcher.route(
      'https://example.com/master.m3u8',
      MockRoute(body: _utf8(_masterM3u8), contentType: 'application/vnd.apple.mpegurl'),
    );

    final dl = await h.manager.addUrl('https://example.com/master.m3u8');
    await dl.start();

    expect(dl.state, DownloadState.completed);
    // Two child downloads (the variant streams) were registered with the manager.
    expect(h.manager.list().length, equals(3));
  });

  test('errors on a live stream', () async {
    final h = await Harness.create();
    _routeMedia(h.io, 'https://example.com/live.m3u8', _liveM3u8);

    final dl = await h.manager.addUrl('https://example.com/live.m3u8');
    await dl.start();

    expect(dl.state, DownloadState.error);
    expect(dl.meta.errorMessage, contains('Live HLS'));
  });

  test('retries a failing segment then completes', () async {
    final h = await Harness.create(maxRetries: 2, retryDelay: 1);
    _routeMedia(h.io, 'https://example.com/media.m3u8', '''
#EXTM3U
#EXT-X-TARGETDURATION:5
#EXTINF:5.0,
https://cdn.example.com/seg-000001.ts
#EXT-X-ENDLIST
''');
    h.io.fetcher.route(
      'https://cdn.example.com/seg-000001.ts',
      MockRoute(body: _segBody, failTimes: 1, failStatus: 503),
    );

    final dl = await h.manager.addUrl('https://example.com/media.m3u8');
    await dl.start();

    expect(dl.state, DownloadState.completed);
    final segCalls =
        h.io.fetcher.requests.where((r) => r.url.contains('seg-000001')).toList();
    expect(segCalls, hasLength(2));
  });

  test('caps concurrent segment downloads at targetChunkCount', () async {
    final io = MockIo();
    var live = 0;
    var maxLive = 0;
    io.fetchHook = (url, init, proceed) async {
      if (url.contains('seg-')) {
        live++;
        if (live > maxLive) maxLive = live;
        await Future.delayed(const Duration(milliseconds: 5));
        final res = await proceed();
        live--;
        return res;
      }
      return proceed();
    };
    final h = await Harness.create(targetChunkCount: 2, io: io);
    _routeMedia(io, 'https://example.com/media.m3u8', '''
#EXTM3U
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
''');
    _routeSegments(io, 5);

    final dl = await h.manager.addUrl('https://example.com/media.m3u8');
    await dl.start();

    expect(dl.state, DownloadState.completed);
    expect(maxLive, lessThanOrEqualTo(2));
  });

  test('resume skips already-downloaded segment files', () async {
    final h = await Harness.create();
    _routeMedia(h.io, 'https://example.com/media.m3u8');
    _routeSegments(h.io, 3);

    final dl = await h.manager.addUrl('https://example.com/media.m3u8');
    // Pre-place segment 0 as if a previous run downloaded it.
    await h.io.mkdir('/cache/${dl.id}-hls');
    await h.io.writeFile('/cache/${dl.id}-hls/seg-000000.ts', _segBody);

    await dl.start();

    expect(dl.state, DownloadState.completed);
    final segUrls = h.io.fetcher.requests
        .map((r) => r.url)
        .where((u) => u.contains('seg-'))
        .toList();
    expect(segUrls, isNot(contains('https://cdn.example.com/seg-000001.ts')));
    expect(segUrls, contains('https://cdn.example.com/seg-000002.ts'));
    expect(segUrls, contains('https://cdn.example.com/seg-000003.ts'));
  });

  test('reports segment-based progress (hlsSegmentsDone / total)', () async {
    final h = await Harness.create();
    _routeMedia(h.io, 'https://example.com/media.m3u8');
    _routeSegments(h.io, 3);

    final dl = await h.manager.addUrl('https://example.com/media.m3u8');
    await dl.start();

    final d = dl.describe();
    expect(d.hlsTotalSegments, equals(3));
    expect(d.hlsSegmentsDone, equals(3));
    expect(d.percent, equals(100));
  });
}
