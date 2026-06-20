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
      builder: (context, _) {
        final state = vm.state;
        final d = vm.desc;

        return switch (state) {
          DownloadState.downloading => _ActiveCard(
              d: d, onPause: onPause, onRemove: onRemove, onTap: onTap),
          DownloadState.paused => _PausedCard(
              d: d, onStart: onStart, onRemove: onRemove, onTap: onTap),
          DownloadState.probing => _ProbingCard(
              d: d, onRemove: onRemove, onTap: onTap),
          DownloadState.completed => _CompletedCard(
              d: d, onRemove: onRemove, onTap: onTap),
          DownloadState.error => _ErrorCard(
              d: d, onStart: onStart, onRemove: onRemove, onTap: onTap),
          _ => _PausedCard(
              d: d, onStart: onStart, onRemove: onRemove, onTap: onTap),
        };
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Active card
// ---------------------------------------------------------------------------

class _ActiveCard extends StatelessWidget {
  final DownloadDescription d;
  final VoidCallback onPause;
  final VoidCallback onRemove;
  final VoidCallback onTap;

  const _ActiveCard({
    required this.d,
    required this.onPause,
    required this.onRemove,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final frac = d.percent == null ? null : d.percent! / 100;
    return _CardShell(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FileIcon(state: DownloadState.downloading),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        d.filename ?? d.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodyLg.copyWith(color: AppColors.onSurface),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      formatSpeed(d.totalSpeedBps.toDouble()),
                      style: AppTextStyles.dataDisplay.copyWith(color: AppColors.primary),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    SizedBox(
                      width: 40,
                      child: Text(
                        formatPercent(d.percent),
                        textAlign: TextAlign.right,
                        style: AppTextStyles.dataDisplay
                            .copyWith(color: AppColors.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                _GlowProgressBar(value: frac),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Text(_sizeLabel(d),
                        style: AppTextStyles.labelSm
                            .copyWith(color: AppColors.onSurfaceVariant)),
                    const Spacer(),
                    Text(
                      d.etaMs == null ? 'ETA: --' : 'ETA: ${formatDuration(d.etaMs!)}',
                      style: AppTextStyles.labelSm
                          .copyWith(color: AppColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          _HoverActions(
            primaryIcon: Icons.pause_rounded,
            primaryTooltip: 'Pause',
            onPrimary: onPause,
            onRemove: onRemove,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Paused card
// ---------------------------------------------------------------------------

class _PausedCard extends StatelessWidget {
  final DownloadDescription d;
  final VoidCallback onStart;
  final VoidCallback onRemove;
  final VoidCallback onTap;

  const _PausedCard({
    required this.d,
    required this.onStart,
    required this.onRemove,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      onTap: onTap,
      dimmed: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FileIcon(state: DownloadState.paused),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _StatusChip(label: 'Paused', color: AppColors.tertiary),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        d.filename ?? d.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodyLg
                            .copyWith(color: AppColors.onSurfaceVariant),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      d.totalBytes == null ? '' : formatBytes(d.totalBytes!),
                      style: AppTextStyles.dataDisplay
                          .copyWith(color: AppColors.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                _FlatProgressBar(value: d.percent == null ? null : d.percent! / 100),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          _HoverActions(
            primaryIcon: Icons.play_arrow_rounded,
            primaryTooltip: 'Resume',
            onPrimary: onStart,
            onRemove: onRemove,
            primaryColor: AppColors.primary,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Probing card
// ---------------------------------------------------------------------------

class _ProbingCard extends StatelessWidget {
  final DownloadDescription d;
  final VoidCallback onRemove;
  final VoidCallback onTap;

  const _ProbingCard({required this.d, required this.onRemove, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      onTap: onTap,
      child: Row(
        children: [
          _SpinningIcon(),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  d.filename ?? d.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyMd
                      .copyWith(color: AppColors.onSurface, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text('Probing...',
                    style: AppTextStyles.labelSm
                        .copyWith(color: AppColors.onSurfaceVariant)),
              ],
            ),
          ),
          _RemoveButton(onPressed: onRemove),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Completed card
// ---------------------------------------------------------------------------

class _CompletedCard extends StatelessWidget {
  final DownloadDescription d;
  final VoidCallback onRemove;
  final VoidCallback onTap;

  const _CompletedCard({required this.d, required this.onRemove, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FileIcon(state: DownloadState.completed),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _StatusChip(label: 'Done', color: AppColors.secondary),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        d.filename ?? d.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodyLg.copyWith(color: AppColors.onSurface),
                      ),
                    ),
                    Text(
                      d.totalBytes == null ? '' : formatBytes(d.totalBytes!),
                      style: AppTextStyles.dataDisplay
                          .copyWith(color: AppColors.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                _FlatProgressBar(value: 1.0, color: AppColors.secondary),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          _RemoveButton(onPressed: onRemove),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Error card
// ---------------------------------------------------------------------------

class _ErrorCard extends StatelessWidget {
  final DownloadDescription d;
  final VoidCallback onStart;
  final VoidCallback onRemove;
  final VoidCallback onTap;

  const _ErrorCard({
    required this.d,
    required this.onStart,
    required this.onRemove,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      onTap: onTap,
      dimmed: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FileIcon(state: DownloadState.error),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _StatusChip(label: 'Error', color: AppColors.error),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        d.filename ?? d.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodyLg.copyWith(color: AppColors.onSurface),
                      ),
                    ),
                  ],
                ),
                if (d.errorMessage != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    d.errorMessage!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.labelSm.copyWith(color: AppColors.error),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          _HoverActions(
            primaryIcon: Icons.refresh_rounded,
            primaryTooltip: 'Retry',
            onPrimary: onStart,
            onRemove: onRemove,
          ),
        ],
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
  final bool dimmed;

  const _CardShell({required this.child, required this.onTap, this.dimmed = false});

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
      child: AnimatedOpacity(
        opacity: widget.dimmed ? 0.75 : 1.0,
        duration: const Duration(milliseconds: 200),
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
      ),
    );
  }
}

class _HoverState extends InheritedWidget {
  final bool hovered;
  const _HoverState({required this.hovered, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_HoverState>()?.hovered ?? false;

  @override
  bool updateShouldNotify(_HoverState old) => old.hovered != hovered;
}

class _HoverActions extends StatelessWidget {
  final IconData primaryIcon;
  final String primaryTooltip;
  final VoidCallback onPrimary;
  final VoidCallback onRemove;
  final Color primaryColor;

  const _HoverActions({
    required this.primaryIcon,
    required this.primaryTooltip,
    required this.onPrimary,
    required this.onRemove,
    this.primaryColor = AppColors.onSurfaceVariant,
  });

  @override
  Widget build(BuildContext context) {
    final hovered = _HoverState.of(context);
    return AnimatedOpacity(
      opacity: hovered ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 150),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionButton(
            icon: primaryIcon,
            tooltip: primaryTooltip,
            color: primaryColor,
            onPressed: onPrimary,
          ),
          const SizedBox(width: AppSpacing.xs),
          _RemoveButton(onPressed: onRemove),
        ],
      ),
    );
  }
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

class _FileIcon extends StatelessWidget {
  final DownloadState state;
  const _FileIcon({required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: colorForState(state).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Icon(iconForState(state), size: 24, color: colorForState(state)),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        label.toUpperCase(),
        style: AppTextStyles.labelSm.copyWith(
          color: color,
          fontSize: 10,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _GlowProgressBar extends StatelessWidget {
  final double? value;
  const _GlowProgressBar({this.value});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 8,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.full),
        child: Stack(
          children: [
            LinearProgressIndicator(
              value: value,
              minHeight: 8,
              backgroundColor: AppColors.surfaceDim,
              color: AppColors.primary,
            ),
            if (value != null)
              Positioned(
                right: (1.0 - value!) * (MediaQuery.sizeOf(context).width),
                top: 0,
                bottom: 0,
                width: 20,
                child: const _GlowEdge(),
              ),
          ],
        ),
      ),
    );
  }
}

class _GlowEdge extends StatefulWidget {
  const _GlowEdge();

  @override
  State<_GlowEdge> createState() => _GlowEdgeState();
}

class _GlowEdgeState extends State<_GlowEdge> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))
      ..repeat();
    _anim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, _) => Opacity(
        opacity: (1 - ((_anim.value - 0.5).abs() * 2)).clamp(0.0, 1.0),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.transparent, Colors.white38],
            ),
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

String _sizeLabel(DownloadDescription d) {
  if (d.totalBytes == null) return formatBytes(d.downloadedBytes);
  return '${formatBytes(d.downloadedBytes)} / ${formatBytes(d.totalBytes!)}';
}
