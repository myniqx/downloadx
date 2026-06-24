import 'package:flutter/material.dart';

import '../../util/palette.dart';

class SpeedBarChart extends StatelessWidget {
  final List<Map<String, double>> frames;
  final int frameCount;
  final List<String> seriesOrder;
  final Color Function(String id) colorOf;
  final double height;

  const SpeedBarChart({
    super.key,
    required this.frames,
    required this.frameCount,
    required this.seriesOrder,
    required this.colorOf,
    this.height = 120,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.outlineVariant.withValues(alpha: 0.4)),
          left: BorderSide(color: AppColors.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: frames.isEmpty
          ? Center(
              child: Text('No data yet',
                  style: AppTextStyles.labelSm
                      .copyWith(color: AppColors.onSurfaceVariant)),
            )
          : CustomPaint(
              painter: _BarChartPainter(
                frames: frames,
                frameCount: frameCount,
                seriesOrder: seriesOrder,
                colorOf: colorOf,
              ),
              size: Size(double.infinity, height),
            ),
    );
  }
}

class _BarChartPainter extends CustomPainter {
  final List<Map<String, double>> frames;
  final int frameCount;
  final List<String> seriesOrder;
  final Color Function(String id) colorOf;

  _BarChartPainter({
    required this.frames,
    required this.frameCount,
    required this.seriesOrder,
    required this.colorOf,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (frames.isEmpty) return;

    double maxSpeed = 0;
    for (final f in frames) {
      final total = f.values.fold(0.0, (a, b) => a + b);
      if (total > maxSpeed) maxSpeed = total;
    }
    if (maxSpeed <= 0) return;

    final gridPaint = Paint()
      ..color = AppColors.outlineVariant.withValues(alpha: 0.15)
      ..strokeWidth = 1;
    for (var i = 1; i <= 4; i++) {
      final y = size.height * (1 - i / 4);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final barCount = frames.length;
    final barW = (size.width / barCount).clamp(2.0, 16.0);
    final gap = barW * 0.15;

    for (var fi = 0; fi < frames.length; fi++) {
      final frame = frames[fi];
      final x = fi * (size.width / barCount);
      double yOffset = size.height;

      for (final id in seriesOrder) {
        final speed = frame[id] ?? 0;
        if (speed <= 0) continue;
        final barH = (speed / maxSpeed) * size.height;
        final rect = Rect.fromLTWH(x + gap / 2, yOffset - barH, barW - gap, barH);
        canvas.drawRRect(
          RRect.fromRectAndCorners(rect,
              topLeft: const Radius.circular(2),
              topRight: const Radius.circular(2)),
          Paint()..color = colorOf(id).withValues(alpha: 0.7),
        );
        yOffset -= barH;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarChartPainter old) =>
      old.frameCount != frameCount || old.seriesOrder != seriesOrder;
}
