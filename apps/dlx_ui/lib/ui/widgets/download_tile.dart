import 'package:downloadx/downloadx.dart';
import 'package:flutter/material.dart';

import '../../models/download_vm.dart';
import '../../services/download_service.dart';
import '../../util/format.dart';
import '../../util/palette.dart';

/// A live row in the download list. Rebuilds on its own [DownloadVm] only, so
/// the rest of the list stays still while one download updates.
class DownloadTile extends StatelessWidget {
  final DownloadVm vm;
  final DownloadService service;
  final VoidCallback onOpen;

  const DownloadTile({
    super.key,
    required this.vm,
    required this.service,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: vm,
      builder: (context, _) {
        final d = vm.desc;
        final state = vm.state;
        final running = state == DownloadState.downloading || state == DownloadState.probing;
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  Icon(iconForState(state), color: colorForState(state)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d.filename ?? d.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: vm.progressFraction,
                            minHeight: 6,
                            backgroundColor: Theme.of(context).dividerColor,
                            color: colorForState(state),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(_subtitle(d, state), style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: running ? 'Pause' : 'Start',
                    icon: Icon(running ? Icons.pause : Icons.play_arrow),
                    onPressed: state == DownloadState.completed
                        ? null
                        : () => running ? service.pause(vm) : service.start(vm),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'open') onOpen();
                      if (v == 'remove') service.remove(vm);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'open', child: Text('Details')),
                      PopupMenuItem(value: 'remove', child: Text('Remove')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _subtitle(DownloadDescription d, DownloadState state) {
    if (state == DownloadState.error) return d.errorMessage ?? 'error';

    if (vm.isHls) {
      final seg = vm.hlsSegmentsDone;
      final total = vm.hlsTotalSegments;
      final segStr = (seg != null && total != null) ? '$seg/$total segs' : (seg != null ? '$seg segs' : 'HLS');
      if (state == DownloadState.downloading) {
        final eta = d.etaMs == null ? '—' : formatDuration(d.etaMs!);
        return '$segStr  ·  ${formatSpeed(d.totalSpeedBps)}  ·  ETA $eta';
      }
      return '$segStr  ·  ${state.name}';
    }

    final size = d.totalBytes == null
        ? formatBytes(d.downloadedBytes)
        : '${formatBytes(d.downloadedBytes)} / ${formatBytes(d.totalBytes!)}';
    final pct = formatPercent(d.percent);
    if (state == DownloadState.downloading) {
      final eta = d.etaMs == null ? '—' : formatDuration(d.etaMs!);
      return '$size  ·  $pct  ·  ${formatSpeed(d.totalSpeedBps)}  ·  ETA $eta  ·  '
          '${d.activeChunks}/${d.totalChunks} chunks';
    }
    return '$size  ·  $pct  ·  ${state.name}';
  }
}
