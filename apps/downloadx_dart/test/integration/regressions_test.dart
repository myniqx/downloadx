import 'dart:typed_data';

import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

import '../helpers/harness.dart';
import '../helpers/mock_io.dart';

const _url = 'https://h/file.bin';

/// Minimal [DownloadConfig] for building a [Chunk] in isolation.
class _Cfg implements DownloadConfig {
  @override
  final DownloadxIo io;
  _Cfg(this.io);
  @override
  int get maxRetries => 1;
  @override
  int get retryDelay => 1;
  @override
  num get retryBackoff => 1;
  @override
  int get speedSampleWindow => 500;
  @override
  int get requestTimeout => 5000;
  @override
  Map<String, String> get headers => const {};
  @override
  void addLog({DiagnosticLevel level = DiagnosticLevel.info, required String code, Map<String, dynamic>? params}) {}
}

void main() {
  group('regressions', () {
    test(
        'in-flight split clamping: shrinking length mid-stream stops writes at the new boundary',
        () async {
      final io = MockIo();
      final body = deterministicBytes(1000);
      io.fetcher
          .route(_url, MockRoute(body: body, etag: 'E1', streamChunkSize: 16));

      final emitter = EventEmitter();
      final chunk = Chunk(ChunkParams(
        id: 'c0',
        downloadId: 'd',
        url: _url,
        targetFilePath: '/p.part',
        offset: 0,
        length: 1000,
        initialDownloadedBytes: 0,
        acceptsRanges: true,
        global: _Cfg(io),
        emitter: emitter,
        medianSpeedRef: () => 0,
      ));

      int? newLen;
      // Once ~100 bytes are in, donate the tail — exactly the in-flight split
      // the Download performs. Writes must clamp to the new (shorter) length.
      emitter.onType<ChunkProgressEvent>((e) {
        if (newLen == null && e.downloadedBytes >= 100) {
          chunk.truncateTail(64);
          newLen = chunk.length;
        }
      });

      await chunk.run();

      expect(newLen, isNotNull);
      expect(newLen, lessThan(1000));
      expect(chunk.status, ChunkStatus.completed);
      // Stopped exactly at the shrunk boundary — never wrote past it.
      expect(chunk.downloadedBytes, newLen);
      final written = io.files['/p.part']!;
      expect(written.length, newLen);
      expect(written, equals(Uint8List.sublistView(body, 0, newLen!)));
    });

    test(
        'no range support: a mid-stream break restarts the chunk from byte zero',
        () async {
      final body = deterministicBytes(400);
      final h = await Harness.create(maxRetries: 3);
      // No range support; the first GET streams 100 bytes then breaks, the
      // retry must restart the body from 0 (not splice at the partial offset).
      h.io.fetcher.route(
        _url,
        MockRoute(
          body: body,
          acceptsRanges: false,
          failStreamTimes: 1,
          failStreamAfterBytes: 100,
          streamChunkSize: 16,
        ),
      );

      var restart = false;
      final dl = await h.manager.addUrl(_url);
      dl.emitter.onType<LogEvent>((e) {
        if (e.message.contains('restarting from byte 0')) restart = true;
      });

      await dl.start();

      expect(dl.state, DownloadState.completed);
      expect(h.io.files['/downloads/file.bin'], equals(body));
      expect(restart, isTrue, reason: 'should have restarted from byte 0');
    });

    test(
        'network idle timeout aborts and retries, then errors when budget runs out',
        () async {
      // Stream emits the first 16 bytes then hangs. The idle timer must fire,
      // abort the attempt (transient), and retry — exhausting the budget ends
      // in `error`, not a hang.
      final h = await Harness.create(maxRetries: 1, requestTimeout: 80);
      h.io.fetcher.route(
        _url,
        MockRoute(
          body: deterministicBytes(200),
          etag: 'E1',
          stallForever: true,
          streamChunkSize: 16,
        ),
      );

      var idleRetry = false;
      h.io; // ensure created
      final dl = await h.manager
          .addUrl(_url, const DownloadOptions(chunkMode: ChunkMode.single));
      dl.emitter.onType<LogEvent>((e) {
        if (e.message.contains('retry #')) idleRetry = true;
      });

      await dl.start().timeout(const Duration(seconds: 10));

      expect(dl.state, DownloadState.error);
      expect(idleRetry, isTrue,
          reason: 'idle timeout should have triggered a retry');
      // The lie never reaches the target path.
      expect(h.io.files.containsKey('/downloads/file.bin'), isFalse);
    });

    test('pause then resume completes correctly (race-tolerant)', () async {
      final body = deterministicBytes(2000);
      final h = await Harness.create(
          targetChunkCount: 4, minChunkSize: 64, speedLimit: 20000);
      h.io.fetcher
          .route(_url, MockRoute(body: body, etag: 'E1', streamChunkSize: 8));

      final dl = await h.manager.addUrl(_url);
      final first = dl.start();
      // Ask to pause almost immediately. It may race to completion — that's fine.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      dl.pause();
      await first;

      if (dl.state != DownloadState.completed) {
        expect(dl.state, DownloadState.paused);
        // Resume to completion.
        await dl.start();
      }
      expect(dl.state, DownloadState.completed);
      expect(h.io.files['/downloads/file.bin'], equals(body));
    });

    test('probe falls back to ranged GET when HEAD lacks Content-Length',
        () async {
      final body = deterministicBytes(300);
      final h = await Harness.create();
      h.io.fetcher.route(
        _url,
        MockRoute(body: body, etag: 'E1', headWithoutLength: true),
      );
      final dl = await h.manager.addUrl(_url);
      await dl.start();
      expect(dl.state, DownloadState.completed);
      expect(h.io.files['/downloads/file.bin'], equals(body));
      // A ranged probe GET (bytes=0-0) was issued because HEAD was unusable.
      final probedRange = h.io.fetcher.requests
          .any((r) => r.method == 'GET' && (r.headers['Range'] == 'bytes=0-0'));
      expect(probedRange, isTrue);
    });

    test('final URL after redirect is used for chunk requests', () async {
      final body = deterministicBytes(300);
      final h = await Harness.create();
      const finalUrl = 'https://cdn/real.bin';
      h.io.fetcher
          .route(_url, MockRoute(body: body, etag: 'E1', finalUrl: finalUrl));
      // The chunk requests go to the final URL; register the same body there.
      h.io.fetcher.route(finalUrl, MockRoute(body: body, etag: 'E1'));

      final dl = await h.manager.addUrl(_url);
      await dl.start();
      expect(dl.state, DownloadState.completed);
      final hitFinal = h.io.fetcher.requests.any((r) => r.url == finalUrl);
      expect(hitFinal, isTrue);
    });
  });
}
