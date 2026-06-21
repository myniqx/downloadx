import 'dart:math';

import 'package:downloadx/downloadx.dart';
import 'package:test/test.dart';

Future<void> _noSleep(int ms, CancelToken? signal) async {}

void main() {
  group('withRetry', () {
    test('returns on first success', () async {
      var calls = 0;
      final result = await withRetry<int>((attempt) async {
        calls += 1;
        return 42;
      },
          RetryOptions(
              maxRetries: 3, retryDelay: 1, retryBackoff: 2, sleep: _noSleep));
      expect(result, 42);
      expect(calls, 1);
    });

    test('retries transient errors up to maxRetries then throws', () async {
      var calls = 0;
      await expectLater(
        withRetry<int>((attempt) async {
          calls += 1;
          throw Exception('network');
        },
            RetryOptions(
                maxRetries: 2,
                retryDelay: 1,
                retryBackoff: 2,
                sleep: _noSleep)),
        throwsA(isA<Exception>()),
      );
      expect(calls, 3); // initial + 2 retries
    });

    test('does not retry permanent HTTP status (404)', () async {
      var calls = 0;
      await expectLater(
        withRetry<int>((attempt) async {
          calls += 1;
          throw HttpStatusError(404, 'Not Found');
        },
            RetryOptions(
                maxRetries: 5,
                retryDelay: 1,
                retryBackoff: 2,
                sleep: _noSleep)),
        throwsA(isA<HttpStatusError>()),
      );
      expect(calls, 1);
    });

    test('retries retryable HTTP status (503)', () async {
      var calls = 0;
      await expectLater(
        withRetry<int>((attempt) async {
          calls += 1;
          throw HttpStatusError(503, 'Unavailable');
        },
            RetryOptions(
                maxRetries: 2,
                retryDelay: 1,
                retryBackoff: 2,
                sleep: _noSleep)),
        throwsA(isA<HttpStatusError>()),
      );
      expect(calls, 3);
    });

    test('never retries AbortError', () async {
      var calls = 0;
      await expectLater(
        withRetry<int>((attempt) async {
          calls += 1;
          throw const AbortError();
        },
            RetryOptions(
                maxRetries: 5,
                retryDelay: 1,
                retryBackoff: 2,
                sleep: _noSleep)),
        throwsA(isA<AbortError>()),
      );
      expect(calls, 1);
    });

    test('retries TransientAbort (idle timeout / restart)', () async {
      var calls = 0;
      await expectLater(
        withRetry<int>((attempt) async {
          calls += 1;
          throw const TransientAbort('idle timeout');
        },
            RetryOptions(
                maxRetries: 1,
                retryDelay: 1,
                retryBackoff: 2,
                sleep: _noSleep)),
        throwsA(isA<TransientAbort>()),
      );
      expect(calls, 2);
    });

    test('RangeNotHonoredError fails fast (status 200, not retryable)',
        () async {
      var calls = 0;
      await expectLater(
        withRetry<int>((attempt) async {
          calls += 1;
          throw RangeNotHonoredError();
        },
            RetryOptions(
                maxRetries: 5,
                retryDelay: 1,
                retryBackoff: 2,
                sleep: _noSleep)),
        throwsA(isA<RangeNotHonoredError>()),
      );
      expect(calls, 1);
    });

    test('eventually succeeds after transient failures', () async {
      var calls = 0;
      final result = await withRetry<String>((attempt) async {
        calls += 1;
        if (calls < 3) throw Exception('flaky');
        return 'ok';
      },
          RetryOptions(
              maxRetries: 5,
              retryDelay: 1,
              retryBackoff: 2,
              sleep: _noSleep,
              random: Random(1)));
      expect(result, 'ok');
      expect(calls, 3);
    });
  });
}
