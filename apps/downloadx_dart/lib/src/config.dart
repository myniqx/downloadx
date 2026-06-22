import 'io.dart';
import 'key2log.dart';
import 'throttle.dart';
import 'types.dart';

/// The slice of configuration a [Chunk] reads on every retry. Implemented by
/// `Download` so values are live (not snapshotted at construction).
abstract class DownloadConfig {
  /// Maximum HTTP retries per chunk attempt.
  int get maxRetries;

  /// Base delay in ms between retries.
  int get retryDelay;

  /// Exponential backoff multiplier.
  num get retryBackoff;

  /// Moving-average window in ms for chunk-quality decisions.
  int get speedSampleWindow;

  /// Network idle timeout in ms (always defined; default 30000).
  int get requestTimeout;

  /// Extra HTTP headers merged into every request.
  Map<String, String> get headers;

  /// The I/O abstraction providing network and file access.
  DownloadxIo get io;

  /// Add a structured log entry to this download's persistent log.
  void addLog({
    DiagnosticLevel level = DiagnosticLevel.info,
    required LogCode code,
    Map<String, dynamic>? params,
  });
}

/// The full manager-level configuration surface, implemented by both
/// `Download` (delegating to its manager) and `DownloadX`.
abstract class GlobalConfig extends DownloadConfig {
  /// Directory where finished files are written.
  String get targetPath;

  /// Directory where in-progress meta and part files are stored.
  String get cachePath;

  /// Maximum concurrent downloads at the manager level.
  int get maxParallel;

  /// Manager-wide bandwidth cap in bytes/sec (0 = unlimited).
  num get speedLimit;

  /// Target number of chunks per download.
  int get targetChunkCount;

  /// Minimum bytes remaining before a chunk can be split.
  int get minChunkSize;

  /// Whether NDJSON diagnostic journal writing is enabled.
  bool get journal;

  /// Manager-wide bandwidth cap shared by all downloads.
  Throttle get sharedThrottle;
}

/// Minimal interface for the download manager — passed to HlsSession so it can
/// register additional downloads (e.g. multi-stream HLS) without importing DownloadX.
abstract class DlxContext extends GlobalConfig {
  /// Registers a new download for [url] and returns the [Download] handle.
  Future<void> addUrl(String url, [DownloadOptions options]);
}
