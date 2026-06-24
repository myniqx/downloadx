import 'package:flutter/material.dart';

import '../../../util/palette.dart';

enum DlxCardLayout { content, iconLead }

class DlxCard extends StatefulWidget {
  final Widget child;
  final DlxCardLayout layout;
  final VoidCallback? onTap;

  // content layout
  final String? title;
  final IconData? titleIcon;
  final Color? titleIconColor;
  final String? description;

  // iconLead layout
  final Widget? leadIcon;

  const DlxCard({
    super.key,
    required this.child,
    this.layout = DlxCardLayout.content,
    this.onTap,
    this.title,
    this.titleIcon,
    this.titleIconColor,
    this.description,
    this.leadIcon,
  });

  @override
  State<DlxCard> createState() => _DlxCardState();
}

class _DlxCardState extends State<DlxCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final interactive = widget.onTap != null;
    final body = widget.layout == DlxCardLayout.iconLead
        ? _iconLeadLayout()
        : _contentLayout();

    final card = MouseRegion(
      onEnter: interactive ? (_) => setState(() => _hovered = true) : null,
      onExit: interactive ? (_) => setState(() => _hovered = false) : null,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: (interactive && _hovered
                    ? AppColors.surfaceContainerHigh
                    : AppColors.surfaceContainer)
                .withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(
              color: interactive && _hovered
                  ? AppColors.outline
                  : AppColors.outlineVariant,
            ),
          ),
          padding: const EdgeInsets.all(AppSpacing.md),
          child: body,
        ),
      ),
    );

    return card;
  }

  Widget _contentLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.title != null) ...[
          _ContentHeader(
            title: widget.title!,
            icon: widget.titleIcon,
            iconColor: widget.titleIconColor,
            description: widget.description,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        widget.child,
      ],
    );
  }

  Widget _iconLeadLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.leadIcon != null) ...[
          widget.leadIcon!,
          const SizedBox(width: AppSpacing.md),
        ],
        Expanded(child: widget.child),
      ],
    );
  }
}

class _ContentHeader extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Color? iconColor;
  final String? description;

  const _ContentHeader({
    required this.title,
    this.icon,
    this.iconColor,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: iconColor ?? AppColors.onSurface),
          const SizedBox(width: AppSpacing.xs),
        ],
        Text(
          title,
          style: AppTextStyles.headlineMd.copyWith(color: AppColors.onSurface),
        ),
        const Spacer(),
        if (description != null)
          Text(
            description!,
            style: AppTextStyles.labelSm.copyWith(color: AppColors.onSurfaceVariant),
          ),
      ],
    );
  }
}
