/// Per-chunk bandwidth tracker.
///
/// Exposes two independent readings:
///   - [instantSpeed]  — throughput between the last two samples (good for UI).
///   - [windowedSpeed] — moving average over `windowMs` (drives the splitter,
///                       so decisions aren't whipsawed by transient jitter).
///
/// Implemented as a ring buffer of `{ t, bytes }` samples; each [record] drops
/// samples older than `windowMs`.
class SpeedTracker {
  final List<_Sample> _samples = [];
  int? _lastSampleAt;
  double _lastInstantSpeed = 0;
  int _totalBytes = 0;
  final int _startedAt;
  final int windowMs;
  final int Function() _now;

  /// Creates a [SpeedTracker] with a moving-average [windowMs].
  /// [now] overrides the clock source for deterministic tests.
  SpeedTracker(this.windowMs, [int Function()? now])
      : _now = now ?? _defaultNow,
        _startedAt = (now ?? _defaultNow)() {
    if (windowMs <= 0) {
      throw ArgumentError('SpeedTracker: windowMs must be > 0 (got $windowMs)');
    }
  }

  /// Register [deltaBytes] newly downloaded. Call once per network read.
  void record(int deltaBytes) {
    if (deltaBytes < 0) {
      throw ArgumentError(
          'SpeedTracker.record: deltaBytes must be >= 0 (got $deltaBytes)');
    }
    final t = _now();
    _totalBytes += deltaBytes;

    if (_lastSampleAt != null) {
      final dt = t - _lastSampleAt!;
      if (dt > 0) {
        _lastInstantSpeed = (deltaBytes * 1000) / dt;
      }
    }
    _lastSampleAt = t;

    _samples.add(_Sample(t, deltaBytes));
    _evict(t);
  }

  /// Bytes per second measured between the last two samples.
  double get instantSpeed => _lastInstantSpeed;

  /// Bytes per second averaged across the configured window.
  double get windowedSpeed {
    final t = _now();
    _evict(t);
    if (_samples.isEmpty) return 0;
    final span = t - _samples.first.t;
    if (span <= 0) return 0;
    var bytes = 0;
    for (final s in _samples) {
      bytes += s.bytes;
    }
    return (bytes * 1000) / span;
  }

  /// Overall average since the tracker was created.
  double get averageSpeed {
    final span = _now() - _startedAt;
    if (span <= 0) return 0;
    return (_totalBytes * 1000) / span;
  }

  /// Total bytes recorded since construction.
  int get bytesRecorded => _totalBytes;

  /// Milliseconds elapsed since this tracker was created.
  int get ageMs => _now() - _startedAt;

  /// Whether enough time has passed since start to trust the windowed speed
  /// for quality decisions (avoids flagging a chunk `poor` during TCP warmup).
  bool hasWarmedUp(int warmupMs) => ageMs >= warmupMs;

  /// Clears speed samples and resets the instant speed to zero.
  void reset() {
    _samples.clear();
    _lastSampleAt = null;
    _lastInstantSpeed = 0;
  }

  void _evict(int now) {
    final cutoff = now - windowMs;
    while (_samples.isNotEmpty && _samples.first.t < cutoff) {
      _samples.removeAt(0);
    }
  }
}

class _Sample {
  final int t;
  final int bytes;
  _Sample(this.t, this.bytes);
}

int _defaultNow() => DateTime.now().millisecondsSinceEpoch;

/// Aggregates many [SpeedTracker] instances into a download-wide view.
/// Lightweight: no samples of its own; just sums over child trackers.
class AggregateSpeed {
  final Map<String, SpeedTracker> _children = {};

  /// Creates an empty [AggregateSpeed].
  AggregateSpeed();

  /// Registers a [tracker] under [id]. Replaces any existing entry.
  void add(String id, SpeedTracker tracker) => _children[id] = tracker;

  /// Removes the tracker registered under [id].
  void remove(String id) => _children.remove(id);

  /// Sum of instant speeds across all registered trackers (bytes/sec).
  double get totalSpeed {
    var sum = 0.0;
    for (final t in _children.values) {
      sum += t.instantSpeed;
    }
    return sum;
  }

  /// Sum of bytes recorded across all registered trackers.
  int get totalBytes {
    var sum = 0;
    for (final t in _children.values) {
      sum += t.bytesRecorded;
    }
    return sum;
  }

  /// Median of windowed speeds across tracked chunks. Used as the reference for
  /// quality classification. Returns 0 when fewer than two chunks are active.
  double medianWindowedSpeed() {
    final speeds = <double>[];
    for (final t in _children.values) {
      if (t.bytesRecorded > 0) speeds.add(t.windowedSpeed);
    }
    if (speeds.length < 2) return 0;
    speeds.sort();
    final mid = speeds.length ~/ 2;
    if (speeds.length.isEven) {
      return (speeds[mid - 1] + speeds[mid]) / 2;
    }
    return speeds[mid];
  }
}
