import 'package:flutter/material.dart';

import '../../util/format.dart';

/// A live, stacked area chart of speed over time.
///
/// Each frame is a `{ seriesId: bytesPerSec }` map; series are stacked in
/// [seriesOrder] so each band's thickness is that series' speed and the stack
/// top is the combined throughput. The Y axis auto-scales to the rolling peak
/// (and to [limit] when set). A dashed horizontal line marks [limit].
class StackedSpeedChart extends StatelessWidget {
  final List<Map<String, double>> frames;
  final List<String> seriesOrder;
  final Color Function(String id) colorOf;
  final double? limit;
  final double height;

  const StackedSpeedChart({
    super.key,
    required this.frames,
    required this.seriesOrder,
    required this.colorOf,
    this.limit,
    this.height = 160,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SpeedChartPainter(
          frames: frames,
          seriesOrder: seriesOrder,
          colorOf: colorOf,
          limit: (limit != null && limit! > 0) ? limit : null,
          gridColor: Theme.of(context).dividerColor,
          labelStyle: Theme.of(context).textTheme.bodySmall ?? const TextStyle(fontSize: 11),
        ),
      ),
    );
  }
}

class _SpeedChartPainter extends CustomPainter {
  final List<Map<String, double>> frames;
  final List<String> seriesOrder;
  final Color Function(String id) colorOf;
  final double? limit;
  final Color gridColor;
  final TextStyle labelStyle;

  _SpeedChartPainter({
    required this.frames,
    required this.seriesOrder,
    required this.colorOf,
    required this.limit,
    required this.gridColor,
    required this.labelStyle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Peak stacked total across frames; floor avoids divide-by-zero and keeps
    // a tiny trace visible at low speeds.
    var peak = 0.0;
    for (final f in frames) {
      var sum = 0.0;
      for (final v in f.values) {
        sum += v;
      }
      if (sum > peak) peak = sum;
    }
    if (limit != null && limit! > peak) peak = limit! * 1.1;
    if (peak <= 0) peak = 1;

    double y(double value) => h - (value / peak) * h;
    double x(int i) => frames.length <= 1 ? w : (i / (frames.length - 1)) * w;

    // Baseline + faint mid gridline.
    final grid = Paint()
      ..color = gridColor.withValues(alpha: 0.4)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, h - 0.5), Offset(w, h - 0.5), grid);
    canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2), grid..color = gridColor.withValues(alpha: 0.15));

    if (frames.isNotEmpty) {
      // Cumulative base height per frame as we stack series upward.
      final base = List<double>.filled(frames.length, 0);
      for (final id in seriesOrder) {
        final color = colorOf(id);
        final top = <Offset>[];
        final bottom = <Offset>[];
        for (var i = 0; i < frames.length; i++) {
          final v = frames[i][id] ?? 0;
          final b = base[i];
          final t = b + v;
          bottom.add(Offset(x(i), y(b)));
          top.add(Offset(x(i), y(t)));
          base[i] = t;
        }
        final path = Path()..moveTo(top.first.dx, top.first.dy);
        for (final p in top.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        for (final p in bottom.reversed) {
          path.lineTo(p.dx, p.dy);
        }
        path.close();
        canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.55));
        // Crisp top edge.
        final edge = Path()..moveTo(top.first.dx, top.first.dy);
        for (final p in top.skip(1)) {
          edge.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(
          edge,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }

    // Limit line.
    if (limit != null) {
      final ly = y(limit!);
      final paint = Paint()
        ..color = const Color(0xFFE57373)
        ..strokeWidth = 1.5;
      const dash = 6.0;
      for (var dx = 0.0; dx < w; dx += dash * 2) {
        canvas.drawLine(Offset(dx, ly), Offset(dx + dash, ly), paint);
      }
      _label(canvas, 'limit ${formatSpeed(limit!)}', Offset(4, ly + 2),
          const Color(0xFFE57373));
    }

    // Peak label, top-left.
    _label(canvas, formatSpeed(peak), const Offset(4, 2), labelStyle.color ?? Colors.white70);
  }

  void _label(Canvas canvas, String text, Offset at, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: labelStyle.copyWith(color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _SpeedChartPainter old) => true;
}
