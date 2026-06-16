import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../services/download_service.dart';
import '../util/format.dart';

Future<void> showAddDownloadDialog(BuildContext context, DownloadService service) {
  return showDialog<void>(
    context: context,
    builder: (_) => _AddDownloadDialog(service: service),
  );
}

class _AddDownloadDialog extends StatefulWidget {
  final DownloadService service;
  const _AddDownloadDialog({required this.service});

  @override
  State<_AddDownloadDialog> createState() => _AddDownloadDialogState();
}

class _AddDownloadDialogState extends State<_AddDownloadDialog> {
  final _url = TextEditingController();
  final _filename = TextEditingController();
  final _chunkCount = TextEditingController();
  final _speedLimit = TextEditingController();
  ChunkMode _mode = ChunkMode.auto;
  bool _autoStart = true;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _filename.dispose();
    _chunkCount.dispose();
    _speedLimit.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _url.text.trim();
    if (url.isEmpty || Uri.tryParse(url)?.hasScheme != true) {
      setState(() => _error = 'Enter a valid URL (http/https).');
      return;
    }
    int? speedLimit;
    if (_speedLimit.text.trim().isNotEmpty) {
      speedLimit = parseSpeedLimit(_speedLimit.text);
      if (speedLimit == null) {
        setState(() => _error = 'Speed limit looks invalid (try "2M", "500k").');
        return;
      }
    }
    final options = DownloadOptions(
      filename: _filename.text.trim().isEmpty ? null : _filename.text.trim(),
      chunkMode: _mode,
      targetChunkCount: int.tryParse(_chunkCount.text.trim()),
      speedLimit: speedLimit,
    );
    widget.service.addUrl(url, options: options, autoStart: _autoStart);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add download'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _url,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  hintText: 'https://example.com/file.iso',
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Start immediately'),
                value: _autoStart,
                onChanged: (v) => setState(() => _autoStart = v),
              ),
              ExpansionPanelList.radio(
                elevation: 0,
                expandedHeaderPadding: EdgeInsets.zero,
                children: [
                  ExpansionPanelRadio(
                    value: 'adv',
                    headerBuilder: (_, _) => const ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Advanced (per-download)'),
                    ),
                    body: Column(
                      children: [
                        TextField(
                          controller: _filename,
                          decoration: const InputDecoration(
                              labelText: 'Filename (optional)'),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<ChunkMode>(
                          initialValue: _mode,
                          decoration: const InputDecoration(labelText: 'Chunk mode'),
                          items: ChunkMode.values
                              .map((m) => DropdownMenuItem(value: m, child: Text(m.name)))
                              .toList(),
                          onChanged: (m) => setState(() => _mode = m ?? ChunkMode.auto),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _chunkCount,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'Target chunk count (optional)'),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _speedLimit,
                          decoration: const InputDecoration(
                            labelText: 'Speed limit (optional)',
                            hintText: 'e.g. 2M, 500k — empty = unlimited',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }
}
