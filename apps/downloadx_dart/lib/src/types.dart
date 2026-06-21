/// Core type definitions for downloadx.
///
/// The download engine is environment-agnostic: all I/O (network + file
/// system) goes through the [DownloadxIo] abstraction so it can run against
/// real disk (the default [NativeIo]), an in-memory mock, or a custom backend.
library;

import 'io.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Strategy for splitting a download into chunks.
enum ChunkMode { auto, single, fixed }

/// Lifecycle state of a whole download.
enum DownloadState {
  idle,
  probing,
  downloading,
  paused,
  completed,
  error,
  cancelled,
}

/// Lifecycle state of a single chunk.
enum ChunkStatus {
  pending,
  downloading,
  paused,
  completed,
  failed,
  reassigned,
}

/// Qualitative health of a chunk, used by the dynamic splitter.
enum ChunkQuality { good, poor, stalled }

/// Why a split happened. Serialised with the wire-compatible string used by
/// the TypeScript implementation (`completed-reassign`, not `completedReassign`).
enum SplitReason {
  slow,
  failed,
  completedReassign;

  String get wire => switch (this) {
        SplitReason.slow => 'slow',
        SplitReason.failed => 'failed',
        SplitReason.completedReassign => 'completed-reassign',
      };
}

/// Severity level of a [DiagnosticPayload].
enum DiagnosticLevel { info, warn, error }

// Enum <-> string helpers (names are wire-compatible with the TS package, so
// meta sidecars are interchangeable between the two implementations).

T _enumByName<T extends Enum>(List<T> values, String name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

ChunkMode chunkModeFromString(String s) =>
    _enumByName(ChunkMode.values, s, ChunkMode.auto);
DownloadState downloadStateFromString(String s) =>
    _enumByName(DownloadState.values, s, DownloadState.idle);
ChunkStatus chunkStatusFromString(String s) =>
    _enumByName(ChunkStatus.values, s, ChunkStatus.pending);
ChunkQuality chunkQualityFromString(String s) =>
    _enumByName(ChunkQuality.values, s, ChunkQuality.good);

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Global configuration for a `DownloadX` manager instance. Every field except
/// [targetPath] has a sensible default; see [DefaultConfig].
class DownloadXConfig {
  /// Injected I/O (network + file system). Defaults to [NativeIo] when null.
  final DownloadxIo? io;

  /// Directory where finished files are written.
  final String targetPath;

  /// Directory where in-progress meta/part files are written.
  /// Defaults to [targetPath]. Fixed at construction.
  final String? cachePath;

  /// Max number of downloads running concurrently at the manager level.
  int? maxParallel;

  /// Default chunking strategy for new downloads.
  ChunkMode? chunkMode;

  /// Target number of chunks per download (upper bound, including splits).
  int? targetChunkCount;

  /// Minimum bytes remaining in a chunk before it can be split again.
  int? minChunkSize;

  /// Max HTTP retries per chunk before giving up.
  int? maxRetries;

  /// Base delay (ms) between retries.
  int? retryDelay;

  /// Exponential backoff multiplier applied per retry attempt.
  num? retryBackoff;

  /// Moving-average window (ms) used for chunk-quality decisions.
  int? speedSampleWindow;

  /// Global bandwidth limit in bytes/sec shared by all downloads. 0 = unlimited.
  int? speedLimit;

  /// Extra HTTP headers sent on every probe/chunk request.
  Map<String, String>? headers;

  /// Network idle timeout in ms: a chunk request is aborted (and retried) when
  /// no bytes arrive for this long. Null = no timeout. NOT a cap on total
  /// request duration — long downloads are unaffected while data flows.
  int? requestTimeout;

  /// Write an NDJSON journal sidecar recording retries, splits, timeouts, and
  /// state changes.
  bool? journal;

  DownloadXConfig({
    this.io,
    required this.targetPath,
    this.cachePath,
    this.maxParallel,
    this.chunkMode,
    this.targetChunkCount,
    this.minChunkSize,
    this.maxRetries,
    this.retryDelay,
    this.retryBackoff,
    this.speedSampleWindow,
    this.speedLimit,
    this.headers,
    this.requestTimeout,
    this.journal,
  });
}

/// Per-download overrides passed to `DownloadX.addUrl`.
class DownloadOptions {
  /// Override filename. Defaults to one inferred from URL / Content-Disposition.
  final String? filename;

  /// Override target directory for this download's final file.
  final String? targetPath;

  /// Override chunk mode for this download.
  final ChunkMode? chunkMode;

  /// Override target chunk count for this download.
  final int? targetChunkCount;

  /// Override per-download speed limit (bytes/sec). 0 = unlimited.
  final int? speedLimit;

  /// Override minimum chunk size for this download.
  final int? minChunkSize;

  /// Write NDJSON diagnostic journal for this download.
  final bool? journal;

  /// Override retry behaviour.
  final int? maxRetries;
  final int? retryDelay;
  final num? retryBackoff;

  /// Extra HTTP headers merged with manager headers.
  final Map<String, String>? headers;

  /// Override the download id. Defaults to a hash of the url.
  final String? id;

  /// Start the download immediately after addUrl.
  final bool? autoStart;

  const DownloadOptions({
    this.filename,
    this.targetPath,
    this.chunkMode,
    this.targetChunkCount,
    this.speedLimit,
    this.minChunkSize,
    this.journal,
    this.maxRetries,
    this.retryDelay,
    this.retryBackoff,
    this.headers,
    this.id,
    this.autoStart,
  });
}

// ---------------------------------------------------------------------------
// Snapshots / probe / meta
// ---------------------------------------------------------------------------

/// A half-open byte range `[offset, offset + length)`.
class ByteRange {
  final int offset;
  final int length;
  const ByteRange({required this.offset, required this.length});
}

/// Snapshot of a chunk, persisted to the meta file for resume.
class ChunkSnapshot {
  String id;
  int offset;
  int length;
  int downloadedBytes;
  ChunkStatus status;
  ChunkQuality quality;
  int retries;
  String? lastError;

  ChunkSnapshot({
    required this.id,
    required this.offset,
    required this.length,
    required this.downloadedBytes,
    required this.status,
    required this.quality,
    required this.retries,
    this.lastError,
  });

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'offset': offset,
      'length': length,
      'downloadedBytes': downloadedBytes,
      'status': status.name,
      'quality': quality.name,
      'retries': retries,
    };
    if (lastError != null) m['lastError'] = lastError;
    return m;
  }

  factory ChunkSnapshot.fromJson(Map<String, dynamic> j) => ChunkSnapshot(
        id: j['id'] as String,
        offset: (j['offset'] as num).toInt(),
        length: (j['length'] as num).toInt(),
        downloadedBytes: (j['downloadedBytes'] as num).toInt(),
        status: chunkStatusFromString(j['status'] as String),
        quality: chunkQualityFromString(j['quality'] as String),
        retries: (j['retries'] as num).toInt(),
        lastError: j['lastError'] as String?,
      );
}

