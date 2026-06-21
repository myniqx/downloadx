import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

void main() {
  group('Throttle', () {
    test('zero capacity is a no-op', () async {
      final t = Throttle(0);
      await t.consume(1000000); // resolves immediately
      expect(t.capacityBytesPerSec, 0);
    });

    test('rejects negative capacity', () {
      expect(() => Throttle(-1), throwsArgumentError);
    });

    test('consumes within budget immediately', () async {
      final now = 0;
      final t = Throttle(1000, now: () => now);
      await t.consume(500); // bucket starts full
      await t.consume(500);
    });

    test('queues when over budget and drains after refill', () async {
      var now = 0;
      final scheduled = <void Function()>[];
      final t = Throttle(
        1000,
        now: () => now,
        schedule: (ms, cb) => scheduled.add(cb),
      );
      await t.consume(1000); // empties the bucket
      var done = false;
      final f = t.consume(1000).then((_) => done = true);
      expect(done, isFalse);
      // Advance time so a full second has refilled, then run scheduled drain.
      now += 1000;
      for (final cb in List.of(scheduled)) {
        cb();
      }
      await f;
      expect(done, isTrue);
    });

    test('setCapacity to 0 releases waiters immediately', () async {
      final now = 0;
      final t = Throttle(1000, now: () => now, schedule: (ms, cb) {});
      await t.consume(1000);
      final f = t.consume(1000);
      t.setCapacity(0); // unlimited — release everything
      await f; // resolves
    });

    test('consume aborts when signal cancelled', () async {
      final now = 0;
      final t = Throttle(1000, now: () => now, schedule: (ms, cb) {});
      await t.consume(1000);
      final token = CancelToken();
      final f = t.consume(1000, token);
      token.cancel();
      await expectLater(f, throwsA(isA<AbortError>()));
    });
  });
}
