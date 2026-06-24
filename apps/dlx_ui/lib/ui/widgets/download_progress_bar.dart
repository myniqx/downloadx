import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../../models/download_vm.dart';
import '../../util/palette.dart';

class DownloadProgressBar extends StatelessWidget {
  final DownloadVm vm;

  const DownloadProgressBar({super.key, required this.vm});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) => _buildBar(),
    );
  }

  Widget _buildBar() {
    final state = vm.state;
    final snapshots = vm.snapshots;
    final totalBytes = vm.desc.totalBytes;
    final running = state == DownloadState.downloading ||
        state == DownloadState.probing;
    final completed = state == DownloadState.completed;

    final double? value;
    if (completed) {
      value = 1.0;
    } else if (running) {
      value = vm.progressFraction;
    } else {
      value = vm.progressFraction ?? 0.0;
    }

    if (snapshots.isNotEmpty && totalBytes != null && totalBytes > 0) {
      return _SegmentBar(chunks: snapshots, totalBytes: totalBytes);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: LinearProgressIndicator(
        value: value,
        minHeight: 8,
        backgroundColor: AppColors.surfaceDim,
        color: colorForState(state),
      ),
    );
  }
}

class _SegmentBar extends StatelessWidget {
  final List<ChunkSnapshot> chunks;
  final int totalBytes;

  const _SegmentBar({required this.chunks, required this.totalBytes});

  @override
  Widget build(BuildContext context) {
    final sorted = [...chunks]..sort((a, b) => a.offset.compareTo(b.offset));
    return SizedBox(
      height: 8,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.full),
        child: CustomPaint(
          painter: _SegmentPainter(
            chunks: sorted,
            totalBytes: totalBytes,
            activeColor: AppColors.primary,
            completedColor: AppColors.primary,
            pendingColor: AppColors.primary.withValues(alpha: 0.2),
            stalledColor: AppColors.error,
            trackColor: AppColors.surfaceDim,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _SegmentPainter extends CustomPainter {
  final List<ChunkSnapshot> chunks;
  final int totalBytes;
  final Color activeColor;
  final Color completedColor;
  final Color pendingColor;
  final Color stalledColor;
  final Color trackColor;

  const _SegmentPainter({
    required this.chunks,
    required this.totalBytes,
    required this.activeColor,
    required this.completedColor,
    required this.pendingColor,
    required this.stalledColor,
    required this.trackColor,
  });

  static const _gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = trackColor);
    if (totalBytes <= 0) return;

    final n = chunks.length;
    final totalGap = n > 1 ? (n - 1) * _gap : 0.0;
    final usable = size.width - totalGap;

    for (var i = 0; i < n; i++) {
      final c = chunks[i];
      final chunkW = (c.length / totalBytes) * usable;
      if (chunkW <= 0) continue;

      final offsetX = (c.offset / totalBytes) * usable + i * _gap;
      final completed = c.status == ChunkStatus.completed;
      final stalled = c.quality == ChunkQuality.stalled;
      final active = c.status == ChunkStatus.downloading;

      final fillFrac = c.length > 0
          ? (c.downloadedBytes / c.length).clamp(0.0, 1.0)
          : 0.0;

      canvas.drawRect(
        Rect.fromLTWH(offsetX, 0, chunkW, size.height),
        Paint()..color = pendingColor,
      );

      if (fillFrac > 0) {
        final fillColor = completed
            ? completedColor
            : stalled
                ? stalledColor
                : activeColor.withValues(alpha: active ? 0.85 : 0.5);
        canvas.drawRect(
          Rect.fromLTWH(offsetX, 0, chunkW * fillFrac, size.height),
          Paint()..color = fillColor,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SegmentPainter old) =>
      old.chunks != chunks || old.totalBytes != totalBytes;
}
