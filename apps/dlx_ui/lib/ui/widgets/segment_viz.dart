import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../../models/download_vm.dart';
import '../../util/palette.dart';
import 'speed_bar_chart.dart';

const int _maxVisible = 30;

class SegmentViz extends StatefulWidget {
  final List<ChunkSnapshot> segments;
  final DownloadVm? vm;

  const SegmentViz({super.key, required this.segments, this.vm});

  @override
  State<SegmentViz> createState() => _SegmentVizState();
}

class _SegmentVizState extends State<SegmentViz>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = _buildItems(widget.segments);
    final vm = widget.vm;

    Widget segmentGrid = Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: items
          .map((item) => _SegmentCell(item: item, pulse: _pulse))
          .toList(),
    );

    if (vm == null) return segmentGrid;

    final ordered = [...vm.snapshots]..sort((a, b) => a.id.compareTo(b.id));
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
        segmentGrid,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Window logic
// ---------------------------------------------------------------------------

sealed class _Item {}

class _SegItem extends _Item {
  final ChunkSnapshot seg;
  final int index;
  _SegItem(this.seg, this.index);
}

class _TruncItem extends _Item {
  final int count;
  final _TruncKind kind;
  _TruncItem(this.count, this.kind);
}

enum _TruncKind { completed, pending }

List<_Item> _buildItems(List<ChunkSnapshot> segs) {
  if (segs.isEmpty) return [];

  final completed = <int>[];
  final active = <int>[];
  final pending = <int>[];

  for (var i = 0; i < segs.length; i++) {
    final s = segs[i].status;
    if (s == ChunkStatus.completed ||
        s == ChunkStatus.failed ||
        s == ChunkStatus.reassigned) {
      completed.add(i);
    } else if (s == ChunkStatus.downloading) {
      active.add(i);
    } else {
      pending.add(i);
    }
  }

  // Slot allocation: active gets priority, remainder to completed then pending.
  final activeShow = active.length.clamp(0, _maxVisible);
  final remaining = _maxVisible - activeShow;
  // Pending gets its exact need first so completed gets the larger half.
  final pendingShow = (remaining ~/ 2).clamp(0, pending.length);
  final completedShow = (remaining - pendingShow).clamp(0, completed.length);

  final items = <_Item>[];

  // --- completed ---
  final completedHidden = completed.length - completedShow;
  if (completedHidden > 0) {
    items.add(_TruncItem(completedHidden, _TruncKind.completed));
    final shown = completed.skip(completedHidden);
    for (final i in shown) { items.add(_SegItem(segs[i], i)); }
  } else {
    for (final i in completed) { items.add(_SegItem(segs[i], i)); }
  }

  // --- active ---
  final activeHidden = active.length - activeShow;
  if (activeHidden > 0) {
    // Show first half and last half, trunc in middle.
    final half = activeShow ~/ 2;
    for (final i in active.take(half)) { items.add(_SegItem(segs[i], i)); }
    items.add(_TruncItem(activeHidden, _TruncKind.pending));
    for (final i in active.skip(active.length - (activeShow - half))) {
      items.add(_SegItem(segs[i], i));
    }
  } else {
    for (final i in active) { items.add(_SegItem(segs[i], i)); }
  }

  // --- pending ---
  final pendingHidden = pending.length - pendingShow;
  if (pendingHidden > 0) {
    for (final i in pending.take(pendingShow)) { items.add(_SegItem(segs[i], i)); }
    items.add(_TruncItem(pendingHidden, _TruncKind.pending));
  } else {
    for (final i in pending) { items.add(_SegItem(segs[i], i)); }
  }

  return items;
}

// ---------------------------------------------------------------------------
// Cell
// ---------------------------------------------------------------------------

const double _cellSize = 56;

class _SegmentCell extends StatelessWidget {
  final _Item item;
  final Animation<double> pulse;

  const _SegmentCell({required this.item, required this.pulse});

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      _SegItem(:final seg, :final index) => _RealCell(
          seg: seg,
          index: index,
          pulse: pulse,
        ),
      _TruncItem(:final count, :final kind) => _TruncCell(
          count: count,
          kind: kind,
        ),
    };
  }
}

