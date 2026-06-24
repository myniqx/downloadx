import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart' hide DiagnosticLevel;

import '../../util/palette.dart';
import 'dlx_card.dart';

class LogCard extends StatefulWidget {
  final Download download;
  const LogCard({super.key, required this.download});

  @override
  State<LogCard> createState() => _LogCardState();
}

class _LogCardState extends State<LogCard> {
  final List<({int timestamp, DiagnosticLevel level, String message})> _entries = [];
  late final void Function() _unsub;

  @override
  void initState() {
    super.initState();
    _entries.addAll(widget.download.renderedLogs);
    _unsub = widget.download.emitter.onType<LogEvent>((e) {
      if (!mounted) return;
      setState(() => _entries.add((
            timestamp: e.timestamp,
            level: e.level,
            message: e.message,
          )));
    });
  }

  @override
  void dispose() {
    _unsub();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DlxCard(
      title: 'Activity Log',
      titleIcon: Icons.receipt_long_rounded,
      description: '${_entries.length} entries',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: _entries.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                    child: Text(
                      'No log entries yet.',
                      style: AppTextStyles.labelSm.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    itemCount: _entries.length,
                    itemBuilder: (context, i) {
                      final e = _entries[_entries.length - 1 - i];
                      return _LogRow(entry: e);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  final ({int timestamp, DiagnosticLevel level, String message}) entry;
  const _LogRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final color = _logColor(entry.level);
    final label = _logLabel(entry.level);
    final time = _formatTime(entry.timestamp);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            time,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              color: AppColors.outlineVariant,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              entry.message,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: color == AppColors.onSurfaceVariant
                    ? AppColors.onSurfaceVariant
                    : color.withValues(alpha: 0.9),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _logColor(DiagnosticLevel l) => switch (l) {
        DiagnosticLevel.error => AppColors.error,
        DiagnosticLevel.warn => AppColors.tertiary,
        DiagnosticLevel.info => AppColors.onSurfaceVariant,
      };

  String _logLabel(DiagnosticLevel l) => switch (l) {
        DiagnosticLevel.error => 'ERR',
        DiagnosticLevel.warn => 'WRN',
        DiagnosticLevel.info => 'INF',
      };

  String _formatTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
