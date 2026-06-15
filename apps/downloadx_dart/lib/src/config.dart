import 'io.dart';
import 'throttle.dart';

/// The slice of configuration a [Chunk] reads on every retry. Implemented by
/// `Download` so values are live (not snapshotted at construction).
abstract class DownloadConfig {
  int get maxRetries;
  int get retryDelay;
  num get retryBackoff;
  int get speedSampleWindow;

  /// Network idle timeout in ms (always defined; default 30000).
  int get requestTimeout;
  Map<String, String> get headers;
  DownloadxIo get io;
}

/// The full manager-level configuration surface, implemented by both
/// `Download` (delegating to its manager) and `DownloadX`.
abstract class GlobalConfig extends DownloadConfig {
  String get targetPath;
  String get cachePath;
  int get maxParallel;
  num get speedLimit;
  int get targetChunkCount;
  int get minChunkSize;
  bool get journal;

  /// Manager-wide bandwidth cap shared by all downloads.
  Throttle get sharedThrottle;
}
