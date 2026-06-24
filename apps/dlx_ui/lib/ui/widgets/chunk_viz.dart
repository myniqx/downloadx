import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../../models/download_vm.dart';
import '../../util/palette.dart';
import 'speed_bar_chart.dart';

/// Segmented horizontal bar — each chunk is a proportional region,
/// tinted by status: completed (emerald), active/pulsing (blue),
/// stalled (red), queued (dim).
class ChunkViz extends StatelessWidget {
  final int? totalBytes;
  final List<ChunkSnapshot> chunks;
  final double height;
  final DownloadVm? vm;

  const ChunkViz({
    super.key,
    required this.totalBytes,
    required this.chunks,
    this.height = 48,
    this.vm,
  });

  @override
  Widget build(BuildContext context) {
    final vm = this.vm;
    List<String> seriesOrder = const [];
    Map<String, int> colorIndex = const {};
    if (vm != null) {
      final ordered = [...vm.snapshots]..sort((a, b) => a.offset.compareTo(b.offset));
      seriesOrder = ordered.map((c) => c.id).toList();
      colorIndex = {for (var i = 0; i < seriesOrder.length; i++) seriesOrder[i]: i};
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (vm != null) ...[
          SpeedBarChart(
            frames: vm.chunkSpeedHistory.frames,
            frameCount: vm.chunkSpeedHistory.frames.length,
            seriesOrder: seriesOrder,
            colorOf: (id) => colorForIndex(colorIndex[id] ?? 0),
            height: 80,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        SizedBox(
          height: height,
          width: double.infinity,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: CustomPaint(
              painter: _ChunkVizPainter(
                totalBytes: totalBytes,
                chunks: chunks,
                trackColor: AppColors.surfaceContainerLowest,
                borderColor: AppColors.outlineVariant,
              ),
            ),
          ),
        ),
        if (chunks.any((c) => c.status == ChunkStatus.downloading || c.status == ChunkStatus.paused)) ...[
          const SizedBox(height: AppSpacing.md),
          _ActiveChunkList(chunks: chunks, totalBytes: totalBytes),
        ],
      ],
    );
  }
}

class _ChunkVizPainter extends CustomPainter {
  final int? totalBytes;
  final List<ChunkSnapshot> chunks;
  final Color trackColor;
  final Color borderColor;

  _ChunkVizPainter({
    required this.totalBytes,
    required this.chunks,
    required this.trackColor,
    required this.borderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()..color = trackColor,
    );

    final total = totalBytes;
    if (total == null || total <= 0) {
      _hatch(canvas, size);
      return;
    }

    final sorted = [...chunks]..sort((a, b) => a.offset.compareTo(b.offset));

    for (final c in sorted) {
      final xs = (c.offset / total) * w;
      final cw = (c.length / total) * w;
      if (cw <= 0) continue;

      final completed = c.status == ChunkStatus.completed;
      final active = c.status == ChunkStatus.downloading;
      final stalled = c.quality == ChunkQuality.stalled && active;
      final fillFrac = c.length > 0
          ? (c.downloadedBytes / c.length).clamp(0.0, 1.0)
          : 0.0;

      final baseColor = completed
          ? AppColors.secondary
          : stalled
              ? AppColors.error
              : active
                  ? AppColors.primary
                  : AppColors.surfaceContainerHigh;

      // Background (pending portion)
      canvas.drawRect(
        Rect.fromLTWH(xs, 0, cw, h),
        Paint()..color = baseColor.withValues(alpha: completed ? 1.0 : 0.15),
      );

      // Filled (downloaded) portion
      if (fillFrac > 0) {
        canvas.drawRect(
          Rect.fromLTWH(xs, 0, cw * fillFrac, h),
          Paint()..color = baseColor.withValues(alpha: completed ? 1.0 : 0.55),
        );
      }

      // Chunk boundary line
      if (xs > 0) {
        canvas.drawLine(
          Offset(xs, 0),
          Offset(xs, h),
          Paint()
            ..color = AppColors.background.withValues(alpha: 0.4)
            ..strokeWidth = 1.5,
        );
      }
    }

    // Border
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  void _hatch(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.25)
      ..strokeWidth = 6;
    for (var x = -size.height; x < size.width; x += 16) {
      canvas.drawLine(
          Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ChunkVizPainter old) =>
      old.chunks != chunks || old.totalBytes != totalBytes;
}

class _ActiveChunkList extends StatelessWidget {
  final List<ChunkSnapshot> chunks;
  final int? totalBytes;

  const _ActiveChunkList({required this.chunks, required this.totalBytes});

  @override
  Widget build(BuildContext context) {
    final active = chunks
        .where((c) => c.status == ChunkStatus.downloading || c.status == ChunkStatus.paused)
        .toList();

    return Column(
      children: [
        // Two-column grid of active chunks, matching HTML metadata labels
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: AppSpacing.sm,
            mainAxisSpacing: AppSpacing.sm,
            childAspectRatio: 3.0,
          ),
          itemCount: active.length > 4 ? 4 : active.length,
          itemBuilder: (context, i) {
            final c = active[i];
            final downloaded = c.downloadedBytes;
            final total = c.length;
            return Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(AppRadius.def),
                border: Border.all(
                    color: AppColors.outlineVariant.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        c.id.split('-').last.toUpperCase(),
                        style: AppTextStyles.labelSm.copyWith(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 10,
                            letterSpacing: 0.8),
                      ),
                      Text(
                        '${_fmt(downloaded)} / ${_fmt(total)}',
                        style: AppTextStyles.dataDisplay
                            .copyWith(color: AppColors.primary),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Offset',
                          style: AppTextStyles.labelSm.copyWith(
                              color: AppColors.onSurfaceVariant, fontSize: 10)),
                      Text(
                        _fmt(c.offset),
                        style: AppTextStyles.dataDisplay
                            .copyWith(color: AppColors.onSurface),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  static String _fmt(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
