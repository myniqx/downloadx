import 'package:downloadx/downloadx.dart';
import 'package:flutter/foundation.dart';

import '../services/speed_history.dart';

/// View-model for a single download. Wraps a [Download] from the engine,
/// caches its latest [DownloadDescription] + chunk snapshots, and keeps a
/// rolling per-chunk speed history for the detail chart.
///
/// It is a [ChangeNotifier]: the tile and detail screen rebuild when it
/// notifies. The owning service feeds it engine events and ticks it.
class DownloadVm extends ChangeNotifier {
  final Download download;

  DownloadDescription desc;
  List<ChunkSnapshot> snapshots;
  double currentSpeed = 0;

  /// Latest per-chunk instant speed (bytes/sec), updated from chunk events.
  final Map<String, double> _chunkSpeed = {};

  /// Rolling per-chunk speed frames for the detail chart.
  final SpeedHistory chunkSpeedHistory = SpeedHistory();

  DownloadVm(this.download)
      : desc = download.describe(),
        snapshots = download.getChunkSnapshots();

  String get id => download.id;
  DownloadState get state => download.state;

  /// Effective per-download speed limit in bytes/sec (null = none/inherits).
  int? get speedLimit => download.get('speedLimit') as int?;

  /// Feed an engine event. Updates cached speeds; does not notify (the ticker
  /// and structural refreshes drive repaints to keep the UI cadence steady).
  void onEvent(DownloadEvent e) {
    if (e is ChunkProgressEvent) {
      _chunkSpeed[e.chunkId] = e.instantSpeed;
    } else if (e is ChunkLifecycleEvent) {
      if (e.status != ChunkStatus.downloading) {
        _chunkSpeed.remove(e.chunkId);
      }
    } else if (e is ProgressEvent) {
      currentSpeed = e.totalSpeed;
    }
  }

  /// Recompute the cached description/snapshots from the engine and notify.
  void refresh() {
    desc = download.describe();
    snapshots = download.getChunkSnapshots();
    if (download.state != DownloadState.downloading) {
      currentSpeed = 0;
    } else {
      currentSpeed = desc.totalSpeedBps.toDouble();
    }
    notifyListeners();
  }

  /// Push one speed frame (per-chunk) for the detail chart. Called on the tick.
  void tick() {
    if (download.state == DownloadState.downloading) {
      final frame = <String, double>{};
      for (final s in snapshots) {
        if (s.status == ChunkStatus.downloading) {
          frame[s.id] = _chunkSpeed[s.id] ?? 0;
        }
      }
      chunkSpeedHistory.push(frame);
    } else if (chunkSpeedHistory.frames.isNotEmpty) {
      // Let the trace decay to zero once the download stops.
      chunkSpeedHistory.push(const {});
    }
  }
}
