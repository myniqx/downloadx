import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

void main() {
  group('planChunks', () {
    test('single chunk when smaller than minChunkSize', () {
      final plans = planChunks(const PlanOptions(
        totalSize: 500,
        targetChunkCount: 4,
        minChunkSize: 1000,
      ));
      expect(plans.length, 1);
      expect(plans.first.length, 500);
    });

    test('single chunk when targetChunkCount <= 1', () {
      final plans = planChunks(const PlanOptions(
        totalSize: 10000,
        targetChunkCount: 1,
        minChunkSize: 10,
      ));
      expect(plans.length, 1);
      expect(plans.first.length, 10000);
    });

    test('tiles the file with no gaps or overlaps', () {
      final plans = planChunks(const PlanOptions(
        totalSize: 1000,
        targetChunkCount: 4,
        minChunkSize: 100,
      ));
      expect(plans.length, 4);
      var expectedOffset = 0;
      var sum = 0;
      for (final p in plans) {
        expect(p.offset, expectedOffset);
        expectedOffset += p.length;
        sum += p.length;
      }
      expect(sum, 1000);
      expect(plans.last.offset + plans.last.length, 1000);
    });

    test('count is bounded by totalSize / minChunkSize', () {
      final plans = planChunks(const PlanOptions(
        totalSize: 1000,
        targetChunkCount: 100,
        minChunkSize: 250,
      ));
      // 1000 / 250 = 4 max chunks
      expect(plans.length, 4);
    });

    test('preserves resumeFrom layout', () {
      final plans = planChunks(PlanOptions(
        totalSize: 1000,
        targetChunkCount: 4,
        minChunkSize: 100,
        resumeFrom: const [
          ChunkPlan(offset: 0, length: 600, downloadedBytes: 300),
          ChunkPlan(offset: 600, length: 400, downloadedBytes: 0),
        ],
      ));
      expect(plans.length, 2);
      expect(plans.first.downloadedBytes, 300);
    });
  });
}
