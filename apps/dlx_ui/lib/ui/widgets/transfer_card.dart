import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../../models/download_vm.dart';
import '../../util/format.dart';
import '../../util/palette.dart';

class TransferCard extends StatelessWidget {
  final DownloadVm vm;
  final VoidCallback onPause;
  final VoidCallback onStart;
  final VoidCallback onRemove;
  final VoidCallback onTap;

  const TransferCard({
    super.key,
    required this.vm,
    required this.onPause,
    required this.onStart,
    required this.onRemove,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) => _MobileCard(
        vm: vm,
        d: vm.desc,
        snapshots: vm.snapshots,
        onPause: onPause,
        onStart: onStart,
        onRemove: onRemove,
        onTap: onTap,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared sub-widgets
// ---------------------------------------------------------------------------

class _CardShell extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  const _CardShell({required this.child, required this.onTap});

  @override
  State<_CardShell> createState() => _CardShellState();
}

class _CardShellState extends State<_CardShell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: _hovered
                ? AppColors.surfaceContainerHigh.withValues(alpha: 0.8)
                : AppColors.surfaceContainer.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
              color: _hovered ? AppColors.outline : AppColors.outlineVariant,
            ),
          ),
          padding: const EdgeInsets.all(AppSpacing.md),
          child: _HoverState(
            hovered: _hovered,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _HoverState extends InheritedWidget {
  final bool hovered;
  const _HoverState({required this.hovered, required super.child});

  @override
  bool updateShouldNotify(_HoverState old) => old.hovered != hovered;
}


class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.outlineVariant),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
        ),
      ),
    );
  }
}

class _RemoveButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _RemoveButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Remove',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          hoverColor: AppColors.errorContainer.withValues(alpha: 0.2),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.outlineVariant),
            ),
            child: const Icon(Icons.close_rounded, size: 18, color: AppColors.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}


class _FlatProgressBar extends StatelessWidget {
  final double? value;
  final Color color;
  const _FlatProgressBar({this.value, this.color = AppColors.outline});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: LinearProgressIndicator(
        value: value,
        minHeight: 8,
        backgroundColor: AppColors.surfaceDim,
        color: color,
      ),
    );
  }
}

class _SpinningIcon extends StatefulWidget {
  @override
  State<_SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<_SpinningIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 3))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _ctrl,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: AppColors.outlineVariant,
            style: BorderStyle.solid,
            width: 1.5,
          ),
        ),
        child: const Icon(Icons.sync_rounded, size: 20, color: AppColors.onSurfaceVariant),
      ),
    );
  }
}


// ---------------------------------------------------------------------------
// Mobile card
// ---------------------------------------------------------------------------

class _MobileCard extends StatelessWidget {
  final DownloadVm vm;
  final DownloadDescription d;
  final List<ChunkSnapshot> snapshots;
  final VoidCallback onPause;
  final VoidCallback onStart;
  final VoidCallback onRemove;
  final VoidCallback onTap;

  const _MobileCard({
    required this.vm,
    required this.d,
    required this.snapshots,
    required this.onPause,
    required this.onStart,
    required this.onRemove,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final state = vm.state;
    final running = state == DownloadState.downloading || state == DownloadState.probing;
    final paused = state == DownloadState.paused || state == DownloadState.idle;
    final completed = state == DownloadState.completed;
    final error = state == DownloadState.error;

    return _CardShell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top row: icon + name + actions
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colorForState(state).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(iconForState(state), size: 20, color: colorForState(state)),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      d.filename ?? d.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyMd.copyWith(
                        color: AppColors.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    _StateChip(state: state, isHls: vm.isHls),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              // Action buttons always visible on mobile
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!completed)
                    _ActionButton(
                      icon: running
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      tooltip: running ? 'Pause' : 'Resume',
                      color: AppColors.onSurfaceVariant,
                      onPressed: running ? onPause : onStart,
                    ),
                  const SizedBox(width: AppSpacing.xs),
                  _RemoveButton(onPressed: onRemove),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // Percent + speed + eta row
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                error
                    ? 'Error'
                    : paused
                        ? 'Paused'
                        : completed
                            ? '100%'
                            : vm.isHls
                                ? '${vm.hlsSegmentsDone ?? 0} / ${vm.hlsTotalSegments ?? '?'}'
                                : formatPercent(d.percent),
                style: AppTextStyles.headlineMd.copyWith(
                  color: error
                      ? AppColors.error
                      : paused
                          ? AppColors.onSurfaceVariant
                          : AppColors.primary,
                ),
              ),
              const Spacer(),
              if (running) ...[
                Text(
                  formatSpeed(d.totalSpeedBps.toDouble()),
                  style: AppTextStyles.dataDisplay
                      .copyWith(color: AppColors.onSurfaceVariant),
                ),
                const SizedBox(width: AppSpacing.md),
                Text(
                  d.etaMs == null ? '--' : formatDuration(d.etaMs!),
                  style: AppTextStyles.dataDisplay
                      .copyWith(color: AppColors.onSurface),
                ),
              ] else if (d.totalBytes != null) ...[
                Text(
                  formatBytes(d.totalBytes!),
                  style: AppTextStyles.dataDisplay
                      .copyWith(color: AppColors.onSurfaceVariant),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          // Segment track
          if (snapshots.isNotEmpty && d.totalBytes != null)
            _SegmentTrack(
              chunks: snapshots,
              totalBytes: d.totalBytes!,
              state: state,
            )
          else
            _FlatProgressBar(
              value: d.percent == null ? null : d.percent! / 100,
              color: colorForState(state),
            ),
          if (error && d.errorMessage != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              d.errorMessage!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.labelSm.copyWith(color: AppColors.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  final DownloadState state;
  final bool isHls;
  const _StateChip({required this.state, this.isHls = false});

  @override
  Widget build(BuildContext context) {
    final label = switch (state) {
      DownloadState.downloading => isHls ? 'HLS' : 'Direct Link',
      DownloadState.paused     => 'Paused',
      DownloadState.probing    => 'Probing',
      DownloadState.completed  => 'Done',
      DownloadState.error      => 'Error',
      _                        => state.name,
    };
    final color = colorForState(state);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        label.toUpperCase(),
        style: AppTextStyles.labelSm.copyWith(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Segment track — chunk-aware progress bar for mobile
// ---------------------------------------------------------------------------

class _SegmentTrack extends StatelessWidget {
  final List<ChunkSnapshot> chunks;
  final int totalBytes;
  final DownloadState state;

  const _SegmentTrack({
    required this.chunks,
    required this.totalBytes,
    required this.state,
  });

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

      // Pending background
      canvas.drawRect(
        Rect.fromLTWH(offsetX, 0, chunkW, size.height),
        Paint()..color = pendingColor,
      );

      // Filled portion
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
