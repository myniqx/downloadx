import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../../models/download_vm.dart';
import '../../util/palette.dart';
import 'speed_bar_chart.dart';

/// Segmented horizontal bar — each chunk is a proportional region,
/// tinted by status: completed (emerald), active/pulsing (blue),
/// stalled (red), queued (dim).
class ChunkViz extends StatelessWidget {
  final DownloadVm vm;
  final double height;

  const ChunkViz({
    super.key,
    required this.vm,
    this.height = 48,
  });

  @override
  Widget build(BuildContext context) {
    final chunks = vm.snapshots;
    final totalBytes = vm.desc.totalBytes;

    final ordered = [...chunks]..sort((a, b) => a.offset.compareTo(b.offset));
    final seriesOrder = ordered.map((c) => c.id).toList();
    final colorIndex = {for (var i = 0; i < seriesOrder.length; i++) seriesOrder[i]: i};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SpeedBarChart(
          frames: vm.chunkSpeedHistory.frames,
          frameCount: vm.chunkSpeedHistory.frames.length,
          seriesOrder: seriesOrder,
          colorOf: (id) => colorForIndex(colorIndex[id] ?? 0),
          height: 80,
        ),
        const SizedBox(height: AppSpacing.md),
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
          _ActiveChunkList(chunks: chunks, vm: vm),
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
  final DownloadVm vm;

  const _ActiveChunkList({required this.chunks, required this.vm});

  @override
  Widget build(BuildContext context) {
    final active = chunks
        .where((c) => c.status == ChunkStatus.downloading || c.status == ChunkStatus.paused)
        .toList();

    final headerStyle = AppTextStyles.labelSm.copyWith(
      color: AppColors.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    final cellStyle = AppTextStyles.labelSm.copyWith(color: AppColors.onSurface);

    final lastFrame = vm.chunkSpeedHistory.frames.isNotEmpty
        ? vm.chunkSpeedHistory.frames.last
        : const <String, double>{};

    final headerRow = TableRow(
      decoration: BoxDecoration(color: AppColors.surfaceContainerLow),
      children: [
        _cell(Text('#', style: headerStyle), isHeader: true),
        _cell(Text('Offset', style: headerStyle), isHeader: true),
        _cell(Text('Size', style: headerStyle), isHeader: true),
        _cell(Text('Downloaded', style: headerStyle), isHeader: true),
        _cell(Text('Speed', style: headerStyle), isHeader: true),
        _cell(Text('Status', style: headerStyle), isHeader: true),
      ],
    );

    return Table(
      columnWidths: const {
        0: FlexColumnWidth(1),
        1: FlexColumnWidth(2),
        2: FlexColumnWidth(2),
        3: FlexColumnWidth(2),
        4: FlexColumnWidth(2),
        5: FlexColumnWidth(2),
      },
      border: TableBorder(
        horizontalInside: BorderSide(
            color: AppColors.outlineVariant.withValues(alpha: 0.3), width: 0.5),
        bottom: BorderSide(
            color: AppColors.outlineVariant.withValues(alpha: 0.3), width: 0.5),
      ),
      children: [
        headerRow,
        ...active.map((c) {
          final color = colorForQuality(c.quality,
              completed: c.status == ChunkStatus.completed);
          final speed = lastFrame[c.id] ?? 0;
          return TableRow(children: [
            _cell(Text(c.id.split('-').last.toUpperCase(),
                style: cellStyle.copyWith(color: color))),
            _cell(Text(_fmt(c.offset), style: cellStyle)),
            _cell(Text(_fmt(c.length), style: cellStyle)),
            _cell(Text(_fmt(c.downloadedBytes),
                style: cellStyle.copyWith(color: AppColors.primary))),
            _cell(Text(speed > 0 ? '${_fmt(speed.toInt())}/s' : '—',
                style: cellStyle.copyWith(
                    color: speed > 0 ? AppColors.onSurface : AppColors.onSurfaceVariant))),
            _cell(Text(
              c.status.name + (c.retries > 0 ? ' ·r${c.retries}' : ''),
              style: cellStyle.copyWith(color: color),
            )),
          ]);
        }),
      ],
    );
  }

  static Widget _cell(Widget child, {bool isHeader = false}) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: isHeader ? AppSpacing.xs : AppSpacing.xs,
      ),
      child: child,
    );
  }

  static String _fmt(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
