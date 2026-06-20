import 'package:flutter/material.dart';

import '../../util/palette.dart';

/// Stacked area chart that scrolls left as new frames arrive.
///
/// Each series (download) fills its own band stacked on top of the previous
/// one. Y-axis scales to the peak stacked total visible in [frames] × 1.2.
/// If [limits] is provided and a frame's limit fits within the Y range, a red
/// dashed horizontal line is drawn at that position.
class StackedSpeedChart extends StatefulWidget {
  final List<Map<String, double>> frames;
  final List<double?> limits;
  final List<String> seriesOrder;
  final Color Function(String id) colorOf;
  final double? height;

  const StackedSpeedChart({
    super.key,
    required this.frames,
    required this.seriesOrder,
    required this.colorOf,
    this.limits = const [],
    this.height = 96,
  });

  @override
  State<StackedSpeedChart> createState() => _StackedSpeedChartState();
}

class _StackedSpeedChartState extends State<StackedSpeedChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  /// Fraction of one column already scrolled off to the left (0→1).
  double _scrollOffset = 0;

  /// How many frames we had last tick — detects new frame arrival.
  int _lastFrameCount = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _ctrl.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(StackedSpeedChart old) {
    super.didUpdateWidget(old);
    final count = widget.frames.length;
    if (count > _lastFrameCount && _lastFrameCount > 0) {
      // New frame arrived — animate scroll from 0 to 1 column width.
      _scrollOffset = 1.0;
      _ctrl.forward(from: 0).then((_) => setState(() => _scrollOffset = 0));
    }
    _lastFrameCount = count;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: CustomPaint(
        painter: _ChartPainter(
          frames: widget.frames,
          limits: widget.limits,
          seriesOrder: widget.seriesOrder,
          colorOf: widget.colorOf,
          // Ease-out: starts fast, slows at the end.
          scrollFrac: _scrollOffset * (1 - _ctrl.value),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

class _ChartPainter extends CustomPainter {
  final List<Map<String, double>> frames;
  final List<double?> limits;
  final List<String> seriesOrder;
  final Color Function(String id) colorOf;

  /// Fraction of one column-width to shift the whole chart leftward.
  /// Goes from 1→0 during the scroll animation.
  final double scrollFrac;

  _ChartPainter({
    required this.frames,
    required this.limits,
    required this.seriesOrder,
    required this.colorOf,
    required this.scrollFrac,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (frames.isEmpty) return;

    // --- Y scale: peak stacked total in visible frames × 1.2 ---------------
    var peak = 0.0;
    for (final f in frames) {
      var sum = 0.0;
      for (final v in f.values) {
        sum += v;
      }
      if (sum > peak) peak = sum;
    }
    final yMax = peak > 0 ? peak * 1.2 : 1.0;

    // --- Column geometry ----------------------------------------------------
    final n = frames.length;
    // One extra virtual column so the newest frame slides in from the right.
    final colW = size.width / (n + 1);
    // Shift everything left by scrollFrac columns.
    final shiftX = -scrollFrac * colW;

    // --- Draw each series as a stacked filled path -------------------------
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    // Compute per-column stacked base offsets.
    // bases[col] = Y-pixel at the top of the area drawn so far for that col.
    final bases = List<double>.filled(n, size.height);

    for (final id in seriesOrder) {
      final path = Path();
      final fillPaint = Paint()..style = PaintingStyle.fill;

      // Build top-edge points for this series.
      final topPts = <Offset>[];
      final botPts = <Offset>[];

      for (var i = 0; i < n; i++) {
        final x = shiftX + i * colW + colW / 2;
        final v = frames[i][id] ?? 0.0;
        final h = (v / yMax) * size.height;
        final top = bases[i] - h;
        topPts.add(Offset(x, top.clamp(0.0, size.height)));
        botPts.add(Offset(x, bases[i]));
        bases[i] = top.clamp(0.0, size.height);
      }

      if (topPts.isEmpty) continue;

      // Build smooth path: top curve (catmull-rom-ish via cubics), then
      // bottom curve in reverse, close.
      path.moveTo(botPts.first.dx, botPts.first.dy);
      _addSmoothLine(path, botPts);
      path.lineTo(topPts.last.dx, topPts.last.dy);
      _addSmoothLineReversed(path, topPts);
      path.close();

      final color = colorOf(id);
      fillPaint.shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withValues(alpha: 0.7), color.withValues(alpha: 0.35)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

      canvas.drawPath(path, fillPaint);

      // Top edge stroke
      final strokePath = Path()..moveTo(topPts.first.dx, topPts.first.dy);
      _addSmoothLine(strokePath, topPts);
      canvas.drawPath(
        strokePath,
        Paint()
          ..color = color.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    canvas.restore();

    // --- Speed limit line --------------------------------------------------
    _drawLimitLine(canvas, size, yMax, colW, shiftX);
  }

  void _drawLimitLine(
      Canvas canvas, Size size, double yMax, double colW, double shiftX) {
    if (limits.isEmpty || frames.isEmpty) return;

    // Draw a dashed red line segment for each frame that has a limit.
    // We group consecutive frames with the same limit into one segment.
    final paint = Paint()
      ..color = AppColors.error.withValues(alpha: 0.8)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    double? segLimit;
    double segStartX = 0;

    void flushSegment(double endX) {
      if (segLimit == null) return;
      final y = size.height - (segLimit / yMax) * size.height;
      if (y < 0 || y > size.height) return;
      _drawDashedLine(canvas, Offset(segStartX, y), Offset(endX, y), paint);
    }

    for (var i = 0; i < frames.length; i++) {
      final x = shiftX + i * colW + colW / 2;
      final lim = i < limits.length ? limits[i] : null;

      if (lim != segLimit) {
        flushSegment(x);
        segLimit = lim;
        segStartX = x;
      }
    }
    // Flush last segment to right edge.
    final lastX = shiftX + (frames.length - 1) * colW + colW / 2;
    flushSegment(lastX);
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    const dashLen = 6.0;
    const gapLen = 4.0;
    final total = (p2 - p1).distance;
    var drawn = 0.0;
    final dir = (p2 - p1) / total;
    while (drawn < total) {
      final end = (drawn + dashLen).clamp(0.0, total);
      canvas.drawLine(p1 + dir * drawn, p1 + dir * end, paint);
      drawn += dashLen + gapLen;
    }
  }

  /// Adds a smooth cubic bezier through [pts] to [path].
  void _addSmoothLine(Path path, List<Offset> pts) {
    for (var i = 1; i < pts.length; i++) {
      final p0 = pts[i - 1];
      final p1 = pts[i];
      final cx = (p0.dx + p1.dx) / 2;
      path.cubicTo(cx, p0.dy, cx, p1.dy, p1.dx, p1.dy);
    }
  }

  void _addSmoothLineReversed(Path path, List<Offset> pts) {
    for (var i = pts.length - 2; i >= 0; i--) {
      final p0 = pts[i + 1];
      final p1 = pts[i];
      final cx = (p0.dx + p1.dx) / 2;
      path.cubicTo(cx, p0.dy, cx, p1.dy, p1.dx, p1.dy);
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.frames != frames ||
      old.scrollFrac != scrollFrac ||
      old.seriesOrder != seriesOrder;
}
