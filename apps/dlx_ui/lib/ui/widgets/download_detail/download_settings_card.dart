import 'package:flutter/material.dart';

import '../../../models/download_vm.dart';
import '../../../util/format.dart';
import '../../../util/palette.dart';
import '../ui/dlx_button.dart';
import '../ui/dlx_card.dart';
import '../ui/editable_field.dart';
import '../ui/key_value_editor.dart';
import '../ui/slider_number_field.dart';

class DownloadSettingsCard extends StatefulWidget {
  final DownloadVm vm;
  const DownloadSettingsCard({super.key, required this.vm});

  @override
  State<DownloadSettingsCard> createState() => _DownloadSettingsCardState();
}

class _DownloadSettingsCardState extends State<DownloadSettingsCard> {
  static const int _maxSpeedBytes = 100 * 1024 * 1024;
  static const int _speedStep = 256 * 1024;
  static const int _maxChunks = 32;

  DownloadVm get vm => widget.vm;

  void _refresh() => vm.refresh();

  @override
  Widget build(BuildContext context) {
    final d = vm.desc;
    final dl = vm.download;
    final currentSpeed = dl.speedLimit > 0 ? dl.speedLimit.toInt() : 0;
    final currentChunks = dl.targetChunkCount.clamp(1, _maxChunks);
    final currentJournal = dl.journal;
    final currentHeaders = Map<String, String>.from(dl.headers);
    final currentMetadata = d.metadata ?? {};

    return DlxCard(
      title: 'Settings',
      titleIcon: Icons.tune_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EditableField(
            label: 'Description',
            viewBuilder: () => Text(
              d.description?.isNotEmpty == true ? d.description! : '—',
              style: AppTextStyles.bodyMd.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            editBuilder: (confirm, cancel) {
              final ctrl = TextEditingController(text: d.description ?? '');
              return _InlineTextEdit(
                controller: ctrl,
                onConfirm: () {
                  dl.setDescription(
                    ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
                  );
                  _refresh();
                  confirm();
                },
                onCancel: cancel,
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),

          EditableField(
            label: 'Speed limit',
            viewBuilder: () => Text(
              currentSpeed == 0 ? 'Unlimited' : formatSpeedLimit(currentSpeed),
              style: AppTextStyles.bodyMd.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
            editBuilder: (confirm, cancel) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Speed limit',
                  style: AppTextStyles.bodyMd.copyWith(color: AppColors.onSurface),
                ),
                const SizedBox(height: AppSpacing.xs),
                SliderNumberField(
                  value: currentSpeed,
                  min: 0,
                  max: _maxSpeedBytes,
                  step: _speedStep,
                  labelBuilder: (v) => v == 0 ? 'Unlimited' : formatSpeedLimit(v),
                  inputParser: (s) => s.trim().toLowerCase() == 'unlimited'
                      ? 0
                      : parseSpeedLimit(s),
                  onChanged: (v) {
                    dl.setSpeedLimit(v == 0 ? null : v);
                    _refresh();
                  },
                ),
                const SizedBox(height: AppSpacing.xs),
                Align(
                  alignment: Alignment.centerRight,
                  child: DlxButton(
                    label: 'Done',
                    onPressed: confirm,
                    variant: DlxButtonVariant.ghost,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          EditableField(
            label: 'Target chunk count',
            viewBuilder: () => Text(
              '$currentChunks',
              style: AppTextStyles.bodyMd.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
            editBuilder: (confirm, cancel) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Target chunk count',
                  style: AppTextStyles.bodyMd.copyWith(color: AppColors.onSurface),
                ),
                const SizedBox(height: AppSpacing.xs),
                SliderNumberField(
                  value: currentChunks,
                  min: 1,
                  max: _maxChunks,
                  step: 1,
                  labelBuilder: (v) => '$v',
                  onChanged: (v) {
                    dl.setTargetChunkCount(v);
                    _refresh();
                  },
                ),
                const SizedBox(height: AppSpacing.xs),
                Align(
                  alignment: Alignment.centerRight,
                  child: DlxButton(
                    label: 'Done',
                    onPressed: confirm,
                    variant: DlxButtonVariant.ghost,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          EditableField(
            label: 'Write diagnostic journal',
            viewBuilder: () => Text(
              currentJournal ? 'Enabled' : 'Disabled',
              style: AppTextStyles.bodyMd.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
            editBuilder: (confirm, cancel) => Row(
              children: [
                Expanded(
                  child: Text(
                    'Write diagnostic journal',
                    style: AppTextStyles.bodyMd.copyWith(color: AppColors.onSurface),
                  ),
                ),
                Switch(
                  value: currentJournal,
                  onChanged: (v) {
                    dl.setJournal(v);
                    _refresh();
                    confirm();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          EditableField(
            label: 'HTTP Headers',
            viewBuilder: () => Text(
              currentHeaders.isEmpty
                  ? 'none'
                  : '${currentHeaders.length} entries',
              style: AppTextStyles.bodyMd.copyWith(
                color: currentHeaders.isEmpty
                    ? AppColors.outlineVariant
                    : AppColors.onSurfaceVariant,
              ),
            ),
            editBuilder: (confirm, cancel) {
              final ctrl = KeyValueEditorController();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  KeyValueEditor(
                    controller: ctrl,
                    label: 'HTTP Headers',
                    keyHint: 'Header name',
                    valueHint: 'Value',
                    initialValues: currentHeaders,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      DlxButton(
                        label: 'Cancel',
                        onPressed: cancel,
                        variant: DlxButtonVariant.ghost,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      DlxButton(
                        label: 'Confirm',
                        onPressed: () {
                          final newMap = ctrl.read();
                          dl.clearHeaders();
                          if (newMap.isNotEmpty)
                            dl.setHeaders(newMap.map((k, v) => MapEntry(k, v)));
                          _refresh();
                          confirm();
                        },
                        variant: DlxButtonVariant.filled,
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),

          EditableField(
            label: 'Metadata',
            viewBuilder: () => Text(
              currentMetadata.isEmpty
                  ? 'none'
                  : '${currentMetadata.length} entries',
              style: AppTextStyles.bodyMd.copyWith(
                color: currentMetadata.isEmpty
                    ? AppColors.outlineVariant
                    : AppColors.onSurfaceVariant,
              ),
            ),
            editBuilder: (confirm, cancel) {
              final ctrl = KeyValueEditorController();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  KeyValueEditor(
                    controller: ctrl,
                    label: 'Metadata',
                    keyHint: 'Key',
                    valueHint: 'Value',
                    initialValues: currentMetadata,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      DlxButton(
                        label: 'Cancel',
                        onPressed: cancel,
                        variant: DlxButtonVariant.ghost,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      DlxButton(
                        label: 'Confirm',
                        onPressed: () {
                          final newMap = ctrl.read();
                          dl.clearMetadata();
                          if (newMap.isNotEmpty)
                            dl.setMetadata(newMap.map((k, v) => MapEntry(k, v)));
                          _refresh();
                          confirm();
                        },
                        variant: DlxButtonVariant.filled,
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _InlineTextEdit extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _InlineTextEdit({
    required this.controller,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(isDense: true),
            onSubmitted: (_) => onConfirm(),
          ),
        ),
        DlxButton(
          icon: Icons.check_rounded,
          tooltip: 'Confirm',
          onPressed: onConfirm,
          variant: DlxButtonVariant.ghost,
          shape: DlxButtonShape.circle,
          size: DlxButtonSize.sm,
        ),
        DlxButton(
          icon: Icons.close_rounded,
          tooltip: 'Cancel',
          onPressed: onCancel,
          variant: DlxButtonVariant.ghost,
          shape: DlxButtonShape.circle,
          size: DlxButtonSize.sm,
        ),
      ],
    );
  }
}

