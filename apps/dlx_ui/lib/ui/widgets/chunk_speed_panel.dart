import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../../models/download_vm.dart';
import '../../util/palette.dart';
import 'speed_bar_chart.dart';

const int _completedLingerMs = 2000;

/// Per-chunk speed breakdown — bar chart (one bar per time frame, stacked by
/// chunk) + a live chunk row list below it showing id, progress, speed.
class ChunkSpeedPanel extends StatelessWidget {
  final DownloadVm vm;

  const ChunkSpeedPanel({super.key, required this.vm});

  @override
  Widget build(BuildContext context) {
    // For the chart: all chunks ordered by offset (or index for HLS).
    final ordered = [...vm.snapshots]..sort((a, b) {
        if (a.isSegment == true) {
          return a.id.compareTo(b.id);
        }
        return a.offset.compareTo(b.offset);
      });
    final seriesOrder = ordered.map((c) => c.id).toList();
    final colorIndex = {for (var i = 0; i < seriesOrder.length; i++) seriesOrder[i]: i};

    // For the rows: exclude pending, hide completed after linger window.
    final now = DateTime.now().millisecondsSinceEpoch;
    final visibleRows = ordered.where((c) {
      if (c.status == ChunkStatus.pending) {
        return false;
      }
      if (c.status == ChunkStatus.completed ||
          c.status == ChunkStatus.failed ||
          c.status == ChunkStatus.reassigned) {
        final t = vm.chunkCompletedAt[c.id];
        if (t == null) return false;
        return now - t < _completedLingerMs;
      }
      return true;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Speed Tracker',
                style: AppTextStyles.headlineMd.copyWith(color: AppColors.onSurface)),
            Text('Last ${(vm.chunkSpeedHistory.capacity * 0.4 / 60).toStringAsFixed(0)}m',
                style: AppTextStyles.dataDisplay
                    .copyWith(color: AppColors.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        SpeedBarChart(
          frames: vm.chunkSpeedHistory.frames,
          frameCount: vm.chunkSpeedHistory.frames.length,
          seriesOrder: seriesOrder,
          colorOf: (id) => colorForIndex(colorIndex[id] ?? 0),
        ),
        if (visibleRows.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          ..._chunkRows(visibleRows),
        ],
      ],
    );
  }

  List<Widget> _chunkRows(List<ChunkSnapshot> chunks) {
    return chunks.map((c) {
      final frac = c.length > 0
          ? (c.downloadedBytes / c.length).clamp(0.0, 1.0)
          : 0.0;
      final isDone = c.status == ChunkStatus.completed;
      final color = colorForQuality(c.quality, completed: isDone);
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
              width: 32,
              child: Text(
                c.id.split('-').last,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
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
              width: 90,
              child: Text(
                isDone
                    ? 'done'
                    : c.status.name + (c.retries > 0 ? ' ·r${c.retries}' : ''),
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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



