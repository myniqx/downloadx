import 'package:flutter/material.dart';

import '../../util/palette.dart';

enum DlxButtonVariant { filled, outline, ghost, danger }

enum DlxButtonSize { sm, md, lg }

enum DlxButtonShape { rect, pill, circle }

class DlxButton extends StatelessWidget {
  final IconData? icon;
  final String? label;
  final String? tooltip;
  final VoidCallback? onPressed;
  final DlxButtonVariant variant;
  final DlxButtonSize size;
  final DlxButtonShape shape;
  final bool disabled;

  const DlxButton({
    super.key,
    this.icon,
    this.label,
    this.tooltip,
    this.onPressed,
    this.variant = DlxButtonVariant.outline,
    this.size = DlxButtonSize.md,
    this.shape = DlxButtonShape.rect,
    this.disabled = false,
  }) : assert(icon != null || label != null, 'icon veya label gerekli');

  @override
  Widget build(BuildContext context) {
    final colors = _resolveColors();
    final dims = _resolveDims();
    final radius = _resolveRadius(dims.height);
    final effectiveOnPressed = disabled ? null : onPressed;

    Widget child;

    if (shape == DlxButtonShape.circle) {
      child = Tooltip(
        message: tooltip ?? label ?? '',
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: effectiveOnPressed,
            hoverColor: colors.hoverColor,
            child: Opacity(
              opacity: disabled ? 0.4 : 1.0,
              child: Container(
                width: dims.height,
                height: dims.height,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.background,
                  border: colors.border != null
                      ? Border.all(color: colors.border!)
                      : null,
                ),
                child: icon != null
                    ? Icon(icon, size: dims.iconSize, color: colors.foreground)
                    : null,
              ),
            ),
          ),
        ),
      );
    } else {
      final hasIcon = icon != null;
      final hasLabel = label != null && label!.isNotEmpty;

      Widget content = hasIcon && hasLabel
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: dims.iconSize, color: colors.foreground),
                SizedBox(width: AppSpacing.xs),
                Text(label!, style: dims.textStyle.copyWith(color: colors.foreground)),
              ],
            )
          : hasIcon
              ? Icon(icon, size: dims.iconSize, color: colors.foreground)
              : Text(label!, style: dims.textStyle.copyWith(color: colors.foreground));

      child = Tooltip(
        message: tooltip ?? '',
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(radius),
          child: InkWell(
            onTap: effectiveOnPressed,
            borderRadius: BorderRadius.circular(radius),
            hoverColor: colors.hoverColor,
            child: Opacity(
              opacity: disabled ? 0.4 : 1.0,
              child: Container(
                padding: dims.padding,
                decoration: BoxDecoration(
                  color: colors.background,
                  borderRadius: BorderRadius.circular(radius),
                  border: colors.border != null
                      ? Border.all(color: colors.border!)
                      : null,
                ),
                child: content,
              ),
            ),
          ),
        ),
      );
    }

    return child;
  }

  _ButtonColors _resolveColors() {
    return switch (variant) {
      DlxButtonVariant.filled => _ButtonColors(
          foreground: AppColors.onPrimary,
          background: AppColors.primary,
          border: null,
          hoverColor: AppColors.primary.withValues(alpha: 0.12),
        ),
      DlxButtonVariant.outline => _ButtonColors(
          foreground: AppColors.onSurface,
          background: AppColors.surfaceContainerHigh,
          border: AppColors.outlineVariant,
          hoverColor: AppColors.surfaceContainerHigh.withValues(alpha: 0.5),
        ),
      DlxButtonVariant.ghost => _ButtonColors(
          foreground: AppColors.onSurfaceVariant,
          background: Colors.transparent,
          border: null,
          hoverColor: AppColors.surfaceContainerHigh.withValues(alpha: 0.5),
        ),
      DlxButtonVariant.danger => _ButtonColors(
          foreground: AppColors.error,
          background: AppColors.error.withValues(alpha: 0.08),
          border: AppColors.error.withValues(alpha: 0.4),
          hoverColor: AppColors.errorContainer.withValues(alpha: 0.2),
        ),
    };
  }

  _ButtonDims _resolveDims() {
    return switch (size) {
      DlxButtonSize.sm => _ButtonDims(
          height: 28,
          iconSize: 14,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: 4),
          textStyle: AppTextStyles.labelSm,
        ),
      DlxButtonSize.md => _ButtonDims(
          height: 32,
          iconSize: 18,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
          textStyle: AppTextStyles.labelSm,
        ),
      DlxButtonSize.lg => _ButtonDims(
          height: 40,
          iconSize: 18,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          textStyle: AppTextStyles.bodyMd,
        ),
    };
  }

  double _resolveRadius(double height) {
    return switch (shape) {
      DlxButtonShape.rect => AppRadius.lg,
      DlxButtonShape.pill => AppRadius.full,
      DlxButtonShape.circle => height / 2,
    };
  }
}

class _ButtonColors {
  final Color foreground;
  final Color background;
  final Color? border;
  final Color hoverColor;

  const _ButtonColors({
    required this.foreground,
    required this.background,
    required this.border,
    required this.hoverColor,
  });
}

class _ButtonDims {
  final double height;
  final double iconSize;
  final EdgeInsets padding;
  final TextStyle textStyle;

  const _ButtonDims({
    required this.height,
    required this.iconSize,
    required this.padding,
    required this.textStyle,
  });
}
