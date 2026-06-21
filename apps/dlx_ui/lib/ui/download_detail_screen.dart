import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart' hide DiagnosticLevel;

import '../models/download_vm.dart';
import '../services/download_service.dart';
import '../util/format.dart';
import '../util/palette.dart';
import 'shell.dart' show kBreakpointMd;
import 'widgets/chunk_speed_panel.dart';
import 'widgets/chunk_viz.dart';

class DownloadDetailScreen extends StatelessWidget {
  final DownloadVm vm;
  final DownloadService service;

  const DownloadDetailScreen({super.key, required this.vm, required this.service});

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
        final running = vm.state == DownloadState.downloading ||
            vm.state == DownloadState.probing;
        return Container(
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.9),
            border: const Border(
                bottom: BorderSide(color: AppColors.outlineVariant, width: 0.5)),
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  color: AppColors.primary,
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Text(
                    vm.desc.filename ?? vm.desc.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.headlineMd.copyWith(color: AppColors.primary),
                  ),
                ),
                if (vm.state != DownloadState.completed)
                  IconButton(
                    icon: Icon(running ? Icons.pause_rounded : Icons.play_arrow_rounded),
                    color: AppColors.onSurfaceVariant,
                    tooltip: running ? 'Pause' : 'Resume',
                    onPressed: () =>
                        running ? service.pause(vm) : service.start(vm),
                  ),
                IconButton(
                  icon: const Icon(Icons.more_vert_rounded),
                  color: AppColors.onSurfaceVariant,
                  onPressed: () => _showMoreMenu(context),
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
            leading: const Icon(Icons.delete_outline_rounded, color: AppColors.error),
            title: Text('Remove',
                style: AppTextStyles.bodyMd.copyWith(color: AppColors.error)),
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
          AppSpacing.md, AppSpacing.md, AppSpacing.md, 100),
      children: [
        // Status card
        _GlassCard(
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: colorForState(vm.state).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                    ),
                    child: Icon(iconForState(vm.state),
                        size: 28, color: colorForState(vm.state)),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_stateLabel(vm.state),
                            style: AppTextStyles.headlineMd
                                .copyWith(color: AppColors.onSurface)),
                        Text(
                          running ? 'Active Connection' : vm.state.name,
                          style: AppTextStyles.labelSm
                              .copyWith(color: AppColors.onSurfaceVariant),
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
                  Text('Progress',
                      style: AppTextStyles.labelSm
                          .copyWith(color: AppColors.onSurfaceVariant)),
                  Text(
                    formatPercent(d.percent),
                    style: AppTextStyles.labelSm
                        .copyWith(color: AppColors.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              _GlowProgressBar(
                value: d.percent == null ? null : d.percent! / 100,
                active: running,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),

        // Stats bento grid
        _StatsBento(d: d),
        const SizedBox(height: AppSpacing.md),

        // Chunk visualization
        _GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionHeader(
                  title: 'Chunk Visualization',
                  trailing: '${vm.desc.totalChunks} Chunks'),
              const SizedBox(height: AppSpacing.md),
              ChunkViz(
                totalBytes: d.totalBytes,
                chunks: vm.snapshots,
              ),
              const SizedBox(height: AppSpacing.md),
              _ChunkLegend(),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),

        // Chunk speed panel
        ListenableBuilder(
          listenable: service.ticker,
          builder: (context, _) => _GlassCard(
            child: ChunkSpeedPanel(vm: vm),
          ),
        ),
        const SizedBox(height: AppSpacing.md),

        // Controls
        _ControlButtons(vm: vm, service: service),

        // Diagnostics
        if (d.recentDiagnostics.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          _DiagnosticsPanel(diags: d.recentDiagnostics),
        ],
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
              _GlassCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: AppColors.outlineVariant),
                      ),
                      child: Icon(iconForState(vm.state),
                          size: 36, color: colorForState(vm.state)),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            d.filename ?? d.url,
                            style: AppTextStyles.headlineLgMobile
                                .copyWith(color: AppColors.onSurface),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          if (d.targetPath != null)
                            Row(
                              children: [
                                const Icon(Icons.folder_open_outlined,
                                    size: 14, color: AppColors.onSurfaceVariant),
                                const SizedBox(width: AppSpacing.xs),
                                Text(d.targetPath!,
                                    style: AppTextStyles.labelSm.copyWith(
                                        color: AppColors.onSurfaceVariant)),
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
                          formatPercent(d.percent),
                          style: AppTextStyles.headlineLg.copyWith(
                              color: AppColors.primary, fontSize: 28),
                        ),
                        if (d.totalBytes != null)
                          Text(
                            '/ ${formatBytes(d.totalBytes!)}',
                            style: AppTextStyles.dataDisplay
                                .copyWith(color: AppColors.onSurfaceVariant),
                          ),
                        if (running) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Row(
                            children: [
                              const Icon(Icons.download_rounded,
                                  size: 14, color: AppColors.secondary),
                              const SizedBox(width: 4),
                              Text(
                                formatSpeed(d.totalSpeedBps.toDouble()),
                                style: AppTextStyles.dataDisplay
                                    .copyWith(color: AppColors.secondary),
                              ),
                            ],
                          ),
                          if (d.etaMs != null)
                            Text(
                              'ETA: ${formatDuration(d.etaMs!)}',
                              style: AppTextStyles.labelSm
                                  .copyWith(color: AppColors.onSurfaceVariant),
                            ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),

              // Progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.full),
                child: _GlowProgressBar(
                  value: d.percent == null ? null : d.percent! / 100,
                  active: running,
                  height: 10,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),

              // Chunk visualization
              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SectionHeader(
                      title: 'Chunk Distribution',
                      trailing: '${d.activeChunks} active / ${d.totalChunks} total',
                      icon: Icons.grid_view_rounded,
                    ),
                    const SizedBox(height: AppSpacing.md),
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
                builder: (context, _) => _GlassCard(
                  child: ChunkSpeedPanel(vm: vm),
                ),
              ),

              // Diagnostics
              if (d.recentDiagnostics.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.lg),
                _DiagnosticsPanel(diags: d.recentDiagnostics),
              ],
            ],
          ),
        ),

        // Right column — stats + controls
        SizedBox(
          width: 280,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, AppSpacing.lg, AppSpacing.lg, AppSpacing.lg),
            children: [
              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Metrics',
                        style: AppTextStyles.labelSm.copyWith(
                            color: AppColors.onSurfaceVariant,
                            letterSpacing: 0.8)),
                    const SizedBox(height: AppSpacing.md),
                    _MetricRow(
                        label: 'Downloaded',
                        value: formatBytes(d.downloadedBytes)),
                    _MetricRow(
                        label: 'Total Size',
                        value: d.totalBytes == null
                            ? '—'
                            : formatBytes(d.totalBytes!)),
                    _MetricRow(label: 'Speed', value: formatSpeed(d.totalSpeedBps.toDouble())),
                    _MetricRow(
                        label: 'ETA',
                        value: d.etaMs == null ? '—' : formatDuration(d.etaMs!)),
                    _MetricRow(
                        label: 'Elapsed', value: formatDuration(d.elapsedMs)),
                    _MetricRow(
                        label: 'Chunks',
                        value: '${d.activeChunks} / ${d.totalChunks}'),
                    _MetricRow(label: 'State', value: d.state.name),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Actions',
                            style: AppTextStyles.labelSm.copyWith(
                                color: AppColors.onSurfaceVariant,
                                letterSpacing: 0.8)),
                        TextButton.icon(
                          icon: const Icon(Icons.tune_rounded, size: 14),
                          label: const Text('Limit Speed'),
                          style: TextButton.styleFrom(
                            textStyle: AppTextStyles.labelSm,
                            foregroundColor: AppColors.onSurfaceVariant,
                            padding: EdgeInsets.zero,
                          ),
                          onPressed: () {},
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _ControlButtons(vm: vm, service: service, dense: true),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared section widgets
// ---------------------------------------------------------------------------

class _GlassCard extends StatelessWidget {
  final Widget child;
  const _GlassCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: AppColors.outlineVariant),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: child,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? trailing;
  final IconData? icon;

  const _SectionHeader({required this.title, this.trailing, this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: AppColors.onSurface),
          const SizedBox(width: AppSpacing.xs),
        ],
        Text(title,
            style: AppTextStyles.headlineMd.copyWith(color: AppColors.onSurface)),
        const Spacer(),
        if (trailing != null)
          Text(trailing!,
              style: AppTextStyles.labelSm
                  .copyWith(color: AppColors.onSurfaceVariant)),
      ],
    );
  }
}

