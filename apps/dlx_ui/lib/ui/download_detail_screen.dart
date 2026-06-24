import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../models/download_vm.dart';
import '../services/download_service.dart';
import '../util/format.dart';
import '../util/palette.dart';
import 'widgets/dlx_button.dart';
import 'widgets/dlx_card.dart';
import 'widgets/editable_field.dart';
import 'widgets/folder_path_field.dart';
import 'widgets/download_detail/chunk_viz.dart';
import 'widgets/download_detail/download_settings_card.dart';
import 'widgets/download_detail/log_card.dart';
import 'widgets/download_detail/segment_viz.dart';

class DownloadDetailScreen extends StatelessWidget {
  final DownloadVm vm;
  final DownloadService service;
  final VoidCallback? onBack;
  final bool hideAppBar;

  const DownloadDetailScreen({
    super.key,
    required this.vm,
    required this.service,
    this.onBack,
    this.hideAppBar = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: hideAppBar ? null : _DetailAppBar(vm: vm, service: service, onBack: onBack),
      body: ListenableBuilder(
        listenable: vm,
        builder: (context, _) {
          final width = MediaQuery.sizeOf(context).width;
          final isDesktop = width >= kBreakpointMd;
          return isDesktop
              ? _DesktopLayout(vm: vm, service: service, onBack: onBack)
              : _MobileLayout(vm: vm, service: service, onBack: onBack);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// AppBar
// ---------------------------------------------------------------------------

class _DetailAppBar extends StatelessWidget implements PreferredSizeWidget {
  final DownloadVm vm;
  final DownloadService service;
  final VoidCallback? onBack;

  const _DetailAppBar({required this.vm, required this.service, this.onBack});

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) {
        final running =
            vm.state == DownloadState.downloading ||
            vm.state == DownloadState.probing;
        return Container(
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.9),
            border: const Border(
              bottom: BorderSide(color: AppColors.outlineVariant, width: 0.5),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                DlxButton(
                  icon: Icons.arrow_back_rounded,
                  tooltip: 'Back',
                  onPressed: onBack ?? () => Navigator.of(context).pop(),
                  variant: DlxButtonVariant.ghost,
                  shape: DlxButtonShape.circle,
                ),
                Expanded(
                  child: Text(
                    _displayName(vm.desc.filename, vm.desc.url),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.headlineMd.copyWith(
                      color: AppColors.primary,
                    ),
                  ),
                ),
                if (vm.state != DownloadState.completed)
                  DlxButton(
                    icon: running
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    tooltip: running ? 'Pause' : 'Resume',
                    onPressed: () =>
                        running ? service.pause(vm) : service.start(vm),
                    variant: DlxButtonVariant.ghost,
                    shape: DlxButtonShape.circle,
                  ),
                DlxButton(
                  icon: Icons.more_vert_rounded,
                  tooltip: 'More',
                  onPressed: () => _showMoreMenu(context),
                  variant: DlxButtonVariant.ghost,
                  shape: DlxButtonShape.circle,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showMoreMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (_) => _MoreMenu(vm: vm, service: service, onBack: onBack),
    );
  }
}

class _MoreMenu extends StatelessWidget {
  final DownloadVm vm;
  final DownloadService service;
  final VoidCallback? onBack;

  const _MoreMenu({required this.vm, required this.service, this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: AppSpacing.lg),
            decoration: BoxDecoration(
              color: AppColors.outlineVariant,
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
          ),
          ListTile(
            leading: const Icon(
              Icons.delete_outline_rounded,
              color: AppColors.error,
            ),
            title: Text(
              'Remove',
              style: AppTextStyles.bodyMd.copyWith(color: AppColors.error),
            ),
            onTap: () {
              Navigator.of(context).pop();
              service.remove(vm);
              if (onBack != null) {
                onBack!();
              } else {
                Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile layout
// ---------------------------------------------------------------------------

class _MobileLayout extends StatelessWidget {
  final DownloadVm vm;
  final DownloadService service;
  final VoidCallback? onBack;

  const _MobileLayout({required this.vm, required this.service, this.onBack});

  @override
  Widget build(BuildContext context) {
    final d = vm.desc;
    final running = vm.state == DownloadState.downloading;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        100,
      ),
      children: [
        // File info header
        DlxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              EditableField(
                viewBuilder: () => Text(
                  _displayName(d.filename, d.url),
                  style: AppTextStyles.headlineLgMobile.copyWith(
                    color: AppColors.onSurface,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                editBuilder: (confirm, cancel) {
                  final ctrl = TextEditingController(text: d.filename ?? '');
                  return _InlineTextEdit(
                    controller: ctrl,
                    onConfirm: () {
                      vm.download.setFilename(
                        ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
                      );
                      confirm();
                    },
                    onCancel: cancel,
                  );
                },
              ),
              const SizedBox(height: AppSpacing.xs),
              EditableField(
                viewBuilder: () => Row(
                  children: [
                    const Icon(
                      Icons.folder_open_outlined,
                      size: 14,
                      color: AppColors.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        d.targetPath ?? '—',
                        style: AppTextStyles.labelSm.copyWith(
                          color: AppColors.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                editBuilder: (confirm, cancel) {
                  final ctrl = TextEditingController(text: d.targetPath ?? '');
                  return _InlineFolderEdit(
                    controller: ctrl,
                    onConfirm: () {
                      vm.download.setTargetPath(
                        ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
                      );
                      confirm();
                    },
                    onCancel: cancel,
                  );
                },
              ),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  const Icon(
                    Icons.link_rounded,
                    size: 14,
                    color: AppColors.outlineVariant,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      d.url,
                      style: AppTextStyles.labelSm.copyWith(
                        color: AppColors.outlineVariant,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),

        // Status card
        DlxCard(
          layout: DlxCardLayout.iconLead,
          leadIcon: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: colorForState(vm.state).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Icon(
              iconForState(vm.state),
              size: 28,
              color: colorForState(vm.state),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _stateLabel(vm.state),
                          style: AppTextStyles.headlineMd.copyWith(
                            color: AppColors.onSurface,
                          ),
                        ),
                        Text(
                          running ? 'Active Connection' : vm.state.name,
                          style: AppTextStyles.labelSm.copyWith(
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (running)
                    _SpeedBadge(speedBps: d.totalSpeedBps.toDouble()),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Progress',
                    style: AppTextStyles.labelSm.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    formatPercent(d.percent),
                    style: AppTextStyles.labelSm.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),

        // Stats bento grid
        _StatsBento(d: d, vm: vm),
        const SizedBox(height: AppSpacing.md),

        // Chunk / segment visualization
        if (vm.isHls)
          DlxCard(
            title: 'Segment Distribution',
            titleIcon: Icons.grid_view_rounded,
            description:
                '${vm.hlsSegmentsDone ?? 0} done / ${vm.hlsTotalSegments ?? vm.desc.totalChunks} total',
            child: SegmentViz(segments: vm.snapshots, vm: vm),
          )
        else
          DlxCard(
            title: 'Chunk Visualization',
            description: '${vm.desc.totalChunks} Chunks',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ChunkViz(vm: vm),
                const SizedBox(height: AppSpacing.md),
                _ChunkLegend(),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.md),

        // Controls
        _ControlButtons(vm: vm, service: service, onBack: onBack),
        const SizedBox(height: AppSpacing.md),

        // Settings
        DownloadSettingsCard(vm: vm),

        const SizedBox(height: AppSpacing.md),
        LogCard(download: vm.download),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Desktop layout
// ---------------------------------------------------------------------------

class _DesktopLayout extends StatelessWidget {
  final DownloadVm vm;
  final DownloadService service;
  final VoidCallback? onBack;

  const _DesktopLayout({required this.vm, required this.service, this.onBack});

  @override
  Widget build(BuildContext context) {
    final d = vm.desc;
    final running = vm.state == DownloadState.downloading;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left column — main content
        Expanded(
          flex: 3,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              // Header card
              DlxCard(
                layout: DlxCardLayout.iconLead,
                leadIcon: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: AppColors.outlineVariant),
                  ),
                  child: Icon(
                    iconForState(vm.state),
                    size: 36,
                    color: colorForState(vm.state),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          EditableField(
                            viewBuilder: () => Text(
                              _displayName(d.filename, d.url),
                              style: AppTextStyles.headlineLgMobile.copyWith(
                                color: AppColors.onSurface,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            editBuilder: (confirm, cancel) {
                              final ctrl = TextEditingController(
                                text: d.filename ?? '',
                              );
                              return _InlineTextEdit(
                                controller: ctrl,
                                onConfirm: () {
                                  vm.download.setFilename(
                                    ctrl.text.trim().isEmpty
                                        ? null
                                        : ctrl.text.trim(),
                                  );
                                  vm.refresh();
                                  confirm();
                                },
                                onCancel: cancel,
                              );
                            },
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          EditableField(
                            viewBuilder: () => Row(
                              children: [
                                const Icon(
                                  Icons.folder_open_outlined,
                                  size: 14,
                                  color: AppColors.onSurfaceVariant,
                                ),
                                const SizedBox(width: AppSpacing.xs),
                                Expanded(
                                  child: Text(
                                    d.targetPath ?? '—',
                                    style: AppTextStyles.labelSm.copyWith(
                                      color: AppColors.onSurfaceVariant,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            editBuilder: (confirm, cancel) {
                              final ctrl = TextEditingController(
                                text: d.targetPath ?? '',
                              );
                              return _InlineFolderEdit(
                                controller: ctrl,
                                onConfirm: () {
                                  vm.download.setTargetPath(
                                    ctrl.text.trim().isEmpty
                                        ? null
                                        : ctrl.text.trim(),
                                  );
                                  vm.refresh();
                                  confirm();
                                },
                                onCancel: cancel,
                              );
                            },
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Row(
                            children: [
                              const Icon(
                                Icons.link_rounded,
                                size: 14,
                                color: AppColors.outlineVariant,
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              Expanded(
                                child: Text(
                                  d.url,
                                  style: AppTextStyles.labelSm.copyWith(
                                    color: AppColors.outlineVariant,
                                    fontSize: 11,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Row(
                            children: [
                              _TagChip(
                                label: vm.state.name,
                                color: colorForState(vm.state),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          vm.isHls
                              ? _hlsProgressLabel(vm)
                              : formatPercent(d.percent),
                          style: AppTextStyles.headlineLg.copyWith(
                            color: AppColors.primary,
                            fontSize: 28,
                          ),
                        ),
                        if (d.totalBytes != null)
                          Text(
                            '/ ${formatBytes(d.totalBytes!)}',
                            style: AppTextStyles.dataDisplay.copyWith(
                              color: AppColors.onSurfaceVariant,
                            ),
                          ),
                        if (running) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Row(
                            children: [
                              const Icon(
                                Icons.download_rounded,
                                size: 14,
                                color: AppColors.secondary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                formatSpeed(d.totalSpeedBps.toDouble()),
                                style: AppTextStyles.dataDisplay.copyWith(
                                  color: AppColors.secondary,
                                ),
                              ),
                            ],
                          ),
                          if (d.etaMs != null)
                            Text(
                              'ETA: ${formatDuration(d.etaMs!)}',
                              style: AppTextStyles.labelSm.copyWith(
                                color: AppColors.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),

              // Chunk / segment visualization
              if (vm.isHls)
                DlxCard(
                  title: 'Segment Distribution',
                  titleIcon: Icons.grid_view_rounded,
                  description:
                      '${vm.hlsSegmentsDone ?? 0} done / ${vm.hlsTotalSegments ?? d.totalChunks} total',
                  child: SegmentViz(segments: vm.snapshots, vm: vm),
                )
              else
                DlxCard(
                  title: 'Chunk Distribution',
                  titleIcon: Icons.grid_view_rounded,
                  description:
                      '${d.activeChunks} active / ${d.totalChunks} total',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ChunkViz(vm: vm, height: 56),
                      const SizedBox(height: AppSpacing.md),
                      _ChunkLegend(),
                    ],
                  ),
                ),
              const SizedBox(height: AppSpacing.lg),

              // Settings
              DownloadSettingsCard(vm: vm),

              const SizedBox(height: AppSpacing.lg),
              LogCard(download: vm.download),
            ],
          ),
        ),

        // Right column — stats + controls
        SizedBox(
          width: 320,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              0,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            children: [
              DlxCard(
                title: 'Metrics',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _MetricRow(
                      label: 'Percent',
                      value: formatPercent(d.percent),
                      highlight: true,
                    ),
                    _MetricRow(
                      label: 'Downloaded',
                      value: formatBytes(d.downloadedBytes),
                    ),
                    if (!vm.isHls)
                      _MetricRow(
                        label: 'Total Size',
                        value: d.totalBytes == null
                            ? '—'
                            : formatBytes(d.totalBytes!),
                      ),
                    if (vm.isHls)
                      _MetricRow(
                        label: 'Segments',
                        value: vm.hlsTotalSegments != null
                            ? '${vm.hlsSegmentsDone ?? 0} / ${vm.hlsTotalSegments}'
                            : '${vm.hlsSegmentsDone ?? 0}',
                      ),
                    _MetricRow(
                      label: 'Speed',
                      value: formatSpeed(d.totalSpeedBps.toDouble()),
                    ),
                    _MetricRow(
                      label: 'ETA',
                      value: d.etaMs == null ? '—' : formatDuration(d.etaMs!),
                    ),
                    _MetricRow(
                      label: 'Elapsed',
                      value: formatDuration(d.elapsedMs),
                    ),
                    if (!vm.isHls)
                      _MetricRow(
                        label: 'Chunks',
                        value: '${d.activeChunks} / ${d.totalChunks}',
                      ),
                    _MetricRow(label: 'State', value: d.state.name),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              DlxCard(
                title: 'Actions',
                child: _ControlButtons(vm: vm, service: service, dense: true, onBack: onBack),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatsBento extends StatelessWidget {
  final DownloadDescription d;
  final DownloadVm vm;
  const _StatsBento({required this.d, required this.vm});

  @override
  Widget build(BuildContext context) {
    final segLabel = vm.isHls
        ? (vm.hlsTotalSegments != null
              ? '${vm.hlsSegmentsDone ?? 0}/${vm.hlsTotalSegments}'
              : '${vm.hlsSegmentsDone ?? 0}')
        : '${d.activeChunks}/${d.totalChunks}';
    final sizeLabel = vm.isHls
        ? formatBytes(d.downloadedBytes)
        : (d.totalBytes == null ? '—' : formatBytes(d.totalBytes!));

    final items = [
      (Icons.storage_rounded, AppColors.onSurfaceVariant, 'Size', sizeLabel),
      (
        Icons.speed_rounded,
        AppColors.primary,
        'Speed',
        formatSpeed(d.totalSpeedBps.toDouble()),
      ),
      (
        Icons.timer_outlined,
        AppColors.onSurfaceVariant,
        'ETA',
        d.etaMs == null ? '—' : formatDuration(d.etaMs!),
      ),
      (
        Icons.layers_rounded,
        AppColors.secondary,
        vm.isHls ? 'Segments' : 'Chunks',
        segLabel,
      ),
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: AppSpacing.sm,
        mainAxisSpacing: AppSpacing.sm,
        mainAxisExtent: 100,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) => _BentoCell(
        icon: items[i].$1,
        iconColor: items[i].$2,
        label: items[i].$3,
        value: items[i].$4,
      ),
    );
  }
}

class _BentoCell extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;

  const _BentoCell({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return DlxCard(
      title: label,
      titleIcon: icon,
      titleIconColor: iconColor,
      child: Align(
        alignment: Alignment.bottomRight,
        child: Text(
          value,
          style: AppTextStyles.dataDisplay.copyWith(
            color: AppColors.onSurface,
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;
  const _MetricRow({required this.label, required this.value, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: AppTextStyles.labelSm.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: highlight
                ? AppTextStyles.headlineMd.copyWith(color: AppColors.primary)
                : AppTextStyles.dataDisplay.copyWith(color: AppColors.onSurface),
          ),
        ],
      ),
    );
  }
}

class _SpeedBadge extends StatelessWidget {
  final double speedBps;
  const _SpeedBadge({required this.speedBps});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: AppColors.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            formatSpeed(speedBps),
            style: AppTextStyles.dataDisplay.copyWith(color: AppColors.primary),
          ),
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;
  final Color color;
  const _TagChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label, style: AppTextStyles.labelSm.copyWith(color: color)),
    );
  }
}

class _ChunkLegend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.xs,
      children: const [
        _LegendItem(color: AppColors.secondary, label: 'Completed'),
        _LegendItem(color: AppColors.primary, label: 'Active'),
        _LegendItem(color: AppColors.surfaceContainerHigh, label: 'Queued'),
        _LegendItem(color: AppColors.error, label: 'Stalled'),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          label,
          style: AppTextStyles.labelSm.copyWith(
            color: AppColors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ControlButtons extends StatelessWidget {
  final DownloadVm vm;
  final DownloadService service;
  final bool dense;
  final VoidCallback? onBack;

  const _ControlButtons({
    required this.vm,
    required this.service,
    this.dense = false,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final running =
        vm.state == DownloadState.downloading ||
        vm.state == DownloadState.probing;
    final completed = vm.state == DownloadState.completed;

    if (dense) {
      return Row(
        children: [
          if (!completed)
            Expanded(
              child: DlxButton(
                icon: running ? Icons.pause_rounded : Icons.play_arrow_rounded,
                label: running ? 'Pause' : 'Resume',
                onPressed: () =>
                    running ? service.pause(vm) : service.start(vm),
                size: DlxButtonSize.lg,
                shape: DlxButtonShape.pill,
              ),
            ),
          if (!completed) const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: DlxButton(
              icon: Icons.close_rounded,
              label: 'Remove',
              onPressed: () {
                service.remove(vm);
                if (onBack != null) { onBack!(); } else { Navigator.of(context).pop(); }
              },
              variant: DlxButtonVariant.danger,
              size: DlxButtonSize.lg,
              shape: DlxButtonShape.pill,
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        if (!completed)
          Expanded(
            child: DlxButton(
              icon: running ? Icons.pause_rounded : Icons.play_arrow_rounded,
              label: running ? 'Pause' : 'Resume',
              onPressed: () => running ? service.pause(vm) : service.start(vm),
              size: DlxButtonSize.lg,
              shape: DlxButtonShape.pill,
            ),
          ),
        if (!completed) const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: DlxButton(
            icon: Icons.close_rounded,
            label: 'Remove',
            onPressed: () {
              service.remove(vm);
              if (onBack != null) { onBack!(); } else { Navigator.of(context).pop(); }
            },
            variant: DlxButtonVariant.danger,
            size: DlxButtonSize.lg,
            shape: DlxButtonShape.pill,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: DlxButton(
            icon: Icons.tune_rounded,
            label: 'Speed Limit',
            onPressed: () {},
            size: DlxButtonSize.lg,
            shape: DlxButtonShape.pill,
          ),
        ),
      ],
    );
  }
}

String _hlsProgressLabel(DownloadVm vm) {
  final done = vm.hlsSegmentsDone;
  final total = vm.hlsTotalSegments;
  if (done == null) return 'HLS';
  if (total != null && total > 0)
    return '${(done / total * 100).toStringAsFixed(0)}%';
  return '$done segs';
}

String _displayName(String? filename, String url) {
  if (filename != null && filename.isNotEmpty) return filename;
  final path = Uri.tryParse(
    url,
  )?.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
  return path ?? url;
}


class _InlineTextEdit extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _InlineTextEdit({
    required this.controller,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(isDense: true),
            onSubmitted: (_) => onConfirm(),
          ),
        ),
        DlxButton(
          icon: Icons.check_rounded,
          tooltip: 'Confirm',
          onPressed: onConfirm,
          variant: DlxButtonVariant.ghost,
          shape: DlxButtonShape.circle,
          size: DlxButtonSize.sm,
        ),
        DlxButton(
          icon: Icons.close_rounded,
          tooltip: 'Cancel',
          onPressed: onCancel,
          variant: DlxButtonVariant.ghost,
          shape: DlxButtonShape.circle,
          size: DlxButtonSize.sm,
        ),
      ],
    );
  }
}

class _InlineFolderEdit extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _InlineFolderEdit({
    required this.controller,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FolderPathField(controller: controller),
        const SizedBox(height: AppSpacing.xs),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            DlxButton(
              label: 'Cancel',
              onPressed: onCancel,
              variant: DlxButtonVariant.ghost,
            ),
            const SizedBox(width: AppSpacing.xs),
            DlxButton(
              label: 'Confirm',
              onPressed: onConfirm,
              variant: DlxButtonVariant.filled,
            ),
          ],
        ),
      ],
    );
  }
}


String _stateLabel(DownloadState s) => switch (s) {
  DownloadState.downloading => 'Downloading',
  DownloadState.probing => 'Probing...',
  DownloadState.paused => 'Paused',
  DownloadState.completed => 'Completed',
  DownloadState.error => 'Error',
  DownloadState.cancelled => 'Cancelled',
  DownloadState.idle => 'Idle',
};
