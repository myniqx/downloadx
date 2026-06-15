import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

import '../helpers/harness.dart';
import '../helpers/mock_io.dart';

const _url = 'https://h/file.bin';

void main() {
  group('regressions', () {
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
      dl.emitter.onType<DiagnosticEvent>((e) {
        if (e.payload.code == 'chunk-retry') idleRetry = true;
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
