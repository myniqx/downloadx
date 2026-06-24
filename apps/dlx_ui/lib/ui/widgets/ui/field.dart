import 'package:flutter/material.dart';

import '../../../util/palette.dart';

class Field extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Widget child;

  const Field({
    super.key,
    required this.label,
    required this.child,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: AppColors.onSurfaceVariant),
              const SizedBox(width: AppSpacing.xs),
            ],
            Text(
              label,
              style: AppTextStyles.bodyMd.copyWith(
                color: AppColors.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Padding(
          padding: const EdgeInsets.only(left: AppSpacing.sm),
          child: child,
        ),
      ],
    );
  }
}
