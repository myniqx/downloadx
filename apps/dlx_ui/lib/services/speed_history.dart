/// A fixed-capacity ring of speed frames. Each frame maps a series id
/// (download id) to its bytes/sec at that instant, plus the global speed
/// limit active at that moment (null = unlimited).
class SpeedHistory {
  final int capacity;
  final List<Map<String, double>> _frames = [];
  final List<double?> _limits = [];

  SpeedHistory({this.capacity = 120});

  void push(Map<String, double> frame, {double? speedLimit}) {
    _frames.add(frame);
    _limits.add(speedLimit == 0 ? null : speedLimit);
    while (_frames.length > capacity) {
      _frames.removeAt(0);
      _limits.removeAt(0);
    }
  }

  List<Map<String, double>> get frames => _frames;

  /// Speed limit value for each frame (parallel to [frames]).
  List<double?> get limits => _limits;

  /// Largest stacked total across all frames — natural Y auto-scale bound.
  double get peakTotal {
    var peak = 0.0;
    for (final f in _frames) {
      var sum = 0.0;
      for (final v in f.values) {
        sum += v;
      }
      if (sum > peak) peak = sum;
    }
    return peak;
  }

  void clear() {
    _frames.clear();
    _limits.clear();
  }
}
