import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

import '../helpers/mock_io.dart';

void main() {
  group('meta', () {
    test('createEmptyMeta has nulls before probe', () {
      final m = createEmptyMeta(id: 'abc', url: 'https://x/y');
      expect(m.schemaVersion, metaSchemaVersion);
      expect(m.filename, isNull);
      expect(m.totalSize, isNull);
      expect(m.state, DownloadState.idle);
      expect(m.chunks, isEmpty);
    });

    test('applyProbeToMeta fills probe-derived fields', () {
      final m = createEmptyMeta(id: 'abc', url: 'https://x/y');
      const probe = ProbeResult(
        url: 'https://x/y',
        finalUrl: 'https://x/y',
        totalSize: 1000,
        acceptsRanges: true,
        etag: 'W/"abc"',
        lastModified: null,
        contentType: 'application/octet-stream',
        filename: 'y',
        isHls: false,
      );
      applyProbeToMeta(m, probe, []);
      expect(m.filename, 'y');
      expect(m.totalSize, 1000);
      expect(m.acceptsRanges, isTrue);
      expect(m.etag, 'W/"abc"');
    });

    test('persist + load round trip', () async {
      final io = MockIo();
      final m = createMeta(
        id: 'abc',
        url: 'https://x/y',
        probe: const ProbeResult(
          url: 'https://x/y',
          finalUrl: 'https://x/y',
          totalSize: 300,
          acceptsRanges: true,
          etag: 'E1',
          lastModified: null,
          contentType: null,
          filename: 'y',
          isHls: false,
        ),
        chunks: [
          ChunkSnapshot(
            id: 'abc-c0',
            offset: 0,
            length: 300,
            downloadedBytes: 100,
            status: ChunkStatus.downloading,
            quality: ChunkQuality.good,
            retries: 1,
          ),
        ],
      );
      final loc = MetaLocator(dir: '/cache', id: 'abc');
      await persistMeta(io, loc, m);
      final loaded = await loadMeta(io, loc);
      expect(loaded, isNotNull);
      expect(loaded!.totalSize, 300);
      expect(loaded.chunks.length, 1);
      expect(loaded.chunks.first.downloadedBytes, 100);
      // downloading state is dehydrated to paused only when the engine persists;
      // here we persisted as-is, so it remains downloading.
      expect(loaded.chunks.first.status, ChunkStatus.downloading);
    });

    test('listMetaFiles finds only matching sidecars', () async {
      final io = MockIo();
      final loc = MetaLocator(dir: '/cache', id: 'abc');
      await persistMeta(io, loc, createEmptyMeta(id: 'abc', url: 'u'));
      await io.writeFile('/cache/not-a-meta.txt', [1, 2, 3]);
      final metas = await listMetaFiles(io, '/cache');
      expect(metas.length, 1);
      expect(metas.first.id, 'abc');
    });

    test('canResumeAgainst: etag match', () {
      final m = createEmptyMeta(id: 'a', url: 'u')
        ..totalSize = 100
        ..etag = 'E1';
      const probe = ProbeResult(
        url: 'u',
        finalUrl: 'u',
        totalSize: 100,
        acceptsRanges: true,
        etag: 'E1',
        lastModified: null,
        contentType: null,
        filename: 'f',
        isHls: false,
      );
      expect(canResumeAgainst(m, probe), isTrue);
    });

    test('canResumeAgainst: etag mismatch blocks resume', () {
      final m = createEmptyMeta(id: 'a', url: 'u')
        ..totalSize = 100
        ..etag = 'E1';
      const probe = ProbeResult(
        url: 'u',
        finalUrl: 'u',
        totalSize: 100,
        acceptsRanges: true,
        etag: 'E2',
        lastModified: null,
        contentType: null,
        filename: 'f',
        isHls: false,
      );
      expect(canResumeAgainst(m, probe), isFalse);
    });

    test('canResumeAgainst: size mismatch blocks resume', () {
      final m = createEmptyMeta(id: 'a', url: 'u')..totalSize = 100;
      const probe = ProbeResult(
        url: 'u',
        finalUrl: 'u',
        totalSize: 200,
        acceptsRanges: true,
        etag: null,
        lastModified: null,
        contentType: null,
        filename: 'f',
        isHls: false,
      );
      expect(canResumeAgainst(m, probe), isFalse);
    });

    test('dehydrateState maps downloading/probing to paused', () {
      expect(dehydrateState(DownloadState.downloading), DownloadState.paused);
      expect(dehydrateState(DownloadState.probing), DownloadState.paused);
      expect(dehydrateState(DownloadState.completed), DownloadState.completed);
      expect(dehydrateState(DownloadState.error), DownloadState.error);
    });

    test('corrupt meta loads as null', () async {
      final io = MockIo();
      await io.writeFile('/cache/bad$metaExt', 'not json'.codeUnits);
      final loaded = await loadMeta(io, MetaLocator(dir: '/cache', id: 'bad'));
      expect(loaded, isNull);
    });
  });
}
