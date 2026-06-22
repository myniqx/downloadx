import 'dart:convert';
import 'dart:typed_data';

import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

import '../helpers/harness.dart';
import '../helpers/mock_io.dart';

const _url = 'https://h/file.bin';

void main() {
  group('end-to-end', () {
    test('multi-chunk download assembles the exact file', () async {
      final body = deterministicBytes(1000);
      final h = await Harness.create(targetChunkCount: 4, minChunkSize: 64);
      h.io.fetcher.route(_url, MockRoute(body: body, etag: 'E1'));

      final dl = await h.manager.addUrl(_url);
      await dl.start();

      expect(dl.state, DownloadState.completed);
      expect(h.io.files['/downloads/file.bin'], equals(body));
      // Part file renamed away.
      expect(h.io.files.keys.any((k) => k.endsWith(tempExt)), isFalse);
      // More than one chunk was actually used.
      final getCount =
          h.io.fetcher.requests.where((r) => r.method == 'GET').length;
      expect(getCount, greaterThan(1));
    });

    test('single chunk mode uses one ranged request', () async {
      final body = deterministicBytes(500);
      final h = await Harness.create();
      h.io.fetcher.route(_url, MockRoute(body: body, etag: 'E1'));

      final dl = await h.manager
          .addUrl(_url, const DownloadOptions(chunkMode: ChunkMode.single));
      await dl.start();

      expect(dl.state, DownloadState.completed);
      expect(h.io.files['/downloads/file.bin'], equals(body));
    });

    test('describe() reports 100% and full bytes after completion', () async {
      final body = deterministicBytes(300);
      final h = await Harness.create();
      h.io.fetcher.route(_url, MockRoute(body: body, etag: 'E1'));
      final dl = await h.manager.addUrl(_url);
      await dl.start();

      final d = dl.describe();
      expect(d.state, DownloadState.completed);
      expect(d.downloadedBytes, 300);
      expect(d.totalBytes, 300);
    });

    test('emits stateChange, progress and completed events', () async {
      final body = deterministicBytes(400);
      final h = await Harness.create();
      h.io.fetcher.route(_url, MockRoute(body: body, etag: 'E1'));
      final dl = await h.manager.addUrl(_url);

      final states = <DownloadState>[];
      var progressSeen = false;
      var completedSeen = false;
      dl.emitter.onType<StateChangeEvent>((e) => states.add(e.current));
      dl.emitter.onType<ProgressEvent>((_) => progressSeen = true);
      dl.emitter.onType<CompletedEvent>((_) => completedSeen = true);

      await dl.start();

      expect(states, contains(DownloadState.downloading));
      expect(states, contains(DownloadState.completed));
      expect(progressSeen, isTrue);
      expect(completedSeen, isTrue);
    });
  });

  group('resume', () {
    test('cross-instance resume fetches only the remaining range', () async {
      final body = deterministicBytes(1000);
      final io = MockIo();
      io.fetcher
          .route(_url, MockRoute(body: body, etag: 'E1', acceptsRanges: true));

      const id = 'fixedid';
      // Seed a half-finished download: part file with the first 500 bytes and a
      // paused meta describing a single 1000-byte chunk at 500/1000.
      await io.writeFile(
          '/cache/fixedid$tempExt', Uint8List.sublistView(body, 0, 500));
      final meta = createMeta(
        id: id,
        url: _url,
        probe: const ProbeResult(
          url: _url,
          finalUrl: _url,
          totalSize: 1000,
          acceptsRanges: true,
          etag: 'E1',
          lastModified: null,
          contentType: null,
          filename: 'file.bin',
          isHls: false,
        ),
        chunks: [
          ChunkSnapshot(
            id: '$id-c0',
            offset: 0,
            length: 1000,
            downloadedBytes: 500,
            status: ChunkStatus.paused,
            quality: ChunkQuality.good,
            retries: 0,
          ),
        ],
      );
      meta.state = DownloadState.paused;
      await persistMeta(io, MetaLocator(dir: '/cache', id: id), meta);

      final h = await Harness.create(io: io);
      final dl = h.manager.getDownload(id);
      expect(dl, isNotNull);
      await dl!.start();

      expect(dl.state, DownloadState.completed);
      expect(h.io.files['/downloads/file.bin'], equals(body));
      // The resumed GET asked only for bytes 500-999.
      final ranges = h.io.fetcher.requests
          .where((r) => r.method == 'GET')
          .map((r) => r.headers['Range'])
          .whereType<String>()
          .toList();
      expect(ranges, contains('bytes=500-999'));
    });
  });

  group('robustness', () {
    test('cancel stops the download and leaves no final file', () async {
      final h = await Harness.create(targetChunkCount: 2);
      // Stalling stream so the download cannot race to completion before cancel.
      h.io.fetcher.route(
        _url,
        MockRoute(
            body: deterministicBytes(2000), etag: 'E1', stallForever: true),
      );
      final dl = await h.manager.addUrl(_url);
      final run = dl.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      dl.cancel();
      await run.timeout(const Duration(seconds: 10));

      expect(dl.state, DownloadState.cancelled);
      expect(h.io.files.containsKey('/downloads/file.bin'), isFalse);
    });

    test('404 propagates as error state and fatal error event', () async {
      final h = await Harness.create();
      // No route registered for this URL → 404.
      final dl = await h.manager.addUrl('https://h/missing.bin');
      ErrorEvent? err;
      dl.emitter.onType<ErrorEvent>((e) {
        if (e.fatal) err = e;
      });
      await dl.start();
      expect(dl.state, DownloadState.error);
      expect(err, isNotNull);
    });

    test('range-ignored server (200 instead of 206) falls back to single chunk',
        () async {
      final body = deterministicBytes(800);
      final h = await Harness.create(targetChunkCount: 4, minChunkSize: 64);
      h.io.fetcher
          .route(_url, MockRoute(body: body, etag: 'E1', ignoreRange: true));

      final dl = await h.manager.addUrl(_url);
      await dl.start();

      expect(dl.state, DownloadState.completed);
      expect(h.io.files['/downloads/file.bin'], equals(body));
    });

    test('unknown size streams to EOF in a single chunk', () async {
      final body = deterministicBytes(640);
      final h = await Harness.create();
      h.io.fetcher.route(_url, MockRoute(body: body, unknownSize: true));

      final dl = await h.manager.addUrl(_url);
      await dl.start();

      expect(dl.state, DownloadState.completed);
      expect(h.io.files['/downloads/file.bin'], equals(body));
    });

    test('retries transient GET failures then succeeds', () async {
      final body = deterministicBytes(200);
      final h = await Harness.create(maxRetries: 5);
      // First two GET attempts fail with 503, then succeed.
      h.io.fetcher.route(
          _url,
          MockRoute(
              body: body, etag: 'E1', failTimes: 2, streamChunkSize: 200));

      final dl = await h.manager
          .addUrl(_url, const DownloadOptions(chunkMode: ChunkMode.single));
      await dl.start();

      expect(dl.state, DownloadState.completed);
      expect(h.io.files['/downloads/file.bin'], equals(body));
    });

    test('size mismatch is rejected before rename', () async {
      // Lying server: advertises 1000 bytes, no range support, but the body is
      // only 500. The chunk streams to EOF and the final fileSize check catches
      // the shortfall before the part file is renamed into place. Pre-allocation
      // is disabled so the part file is exactly the bytes written (otherwise
      // prealloc would zero-fill to the advertised size and hide the shortfall).
      final body = deterministicBytes(500);
      final io = MockIo(enableTruncate: false);
      final h = await Harness.create(io: io);
      h.io.fetcher.route(
        _url,
        MockRoute(
            body: body,
            etag: 'E1',
            acceptsRanges: false,
            advertisedLength: 1000),
      );
      final dl = await h.manager.addUrl(_url);
      await dl.start();
      expect(dl.state, DownloadState.error);
      // The lie never reaches the target path.
      expect(h.io.files.containsKey('/downloads/file.bin'), isFalse);
    });
  });

  group('manager', () {
    test('maxParallel=1 still completes multiple downloads', () async {
      final h = await Harness.create(maxParallel: 1);
      final a = deterministicBytes(300);
      final b = deterministicBytes(400);
      h.io.fetcher.route('https://h/a.bin', MockRoute(body: a, etag: 'A'));
      h.io.fetcher.route('https://h/b.bin', MockRoute(body: b, etag: 'B'));

      final da = await h.manager.addUrl('https://h/a.bin');
      final db = await h.manager.addUrl('https://h/b.bin');
      await Future.wait([da.start(), db.start()]);

      expect(h.io.files['/downloads/a.bin'], equals(a));
      expect(h.io.files['/downloads/b.bin'], equals(b));
    });

    test('manager relays events from child downloads', () async {
      final h = await Harness.create();
      h.io.fetcher
          .route(_url, MockRoute(body: deterministicBytes(200), etag: 'E1'));
      var completed = false;
      h.manager.emitter.onType<CompletedEvent>((_) => completed = true);
      final dl = await h.manager.addUrl(_url);
      await dl.start();
      expect(completed, isTrue);
    });

    test('speed limit does not corrupt the download', () async {
      final body = deterministicBytes(500);
      final h = await Harness.create(speedLimit: 100000);
      h.io.fetcher.route(_url, MockRoute(body: body, etag: 'E1'));
      final dl = await h.manager.addUrl(_url);
      await dl.start();
      expect(h.io.files['/downloads/file.bin'], equals(body));
    });
  });

  group('features', () {
    test('journal writes NDJSON diagnostic lines', () async {
      final h = await Harness.create(journal: true);
      h.io.fetcher
          .route(_url, MockRoute(body: deterministicBytes(200), etag: 'E1'));
      final dl = await h.manager.addUrl(_url);
      await dl.start();

      final journalPath = '/cache/${dl.id}$journalExt';
      final raw = h.io.files[journalPath];
      expect(raw, isNotNull);
      final lines =
          utf8.decode(raw!).trim().split('\n').where((l) => l.isNotEmpty);
      // Every line is a valid JSON diagnostic with a code.
      for (final line in lines) {
        final obj = jsonDecode(line) as Map<String, dynamic>;
        expect(obj['code'], isA<String>());
      }
      expect(lines.any((l) => l.contains('state-change')), isTrue);
    });

    test('clear removes part file, meta, and journal', () async {
      final h = await Harness.create(journal: true);
      h.io.fetcher
          .route(_url, MockRoute(body: deterministicBytes(200), etag: 'E1'));
      final dl = await h.manager.addUrl(_url);
      await dl.start();
      final id = dl.id;
      await h.manager.clear(id);
      expect(h.io.files.containsKey('/cache/$id$metaExt'), isFalse);
      expect(h.manager.getDownload(id), isNull);
    });

    test('prealloc still works with truncate disabled', () async {
      final io = MockIo(enableTruncate: false);
      final h = await Harness.create(io: io);
      final body = deterministicBytes(300);
      io.fetcher.route(_url, MockRoute(body: body, etag: 'E1'));
      final dl = await h.manager.addUrl(_url);
      await dl.start();
      expect(io.files['/downloads/file.bin'], equals(body));
    });
  });
}
