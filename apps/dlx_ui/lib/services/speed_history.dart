/// A fixed-capacity ring of speed frames. Each frame maps a series id
/// (download id, or chunk id) to its bytes/sec at that instant. The charts
/// stack the series within each frame.
class SpeedHistory {
  final int capacity;
  final List<Map<String, double>> _frames = [];

  SpeedHistory({this.capacity = 120});

  void push(Map<String, double> frame) {
    _frames.add(frame);
    while (_frames.length > capacity) {
      _frames.removeAt(0);
    }
  }

  List<Map<String, double>> get frames => _frames;

  /// Largest stacked total across all frames — the natural Y auto-scale bound.
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

  void clear() => _frames.clear();
}
