import 'package:downloadx/downloadx.dart';
// Hide Flutter's DiagnosticLevel so the engine's (used by DiagnosticPayload) wins.
import 'package:flutter/material.dart' hide DiagnosticLevel;

import '../models/download_vm.dart';
import '../services/download_service.dart';
import '../util/format.dart';
import '../util/palette.dart';
import 'widgets/chunk_blocks.dart';
import 'widgets/speed_chart.dart';

/// The graphical "watch": live segment bar, stacked per-chunk speed chart,
/// chunk table, and recent diagnostics for one download.
class DownloadDetailScreen extends StatelessWidget {
  final DownloadVm vm;
  final DownloadService service;

  const DownloadDetailScreen({super.key, required this.vm, required this.service});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) {
        final d = vm.desc;
        final running = vm.state == DownloadState.downloading || vm.state == DownloadState.probing;
        final ordered = [...vm.snapshots]..sort((a, b) => a.offset.compareTo(b.offset));
        final seriesOrder = ordered.map((c) => c.id).toList();
        final colorIndex = {for (var i = 0; i < seriesOrder.length; i++) seriesOrder[i]: i};
        final limit = (vm.speedLimit ?? service.settings.speedLimit).toDouble();

        return Scaffold(
          appBar: AppBar(
            title: Text(d.filename ?? d.url, overflow: TextOverflow.ellipsis),
            actions: [
              if (vm.state != DownloadState.completed)
                IconButton(
                  tooltip: running ? 'Pause' : 'Start',
                  icon: Icon(running ? Icons.pause : Icons.play_arrow),
                  onPressed: () => running ? service.pause(vm) : service.start(vm),
                ),
              IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  service.remove(vm);
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _stats(context, d),
              const SizedBox(height: 20),
              _sectionTitle(context, 'Segments'),
              const SizedBox(height: 8),
              ChunkBlocks(totalBytes: d.totalBytes, chunks: ordered),
              const SizedBox(height: 20),
              _sectionTitle(context, 'Speed (stacked per chunk)'),
              const SizedBox(height: 8),
              StackedSpeedChart(
                frames: vm.chunkSpeedHistory.frames,
                seriesOrder: seriesOrder,
                colorOf: (id) => colorForIndex(colorIndex[id] ?? 0),
                limit: limit,
              ),
              const SizedBox(height: 20),
              _sectionTitle(context, 'Chunks'),
              const SizedBox(height: 8),
              ..._chunkRows(context, ordered, d.totalBytes),
              if (d.recentDiagnostics.isNotEmpty) ...[
                const SizedBox(height: 20),
                _sectionTitle(context, 'Recent activity'),
                const SizedBox(height: 8),
                ...d.recentDiagnostics.reversed.map((diag) => ListTile(
                      dense: true,
                      leading: Icon(_diagIcon(diag.level), size: 18, color: _diagColor(diag.level)),
                      title: Text('[${diag.code}] ${diag.message}'),
                    )),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _stats(BuildContext context, DownloadDescription d) {
    final size = d.totalBytes == null
        ? formatBytes(d.downloadedBytes)
        : '${formatBytes(d.downloadedBytes)} / ${formatBytes(d.totalBytes!)}';
    final cells = <List<String>>[
      ['State', d.state.name],
      ['Progress', formatPercent(d.percent)],
      ['Size', size],
      ['Speed', formatSpeed(d.totalSpeedBps)],
      ['ETA', d.etaMs == null ? '—' : formatDuration(d.etaMs!)],
      ['Elapsed', formatDuration(d.elapsedMs)],
      ['Chunks', '${d.activeChunks} active / ${d.totalChunks}'],
      ['Target', d.targetPath ?? service.settings.targetPath],
    ];
    return Wrap(
      spacing: 24,
      runSpacing: 12,
      children: cells
          .map((c) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(c[0], style: Theme.of(context).textTheme.labelSmall),
                  Text(c[1], style: Theme.of(context).textTheme.titleMedium),
                ],
              ))
          .toList(),
    );
  }

  List<Widget> _chunkRows(BuildContext context, List<ChunkSnapshot> chunks, int? total) {
    return chunks.map((c) {
      final frac = c.length > 0 ? (c.downloadedBytes / c.length).clamp(0.0, 1.0) : 0.0;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: colorForQuality(c.quality, completed: c.status == ChunkStatus.completed),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(width: 90, child: Text(c.id, overflow: TextOverflow.ellipsis)),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: frac,
                  minHeight: 6,
                  backgroundColor: Theme.of(context).dividerColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text('${c.status.name}'
                '${c.retries > 0 ? ' · r${c.retries}' : ''}'),
          ],
        ),
      );
    }).toList();
  }

  Widget _sectionTitle(BuildContext context, String text) =>
      Text(text, style: Theme.of(context).textTheme.titleSmall);

  IconData _diagIcon(DiagnosticLevel l) => switch (l) {
        DiagnosticLevel.error => Icons.error_outline,
        DiagnosticLevel.warn => Icons.warning_amber,
        DiagnosticLevel.info => Icons.info_outline,
      };

  Color _diagColor(DiagnosticLevel l) => switch (l) {
        DiagnosticLevel.error => const Color(0xFFE57373),
        DiagnosticLevel.warn => const Color(0xFFFFB74D),
        DiagnosticLevel.info => const Color(0xFF90CAF9),
      };
}
