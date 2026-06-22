import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../services/download_service.dart';
import '../util/format.dart';
import '../util/palette.dart';
import 'widgets/folder_path_field.dart';
import 'widgets/key_value_editor.dart';

Future<void> showAddDownloadDialog(
  BuildContext context,
  DownloadService service, {
  String? initialUrl,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _AddDownloadDialog(service: service, initialUrl: initialUrl),
  );
}

class _AddDownloadDialog extends StatefulWidget {
  final DownloadService service;
  final String? initialUrl;
  const _AddDownloadDialog({required this.service, this.initialUrl});

  @override
  State<_AddDownloadDialog> createState() => _AddDownloadDialogState();
}

class _AddDownloadDialogState extends State<_AddDownloadDialog> {
  late final _url = TextEditingController(text: widget.initialUrl ?? '');
  final _filename = TextEditingController();
  final _targetPath = TextEditingController();
  final _description = TextEditingController();
  final _chunkCount = TextEditingController();
  final _speedLimit = TextEditingController();
  ChunkMode _mode = ChunkMode.auto;
  bool _autoStart = true;
  bool _journal = false;
  bool _showAdvanced = false;
  String? _error;

  final _headersCtrl = KeyValueEditorController();
  final _metadataCtrl = KeyValueEditorController();

  @override
  void initState() {
    super.initState();
    _url.addListener(_onUrlChanged);
    if (widget.initialUrl != null) _prefillFilenameIfHls(widget.initialUrl!);
  }

  void _onUrlChanged() => _prefillFilenameIfHls(_url.text.trim());

  void _prefillFilenameIfHls(String url) {
    if (!_isHlsUrl(url)) return;
    if (_filename.text.isNotEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final segment = uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
    final stem = segment.contains('.') ? segment.substring(0, segment.lastIndexOf('.')) : segment;
    if (stem.isNotEmpty) _filename.text = '$stem.mp4';
  }

  static bool _isHlsUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') || lower.contains('application/x-mpegurl');
  }

  @override
  void dispose() {
    _url.removeListener(_onUrlChanged);
    _url.dispose();
    _filename.dispose();
    _targetPath.dispose();
    _description.dispose();
    _chunkCount.dispose();
    _speedLimit.dispose();
    _headersCtrl.dispose();
    _metadataCtrl.dispose();
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
    final headers = _headersCtrl.read();
    final metadata = _metadataCtrl.read();
    final options = DownloadOptions(
      filename: _filename.text.trim().isEmpty ? null : _filename.text.trim(),
      targetPath: _targetPath.text.trim().isEmpty ? null : _targetPath.text.trim(),
      description: _description.text.trim().isEmpty ? null : _description.text.trim(),
      chunkMode: _mode,
      targetChunkCount: int.tryParse(_chunkCount.text.trim()),
      speedLimit: speedLimit,
      journal: _journal ? true : null,
      headers: headers.isEmpty ? null : headers,
      metadata: metadata.isEmpty ? null : metadata,
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
                style: AppTextStyles.dataDisplay,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  hintText: 'https://example.com/file.iso',
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: AppSpacing.xs),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Start immediately'),
                value: _autoStart,
                onChanged: (v) => setState(() => _autoStart = v),
              ),
              InkWell(
                onTap: () => setState(() => _showAdvanced = !_showAdvanced),
                borderRadius: BorderRadius.circular(AppRadius.def),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: AppSpacing.sm,
                    horizontal: AppSpacing.md,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Advanced (per-download)',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      Icon(
                        _showAdvanced ? Icons.expand_less : Icons.expand_more,
                        color: AppColors.onSurfaceVariant,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
              if (_showAdvanced) ...[
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _filename,
                  decoration: const InputDecoration(
                    labelText: 'Filename (optional)',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                FolderPathField(
                  controller: _targetPath,
                  label: 'Save to folder (optional)',
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _description,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                DropdownMenu<ChunkMode>(
                  initialSelection: _mode,
                  label: const Text('Chunk mode'),
                  expandedInsets: EdgeInsets.zero,
                  onSelected: (m) => setState(() => _mode = m ?? ChunkMode.auto),
                  dropdownMenuEntries: ChunkMode.values
                      .map((m) => DropdownMenuEntry(value: m, label: m.name))
                      .toList(),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _chunkCount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Target chunk count (optional)',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _speedLimit,
                  decoration: const InputDecoration(
                    labelText: 'Speed limit (optional)',
                    hintText: 'e.g. 2M, 500k — empty = unlimited',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Write diagnostic journal'),
                  value: _journal,
                  onChanged: (v) => setState(() => _journal = v),
                ),
                const SizedBox(height: AppSpacing.md),
                KeyValueEditor(
                  controller: _headersCtrl,
                  label: 'HTTP Headers',
                  keyHint: 'Header name',
                  valueHint: 'Value',
                ),
                const SizedBox(height: AppSpacing.md),
                KeyValueEditor(
                  controller: _metadataCtrl,
                  label: 'Metadata',
                  keyHint: 'Key',
                  valueHint: 'Value',
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.base),
                  child: Text(_error!, style: const TextStyle(color: AppColors.error)),
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
