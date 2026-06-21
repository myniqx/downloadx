import 'types.dart';

/// Sealed hierarchy of everything a download can emit. Idiomatic Dart `switch`
/// over the subtype gives exhaustiveness; the [EventEmitter] dispatches these
/// synchronously, mirroring the TypeScript `TypedEventEmitter`.
sealed class DownloadEvent {
  final String downloadId;
  const DownloadEvent(this.downloadId);
}

/// Aggregate download progress.
class ProgressEvent extends DownloadEvent {
  final int? totalBytes;
  final int downloadedBytes;
  final double totalSpeed;
  final int activeChunks;
  final double? percent;

  /// Estimated remaining time in ms, or null when size/speed is unknown.
  final int? etaMs;

  /// Number of HLS segments downloaded so far. Null for non-HLS downloads.
  final int? hlsSegmentsDone;

  /// Total HLS segment count. Null for non-HLS downloads.
  final int? hlsTotalSegments;

  const ProgressEvent(
    super.downloadId, {
    required this.totalBytes,
    required this.downloadedBytes,
    required this.totalSpeed,
    required this.activeChunks,
    required this.percent,
    required this.etaMs,
    this.hlsSegmentsDone,
    this.hlsTotalSegments,
  });
}

/// Shared fields for the two per-chunk progress events.
abstract class ChunkProgressBase extends DownloadEvent {
  final String chunkId;
  final int offset;
  final int length;
  final int downloadedBytes;
  final double instantSpeed;
  final double windowedSpeed;
  final ChunkQuality quality;

  const ChunkProgressBase(
    super.downloadId, {
    required this.chunkId,
    required this.offset,
    required this.length,
    required this.downloadedBytes,
    required this.instantSpeed,
    required this.windowedSpeed,
    required this.quality,
  });
}

class ChunkProgressEvent extends ChunkProgressBase {
  const ChunkProgressEvent(
    super.downloadId, {
    required super.chunkId,
    required super.offset,
    required super.length,
    required super.downloadedBytes,
    required super.instantSpeed,
    required super.windowedSpeed,
    required super.quality,
  });
}

/// Same payload shape as [ChunkProgressEvent], emitted whenever a chunk's
/// quality classification is re-evaluated.
class ChunkQualityEvent extends ChunkProgressBase {
  const ChunkQualityEvent(
    super.downloadId, {
    required super.chunkId,
    required super.offset,
    required super.length,
    required super.downloadedBytes,
    required super.instantSpeed,
    required super.windowedSpeed,
    required super.quality,
  });
}

class ChunkLifecycleEvent extends DownloadEvent {
  final String chunkId;
  final ChunkStatus status;
  const ChunkLifecycleEvent(super.downloadId,
      {required this.chunkId, required this.status});
}

class ChunkSplitEvent extends DownloadEvent {
  final String sourceChunkId;
  final String newChunkId;
  final int splitOffset;
  final SplitReason reason;
  const ChunkSplitEvent(
    super.downloadId, {
    required this.sourceChunkId,
    required this.newChunkId,
    required this.splitOffset,
    required this.reason,
  });
}

class StateChangeEvent extends DownloadEvent {
  final DownloadState previous;
  final DownloadState current;
  const StateChangeEvent(super.downloadId,
      {required this.previous, required this.current});
}

class ErrorEvent extends DownloadEvent {
  final String? chunkId;
  final Object error;
  final bool fatal;
  const ErrorEvent(super.downloadId,
      {this.chunkId, required this.error, required this.fatal});
}

class CompletedEvent extends DownloadEvent {
  final String filename;
  final int totalBytes;
  final int durationMs;
  const CompletedEvent(super.downloadId,
      {required this.filename,
      required this.totalBytes,
      required this.durationMs});
}

class DiagnosticEvent extends DownloadEvent {
  final DiagnosticPayload payload;
  const DiagnosticEvent(super.downloadId, this.payload);
}

/// Zero-dependency, synchronous event dispatcher.
///
/// Listeners are dispatched synchronously in registration order. Errors thrown
/// from listeners are caught and reported via [onError] so one bad listener
/// cannot block the rest or crash the download pipeline.
class EventEmitter {
  final List<void Function(DownloadEvent)> _listeners = [];

  /// Optional hook invoked when a listener throws. Defaults to silent.
  void Function(Object error, DownloadEvent event) onError = (_, __) {};

  /// Register a listener for every event. Returns a disposer.
  void Function() on(void Function(DownloadEvent event) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Register a listener for a single event subtype [T]. Returns a disposer.
  void Function() onType<T extends DownloadEvent>(
      void Function(T event) listener) {
    void wrapper(DownloadEvent e) {
      if (e is T) listener(e);
    }

    _listeners.add(wrapper);
    return () => _listeners.remove(wrapper);
  }

  void emit(DownloadEvent event) {
    if (_listeners.isEmpty) return;
    // Copy so listeners that remove themselves during dispatch don't corrupt
    // the iteration.
    final snapshot = List<void Function(DownloadEvent)>.of(_listeners);
    for (final listener in snapshot) {
      try {
        listener(event);
      } catch (err) {
        try {
          onError(err, event);
        } catch (_) {
          /* never allow onError to throw */
        }
      }
    }
  }

  int get listenerCount => _listeners.length;

  void removeAllListeners() => _listeners.clear();

  /// Re-emit every event this emitter fires through [target]. Used so a single
  /// `Download`'s events surface on the parent `DownloadX` emitter. The returned
  /// function tears down the relay.
  void Function() pipeTo(EventEmitter target) {
    return on(target.emit);
  }
}
