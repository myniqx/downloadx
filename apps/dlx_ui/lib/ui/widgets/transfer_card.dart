import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../../models/download_vm.dart';
import '../../util/format.dart';
import '../../util/palette.dart';
import 'ui/dlx_button.dart';
import 'ui/dlx_card.dart';
import 'download_progress_bar.dart';

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

    return DlxCard(
      onTap: onTap,
      layout: DlxCardLayout.iconLead,
      leadIcon: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorForState(state).withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(iconForState(state), size: 20, color: colorForState(state)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!completed)
                    DlxButton(
                      icon: running ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      tooltip: running ? 'Pause' : 'Resume',
                      onPressed: running ? onPause : onStart,
                      shape: DlxButtonShape.circle,
                      variant: DlxButtonVariant.outline,
                    ),
                  const SizedBox(width: AppSpacing.xs),
                  DlxButton(
                    icon: Icons.close_rounded,
                    tooltip: 'Remove',
                    onPressed: onRemove,
                    shape: DlxButtonShape.circle,
                    variant: DlxButtonVariant.danger,
                  ),
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
          DownloadProgressBar(vm: vm),
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