class _RealCell extends StatelessWidget {
  final ChunkSnapshot seg;
  final int index;
  final Animation<double> pulse;

  const _RealCell({
    required this.seg,
    required this.index,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context) {
    final status = seg.status;
    final isActive = status == ChunkStatus.downloading;
    final isCompleted =
        status == ChunkStatus.completed || status == ChunkStatus.reassigned;
    final isFailed = status == ChunkStatus.failed;
    final isStalled =
        isActive && seg.quality == ChunkQuality.stalled;

    final Color baseColor;
    if (isCompleted) {
      baseColor = AppColors.secondary;
    } else if (isFailed || isStalled) {
      baseColor = AppColors.error;
    } else if (isActive) {
      baseColor = AppColors.primary;
    } else {
      baseColor = AppColors.outlineVariant;
    }

    final fillFrac = (seg.length > 0)
        ? (seg.downloadedBytes / seg.length).clamp(0.0, 1.0)
        : (isCompleted ? 1.0 : 0.0);

    final String? bottomLabel;
    if (isCompleted) {
      bottomLabel = '100%';
    } else if (isActive && seg.length > 0) {
      bottomLabel = '${(fillFrac * 100).toStringAsFixed(0)}%';
    } else {
      bottomLabel = null;
    }

    Widget cell = Container(
      width: _cellSize,
      height: _cellSize,
      decoration: BoxDecoration(
        color: baseColor.withValues(alpha: isCompleted ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(AppRadius.def),
        border: Border.all(
          color: baseColor.withValues(alpha: isCompleted ? 0.5 : 0.3),
          style: (status == ChunkStatus.pending || status == ChunkStatus.paused)
              ? BorderStyle.solid
              : BorderStyle.solid,
        ),
      ),
      child: Stack(
        children: [
          // Fill bar (bottom portion fills up)
          if (fillFrac > 0 && !isCompleted)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: _cellSize * fillFrac,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: baseColor.withValues(alpha: 0.25),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(AppRadius.def),
                    bottomRight: Radius.circular(AppRadius.def),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(5),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '#${index + 1}',
                      style: AppTextStyles.labelSm.copyWith(
                        color: baseColor,
                        fontSize: 9,
                        letterSpacing: 0.4,
                      ),
                    ),
                    if (isActive)
                      AnimatedBuilder(
                        animation: pulse,
                        builder: (context, child) => Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: baseColor.withValues(
                                alpha: 0.4 + 0.6 * pulse.value),
                          ),
                        ),
                      ),
                    if (seg.retries > 0)
                      Text(
                        'R${seg.retries}',
                        style: AppTextStyles.labelSm.copyWith(
                          color: AppColors.tertiary,
                          fontSize: 8,
                        ),
                      ),
                  ],
                ),
                if (bottomLabel != null)
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Text(
                      bottomLabel,
                      style: AppTextStyles.dataDisplay.copyWith(
                        color: baseColor,
                        fontSize: 10,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    if (isActive) {
      cell = AnimatedBuilder(
        animation: pulse,
        builder: (_, child) => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.def),
            boxShadow: [
              BoxShadow(
                color: baseColor.withValues(alpha: 0.15 + 0.2 * pulse.value),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
          child: child,
        ),
        child: cell,
      );
    }

    return cell;
  }
}

class _TruncCell extends StatelessWidget {
  final int count;
  final _TruncKind kind;

  const _TruncCell({required this.count, required this.kind});

  @override
  Widget build(BuildContext context) {
    final color = kind == _TruncKind.completed
        ? AppColors.secondary
        : AppColors.outlineVariant;

    return Container(
      width: _cellSize,
      height: _cellSize,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.def),
        border: Border.all(
          color: color.withValues(alpha: 0.25),
        ),
      ),
      child: Center(
        child: Text(
          '+$count',
          style: AppTextStyles.dataDisplay.copyWith(
            color: color,
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}