class _StatsBento extends StatelessWidget {
  final DownloadDescription d;
  const _StatsBento({required this.d});

  @override
  Widget build(BuildContext context) {
    final items = [
      (Icons.storage_rounded, AppColors.onSurfaceVariant, 'Size',
          d.totalBytes == null ? '—' : formatBytes(d.totalBytes!)),
      (Icons.speed_rounded, AppColors.primary, 'Speed',
          formatSpeed(d.totalSpeedBps.toDouble())),
      (Icons.timer_outlined, AppColors.onSurfaceVariant, 'ETA',
          d.etaMs == null ? '—' : formatDuration(d.etaMs!)),
      (Icons.layers_rounded, AppColors.secondary, 'Chunks',
          '${d.activeChunks}/${d.totalChunks}'),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: AppSpacing.sm,
      mainAxisSpacing: AppSpacing.sm,
      childAspectRatio: 2.2,
      children: items
          .map((item) => _BentoCell(
                icon: item.$1,
                iconColor: item.$2,
                label: item.$3,
                value: item.$4,
              ))
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
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.5)),
      ),
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, size: 20, color: iconColor),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label.toUpperCase(),
                  style: AppTextStyles.labelSm.copyWith(
                      color: AppColors.onSurfaceVariant,
                      fontSize: 10,
                      letterSpacing: 0.8)),
              Text(value,
                  style: AppTextStyles.dataDisplay
                      .copyWith(color: AppColors.onSurface, fontSize: 16)),
            ],
          ),
        ],
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
          Text(label,
              style: AppTextStyles.labelSm
                  .copyWith(color: AppColors.onSurfaceVariant)),
          Text(value,
              style: AppTextStyles.dataDisplay.copyWith(color: AppColors.onSurface)),
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
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
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
                color: AppColors.primary, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(formatSpeed(speedBps),
              style: AppTextStyles.dataDisplay.copyWith(color: AppColors.primary)),
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
          horizontal: AppSpacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label,
          style: AppTextStyles.labelSm.copyWith(color: color)),
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
        Text(label,
            style: AppTextStyles.labelSm
                .copyWith(color: AppColors.onSurfaceVariant)),
      ],
    );
  }
}

