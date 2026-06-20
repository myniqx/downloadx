import 'package:flutter/material.dart';

import '../services/download_service.dart';
import '../services/settings_store.dart';
import '../util/format.dart';

/// Global configuration — the GUI counterpart of the CLI's `set` command.
class SettingsScreen extends StatefulWidget {
  final DownloadService service;
  const SettingsScreen({super.key, required this.service});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late GlobalSettings _s;
  late final TextEditingController _targetPath;
  late final TextEditingController _speedLimit;

  @override
  void initState() {
    super.initState();
    _s = widget.service.settings.copy();
    _targetPath = TextEditingController(text: _s.targetPath);
    _speedLimit = TextEditingController(
        text: _s.speedLimit == 0 ? '' : formatBytes(_s.speedLimit));
  }

  @override
  void dispose() {
    _targetPath.dispose();
    _speedLimit.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    _s.targetPath = _targetPath.text.trim();
    _s.speedLimit = _speedLimit.text.trim().isEmpty ? 0 : (parseSpeedLimit(_speedLimit.text) ?? 0);
    await widget.service.applySettings(_s);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _targetPath,
            decoration: const InputDecoration(
              labelText: 'Download folder',
              prefixIcon: Icon(Icons.folder_outlined),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _speedLimit,
            decoration: const InputDecoration(
              labelText: 'Global speed limit',
              hintText: 'e.g. 5M — empty = unlimited',
              prefixIcon: Icon(Icons.speed),
            ),
          ),
          const SizedBox(height: 8),
          _stepper('Max parallel downloads', _s.maxParallel, 1, 16,
              (v) => setState(() => _s.maxParallel = v)),
          _stepper('Target chunk count', _s.targetChunkCount, 1, 32,
              (v) => setState(() => _s.targetChunkCount = v)),
          _stepper('Max retries', _s.maxRetries, 0, 20,
              (v) => setState(() => _s.maxRetries = v)),
          _slider(
            'Min chunk size',
            _s.minChunkSize.toDouble(),
            64 * 1024,
            16 * 1024 * 1024,
            formatBytes(_s.minChunkSize),
            (v) => setState(() => _s.minChunkSize = v.round()),
          ),
          _slider(
            'Request idle timeout',
            _s.requestTimeout.toDouble(),
            5000,
            120000,
            formatDuration(_s.requestTimeout),
            (v) => setState(() => _s.requestTimeout = v.round()),
          ),
          SwitchListTile(
            title: const Text('NDJSON journal'),
            subtitle: const Text('Write a diagnostic log next to each download'),
            value: _s.journal,
            onChanged: (v) => setState(() => _s.journal = v),
          ),
        ],
      ),
    );
  }

  Widget _stepper(String label, int value, int min, int max, ValueChanged<int> onChanged) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: value > min ? () => onChanged(value - 1) : null,
          ),
          SizedBox(width: 32, child: Text('$value', textAlign: TextAlign.center)),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: value < max ? () => onChanged(value + 1) : null,
          ),
        ],
      ),
    );
  }

  Widget _slider(String label, double value, double min, double max, String display,
      ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [Text(label), Text(display, style: Theme.of(context).textTheme.bodySmall)],
          ),
        ),
        Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged),
      ],
    );
  }
}
