import 'dart:typed_data';

import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

import '../helpers/harness.dart';
import '../helpers/mock_io.dart';

const _url = 'https://h/file.bin';

MetaFile _seedMeta({
  required String id,
  required int totalSize,
  required int downloadedBytes,
  String? etag,
  String? lastModified,
}) {
  final meta = createMeta(
    id: id,
    url: _url,
    probe: ProbeResult(
      url: _url,
      finalUrl: _url,
      totalSize: totalSize,
      acceptsRanges: true,
      etag: etag,
      lastModified: lastModified,
      contentType: null,
      filename: 'file.bin',
    ),
    chunks: [
      ChunkSnapshot(
        id: '$id-c0',
        offset: 0,
        length: totalSize,
        downloadedBytes: downloadedBytes,
        status: ChunkStatus.paused,
        quality: ChunkQuality.good,
        retries: 0,
      ),
    ],
  );
  meta.state = DownloadState.paused;
  return meta;
}

void main() {
  group('validator changes', () {
    test('etag mismatch discards the stale part and re-downloads fresh',
        () async {
      final io = MockIo();
      final body = deterministicBytes(600);
      // Server now serves a *new* etag — the resource changed under us.
      io.fetcher.route(_url, MockRoute(body: body, etag: 'E2'));

      const id = 'vid';
      // Stale part: 300 bytes of the WRONG content (zeros).
      await io.writeFile('/downloads/file.bin$tempExt', Uint8List(300));
      await persistMeta(
        io,
        MetaLocator(dir: '/cache', id: id),
        _seedMeta(id: id, totalSize: 600, downloadedBytes: 300, etag: 'E1'),
      );

      final h = await Harness.create(io: io);
      final dl = h.manager.getDownload(id)!;
      await dl.start();

      expect(dl.state, DownloadState.completed);
      // The stale zeros were discarded; the file is the fresh, correct body.
      expect(io.files['/downloads/file.bin'], equals(body));
    });

    test('resume is validated by Last-Modified when no ETag is present',
        () async {
      final io = MockIo();
      final body = deterministicBytes(1000);
      const lm = 'Wed, 21 Oct 2025 07:28:00 GMT';
      io.fetcher.route(_url, MockRoute(body: body, lastModified: lm));

      const id = 'lmid';
      await io.writeFile(
          '/downloads/file.bin$tempExt', Uint8List.sublistView(body, 0, 400));
      await persistMeta(
        io,
        MetaLocator(dir: '/cache', id: id),
        _seedMeta(
            id: id, totalSize: 1000, downloadedBytes: 400, lastModified: lm),
      );

      final h = await Harness.create(io: io);
      final dl = h.manager.getDownload(id)!;
      await dl.start();

      expect(dl.state, DownloadState.completed);
      expect(io.files['/downloads/file.bin'], equals(body));
      final ranges = h.io.fetcher.requests
          .where((r) => r.method == 'GET')
          .map((r) => r.headers['Range'])
          .whereType<String>();
      expect(ranges, contains('bytes=400-999'));
    });
  });

  group('scheduler sizing', () {
    test('totalSize exactly minChunkSize stays a single chunk', () {
      final plans = planChunks(const PlanOptions(
          totalSize: 1000, targetChunkCount: 4, minChunkSize: 1000));
      expect(plans.length, 1);
      expect(plans.first.length, 1000);
    });

    test('zero total size yields one empty chunk', () {
      final plans = planChunks(const PlanOptions(
          totalSize: 0, targetChunkCount: 4, minChunkSize: 64));
      expect(plans.length, 1);
      expect(plans.first.length, 0);
    });

    test('chunks always tile the file exactly', () {
      final plans = planChunks(const PlanOptions(
          totalSize: 1003, targetChunkCount: 4, minChunkSize: 100));
      var offset = 0;
      for (final p in plans) {
        expect(p.offset, offset);
        offset += p.length;
      }
      expect(offset, 1003);
    });
  });

  group('fs edge cases', () {
    test('writeChunk fills gaps with zeros and preserves prior bytes',
        () async {
      final io = MockIo();
      await io.writeChunk('/f', 0, [1, 2, 3]);
      await io.writeChunk('/f', 10, [9, 9]); // leaves a 3..9 gap
      final f = io.files['/f']!;
      expect(f.length, 12);
      expect(f[0], 1);
      expect(f[2], 3);
      expect(f[5], 0); // gap is zero-filled
      expect(f[10], 9);
      expect(f[11], 9);
    });

    test('overlapping writes overwrite in place without growing', () async {
      final io = MockIo();
      await io.writeChunk('/f', 0, [1, 2, 3, 4, 5]);
      await io.writeChunk('/f', 1, [8, 8]);
      final f = io.files['/f']!;
      expect(f.length, 5);
      expect(f, equals(Uint8List.fromList([1, 8, 8, 4, 5])));
    });
  });

  group('transient failures', () {
    test('recovers across several retryable HTTP failures', () async {
      final body = deterministicBytes(256);
      final h = await Harness.create(maxRetries: 5);
      h.io.fetcher.route(
        _url,
        MockRoute(
            body: body,
            etag: 'E1',
            failTimes: 3,
            failStatus: 503,
            streamChunkSize: 256),
      );
      final dl = await h.manager
          .addUrl(_url, const DownloadOptions(chunkMode: ChunkMode.single));
      await dl.start();
      expect(dl.state, DownloadState.completed);
      expect(h.io.files['/downloads/file.bin'], equals(body));
    });
  });
}
