import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../services/download_service.dart';
import '../util/format.dart';
import '../util/palette.dart';
import 'widgets/folder_path_field.dart';
import 'widgets/key_value_editor.dart';
import 'widgets/slider_number_field.dart';

Future<void> showAddDownloadDialog(
  BuildContext context,
  DownloadService service, {
  String? initialUrl,
  DownloadOptions? initialOptions,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _AddDownloadDialog(
      service: service,
      initialUrl: initialUrl,
      initialOptions: initialOptions,
    ),
  );
}

class _AddDownloadDialog extends StatefulWidget {
  final DownloadService service;
  final String? initialUrl;
  final DownloadOptions? initialOptions;

  const _AddDownloadDialog({
    required this.service,
    this.initialUrl,
    this.initialOptions,
  });

  @override
  State<_AddDownloadDialog> createState() => _AddDownloadDialogState();
}

class _AddDownloadDialogState extends State<_AddDownloadDialog> {
  late final TextEditingController _url;
  late final TextEditingController _filename;
  late final TextEditingController _targetPath;
  late final TextEditingController _description;
  late int _chunkCount;
  late int _speedLimit;
  late ChunkMode _mode;
  late bool _autoStart;
  late bool _journal;
  bool _showAdvanced = false;
  String? _error;

  late final KeyValueEditorController _headersCtrl;
  late final KeyValueEditorController _metadataCtrl;

  static const int _maxSpeedBytes = 100 * 1024 * 1024;
  static const int _speedStep = 256 * 1024;
  static const int _maxChunks = 32;

  DownloadOptions? get _opts => widget.initialOptions;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.initialUrl ?? '');
    _filename = TextEditingController(text: _opts?.filename ?? '');
    _targetPath = TextEditingController(text: _opts?.targetPath ?? '');
    _description = TextEditingController(text: _opts?.description ?? '');
    _chunkCount = _opts?.targetChunkCount ?? 4;
    _speedLimit = _opts?.speedLimit ?? 0;
    _mode = _opts?.chunkMode ?? ChunkMode.auto;
    _autoStart = _opts?.autoStart ?? true;
    _journal = _opts?.journal ?? false;
    _headersCtrl = KeyValueEditorController();
    _metadataCtrl = KeyValueEditorController();

    _url.addListener(_onUrlChanged);
    if (widget.initialUrl != null) _prefillFilenameIfHls(widget.initialUrl!);

    if (_opts != null && _hasAnyAdvanced(_opts!)) _showAdvanced = true;
  }

  static bool _hasAnyAdvanced(DownloadOptions o) =>
      o.filename != null ||
      o.targetPath != null ||
      o.description != null ||
      o.chunkMode != null ||
      o.targetChunkCount != null ||
      o.speedLimit != null ||
      o.journal != null ||
      (o.headers?.isNotEmpty ?? false) ||
      (o.metadata?.isNotEmpty ?? false);

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
    final headers = _headersCtrl.read();
    final metadata = _metadataCtrl.read();
    final options = DownloadOptions(
      filename: _filename.text.trim().isEmpty ? null : _filename.text.trim(),
      targetPath: _targetPath.text.trim().isEmpty ? null : _targetPath.text.trim(),
      description: _description.text.trim().isEmpty ? null : _description.text.trim(),
      chunkMode: _mode,
      targetChunkCount: _chunkCount,
      speedLimit: _speedLimit == 0 ? null : _speedLimit,
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
                Text('Target chunk count',
                    style: AppTextStyles.bodyMd.copyWith(color: AppColors.onSurface)),
                const SizedBox(height: AppSpacing.xs),
                SliderNumberField(
                  value: _chunkCount,
                  min: 1,
                  max: _maxChunks,
                  step: 1,
                  labelBuilder: (v) => '$v',
                  onChanged: (v) => setState(() => _chunkCount = v),
                ),
                const SizedBox(height: AppSpacing.md),
                Text('Speed limit',
                    style: AppTextStyles.bodyMd.copyWith(color: AppColors.onSurface)),
                const SizedBox(height: AppSpacing.xs),
                SliderNumberField(
                  value: _speedLimit,
                  min: 0,
                  max: _maxSpeedBytes,
                  step: _speedStep,
                  labelBuilder: (v) => v == 0 ? 'Unlimited' : formatSpeedLimit(v),
                  inputParser: (s) => s.trim().toLowerCase() == 'unlimited' ? 0 : parseSpeedLimit(s),
                  onChanged: (v) => setState(() => _speedLimit = v),
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
                  initialValues: _opts?.headers,
                ),
                const SizedBox(height: AppSpacing.md),
                KeyValueEditor(
                  controller: _metadataCtrl,
                  label: 'Metadata',
                  keyHint: 'Key',
                  valueHint: 'Value',
                  initialValues: _opts?.metadata,
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
