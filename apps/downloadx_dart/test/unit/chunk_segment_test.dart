import 'dart:typed_data';

import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

import '../helpers/mock_io.dart';

/// Phase 1: Chunk.isSegment mode.
///
/// A segment chunk downloads a whole HLS segment file from byte 0 into its own
/// targetFilePath, is never split, and (when size is unknown) streams until
/// EOF. Retry/throttle/speed/resume behave exactly like a normal chunk — those
/// are covered by the Download integration suite, so here we focus on the
/// segment-specific guarantees.

const segUrl = 'https://cdn/seg-000000.ts';
const segPath = '/cache/d1-hls/seg-000000.ts';
final payload = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

/// Minimal live config for constructing a [Chunk] in isolation.
class _TestConfig implements DownloadConfig {
  @override
  final DownloadxIo io;
  _TestConfig(this.io);

  @override
  int get maxRetries => 2;
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

Chunk makeSegmentChunk(
  MockIo io, {
  int initialDownloadedBytes = 0,
  int length = unknownSizeLength,
}) {
  return Chunk(ChunkParams(
    id: 'd1-c0',
    downloadId: 'd1',
    url: segUrl,
    targetFilePath: segPath,
    offset: 0,
    length: length,
    initialDownloadedBytes: initialDownloadedBytes,
    // Optimistic resume: segments download from byte 0 with no range, so a
    // server that ignores Range can't splice stale bytes.
    acceptsRanges: false,
    global: _TestConfig(io),
    isSegment: true,
    emitter: EventEmitter(),
    medianSpeedRef: () => 0,
  ));
}

void main() {
  group('Chunk segment mode', () {
    test('downloads an unknown-size segment from byte 0 into its own file',
        () async {
      final io = MockIo();
      io.fetcher.route(segUrl,
          MockRoute(body: payload, acceptsRanges: false, unknownSize: true));
      final chunk = makeSegmentChunk(io);

      await chunk.run();

      expect(chunk.status, ChunkStatus.completed);
      expect(chunk.downloadedBytes, payload.length);
      expect(await io.readFile(segPath), payload);
    });

    test('is never split, even with plenty of remaining work', () {
      final io = MockIo();
      final chunk = makeSegmentChunk(io, length: 10000);
      expect(chunk.isSegment, isTrue);
      expect(chunk.truncateTail(16), isNull);
    });

    test('does not send a Range header (writes from byte 0)', () async {
      final io = MockIo();
      io.fetcher.route(segUrl,
          MockRoute(body: payload, acceptsRanges: false, unknownSize: true));
      final chunk = makeSegmentChunk(io);

      await chunk.run();

      final segReqs = io.fetcher.requests.where((r) => r.url == segUrl);
      expect(segReqs, isNotEmpty);
      for (final req in segReqs) {
        expect(req.headers.containsKey('Range'), isFalse);
        expect(req.headers.containsKey('range'), isFalse);
      }
    });

    test('restarts from byte 0 when resumed (no-range optimistic behaviour)',
        () async {
      final io = MockIo();
      io.fetcher.route(segUrl,
          MockRoute(body: payload, acceptsRanges: false, unknownSize: true));
      // Simulate a resume: some bytes were already written previously.
      final chunk = makeSegmentChunk(io, initialDownloadedBytes: 3);

      await chunk.run();

      expect(chunk.status, ChunkStatus.completed);
      expect(chunk.downloadedBytes, payload.length);
      expect(await io.readFile(segPath), payload);
    });
  });
}
