import 'package:flutter/material.dart';

import '../../../util/palette.dart';
import 'folder_picker_dialog.dart';

class FolderPathField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;

  const FolderPathField({
    super.key,
    required this.controller,
    this.label = 'Folder',
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            style: AppTextStyles.dataDisplay,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        SizedBox(
          height: 48,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.folder_open_rounded, size: 16),
            label: const Text('Browse'),
            onPressed: () async {
              final current = controller.text.trim();
              final picked = await showFolderPicker(
                context,
                initialPath: current.isEmpty ? null : current,
              );
              if (picked != null) controller.text = picked;
            },
          ),
        ),
      ],
    );
  }
}
