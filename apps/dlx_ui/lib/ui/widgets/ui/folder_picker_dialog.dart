import 'dart:io';

import 'package:flutter/material.dart';

import '../../../util/palette.dart';

/// Opens a [FolderPickerDialog] and returns the selected path, or null if cancelled.
Future<String?> showFolderPicker(BuildContext context, {String? initialPath}) {
  return showDialog<String>(
    context: context,
    builder: (_) => FolderPickerDialog(initialPath: initialPath),
  );
}

class FolderPickerDialog extends StatefulWidget {
  final String? initialPath;
  const FolderPickerDialog({super.key, this.initialPath});

  @override
  State<FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<FolderPickerDialog> {
  late Directory _current;
  List<FileSystemEntity> _entries = [];
  bool _loading = true;
  bool _showHidden = false;
  String? _error;

  static String get _home =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      (Platform.isWindows ? 'C:\\' : '/');

  @override
  void initState() {
    super.initState();
    _navigate(Directory(widget.initialPath ?? _home));
  }

  Future<void> _navigate(Directory dir) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final all = await dir.list().where((e) => e is Directory).toList();
      final entries = all.where((e) {
        final name = e.path.split(Platform.pathSeparator).last;
        return _showHidden || !name.startsWith('.');
      }).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      setState(() {
        _current = dir;
        _entries = entries;
        _loading = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Cannot read directory';
        _loading = false;
      });
    }
  }

  void _goUp() {
    final parent = _current.parent;
    if (parent.path != _current.path) _navigate(parent);
  }

  void _goHome() => _navigate(Directory(_home));

  void _toggleHidden() {
    _showHidden = !_showHidden;
    _navigate(_current);
  }

  Future<void> _createFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NewFolderDialog(),
    );
    if (name == null || name.isEmpty) return;
    final newDir = Directory('${_current.path}${Platform.pathSeparator}$name');
    try {
      await newDir.create();
      await _navigate(_current);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not create folder')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final atRoot = _current.parent.path == _current.path;

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _TitleButton(
                icon: Icons.arrow_upward_rounded,
                tooltip: 'Go up',
                onPressed: atRoot ? null : _goUp,
              ),
              const SizedBox(width: AppSpacing.xs),
              _TitleButton(
                icon: Icons.home_rounded,
                tooltip: 'Home',
                onPressed: _goHome,
              ),
              const SizedBox(width: AppSpacing.xs),
              _TitleButton(
                icon: Icons.create_new_folder_rounded,
                tooltip: 'New folder',
                onPressed: _createFolder,
              ),
              const Spacer(),
              _HiddenToggle(
                value: _showHidden,
                onChanged: (_) => _toggleHidden(),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            _loading ? '...' : _current.path,
            style: AppTextStyles.dataDisplay.copyWith(color: AppColors.onSurface),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        height: 360,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Text(_error!,
                        style: AppTextStyles.bodyMd.copyWith(color: AppColors.error)),
                  )
                : _entries.isEmpty
                    ? Center(
                        child: Text(
                          _showHidden ? 'Empty folder' : 'No folders (try showing hidden)',
                          style: AppTextStyles.bodyMd
                              .copyWith(color: AppColors.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _entries.length,
                        itemBuilder: (context, i) {
                          final name =
                              _entries[i].path.split(Platform.pathSeparator).last;
                          final isHidden = name.startsWith('.');
                          return InkWell(
                            onTap: () => _navigate(Directory(_entries[i].path)),
                            borderRadius: BorderRadius.circular(AppRadius.def),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.sm,
                                vertical: AppSpacing.sm,
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.folder_rounded,
                                      size: 18,
                                      color: isHidden
                                          ? AppColors.tertiary.withValues(alpha: 0.5)
                                          : AppColors.tertiary),
                                  const SizedBox(width: AppSpacing.sm),
                                  Expanded(
                                    child: Text(
                                      name.isEmpty ? _entries[i].path : name,
                                      style: AppTextStyles.bodyMd.copyWith(
                                        color: isHidden
                                            ? AppColors.onSurfaceVariant
                                            : AppColors.onSurface,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const Icon(Icons.chevron_right_rounded,
                                      size: 16, color: AppColors.onSurfaceVariant),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_current.path),
          child: const Text('Select'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// New Folder dialog
// ---------------------------------------------------------------------------

class _NewFolderDialog extends StatefulWidget {
  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New folder'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Folder name'),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Small helper widgets
// ---------------------------------------------------------------------------

class _TitleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _TitleButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 18),
      onPressed: onPressed,
      color: onPressed != null ? AppColors.onSurfaceVariant : AppColors.outlineVariant,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      tooltip: tooltip,
    );
  }
}

class _HiddenToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _HiddenToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            value ? Icons.visibility_rounded : Icons.visibility_off_rounded,
            size: 14,
            color: value ? AppColors.primary : AppColors.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            'Hidden',
            style: AppTextStyles.labelSm.copyWith(
              color: value ? AppColors.primary : AppColors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
