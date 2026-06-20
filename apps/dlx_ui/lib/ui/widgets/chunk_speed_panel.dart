import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../../models/download_vm.dart';
import '../../util/format.dart';
import '../../util/palette.dart';

/// Per-chunk speed breakdown — bar chart (one bar per time frame, stacked by
/// chunk) + a live chunk row list below it showing id, progress, speed.
class ChunkSpeedPanel extends StatelessWidget {
  final DownloadVm vm;

  const ChunkSpeedPanel({super.key, required this.vm});

  @override
  Widget build(BuildContext context) {
    final ordered = [...vm.snapshots]..sort((a, b) => a.offset.compareTo(b.offset));
    final seriesOrder = ordered.map((c) => c.id).toList();
    final colorIndex = {for (var i = 0; i < seriesOrder.length; i++) seriesOrder[i]: i};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Speed Tracker',
                style: AppTextStyles.headlineMd.copyWith(color: AppColors.onSurface)),
            Text('Last 60s',
                style: AppTextStyles.dataDisplay
                    .copyWith(color: AppColors.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _SpeedBarChart(
          frames: vm.chunkSpeedHistory.frames,
          seriesOrder: seriesOrder,
          colorOf: (id) => colorForIndex(colorIndex[id] ?? 0),
        ),
        const SizedBox(height: AppSpacing.md),
        ..._chunkRows(ordered),
      ],
    );
  }

  List<Widget> _chunkRows(List<ChunkSnapshot> chunks) {
    return chunks.map((c) {
      final frac = c.length > 0
          ? (c.downloadedBytes / c.length).clamp(0.0, 1.0)
          : 0.0;
      final color = colorForQuality(c.quality,
          completed: c.status == ChunkStatus.completed);
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            SizedBox(
              width: 80,
              child: Text(
                c.id.split('-').last,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.labelSm
                    .copyWith(color: AppColors.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.full),
                child: LinearProgressIndicator(
                  value: frac,
                  minHeight: 6,
                  backgroundColor: AppColors.surfaceDim,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            SizedBox(
              width: 72,
              child: Text(
                c.status == ChunkStatus.completed
                    ? 'done'
                    : c.status.name +
                        (c.retries > 0 ? ' ·r${c.retries}' : ''),
                textAlign: TextAlign.right,
                style: AppTextStyles.labelSm
                    .copyWith(color: AppColors.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    }).toList();
  }
}

// ---------------------------------------------------------------------------
// Bar chart — time on X, stacked chunk speeds on Y
// ---------------------------------------------------------------------------

class _SpeedBarChart extends StatelessWidget {
  final List<Map<String, double>> frames;
  final List<String> seriesOrder;
  final Color Function(String id) colorOf;

  const _SpeedBarChart({
    required this.frames,
    required this.seriesOrder,
    required this.colorOf,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120,
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
                seriesOrder: seriesOrder,
                colorOf: colorOf,
              ),
              size: const Size(double.infinity, 120),
            ),
    );
  }
}

class _BarChartPainter extends CustomPainter {
  final List<Map<String, double>> frames;
  final List<String> seriesOrder;
  final Color Function(String id) colorOf;

  _BarChartPainter({
    required this.frames,
    required this.seriesOrder,
    required this.colorOf,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (frames.isEmpty) return;

    // Find max total speed across all frames for Y scaling
    double maxSpeed = 0;
    for (final f in frames) {
      final total = f.values.fold(0.0, (a, b) => a + b);
      if (total > maxSpeed) maxSpeed = total;
    }
    if (maxSpeed <= 0) return;

    // Grid lines (4 horizontal)
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
        final rect = Rect.fromLTWH(
            x + gap / 2, yOffset - barH, barW - gap, barH);
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
      old.frames != frames;
}

// ignore: unused_element
String _fmtSpeed(double bps) => formatSpeed(bps);
