import 'dart:async';

import 'io.dart';

/// Token-bucket bandwidth limiter.
///
/// Each chunk calls [consume] right before writing the data it just read. If
/// the bucket has enough tokens, it resolves immediately; otherwise it resolves
/// once the shortage has refilled. One instance is shared by all chunks of a
/// download, so the cap applies to aggregate bandwidth.
///
/// `capacity == 0` disables throttling — [consume] becomes a no-op.
class Throttle {
  num _capacity;
  double _tokens;
  int _lastRefillAt;
  bool _disposed = false;

  final int Function() _now;
  final void Function(int ms, void Function() cb) _schedule;
  final List<_Waiter> _queue = [];

  Throttle(
    num capacity, {
    int Function()? now,
    void Function(int ms, void Function() cb)? schedule,
  })  : _capacity = capacity,
        _now = now ?? _defaultNow,
        _schedule = schedule ?? _defaultSchedule,
        _tokens = capacity.toDouble(),
        _lastRefillAt = (now ?? _defaultNow)() {
    if (capacity < 0) {
      throw ArgumentError('Throttle: capacity must be >= 0 (got $capacity)');
    }
  }

  /// Change the cap live (e.g. user toggles speedLimit mid-download).
  void setCapacity(num capacity) {
    if (capacity < 0) {
      throw ArgumentError('Throttle: capacity must be >= 0 (got $capacity)');
    }
    _refill();
    final previous = _capacity;
    _capacity = capacity;
    if (capacity == 0) {
      // Unlimited — release everything in-flight immediately.
      _tokens = 0;
      final pending = List<_Waiter>.of(_queue);
      _queue.clear();
      for (final entry in pending) {
        entry.dispose?.call();
        entry.resolve();
      }
      return;
    }
    if (capacity > previous) {
      // On raise, top the bucket up so queued waiters make progress at once.
      _tokens = capacity.toDouble();
    } else if (_tokens > capacity) {
      _tokens = capacity.toDouble();
    }
    _drainQueue();
  }

  num get capacityBytesPerSec => _capacity;

  /// Wait until [bytes] tokens are available, then deduct them. Resolves
  /// immediately when capacity is 0 (unlimited).
  Future<void> consume(int bytes, [CancelToken? signal]) {
    if (bytes <= 0) return Future.value();
    if (_capacity == 0) return Future.value();
    if (_disposed) return Future.error(StateError('Throttle disposed'));

    _refill();
    if (_tokens >= bytes) {
      _tokens -= bytes;
      return Future.value();
    }

    final completer = Completer<void>();
    if (signal?.isCancelled ?? false) {
      return Future.error(signal!.reason);
    }
    final waiter = _Waiter(bytes, completer);
    if (signal != null) {
      waiter.dispose = signal.onCancel(() {
        _queue.remove(waiter);
        if (!completer.isCompleted) completer.completeError(signal.reason);
      });
    }
    _queue.add(waiter);
    _scheduleDrain();
    return completer.future;
  }

  void dispose() {
    _disposed = true;
    for (final entry in _queue) {
      entry.dispose?.call();
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(StateError('Throttle disposed'));
      }
    }
    _queue.clear();
  }

  void _refill() {
    if (_capacity == 0) return;
    final now = _now();
    final elapsed = now - _lastRefillAt;
    if (elapsed <= 0) return;
    final next = _tokens + (elapsed * _capacity) / 1000;
    _tokens = next < _capacity ? next : _capacity.toDouble();
    _lastRefillAt = now;
  }

  void _drainQueue() {
    _refill();
    while (_queue.isNotEmpty) {
      final head = _queue.first;
      if (_tokens < head.need) break;
      _tokens -= head.need;
      _queue.removeAt(0);
      head.dispose?.call();
      head.resolve();
    }
    if (_queue.isNotEmpty) _scheduleDrain();
  }

  void _scheduleDrain() {
    if (_queue.isEmpty || _capacity == 0) return;
    final head = _queue.first;
    final missing = head.need - _tokens;
    if (missing <= 0) {
      _drainQueue();
      return;
    }
    final waitMs = (missing * 1000 / _capacity).ceil();
    _schedule(waitMs < 5 ? 5 : waitMs, _drainQueue);
  }
}

class _Waiter {
  final int need;
  final Completer<void> completer;
  void Function()? dispose;
  _Waiter(this.need, this.completer);
  void resolve() {
    if (!completer.isCompleted) completer.complete();
  }
}

int _defaultNow() => DateTime.now().millisecondsSinceEpoch;
void _defaultSchedule(int ms, void Function() cb) =>
    Timer(Duration(milliseconds: ms), cb);
