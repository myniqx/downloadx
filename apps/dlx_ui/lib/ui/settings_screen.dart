import 'package:flutter/material.dart';

import '../services/download_service.dart';
import '../services/settings_store.dart';
import '../util/format.dart';
import '../util/palette.dart';

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
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _s = widget.service.settings.copy();
    _targetPath = TextEditingController(text: _s.targetPath);
    _speedLimit = TextEditingController(
        text: _s.speedLimit == 0 ? '' : formatBytes(_s.speedLimit));
    _targetPath.addListener(_markDirty);
    _speedLimit.addListener(_markDirty);
  }

  @override
  void dispose() {
    _targetPath.dispose();
    _speedLimit.dispose();
    super.dispose();
  }

  void _markDirty() => setState(() => _dirty = true);

  Future<void> _apply() async {
    _s.targetPath = _targetPath.text.trim();
    _s.speedLimit =
        _speedLimit.text.trim().isEmpty ? 0 : (parseSpeedLimit(_speedLimit.text) ?? 0);
    await widget.service.applySettings(_s);
    if (mounted) setState(() => _dirty = false);
  }

  void _discard() {
    setState(() {
      _s = widget.service.settings.copy();
      _targetPath.text = _s.targetPath;
      _speedLimit.text = _s.speedLimit == 0 ? '' : formatBytes(_s.speedLimit);
      _dirty = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isDesktop = width >= kSettingsBreakpoint;

    return Scaffold(
      backgroundColor: AppColors.surfaceContainerLowest,
      body: Column(
        children: [
          Expanded(
            child: isDesktop
                ? _DesktopLayout(
                    s: _s,
                    targetPath: _targetPath,
                    speedLimit: _speedLimit,
                    onChanged: () => setState(_markDirty),
                  )
                : _MobileLayout(
                    s: _s,
                    targetPath: _targetPath,
                    speedLimit: _speedLimit,
                    onApply: _apply,
                    onChanged: () => setState(_markDirty),
                  ),
          ),
          if (isDesktop)
            _SaveBar(dirty: _dirty, onApply: _apply, onDiscard: _discard),
        ],
      ),
    );
  }
}

const double kSettingsBreakpoint = 768;

// ---------------------------------------------------------------------------
// Desktop layout — two-column
// ---------------------------------------------------------------------------

class _DesktopLayout extends StatelessWidget {
  final GlobalSettings s;
  final TextEditingController targetPath;
  final TextEditingController speedLimit;
  final VoidCallback onChanged;

  const _DesktopLayout({
    required this.s,
    required this.targetPath,
    required this.speedLimit,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.marginDesktop),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left column
          Expanded(
            child: Column(
              children: [
                _EngineSection(
                    s: s,
                    targetPath: targetPath,
                    speedLimit: speedLimit,
                    onChanged: onChanged),
                const SizedBox(height: AppSpacing.lg),
                _DirectorySection(targetPath: targetPath, onChanged: onChanged),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          // Right column
          SizedBox(
            width: 320,
            child: Column(
              children: [
                _AboutCard(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile layout — single column scroll
// ---------------------------------------------------------------------------

class _MobileLayout extends StatelessWidget {
  final GlobalSettings s;
  final TextEditingController targetPath;
  final TextEditingController speedLimit;
  final VoidCallback onApply;
  final VoidCallback onChanged;

  const _MobileLayout({
    required this.s,
    required this.targetPath,
    required this.speedLimit,
    required this.onApply,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.marginMobile,
        AppSpacing.lg,
        AppSpacing.marginMobile,
        100,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Configuration',
              style: AppTextStyles.headlineLgMobile
                  .copyWith(color: AppColors.onSurface)),
          const SizedBox(height: AppSpacing.xs),
          Text('Manage your global download preferences.',
              style:
                  AppTextStyles.bodyMd.copyWith(color: AppColors.onSurfaceVariant)),
          const SizedBox(height: AppSpacing.xl),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 8,
                child: _EngineSection(
                    s: s,
                    targetPath: targetPath,
                    speedLimit: speedLimit,
                    onChanged: onChanged),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _DirectorySection(targetPath: targetPath, onChanged: onChanged),
          const SizedBox(height: AppSpacing.lg),
          _MobileSaveCard(onApply: onApply),
          const SizedBox(height: AppSpacing.lg),
          _AboutCard(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Engine Parameters section
// ---------------------------------------------------------------------------

class _EngineSection extends StatelessWidget {
  final GlobalSettings s;
  final TextEditingController targetPath;
  final TextEditingController speedLimit;
  final VoidCallback onChanged;

  const _EngineSection({
    required this.s,
    required this.targetPath,
    required this.speedLimit,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
              icon: Icons.memory_rounded,
              iconColor: AppColors.primary,
              title: 'Engine Parameters'),
          const SizedBox(height: AppSpacing.lg),

          // Download folder
          _FieldLabel('Default Download Directory'),
          const SizedBox(height: AppSpacing.xs),
          _PathField(controller: targetPath),
          const SizedBox(height: AppSpacing.lg),

          // 2-column number grid
          _TwoCol(
            left: _NumberInputField(
              icon: Icons.layers_rounded,
              label: 'Max Concurrent Downloads',
              value: s.maxParallel,
              min: 1,
              max: 32,
              onChanged: (v) {
                s.maxParallel = v;
                onChanged();
              },
            ),
            right: _NumberInputField(
              icon: Icons.cable_rounded,
              label: 'Connections Per File',
              value: s.targetChunkCount,
              min: 1,
              max: 64,
              onChanged: (v) {
                s.targetChunkCount = v;
                onChanged();
              },
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Global speed limit
          _FieldLabel('Global Bandwidth Limit'),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Expanded(child: _PathField(controller: speedLimit, hint: 'e.g. 5M — empty = unlimited')),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),

          // Slider row
          _TwoCol(
            left: _SliderField(
              label: 'Max Retries',
              value: s.maxRetries.toDouble(),
              min: 0,
              max: 20,
              displayValue: '${s.maxRetries}',
              displayColor: AppColors.primary,
              minLabel: '0',
              maxLabel: '20',
              onChanged: (v) {
                s.maxRetries = v.round();
                onChanged();
              },
            ),
            right: _SliderField(
              label: 'Idle Timeout',
              value: s.requestTimeout.toDouble().clamp(5000, 120000),
              min: 5000,
              max: 120000,
              displayValue: formatDuration(s.requestTimeout),
              displayColor: AppColors.tertiary,
              minLabel: '5s',
              maxLabel: '120s',
              onChanged: (v) {
                s.requestTimeout = v.round();
                onChanged();
              },
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Min chunk size + journal
          _TwoCol(
            left: _DropdownField<int>(
              label: 'Minimum Chunk Size',
              value: _nearestChunkSize(s.minChunkSize),
              items: const [
                (64 * 1024, '64 KB'),
                (256 * 1024, '256 KB'),
                (1024 * 1024, '1 MB'),
                (4 * 1024 * 1024, '4 MB'),
                (8 * 1024 * 1024, '8 MB'),
                (16 * 1024 * 1024, '16 MB'),
              ],
              onChanged: (v) {
                s.minChunkSize = v;
                onChanged();
              },
            ),
            right: _ToggleField(
              label: 'NDJSON Journaling',
              subtitle: 'Log detailed download telemetry',
              value: s.journal,
              onChanged: (v) {
                s.journal = v;
                onChanged();
              },
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // Toggle row
          _ToggleRow(
            label: 'Auto-resume interrupted downloads',
            subtitle: 'Attempt to recover network drops automatically',
            value: true,
            onChanged: (_) {},
          ),
          const Divider(color: AppColors.surfaceContainerHigh, height: 1),
          _ToggleRow(
            label: 'Pre-allocate disk space',
            subtitle: 'Prevents fragmentation for large files',
            value: true,
            onChanged: (_) {},
          ),
        ],
      ),
    );
  }

  static int _nearestChunkSize(int val) {
    const opts = [
      64 * 1024, 256 * 1024, 1024 * 1024,
      4 * 1024 * 1024, 8 * 1024 * 1024, 16 * 1024 * 1024
    ];
    return opts.reduce((a, b) => (a - val).abs() < (b - val).abs() ? a : b);
  }
}

// ---------------------------------------------------------------------------
// Directory section — download folder + routing rules
// ---------------------------------------------------------------------------

class _DirectorySection extends StatefulWidget {
  final TextEditingController targetPath;
  final VoidCallback onChanged;

  const _DirectorySection({required this.targetPath, required this.onChanged});

  @override
  State<_DirectorySection> createState() => _DirectorySectionState();
}

class _DirectorySectionState extends State<_DirectorySection> {
  final List<_RoutingRule> _rules = [
    _RoutingRule(
        icon: Icons.movie_outlined,
        label: 'Video Files',
        extensions: '*.mp4, *.mkv, *.avi',
        path: '~/Videos/dlx'),
    _RoutingRule(
        icon: Icons.description_outlined,
        label: 'Documents',
        extensions: '*.pdf, *.doc, *.zip',
        path: '~/Documents/DL'),
  ];

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
              icon: Icons.folder_open_rounded,
              iconColor: AppColors.secondary,
              title: 'Directory Mapping'),
          const SizedBox(height: AppSpacing.lg),

          // Auto-routing rules table
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.surfaceContainerHigh),
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Column(
              children: [
                // Header
                Container(
                  decoration: const BoxDecoration(
                    color: AppColors.surfaceContainerHigh,
                    borderRadius: BorderRadius.vertical(
                        top: Radius.circular(AppRadius.lg)),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
                  child: Row(
                    children: [
                      Text('Auto-Routing Rules',
                          style: AppTextStyles.labelSm
                              .copyWith(color: AppColors.onSurfaceVariant)),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _addRule,
                        icon: const Icon(Icons.add_rounded, size: 14),
                        label: const Text('Add Rule'),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          textStyle: AppTextStyles.labelSm,
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.xs),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                ),
                // Rule rows
                ..._rules.asMap().entries.map((e) {
                  final i = e.key;
                  final rule = e.value;
                  return Column(
                    children: [
                      if (i > 0)
                        const Divider(
                            color: AppColors.surfaceContainerHigh, height: 1),
                      _RuleRow(
                        rule: rule,
                        onRemove: () =>
                            setState(() => _rules.removeAt(i)),
                      ),
                    ],
                  );
                }),
                if (_rules.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Text('No routing rules yet.',
                        style: AppTextStyles.labelSm
                            .copyWith(color: AppColors.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _addRule() {
    setState(() {
      _rules.add(_RoutingRule(
        icon: Icons.insert_drive_file_outlined,
        label: 'New Rule',
        extensions: '*.ext',
        path: '~/Downloads/dlx',
      ));
    });
  }
}

class _RoutingRule {
  final IconData icon;
  final String label;
  final String extensions;
  final String path;

  _RoutingRule({
    required this.icon,
    required this.label,
    required this.extensions,
    required this.path,
  });
}

class _RuleRow extends StatelessWidget {
  final _RoutingRule rule;
  final VoidCallback onRemove;

  const _RuleRow({required this.rule, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(AppRadius.def),
            ),
            child: Icon(rule.icon, size: 18, color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(rule.label,
                    style:
                        AppTextStyles.bodyMd.copyWith(color: AppColors.onSurface)),
                Text(rule.extensions,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: AppColors.onSurfaceVariant,
                    )),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(rule.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        AppTextStyles.bodyMd.copyWith(color: AppColors.onSurface)),
                GestureDetector(
                  onTap: onRemove,
                  child: Text('Remove',
                      style: AppTextStyles.labelSm
                          .copyWith(color: AppColors.error, fontSize: 10)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// About card
// ---------------------------------------------------------------------------

class _AboutCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline_rounded,
                  size: 18, color: AppColors.outline),
              const SizedBox(width: AppSpacing.xs),
              Text('About',
                  style: AppTextStyles.headlineMd
                      .copyWith(color: AppColors.onSurface)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _AboutRow(label: 'Version', value: 'v1.0.0'),
          const Divider(color: AppColors.outlineVariant, height: 16),
          _AboutRow(label: 'Engine', value: 'downloadx-dart'),
          const Divider(color: AppColors.outlineVariant, height: 16),
          _AboutRow(
              label: 'License',
              value: 'Open Source',
              valueColor: AppColors.secondary),
          const SizedBox(height: AppSpacing.md),
          Center(
            child: TextButton(
              onPressed: () {},
              child: Text('Check for Updates',
                  style: AppTextStyles.labelSm
                      .copyWith(color: AppColors.primary)),
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;

  const _AboutRow({
    required this.label,
    required this.value,
    this.valueColor = AppColors.onSurface,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: AppTextStyles.labelSm
                .copyWith(color: AppColors.onSurfaceVariant)),
        Text(value,
            style: AppTextStyles.dataDisplay.copyWith(color: valueColor)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Save bar (desktop sticky bottom)
// ---------------------------------------------------------------------------

class _SaveBar extends StatelessWidget {
  final bool dirty;
  final VoidCallback onApply;
  final VoidCallback onDiscard;

  const _SaveBar(
      {required this.dirty, required this.onApply, required this.onDiscard});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer.withValues(alpha: 0.9),
        border: const Border(top: BorderSide(color: AppColors.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.marginDesktop, vertical: AppSpacing.md),
      child: Row(
        children: [
          if (dirty) ...[
            const Icon(Icons.info_outline_rounded,
                size: 16, color: AppColors.tertiary),
            const SizedBox(width: AppSpacing.xs),
            Text('Unsaved changes',
                style: AppTextStyles.labelSm
                    .copyWith(color: AppColors.onSurfaceVariant)),
          ],
          const Spacer(),
          TextButton(
            onPressed: dirty ? onDiscard : null,
            child: Text('Discard',
                style: AppTextStyles.bodyMd.copyWith(
                    color: dirty
                        ? AppColors.onSurfaceVariant
                        : AppColors.outlineVariant)),
          ),
          const SizedBox(width: AppSpacing.md),
          FilledButton(
            onPressed: dirty ? onApply : null,
            child: const Text('Apply Settings'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile save card
// ---------------------------------------------------------------------------

class _MobileSaveCard extends StatelessWidget {
  final VoidCallback onApply;
  const _MobileSaveCard({required this.onApply});

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Column(
        children: [
          Text('Changes are applied immediately to new tasks.',
              textAlign: TextAlign.center,
              style: AppTextStyles.labelSm
                  .copyWith(color: AppColors.onSurfaceVariant)),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: onApply,
            icon: const Icon(Icons.save_rounded, size: 18),
            label: const Text('Apply Configuration'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              textStyle: AppTextStyles.labelSm,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('Reset to Defaults'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 40),
              foregroundColor: AppColors.onSurfaceVariant,
              side: const BorderSide(color: AppColors.outlineVariant),
              textStyle: AppTextStyles.labelSm,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared field widgets
// ---------------------------------------------------------------------------

class _GlassCard extends StatelessWidget {
  final Widget child;
  const _GlassCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: AppColors.outlineVariant),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: child,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;

  const _SectionHeader({
    required this.icon,
    required this.iconColor,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: AppSpacing.sm),
            Text(title,
                style: AppTextStyles.headlineMd
                    .copyWith(color: AppColors.onSurface)),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        const Divider(color: AppColors.outlineVariant, height: 1),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: AppTextStyles.labelSm.copyWith(color: AppColors.onSurfaceVariant));
  }
}

class _TwoCol extends StatelessWidget {
  final Widget left;
  final Widget right;
  const _TwoCol({required this.left, required this.right});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 500) {
      return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [left, const SizedBox(height: AppSpacing.lg), right]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: AppSpacing.lg),
        Expanded(child: right),
      ],
    );
  }
}

class _PathField extends StatelessWidget {
  final TextEditingController controller;
  final String? hint;
  const _PathField({required this.controller, this.hint});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.outlineVariant),
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
      child: Row(
        children: [
          const Icon(Icons.storage_rounded,
              size: 20, color: AppColors.onSurfaceVariant),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: TextField(
              controller: controller,
              style: AppTextStyles.dataDisplay
                  .copyWith(color: AppColors.onSurface),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                hintText: hint,
                hintStyle: AppTextStyles.bodyMd
                    .copyWith(color: AppColors.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NumberInputField extends StatelessWidget {
  final IconData icon;
  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  const _NumberInputField({
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(label),
        const SizedBox(height: AppSpacing.xs),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceDim,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: AppColors.outlineVariant),
          ),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
          child: Row(
            children: [
              Icon(icon, size: 20, color: AppColors.onSurfaceVariant),
              const Spacer(),
              IconButton(
                onPressed: value > min ? () => onChanged(value - 1) : null,
                icon: const Icon(Icons.remove_rounded, size: 16),
                color: AppColors.onSurfaceVariant,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '$value',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.dataDisplay
                      .copyWith(color: AppColors.onSurface),
                ),
              ),
              IconButton(
                onPressed: value < max ? () => onChanged(value + 1) : null,
                icon: const Icon(Icons.add_rounded, size: 16),
                color: AppColors.onSurfaceVariant,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SliderField extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final String displayValue;
  final Color displayColor;
  final String minLabel;
  final String maxLabel;
  final ValueChanged<double> onChanged;

  const _SliderField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.displayValue,
    required this.displayColor,
    required this.minLabel,
    required this.maxLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
            color: AppColors.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _FieldLabel(label),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs, vertical: 2),
                decoration: BoxDecoration(
                  color: displayColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                child: Text(displayValue,
                    style: AppTextStyles.dataDisplay
                        .copyWith(color: displayColor)),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
            activeColor: displayColor,
            inactiveColor: AppColors.surfaceContainerHigh,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(minLabel,
                  style: AppTextStyles.labelSm
                      .copyWith(color: AppColors.outline, fontSize: 10)),
              Text(maxLabel,
                  style: AppTextStyles.labelSm
                      .copyWith(color: AppColors.outline, fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }
}

class _DropdownField<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;

  const _DropdownField({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(label),
        const SizedBox(height: AppSpacing.xs),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: AppColors.outlineVariant),
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: DropdownButton<T>(
            value: value,
            isExpanded: true,
            dropdownColor: AppColors.surfaceContainerLow,
            underline: const SizedBox(),
            style: AppTextStyles.dataDisplay.copyWith(color: AppColors.onSurface),
            icon: const Icon(Icons.expand_more_rounded,
                color: AppColors.outline, size: 20),
            items: items
                .map((item) => DropdownMenuItem<T>(
                      value: item.$1,
                      child: Text(item.$2),
                    ))
                .toList(),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ],
    );
  }
}

class _ToggleField extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleField({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
            color: AppColors.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: AppTextStyles.labelSm
                        .copyWith(color: AppColors.onSurface)),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.onSurfaceVariant)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.primary,
            inactiveTrackColor: AppColors.surfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: AppTextStyles.bodyMd
                        .copyWith(color: AppColors.onSurface)),
                Text(subtitle,
                    style: AppTextStyles.labelSm
                        .copyWith(color: AppColors.onSurfaceVariant)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.primary,
            inactiveTrackColor: AppColors.surfaceVariant,
          ),
        ],
      ),
    );
  }
}
