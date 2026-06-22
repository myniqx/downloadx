import 'package:flutter/material.dart';

import '../../util/palette.dart';

class _KvEntry {
  final key = TextEditingController();
  final value = TextEditingController();

  void dispose() {
    key.dispose();
    value.dispose();
  }
}

class KeyValueEditorController {
  _KeyValueEditorState? _state;

  Map<String, String> read() => _state?._collect() ?? {};

  void dispose() {
    _state = null;
  }
}

class KeyValueEditor extends StatefulWidget {
  final String label;
  final String keyHint;
  final String valueHint;
  final KeyValueEditorController? controller;

  const KeyValueEditor({
    super.key,
    required this.label,
    this.keyHint = 'Key',
    this.valueHint = 'Value',
    this.controller,
  });

  @override
  State<KeyValueEditor> createState() => _KeyValueEditorState();
}

class _KeyValueEditorState extends State<KeyValueEditor> {
  final _entries = <_KvEntry>[_KvEntry()];

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
  }

  @override
  void dispose() {
    widget.controller?._state = null;
    for (final e in _entries) {
      e.dispose();
    }
    super.dispose();
  }

  Map<String, String> _collect() {
    final result = <String, String>{};
    for (final e in _entries) {
      final k = e.key.text.trim();
      final v = e.value.text.trim();
      if (k.isNotEmpty && v.isNotEmpty) result[k] = v;
    }
    return result;
  }

  bool _hasPartial(_KvEntry e) {
    final k = e.key.text.trim();
    final v = e.value.text.trim();
    return (k.isEmpty) != (v.isEmpty);
  }

  void _add() => setState(() => _entries.add(_KvEntry()));

  void _remove(int i) {
    setState(() {
      _entries[i].dispose();
      _entries.removeAt(i);
      if (_entries.isEmpty) _entries.add(_KvEntry());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: AppSpacing.xs),
        ...List.generate(_entries.length, (i) {
          final e = _entries[i];
          final partial = _hasPartial(e);
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: e.key,
                        decoration: InputDecoration(
                          labelText: widget.keyHint,
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: TextField(
                        controller: e.value,
                        decoration: InputDecoration(
                          labelText: widget.valueHint,
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      color: AppColors.onSurfaceVariant,
                      tooltip: 'Remove',
                      onPressed: () => _remove(i),
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
                if (partial)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(
                      'Both key and value are required.',
                      style: AppTextStyles.labelSm.copyWith(color: AppColors.error),
                    ),
                  ),
              ],
            ),
          );
        }),
        TextButton.icon(
          onPressed: _add,
          icon: const Icon(Icons.add_rounded, size: 16),
          label: const Text('Add entry'),
        ),
      ],
    );
  }
}
