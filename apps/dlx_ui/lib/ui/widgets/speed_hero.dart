import 'package:flutter/material.dart';

import '../../services/speed_history.dart';
import '../../util/format.dart';
import '../../util/palette.dart';
import 'stacked_speed_chart.dart';

/// Global speed hero — desktop: large headline + stacked chart,
/// mobile: headline + mini stacked chart side by side.
class SpeedHero extends StatelessWidget {
  final double speedBps;
  final int activeCount;
  final int queuedCount;
  final VoidCallback? onResumeAll;
  final SpeedHistory history;
  final List<String> seriesOrder;
  final Color Function(String id) colorOf;

  const SpeedHero({
    super.key,
    required this.speedBps,
    required this.activeCount,
    required this.history,
    required this.seriesOrder,
    required this.colorOf,
    this.queuedCount = 0,
    this.onResumeAll,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isDesktop = width >= kBreakpointMd;
    return isDesktop ? _DesktopHero(this) : _MobileHero(this);
  }
}

// ---------------------------------------------------------------------------
// Desktop hero
// ---------------------------------------------------------------------------

class _DesktopHero extends StatelessWidget {
  final SpeedHero w;
  const _DesktopHero(this.w);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: AppColors.outlineVariant),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.primaryContainer.withValues(alpha: 0.08),
                    Colors.transparent,
                  ],
                ),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(AppRadius.xl),
                  topRight: Radius.circular(AppRadius.xl),
                  bottomRight: Radius.circular(AppRadius.xl),
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: AppSpacing.sm,
                        top: AppSpacing.sm,
                      ),
                      child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          formatSpeed(w.speedBps),
                          style: AppTextStyles.headlineLg
                              .copyWith(color: AppColors.onSurface),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Row(
                          children: [
                            const Icon(Icons.arrow_downward_rounded,
                                size: 14, color: AppColors.secondary),
                            const SizedBox(width: AppSpacing.xs),
                            Text('Global Download Speed',
                                style: AppTextStyles.bodyMd
                                    .copyWith(color: AppColors.onSurfaceVariant)),
                          ],
                        ),
                      ],
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('${w.activeCount} Active',
                              style: AppTextStyles.dataDisplay
                                  .copyWith(color: AppColors.onSurface)),
                          const SizedBox(height: 2),
                          Text('${w.queuedCount} Queued',
                              style: AppTextStyles.labelSm
                                  .copyWith(color: AppColors.onSurfaceVariant)),
                        ],
                      ),
                      const SizedBox(width: AppSpacing.md),
                      _ResumeAllButton(onTap: w.onResumeAll),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              StackedSpeedChart(
                frames: w.history.frames,
                limits: w.history.limits,
                seriesOrder: w.seriesOrder,
                colorOf: w.colorOf,
                height: 96,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ResumeAllButton extends StatelessWidget {
  final VoidCallback? onTap;
  const _ResumeAllButton({this.onTap});

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.play_arrow_rounded, size: 18),
      label: const Text('Resume All'),
      style: FilledButton.styleFrom(
        textStyle: AppTextStyles.labelSm,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile hero
// ---------------------------------------------------------------------------

class _MobileHero extends StatelessWidget {
  final SpeedHero w;
  const _MobileHero(this.w);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: AppColors.outlineVariant),
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        children: [
          // Full-width chart at the bottom
          Positioned.fill(
            child: StackedSpeedChart(
              frames: w.history.frames,
              limits: w.history.limits,
              seriesOrder: w.seriesOrder,
              colorOf: w.colorOf,
              height: null,
            ),
          ),
          // Gradient overlay so text stays readable
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.surfaceContainerHigh.withValues(alpha: 0.75),
                    AppColors.surfaceContainerHigh.withValues(alpha: 0.1),
                  ],
                ),
              ),
            ),
          ),
          // Text overlay
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Global Download Speed',
                  style: AppTextStyles.labelSm.copyWith(
                    color: AppColors.onSurfaceVariant,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      _speedValue(w.speedBps),
                      style: AppTextStyles.headlineLgMobile
                          .copyWith(color: AppColors.primary),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      _speedUnit(w.speedBps),
                      style: AppTextStyles.dataDisplay.copyWith(
                          color: AppColors.primary.withValues(alpha: 0.7)),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg + 48),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _speedValue(double bps) {
    if (bps >= 1e9) return (bps / 1e9).toStringAsFixed(1);
    if (bps >= 1e6) return (bps / 1e6).toStringAsFixed(1);
    if (bps >= 1e3) return (bps / 1e3).toStringAsFixed(1);
    return bps.toStringAsFixed(0);
  }

  static String _speedUnit(double bps) {
    if (bps >= 1e9) return 'GB/s';
    if (bps >= 1e6) return 'MB/s';
    if (bps >= 1e3) return 'KB/s';
    return 'B/s';
  }
}