/// Result of the initial HTTP probe.
class ProbeResult {
  final String url;
  final String finalUrl;
  final int? totalSize;
  final bool acceptsRanges;
  final String? etag;
  final String? lastModified;
  final String? contentType;
  final String filename;
  final bool isHls;

  const ProbeResult({
    required this.url,
    required this.finalUrl,
    required this.totalSize,
    required this.acceptsRanges,
    required this.etag,
    required this.lastModified,
    required this.contentType,
    required this.filename,
    required this.isHls,
  });

  ProbeResult copyWith({bool? acceptsRanges}) => ProbeResult(
        url: url,
        finalUrl: finalUrl,
        totalSize: totalSize,
        acceptsRanges: acceptsRanges ?? this.acceptsRanges,
        etag: etag,
        lastModified: lastModified,
        contentType: contentType,
        filename: filename,
        isHls: isHls,
      );
}

/// JSON shape persisted as `{id}.downloadx.json`.
class MetaFile {
  final int schemaVersion;
  final String id;
  final String url;
  String? finalUrl;
  String? filename;
  int? totalSize;
  bool acceptsRanges;
  String? etag;
  String? lastModified;
  String? contentType;
  final int createdAt;
  int updatedAt;
  DownloadState state;
  List<ChunkSnapshot> chunks;
  final int addedAt;
  int? completedAt;
  String? errorMessage;
  int? speedLimit;
  int? targetChunkCount;
  String? targetPath;
  int? minChunkSize;
  bool? journal;

