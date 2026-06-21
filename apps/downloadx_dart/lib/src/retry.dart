import 'dart:async';
import 'dart:math';

import 'constants.dart';
import 'io.dart';

/// Marker error signalling that the HTTP response itself reported a failure.
/// The retry loop uses [status] to decide transient vs permanent.
class HttpStatusError implements Exception {
  final int status;
  final String statusText;
  final String message;

  HttpStatusError(this.status, this.statusText, [String? message])
      : message = message ?? 'HTTP $status $statusText';

  @override
  String toString() => message;
}

/// Thrown when a Range request came back `200 OK` instead of `206 Partial
/// Content` — the server ignored the Range header. Retrying won't help; the
/// download falls back to a single full-body request. Status 200 is in neither
/// retry set, so the retry loop fails fast.
class RangeNotHonoredError extends HttpStatusError {
  RangeNotHonoredError()
      : super(
            200, 'OK', 'Server ignored Range header (HTTP 200 instead of 206)');
}

class RetryInfo {
  final int attempt;
  final int delayMs;
  final Object error;
  const RetryInfo(
      {required this.attempt, required this.delayMs, required this.error});
}

typedef RetrySleep = Future<void> Function(int ms, CancelToken? signal);

class RetryOptions {
  final int maxRetries;

  /// Base delay in ms for the first retry.
  final int retryDelay;

  /// Multiplier applied per attempt: delay = retryDelay * backoff^attempt.
  final num retryBackoff;

  /// Abort signal — when fired, the retry loop exits immediately.
  final CancelToken? signal;

  /// Sleep implementation — overridable for deterministic tests.
  final RetrySleep? sleep;

  /// Observer invoked before each retry; useful for logging / events.
  final void Function(RetryInfo info)? onRetry;

  /// Jitter source — overridable for deterministic tests.
  final Random? random;

  const RetryOptions({
    required this.maxRetries,
    required this.retryDelay,
    required this.retryBackoff,
    this.signal,
    this.sleep,
    this.onRetry,
    this.random,
  });
}

/// Runs [execute] with retry-on-failure. Retries only transient errors:
///   - network errors (anything that is NOT an [HttpStatusError] or [AbortError])
///   - HTTP 408/425/429/5xx (see [retryableStatus])
///
/// Permanent errors (4xx other than the retryable ones) and [AbortError]
/// (deliberate pause/cancel) fail fast.
Future<T> withRetry<T>(
  Future<T> Function(int attempt) execute,
  RetryOptions options,
) async {
  final sleep = options.sleep ?? _defaultSleep;
  final rng = options.random ?? Random();
  var attempt = 0;

  while (true) {
    if (options.signal?.isCancelled ?? false) {
      throw options.signal!.reason;
    }
    try {
      return await execute(attempt);
    } catch (err) {
      if (!_isRetryable(err) || attempt >= options.maxRetries) rethrow;
      final delayMs = _computeDelay(options, attempt, rng);
      options.onRetry
          ?.call(RetryInfo(attempt: attempt + 1, delayMs: delayMs, error: err));
      await sleep(delayMs, options.signal);
      attempt += 1;
    }
  }
}

int _computeDelay(RetryOptions options, int attempt, Random rng) {
  final base = options.retryDelay;
  final factor = pow(options.retryBackoff, attempt).toDouble();
  // Full jitter within [base*factor/2, base*factor] so many retriers don't
  // rethunder the origin in lockstep.
  final ceiling = base * factor;
  final floor = ceiling / 2;
  return (floor + rng.nextDouble() * (ceiling - floor)).round();
}

bool _isRetryable(Object err) {
  if (err is HttpStatusError) {
    if (nonRetryableStatus.contains(err.status)) return false;
    if (retryableStatus.contains(err.status)) return true;
    // Unknown 4xx → permanent; unknown 5xx → retryable.
    return err.status >= 500;
  }
  // Deliberate abort (pause/cancel) is never retried.
  if (err is AbortError) return false;
  // Anything else (network, idle timeout, stall restart, DNS, TLS) retries.
  return true;
}

Future<void> _defaultSleep(int ms, CancelToken? signal) {
  if (signal?.isCancelled ?? false) {
    return Future.error(signal!.reason);
  }
  final completer = Completer<void>();
  Timer? timer;
  void Function()? dispose;
  timer = Timer(Duration(milliseconds: ms), () {
    dispose?.call();
    if (!completer.isCompleted) completer.complete();
  });
  if (signal != null) {
    dispose = signal.onCancel(() {
      timer?.cancel();
      if (!completer.isCompleted) completer.completeError(signal.reason);
    });
  }
  return completer.future;
}
