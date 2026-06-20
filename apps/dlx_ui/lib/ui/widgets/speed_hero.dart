import 'package:flutter/material.dart';

import '../../util/format.dart';
import '../../util/palette.dart';

/// Global speed hero — desktop shows large headline + bar chart area,
/// mobile shows headline + mini SVG-style line chart.
class SpeedHero extends StatelessWidget {
  final double speedBps;
  final int activeCount;
  final int queuedCount;
  final VoidCallback? onResumeAll;

  const SpeedHero({
    super.key,
    required this.speedBps,
    required this.activeCount,
    this.queuedCount = 0,
    this.onResumeAll,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isDesktop = width >= 768;
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
          // Subtle gradient overlay
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
                borderRadius: BorderRadius.circular(AppRadius.xl),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          formatSpeed(w.speedBps),
                          style: AppTextStyles.headlineLg.copyWith(color: AppColors.onSurface),
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
              const _BarChartPlaceholder(),
            ],
          ),
        ],
      ),
    );
  }
}

class _BarChartPlaceholder extends StatelessWidget {
  const _BarChartPlaceholder();

  static const _heights = [0.30, 0.45, 0.60, 0.50, 0.75, 0.90, 0.85, 0.65, 0.95, 1.0];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(_heights.length, (i) {
          final frac = _heights[i];
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Container(
                height: 96 * frac,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.2 + frac * 0.8),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.sm)),
                  boxShadow: i == _heights.length - 1
                      ? [BoxShadow(color: AppColors.primary.withValues(alpha: 0.5), blurRadius: 10)]
                      : null,
                ),
              ),
            ),
          );
        }),
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
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
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
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Stack(
        children: [
          // Glow blob top-right
          Positioned(
            top: -48,
            right: -48,
            child: Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Global Download Speed',
                        style: AppTextStyles.labelSm
                            .copyWith(color: AppColors.onSurfaceVariant, letterSpacing: 0.8)),
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
                          style: AppTextStyles.dataDisplay
                              .copyWith(color: AppColors.primary.withValues(alpha: 0.7)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              const _MiniLineChart(),
            ],
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

class _MiniLineChart extends StatelessWidget {
  const _MiniLineChart();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 64,
      child: CustomPaint(painter: _LineChartPainter()),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  // Normalized y values (0=bottom, 1=top) matching the HTML SVG path
  static const _pts = [
    Offset(0.00, 0.40),
    Offset(0.25, 0.80),
    Offset(0.50, 0.30),
    Offset(0.75, 0.70),
    Offset(0.875, 0.90),
    Offset(1.00, 1.00),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    final fill = Path();

    Offset pt(Offset n) => Offset(n.dx * size.width, size.height - n.dy * size.height);

    path.moveTo(pt(_pts.first).dx, pt(_pts.first).dy);
    for (var i = 1; i < _pts.length; i++) {
      final p0 = pt(_pts[i - 1]);
      final p1 = pt(_pts[i]);
      final cx = (p0.dx + p1.dx) / 2;
      path.cubicTo(cx, p0.dy, cx, p1.dy, p1.dx, p1.dy);
    }

    fill.addPath(path, Offset.zero);
    fill.lineTo(size.width, size.height);
    fill.lineTo(0, size.height);
    fill.close();

    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        AppColors.primary.withValues(alpha: 0.3),
        AppColors.primary.withValues(alpha: 0.0),
      ],
    ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    canvas.drawPath(fill, Paint()..shader = gradient);
    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
