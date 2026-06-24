import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart' hide DiagnosticLevel;

import '../models/download_vm.dart';
import '../services/download_service.dart';
import '../util/format.dart';
import '../util/palette.dart';
import 'widgets/chunk_speed_panel.dart';
import 'widgets/chunk_viz.dart';
import 'widgets/dlx_button.dart';
import 'widgets/dlx_card.dart';
import 'widgets/download_progress_bar.dart';
import 'widgets/editable_field.dart';
import 'widgets/folder_path_field.dart';
import 'widgets/key_value_editor.dart';
import 'widgets/slider_number_field.dart';

class DownloadDetailScreen extends StatelessWidget {
  final DownloadVm vm;
  final DownloadService service;

  const DownloadDetailScreen({
    super.key,
    required this.vm,
    required this.service,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _DetailAppBar(vm: vm, service: service),
      body: ListenableBuilder(
        listenable: vm,
        builder: (context, _) {
          final width = MediaQuery.sizeOf(context).width;
          final isDesktop = width >= kBreakpointMd;
          return isDesktop
              ? _DesktopLayout(vm: vm, service: service)
              : _MobileLayout(vm: vm, service: service);
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

  const _DetailAppBar({required this.vm, required this.service});

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
                  onPressed: () => Navigator.of(context).pop(),
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
      builder: (_) => _MoreMenu(vm: vm, service: service),
    );
  }
}

class _MoreMenu extends StatelessWidget {
  final DownloadVm vm;
  final DownloadService service;

  const _MoreMenu({required this.vm, required this.service});

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
              Navigator.of(context).pop();
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

  const _MobileLayout({required this.vm, required this.service});

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
              const SizedBox(height: AppSpacing.xs),
              DownloadProgressBar(vm: vm),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),

        // Stats bento grid
        _StatsBento(d: d, vm: vm),
        const SizedBox(height: AppSpacing.md),

        // Chunk visualization
        DlxCard(
          title: 'Chunk Visualization',
          description: '${vm.desc.totalChunks} Chunks',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ChunkViz(totalBytes: d.totalBytes, chunks: vm.snapshots),
              const SizedBox(height: AppSpacing.md),
              _ChunkLegend(),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),

        // Chunk speed panel
        ListenableBuilder(
          listenable: service.ticker,
          builder: (context, _) => DlxCard(child: ChunkSpeedPanel(vm: vm)),
        ),
        const SizedBox(height: AppSpacing.md),

        // Controls
        _ControlButtons(vm: vm, service: service),
        const SizedBox(height: AppSpacing.md),

        // Settings
        _DownloadSettingsCard(vm: vm),

        const SizedBox(height: AppSpacing.md),
        _LogCard(download: vm.download),
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

  const _DesktopLayout({required this.vm, required this.service});

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

              // Progress bar
              DownloadProgressBar(vm: vm),
              const SizedBox(height: AppSpacing.lg),

              // Chunk visualization
              DlxCard(
                title: 'Chunk Distribution',
                titleIcon: Icons.grid_view_rounded,
                description:
                    '${d.activeChunks} active / ${d.totalChunks} total',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ChunkViz(
                      totalBytes: d.totalBytes,
                      chunks: vm.snapshots,
                      height: 56,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _ChunkLegend(),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),

              // Chunk speed panel
              ListenableBuilder(
                listenable: service.ticker,
                builder: (context, _) =>
                    DlxCard(child: ChunkSpeedPanel(vm: vm)),
              ),

              // Settings
              const SizedBox(height: AppSpacing.lg),
              _DownloadSettingsCard(vm: vm),

              const SizedBox(height: AppSpacing.lg),
              _LogCard(download: vm.download),
            ],
          ),
        ),

        // Right column — stats + controls
        SizedBox(
          width: 280,
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
                child: _ControlButtons(vm: vm, service: service, dense: true),
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
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: AppSpacing.sm,
      mainAxisSpacing: AppSpacing.sm,
      childAspectRatio: 2.2,
      children: items
          .map(
            (item) => _BentoCell(
              icon: item.$1,
              iconColor: item.$2,
              label: item.$3,
              value: item.$4,
            ),
          )
          .toList(),
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
  const _MetricRow({required this.label, required this.value});

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
            style: AppTextStyles.dataDisplay.copyWith(
              color: AppColors.onSurface,
            ),
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

  const _ControlButtons({
    required this.vm,
    required this.service,
    this.dense = false,
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
                Navigator.of(context).pop();
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
              Navigator.of(context).pop();
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

// ---------------------------------------------------------------------------
// Download settings card
// ---------------------------------------------------------------------------

class _DownloadSettingsCard extends StatefulWidget {
  final DownloadVm vm;
  const _DownloadSettingsCard({required this.vm});

  @override
  State<_DownloadSettingsCard> createState() => _DownloadSettingsCardState();
}

class _DownloadSettingsCardState extends State<_DownloadSettingsCard> {
  static const int _maxSpeedBytes = 100 * 1024 * 1024;
  static const int _speedStep = 256 * 1024;
  static const int _maxChunks = 32;

  DownloadVm get vm => widget.vm;

  void _refresh() => vm.refresh();

  @override
  Widget build(BuildContext context) {
    final d = vm.desc;
    final dl = vm.download;
    final currentSpeed = dl.speedLimit > 0 ? dl.speedLimit.toInt() : 0;
    final currentChunks = dl.targetChunkCount.clamp(1, _maxChunks);
    final currentJournal = dl.journal;
    final currentHeaders = Map<String, String>.from(dl.headers);
    final currentMetadata = d.metadata ?? {};

    return DlxCard(
      title: 'Settings',
      titleIcon: Icons.tune_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Description
          EditableField(
            label: 'Description',
            viewBuilder: () => Text(
              d.description?.isNotEmpty == true ? d.description! : '—',
              style: AppTextStyles.bodyMd.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            editBuilder: (confirm, cancel) {
              final ctrl = TextEditingController(text: d.description ?? '');
              return _InlineTextEdit(
                controller: ctrl,
                onConfirm: () {
                  dl.setDescription(
                    ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
                  );
                  _refresh();
                  confirm();
                },
                onCancel: cancel,
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),

          // Speed limit
          EditableField(
            label: 'Speed limit',
            viewBuilder: () => Text(
              currentSpeed == 0 ? 'Unlimited' : formatSpeedLimit(currentSpeed),
              style: AppTextStyles.bodyMd.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
            editBuilder: (confirm, cancel) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Speed limit',
                  style: AppTextStyles.bodyMd.copyWith(
                    color: AppColors.onSurface,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                SliderNumberField(
                  value: currentSpeed,
                  min: 0,
                  max: _maxSpeedBytes,
                  step: _speedStep,
                  labelBuilder: (v) =>
                      v == 0 ? 'Unlimited' : formatSpeedLimit(v),
                  inputParser: (s) => s.trim().toLowerCase() == 'unlimited'
                      ? 0
                      : parseSpeedLimit(s),
                  onChanged: (v) {
                    dl.setSpeedLimit(v == 0 ? null : v);
                    _refresh();
                  },
                ),
                const SizedBox(height: AppSpacing.xs),
                Align(
                  alignment: Alignment.centerRight,
                  child: DlxButton(
                    label: 'Done',
                    onPressed: confirm,
                    variant: DlxButtonVariant.ghost,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Target chunk count
          EditableField(
            label: 'Target chunk count',
            viewBuilder: () => Text(
              '$currentChunks',
              style: AppTextStyles.bodyMd.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
            editBuilder: (confirm, cancel) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Target chunk count',
                  style: AppTextStyles.bodyMd.copyWith(
                    color: AppColors.onSurface,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                SliderNumberField(
                  value: currentChunks,
                  min: 1,
                  max: _maxChunks,
                  step: 1,
                  labelBuilder: (v) => '$v',
                  onChanged: (v) {
                    dl.setTargetChunkCount(v);
                    _refresh();
                  },
                ),
                const SizedBox(height: AppSpacing.xs),
                Align(
                  alignment: Alignment.centerRight,
                  child: DlxButton(
                    label: 'Done',
                    onPressed: confirm,
                    variant: DlxButtonVariant.ghost,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Journal
          EditableField(
            label: 'Write diagnostic journal',
            viewBuilder: () => Text(
              currentJournal ? 'Enabled' : 'Disabled',
              style: AppTextStyles.bodyMd.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
            editBuilder: (confirm, cancel) => Row(
              children: [
                Expanded(
                  child: Text(
                    'Write diagnostic journal',
                    style: AppTextStyles.bodyMd.copyWith(
                      color: AppColors.onSurface,
                    ),
                  ),
                ),
                Switch(
                  value: currentJournal,
                  onChanged: (v) {
                    dl.setJournal(v);
                    _refresh();
                    confirm();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Headers
          EditableField(
            label: 'HTTP Headers',
            viewBuilder: () => Text(
              currentHeaders.isEmpty
                  ? 'none'
                  : '${currentHeaders.length} entries',
              style: AppTextStyles.bodyMd.copyWith(
                color: currentHeaders.isEmpty
                    ? AppColors.outlineVariant
                    : AppColors.onSurfaceVariant,
              ),
            ),
            editBuilder: (confirm, cancel) {
              final ctrl = KeyValueEditorController();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  KeyValueEditor(
                    controller: ctrl,
                    label: 'HTTP Headers',
                    keyHint: 'Header name',
                    valueHint: 'Value',
                    initialValues: currentHeaders,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      DlxButton(
                        label: 'Cancel',
                        onPressed: cancel,
                        variant: DlxButtonVariant.ghost,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      DlxButton(
                        label: 'Confirm',
                        onPressed: () {
                          final newMap = ctrl.read();
                          dl.clearHeaders();
                          if (newMap.isNotEmpty)
                            dl.setHeaders(newMap.map((k, v) => MapEntry(k, v)));
                          _refresh();
                          confirm();
                        },
                        variant: DlxButtonVariant.filled,
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),

          // Metadata
          EditableField(
            label: 'Metadata',
            viewBuilder: () => Text(
              currentMetadata.isEmpty
                  ? 'none'
                  : '${currentMetadata.length} entries',
              style: AppTextStyles.bodyMd.copyWith(
                color: currentMetadata.isEmpty
                    ? AppColors.outlineVariant
                    : AppColors.onSurfaceVariant,
              ),
            ),
            editBuilder: (confirm, cancel) {
              final ctrl = KeyValueEditorController();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  KeyValueEditor(
                    controller: ctrl,
                    label: 'Metadata',
                    keyHint: 'Key',
                    valueHint: 'Value',
                    initialValues: currentMetadata,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      DlxButton(
                        label: 'Cancel',
                        onPressed: cancel,
                        variant: DlxButtonVariant.ghost,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      DlxButton(
                        label: 'Confirm',
                        onPressed: () {
                          final newMap = ctrl.read();
                          dl.clearMetadata();
                          if (newMap.isNotEmpty)
                            dl.setMetadata(
                              newMap.map((k, v) => MapEntry(k, v)),
                            );
                          _refresh();
                          confirm();
                        },
                        variant: DlxButtonVariant.filled,
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
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

// ---------------------------------------------------------------------------
// Log card
// ---------------------------------------------------------------------------

class _LogCard extends StatefulWidget {
  final Download download;
  const _LogCard({required this.download});

  @override
  State<_LogCard> createState() => _LogCardState();
}

class _LogCardState extends State<_LogCard> {
  final List<({int timestamp, DiagnosticLevel level, String message})>
  _entries = [];
  late final void Function() _unsub;

  @override
  void initState() {
    super.initState();
    _entries.addAll(widget.download.renderedLogs);
    _unsub = widget.download.emitter.onType<LogEvent>((e) {
      if (!mounted) return;
      setState(
        () => _entries.add((
          timestamp: e.timestamp,
          level: e.level,
          message: e.message,
        )),
      );
    });
  }

  @override
  void dispose() {
    _unsub();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DlxCard(
      title: 'Activity Log',
      titleIcon: Icons.receipt_long_rounded,
      description: '${_entries.length} entries',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: _entries.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.md,
                    ),
                    child: Text(
                      'No log entries yet.',
                      style: AppTextStyles.labelSm.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    itemCount: _entries.length,
                    itemBuilder: (context, i) {
                      final e = _entries[_entries.length - 1 - i];
                      return _LogRow(entry: e);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  final ({int timestamp, DiagnosticLevel level, String message}) entry;
  const _LogRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final color = _logColor(entry.level);
    final label = _logLabel(entry.level);
    final time = _formatTime(entry.timestamp);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            time,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              color: AppColors.outlineVariant,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              entry.message,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: color == AppColors.onSurfaceVariant
                    ? AppColors.onSurfaceVariant
                    : color.withValues(alpha: 0.9),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _logColor(DiagnosticLevel l) => switch (l) {
    DiagnosticLevel.error => AppColors.error,
    DiagnosticLevel.warn => AppColors.tertiary,
    DiagnosticLevel.info => AppColors.onSurfaceVariant,
  };

  String _logLabel(DiagnosticLevel l) => switch (l) {
    DiagnosticLevel.error => 'ERR',
    DiagnosticLevel.warn => 'WRN',
    DiagnosticLevel.info => 'INF',
  };

  String _formatTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
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
