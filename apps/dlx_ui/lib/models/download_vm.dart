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
  int? hlsSegmentsDone;
  int? hlsTotalSegments;

  /// Latest per-chunk instant speed (bytes/sec), updated from chunk events.
  final Map<String, double> _chunkSpeed = {};

  /// Timestamp (ms) when each chunk transitioned to completed/failed/reassigned.
  final Map<String, int> chunkCompletedAt = {};

  /// Rolling per-chunk speed frames for the detail chart.
  final SpeedHistory chunkSpeedHistory = SpeedHistory();

  DownloadVm(this.download)
      : desc = download.describe(),
        snapshots = download.getChunkSnapshots() {
    _syncHlsFromDesc();
  }

  String get id => download.id;
  DownloadState get state => download.state;

  bool get isHls =>
      hlsSegmentsDone != null ||
      hlsTotalSegments != null ||
      desc.hlsTotalSegments != null;

  /// Pull HLS segment counts from the latest [describe] so they stay correct
  /// even without a fresh ProgressEvent (e.g. resume, reload, or completion).
  void _syncHlsFromDesc() {
    if (desc.hlsSegmentsDone != null) hlsSegmentsDone = desc.hlsSegmentsDone;
    if (desc.hlsTotalSegments != null) hlsTotalSegments = desc.hlsTotalSegments;
  }

  /// Progress 0–1, null when unknown. For HLS uses segment count if byte percent unavailable.
  double? get progressFraction {
    final p = desc.percent;
    if (p != null) return p / 100;
    final done = hlsSegmentsDone;
    final total = hlsTotalSegments;
    if (done != null && total != null && total > 0) return done / total;
    return null;
  }

  /// Effective per-download speed limit in bytes/sec (null = none/inherits).
  int? get speedLimit => download.speedLimit > 0 ? download.speedLimit.toInt() : null;

  /// Feed an engine event. Updates cached speeds; does not notify (the ticker
  /// and structural refreshes drive repaints to keep the UI cadence steady).
  void onEvent(DownloadEvent e) {
    if (e is ChunkProgressEvent) {
      _chunkSpeed[e.chunkId] = e.instantSpeed;
      _patchSnapshot(e.chunkId, e.downloadedBytes, e.length);
    } else if (e is ChunkLifecycleEvent) {
      if (e.status != ChunkStatus.downloading) {
        _chunkSpeed.remove(e.chunkId);
      }
      if (e.status == ChunkStatus.completed ||
          e.status == ChunkStatus.failed ||
          e.status == ChunkStatus.reassigned) {
        chunkCompletedAt[e.chunkId] = DateTime.now().millisecondsSinceEpoch;
      }
    } else if (e is ProgressEvent) {
      currentSpeed = e.totalSpeed;
      if (e.hlsSegmentsDone != null) hlsSegmentsDone = e.hlsSegmentsDone;
      if (e.hlsTotalSegments != null) hlsTotalSegments = e.hlsTotalSegments;
    }
  }

  void _patchSnapshot(String chunkId, int downloadedBytes, int length) {
    for (final s in snapshots) {
      if (s.id == chunkId) {
        s.downloadedBytes = downloadedBytes;
        s.length = length;
        return;
      }
    }
  }

  /// Recompute the cached description/snapshots from the engine and notify.
  void refresh() {
    desc = download.describe();
    snapshots = download.getChunkSnapshots();
    _syncHlsFromDesc();
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
