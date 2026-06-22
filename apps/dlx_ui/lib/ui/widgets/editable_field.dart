import 'package:flutter/material.dart';

import '../../util/palette.dart';
import 'field.dart';

class EditableField extends StatefulWidget {
  final String? label;
  final IconData? icon;
  final Widget Function() viewBuilder;
  final Widget Function(VoidCallback confirm, VoidCallback cancel) editBuilder;

  const EditableField({
    super.key,
    this.label,
    this.icon,
    required this.viewBuilder,
    required this.editBuilder,
  });

  @override
  State<EditableField> createState() => _EditableFieldState();
}

class _EditableFieldState extends State<EditableField> {
  bool _editing = false;

  void _confirm() => setState(() => _editing = false);
  void _cancel() => setState(() => _editing = false);

  @override
  Widget build(BuildContext context) {
    final child = _editing
        ? widget.editBuilder(_confirm, _cancel)
        : Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: widget.viewBuilder()),
              const SizedBox(width: AppSpacing.xs),
              IconButton(
                icon: const Icon(Icons.edit_rounded, size: 16),
                color: AppColors.onSurfaceVariant,
                tooltip: 'Edit',
                onPressed: () => setState(() => _editing = true),
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
              ),
            ],
          );

    if (widget.label != null) {
      return Field(label: widget.label!, icon: widget.icon, child: child);
    }

    return child;
  }
}
