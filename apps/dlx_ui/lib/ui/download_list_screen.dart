import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../services/download_service.dart';
import '../util/format.dart';
import '../util/palette.dart';
import 'add_download_dialog.dart';
import 'download_detail_screen.dart';
import 'settings_screen.dart';
import 'widgets/download_tile.dart';
import 'widgets/speed_chart.dart';

/// Home: the global stacked speed chart, a summary bar, and the live list.
class DownloadListScreen extends StatelessWidget {
  final DownloadService service;
  const DownloadListScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('dlx'),
        actions: [
          if (kDebugMode)
            ListenableBuilder(
              listenable: service,
              builder: (context, _) => IconButton(
                tooltip: service.demoActive ? 'Clear demo downloads' : 'Inject demo downloads',
                icon: Icon(service.demoActive ? Icons.science : Icons.science_outlined),
                color: service.demoActive ? Theme.of(context).colorScheme.primary : null,
                onPressed: service.toggleDemo,
              ),
            ),
          IconButton(
            tooltip: 'Start all',
            icon: const Icon(Icons.play_arrow),
            onPressed: service.startAll,
          ),
          IconButton(
            tooltip: 'Pause all',
            icon: const Icon(Icons.pause),
            onPressed: service.pauseAll,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SettingsScreen(service: service)),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showAddDownloadDialog(context, service),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          return Column(
            children: [
              _globalChart(context),
              const Divider(height: 1),
              Expanded(
                child: service.downloads.isEmpty
                    ? const _EmptyState()
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: service.downloads.length,
                        itemBuilder: (context, i) {
                          final vm = service.downloads[i];
                          return DownloadTile(
                            vm: vm,
                            service: service,
                            onOpen: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    DownloadDetailScreen(vm: vm, service: service),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _globalChart(BuildContext context) {
    final order = service.downloads.map((vm) => vm.id).toList();
    final colorIndex = {for (var i = 0; i < order.length; i++) order[i]: i};
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Repaints on every tick without rebuilding the list below.
          ListenableBuilder(
            listenable: service.ticker,
            builder: (context, _) => StackedSpeedChart(
              frames: service.globalSpeedHistory.frames,
              seriesOrder: order,
              colorOf: (id) => colorForIndex(colorIndex[id] ?? 0),
              limit: service.settings.speedLimit.toDouble(),
              height: 140,
            ),
          ),
          const SizedBox(height: 6),
          ListenableBuilder(
            listenable: service.ticker,
            builder: (context, _) => Row(
              children: [
                _chip(context, Icons.download, '${service.activeCount} active'),
                const SizedBox(width: 12),
                _chip(context, Icons.speed, formatSpeed(service.totalSpeed)),
                const Spacer(),
                Text('${service.downloads.length} total',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, IconData icon, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ],
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_download_outlined, size: 64, color: Theme.of(context).disabledColor),
          const SizedBox(height: 12),
          const Text('No downloads yet'),
          const SizedBox(height: 4),
          Text('Tap “Add” to start one', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