  MetaFile({
    required this.schemaVersion,
    required this.id,
    required this.url,
    required this.finalUrl,
    required this.filename,
    required this.totalSize,
    required this.acceptsRanges,
    required this.etag,
    required this.lastModified,
    required this.contentType,
    required this.createdAt,
    required this.updatedAt,
    required this.state,
    required this.chunks,
    required this.addedAt,
    required this.completedAt,
    required this.errorMessage,
    required this.speedLimit,
    required this.targetChunkCount,
    required this.targetPath,
    required this.minChunkSize,
    required this.journal,
  });

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'id': id,
        'url': url,
        'finalUrl': finalUrl,
        'filename': filename,
        'totalSize': totalSize,
        'acceptsRanges': acceptsRanges,
        'etag': etag,
        'lastModified': lastModified,
        'contentType': contentType,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'state': state.name,
        'chunks': chunks.map((c) => c.toJson()).toList(),
        'addedAt': addedAt,
        'completedAt': completedAt,
        'errorMessage': errorMessage,
        'speedLimit': speedLimit,
        'targetChunkCount': targetChunkCount,
        'targetPath': targetPath,
        'minChunkSize': minChunkSize,
        'journal': journal,
      };
}

// ---------------------------------------------------------------------------
// Diagnostic / description payloads
// ---------------------------------------------------------------------------

/// Machine-readable diagnostic record. Mirrors what the NDJSON journal stores,
/// so log consumers and event consumers see identical data.
class DiagnosticPayload {
  final String downloadId;
  final String? chunkId;
  final DiagnosticLevel level;

  /// Stable machine-readable code, e.g. `idle-timeout`, `chunk-split`.
  final String code;
  final String message;
  final int timestamp;
  final Map<String, dynamic>? data;

  const DiagnosticPayload({
    required this.downloadId,
    this.chunkId,
    required this.level,
    required this.code,
    required this.message,
    required this.timestamp,
    this.data,
  });

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'downloadId': downloadId,
      'level': level.name,
      'code': code,
      'message': message,
      'timestamp': timestamp,
    };
    if (chunkId != null) m['chunkId'] = chunkId;
    if (data != null) m['data'] = data;
    return m;
  }
}

/// One row in [DownloadDescription.chunks].
class ChunkDescription {
  final String id;
  final ChunkStatus status;
  final ChunkQuality quality;
  final int offset;
  final int length;
  final int downloadedBytes;
  final int retries;

  const ChunkDescription({
    required this.id,
    required this.status,
    required this.quality,
    required this.offset,
    required this.length,
    required this.downloadedBytes,
    required this.retries,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'status': status.name,
        'quality': quality.name,
        'offset': offset,
        'length': length,
        'downloadedBytes': downloadedBytes,
        'retries': retries,
      };
}

/// Compact, serialisable status report aimed at dashboards and LLM/agent
/// consumers. Produced by [Download.describe].
class DownloadDescription {
  final String id;
  final String url;
  final String? filename;
  final String? targetPath;
  final int addedAt;
  final int? completedAt;
  final String? errorMessage;
  final DownloadState state;
  final int? totalBytes;
  final int downloadedBytes;
  final double? percent;
  final int totalSpeedBps;
  final int? etaMs;
  final int elapsedMs;
  final int activeChunks;
  final int totalChunks;
  final List<ChunkDescription> chunks;
  final List<DiagnosticPayload> recentDiagnostics;

  /// Number of HLS segments downloaded so far. Null for non-HLS downloads.
  final int? hlsSegmentsDone;

  /// Total HLS segment count. Null for non-HLS downloads.
  final int? hlsTotalSegments;

  const DownloadDescription({
    required this.id,
    required this.url,
    required this.filename,
    required this.targetPath,
    required this.addedAt,
    required this.completedAt,
    required this.errorMessage,
    required this.state,
    required this.totalBytes,
    required this.downloadedBytes,
    required this.percent,
    required this.totalSpeedBps,
    required this.etaMs,
    required this.elapsedMs,
    required this.activeChunks,
    required this.totalChunks,
    required this.chunks,
    required this.recentDiagnostics,
    this.hlsSegmentsDone,
    this.hlsTotalSegments,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'filename': filename,
        'targetPath': targetPath,
        'addedAt': addedAt,
        'completedAt': completedAt,
        'errorMessage': errorMessage,
        'state': state.name,
        'totalBytes': totalBytes,
        'downloadedBytes': downloadedBytes,
        'percent': percent,
        'totalSpeedBps': totalSpeedBps,
        'etaMs': etaMs,
        'elapsedMs': elapsedMs,
        'activeChunks': activeChunks,
        'totalChunks': totalChunks,
        'chunks': chunks.map((c) => c.toJson()).toList(),
        'recentDiagnostics': recentDiagnostics.map((d) => d.toJson()).toList(),
        if (hlsSegmentsDone != null) 'hlsSegmentsDone': hlsSegmentsDone,
        if (hlsTotalSegments != null) 'hlsTotalSegments': hlsTotalSegments,
      };
}
