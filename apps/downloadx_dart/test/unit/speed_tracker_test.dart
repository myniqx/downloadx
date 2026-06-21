import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

void main() {
  group('SpeedTracker', () {
    test('throws on non-positive window', () {
      expect(() => SpeedTracker(0), throwsArgumentError);
    });

    test('throws on negative delta', () {
      final t = SpeedTracker(1000);
      expect(() => t.record(-1), throwsArgumentError);
    });

    test('instant speed reflects last two samples', () {
      var now = 1000;
      final t = SpeedTracker(10000, () => now);
      t.record(100); // first sample, no instant yet
      now += 1000; // 1s later
      t.record(200); // 200 bytes in 1s => 200 B/s
      expect(t.instantSpeed, closeTo(200, 0.001));
    });

    test('windowed speed averages across window and evicts old samples', () {
      var now = 0;
      final t = SpeedTracker(1000, () => now);
      t.record(100);
      now += 500;
      t.record(100);
      // 200 bytes over 500ms span => 400 B/s
      expect(t.windowedSpeed, closeTo(400, 0.001));
      now += 2000; // everything older than window evicted
      expect(t.windowedSpeed, 0);
    });

    test('hasWarmedUp respects age', () {
      var now = 0;
      final t = SpeedTracker(1000, () => now);
      expect(t.hasWarmedUp(1500), isFalse);
      now += 1600;
      expect(t.hasWarmedUp(1500), isTrue);
    });
  });

  group('AggregateSpeed', () {
    test('median requires at least two active chunks', () {
      var now = 0;
      final agg = AggregateSpeed();
      final a = SpeedTracker(10000, () => now);
      agg.add('a', a);
      a.record(100);
      expect(agg.medianWindowedSpeed(), 0); // only one chunk

      final b = SpeedTracker(10000, () => now);
      agg.add('b', b);
      now += 1000;
      a.record(1000);
      b.record(100);
      expect(agg.medianWindowedSpeed(), greaterThan(0));
    });

    test('totalBytes sums children', () {
      final agg = AggregateSpeed();
      final a = SpeedTracker(10000);
      final b = SpeedTracker(10000);
      agg.add('a', a);
      agg.add('b', b);
      a.record(100);
      b.record(50);
      expect(agg.totalBytes, 150);
      agg.remove('b');
      expect(agg.totalBytes, 100);
    });
  });
}