class _GlowProgressBar extends StatelessWidget {
  final double? value;
  final bool active;
  final double height;

  const _GlowProgressBar({this.value, this.active = false, this.height = 8});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: LinearProgressIndicator(
        value: value,
        minHeight: height,
        backgroundColor: AppColors.surfaceDim,
        color: active ? AppColors.primary : AppColors.outline,
      ),
    );
  }
}

class _ControlButtons extends StatelessWidget {
  final DownloadVm vm;
  final DownloadService service;
  final bool dense;

  const _ControlButtons(
      {required this.vm, required this.service, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final running = vm.state == DownloadState.downloading ||
        vm.state == DownloadState.probing;
    final completed = vm.state == DownloadState.completed;

    if (dense) {
      return Row(
        children: [
          if (!completed)
            Expanded(
              child: _OutlineButton(
                icon: running ? Icons.pause_rounded : Icons.play_arrow_rounded,
                label: running ? 'Pause' : 'Resume',
                onPressed: () =>
                    running ? service.pause(vm) : service.start(vm),
              ),
            ),
          if (!completed) const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: _DangerButton(
              icon: Icons.close_rounded,
              label: 'Remove',
              onPressed: () {
                service.remove(vm);
                Navigator.of(context).pop();
              },
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        if (!completed)
          Expanded(
            child: _OutlineButton(
              icon: running ? Icons.pause_rounded : Icons.play_arrow_rounded,
              label: running ? 'Pause' : 'Resume',
              onPressed: () => running ? service.pause(vm) : service.start(vm),
            ),
          ),
        if (!completed) const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: _DangerButton(
            icon: Icons.close_rounded,
            label: 'Remove',
            onPressed: () {
              service.remove(vm);
              Navigator.of(context).pop();
            },
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: _OutlineButton(
            icon: Icons.tune_rounded,
            label: 'Speed Limit',
            onPressed: () {},
          ),
        ),
      ],
    );
  }
}

class _OutlineButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _OutlineButton(
      {required this.icon, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.onSurface,
        side: const BorderSide(color: AppColors.outlineVariant),
        backgroundColor: AppColors.surfaceContainerHigh,
        textStyle: AppTextStyles.labelSm,
        padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.sm, horizontal: AppSpacing.md),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg)),
      ),
    );
  }
}

class _DangerButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _DangerButton(
      {required this.icon, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.error,
        side: BorderSide(color: AppColors.error.withValues(alpha: 0.4)),
        backgroundColor: AppColors.error.withValues(alpha: 0.08),
        textStyle: AppTextStyles.labelSm,
        padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.sm, horizontal: AppSpacing.md),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg)),
      ),
    );
  }
}

class _DiagnosticsPanel extends StatelessWidget {
  final List<DiagnosticPayload> diags;
  const _DiagnosticsPanel({required this.diags});

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Recent Activity',
              style:
                  AppTextStyles.headlineMd.copyWith(color: AppColors.onSurface)),
          const SizedBox(height: AppSpacing.sm),
          ...diags.reversed.take(5).map((diag) => Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(_diagIcon(diag.level),
                        size: 16, color: _diagColor(diag.level)),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        '[${diag.code}] ${diag.message}',
                        style: AppTextStyles.labelSm
                            .copyWith(color: AppColors.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  IconData _diagIcon(DiagnosticLevel l) => switch (l) {
        DiagnosticLevel.error => Icons.error_outline_rounded,
        DiagnosticLevel.warn => Icons.warning_amber_rounded,
        DiagnosticLevel.info => Icons.info_outline_rounded,
      };

  Color _diagColor(DiagnosticLevel l) => switch (l) {
        DiagnosticLevel.error => AppColors.error,
        DiagnosticLevel.warn => AppColors.tertiary,
        DiagnosticLevel.info => AppColors.primary,
      };
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
