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
enum ChunkMode {
  /// Split automatically based on file size and [DefaultConfig.targetChunkCount].
  auto,

  /// Force a single sequential chunk regardless of server support.
  single,

  /// Use exactly [DownloadXConfig.targetChunkCount] chunks.
  fixed,
}

/// Lifecycle state of a whole download.
enum DownloadState {
  /// Registered but not yet started.
  idle,

  /// Probing the URL to determine size, range support, and filename.
  probing,

  /// Actively downloading chunks.
  downloading,

  /// Paused by the user; resumes from progress on next [Download.start].
  paused,

  /// All chunks completed and the file has been renamed to its final path.
  completed,

  /// A permanent error occurred; see [Download.meta] for the error message.
  error,

  /// Cancelled by the user via [Download.cancel].
  cancelled,
}

/// Lifecycle state of a single chunk.
enum ChunkStatus {
  /// Chunk has not started downloading yet.
  pending,

  /// Chunk is actively streaming bytes.
  downloading,

  /// Chunk was paused; will restart from [Chunk.downloadedBytes] on next run.
  paused,

  /// Chunk finished writing all its bytes.
  completed,

  /// Chunk failed permanently after exhausting retries.
  failed,

  /// Chunk's byte range was transferred to another chunk.
  reassigned,
}

/// Qualitative health of a chunk, used by the dynamic splitter.
enum ChunkQuality {
  /// Chunk speed is within normal range.
  good,

  /// Chunk speed is below [qualityPoorRatio] × median.
  poor,

  /// Chunk speed is below [qualityStalledRatio] × median.
  stalled,
}

/// Why a split happened. Serialised with the wire-compatible string used by
/// the TypeScript implementation (`completed-reassign`, not `completedReassign`).
enum SplitReason {
  /// Split triggered because a chunk was classified as slow or stalled.
  slow,

  /// Split triggered because a chunk failed and its range was reassigned.
  failed,

  /// Split triggered when a completed chunk's remaining capacity was redistributed.
  completedReassign;

  String get wire => switch (this) {
        SplitReason.slow => 'slow',
        SplitReason.failed => 'failed',
        SplitReason.completedReassign => 'completed-reassign',
      };
}

/// Severity level of a [DiagnosticPayload].
enum DiagnosticLevel {
  /// Informational — normal lifecycle events.
  info,

  /// Warning — recoverable condition (retry, stall, range fallback).
  warn,

  /// Error — a failure that may or may not be fatal.
  error,
}

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

  /// Free-form note attached to this download. Persisted and returned in
  /// [Download.describe]; has no behavioural effect.
  final String? description;

  /// Arbitrary key/value data attached to this download (e.g. sourceLink,
  /// fromExtension). Persisted and returned in [Download.describe]; has no
  /// behavioural effect. Intended for apps consuming the core.
  final Map<String, String>? metadata;

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
    this.description,
    this.metadata,
  });
}

// ---------------------------------------------------------------------------
// Snapshots / probe / meta
// ---------------------------------------------------------------------------

/// A half-open byte range `[offset, offset + length)`.
class ByteRange {
  /// Start position within the file.
  final int offset;

  /// Number of bytes in the range.
  final int length;

  /// Creates a [ByteRange].
  const ByteRange({required this.offset, required this.length});
}

/// Snapshot of a chunk, persisted to the meta file for resume.
class ChunkSnapshot {
  /// Unique chunk identifier.
  String id;

  /// Byte offset from the start of the file.
  int offset;

  /// Number of bytes this chunk covers.
  int length;

  /// Bytes already written (non-zero on resume).
  int downloadedBytes;

  /// Last known lifecycle state.
  ChunkStatus status;

  /// Last known quality classification.
  ChunkQuality quality;

  /// Number of retries attempted.
  int retries;

  /// Last error message, or null if no error occurred.
  String? lastError;

  /// HLS segment mode: chunk writes from byte 0 into its own file rather than
  /// at an offset within a shared part file. Null for normal chunks.
  bool? isSegment;

  /// HLS segment: the dedicated file this segment is written to.
  String? targetFilePath;

  /// HLS segment: source segment URI (resolved).
  String? uri;

  /// HLS segment: segment duration in seconds (from #EXTINF), for ETA.
  num? durationSec;

  /// Creates a [ChunkSnapshot].
  ChunkSnapshot({
    required this.id,
    required this.offset,
    required this.length,
    required this.downloadedBytes,
    required this.status,
    required this.quality,
    required this.retries,
    this.lastError,
    this.isSegment,
    this.targetFilePath,
    this.uri,
    this.durationSec,
  });

  /// Serialises this snapshot to a JSON-compatible map.
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
    if (isSegment != null) m['isSegment'] = isSegment;
    if (targetFilePath != null) m['targetFilePath'] = targetFilePath;
    if (uri != null) m['uri'] = uri;
    if (durationSec != null) m['durationSec'] = durationSec;
    return m;
  }

  /// Deserialises a [ChunkSnapshot] from a JSON map.
  factory ChunkSnapshot.fromJson(Map<String, dynamic> j) => ChunkSnapshot(
        id: j['id'] as String,
        offset: (j['offset'] as num).toInt(),
        length: (j['length'] as num).toInt(),
        downloadedBytes: (j['downloadedBytes'] as num).toInt(),
        status: chunkStatusFromString(j['status'] as String),
        quality: chunkQualityFromString(j['quality'] as String),
        retries: (j['retries'] as num).toInt(),
        lastError: j['lastError'] as String?,
        isSegment: j['isSegment'] as bool?,
        targetFilePath: j['targetFilePath'] as String?,
        uri: j['uri'] as String?,
        durationSec: j['durationSec'] as num?,
      );
}

/// Result of the initial HTTP probe.
class ProbeResult {
  /// The original request URL.
  final String url;

  /// Final URL after any redirects.
  final String finalUrl;

  /// Total file size in bytes, or null when unknown (no Content-Length).
  final int? totalSize;

  /// True when the server honours `Range` headers.
  final bool acceptsRanges;

  /// ETag validator for cache-busting on resume.
  final String? etag;

  /// Last-Modified validator for cache-busting on resume.
  final String? lastModified;

  /// Content-Type returned by the server.
  final String? contentType;

  /// Inferred filename (from Content-Disposition, URL path, or timestamp fallback).
  final String filename;

  /// True when the content-type indicates an HLS playlist (`.m3u8`).
  final bool isHls;

  /// Creates a [ProbeResult].
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

  /// Returns a copy with the given fields overridden.
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
  /// Schema version; mismatches cause the file to be discarded on load.
  final int schemaVersion;

  /// Unique download identifier.
  final String id;

  /// Original request URL.
  final String url;

  /// Final URL after redirects (filled after probe).
  String? finalUrl;

  /// Inferred filename (filled after probe).
  String? filename;

  /// Total file size in bytes (filled after probe, null when unknown).
  int? totalSize;

  /// Whether the server supports byte-range requests.
  bool acceptsRanges;

  /// ETag validator (filled after probe).
  String? etag;

  /// Last-Modified validator (filled after probe).
  String? lastModified;

  /// Content-Type returned by the server.
  String? contentType;

  /// Unix timestamp (ms) when the meta file was first created.
  final int createdAt;

  /// Unix timestamp (ms) of the last meta write.
  int updatedAt;

  /// Current download state, dehydrated before persist.
  DownloadState state;

  /// Chunk snapshots, updated on every progress persist.
  List<ChunkSnapshot> chunks;

  /// Unix timestamp (ms) when the download was registered.
  final int addedAt;

  /// Unix timestamp (ms) when the download completed, or null.
  int? completedAt;

  /// Last error message, or null.
  String? errorMessage;

  /// Per-download speed limit in bytes/sec, or null (uses manager default).
  int? speedLimit;

  /// Per-download chunk count override, or null.
  int? targetChunkCount;

  /// Per-download target directory override, or null.
  String? targetPath;

  /// Per-download minimum chunk size override, or null.
  int? minChunkSize;

  /// Whether the NDJSON journal is enabled for this download, or null (manager default).
  bool? journal;

  /// Whether the resolved resource is an HLS playlist. Persisted so resume can
  /// reconstruct segment chunks without re-probing.
  bool isHls;

  /// Free-form note (see [DownloadOptions.description]).
  String? description;

  /// Arbitrary key/value data (see [DownloadOptions.metadata]).
  Map<String, String>? metadata;

  /// Per-download HTTP headers merged on top of global headers.
  Map<String, String>? headers;

  /// Creates a [MetaFile].
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
    this.isHls = false,
    this.description,
    this.metadata,
    this.headers,
  });

  /// Serialises this meta file to a JSON-compatible map.
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
        'isHls': isHls,
        'description': description,
        'metadata': metadata,
        'headers': headers,
      };
}

// ---------------------------------------------------------------------------
// Diagnostic / description payloads
// ---------------------------------------------------------------------------

/// A structured log entry stored in `{id}-log.json`.
class LogEntry {
  final DiagnosticLevel level;
  final String code;
  final Map<String, dynamic>? params;
  final int timestamp;

  const LogEntry({
    this.level = DiagnosticLevel.info,
    required this.code,
    this.params,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'level': level.name,
    'code': code,
    if (params != null) 'params': params,
    'timestamp': timestamp,
  };

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
    level: DiagnosticLevel.values.firstWhere(
      (e) => e.name == json['level'],
      orElse: () => DiagnosticLevel.info,
    ),
    code: json['code'] as String,
    params: json['params'] as Map<String, dynamic>?,
    timestamp: json['timestamp'] as int,
  );
}

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

  /// Serialises this payload to a JSON-compatible map (used for NDJSON journal).
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
  /// Chunk identifier.
  final String id;

  /// Current lifecycle state.
  final ChunkStatus status;

  /// Current quality classification.
  final ChunkQuality quality;

  /// Byte offset from the start of the file.
  final int offset;

  /// Total bytes assigned to this chunk.
  final int length;

  /// Bytes written so far.
  final int downloadedBytes;

  /// Number of retries so far.
  final int retries;

  /// Creates a [ChunkDescription].
  const ChunkDescription({
    required this.id,
    required this.status,
    required this.quality,
    required this.offset,
    required this.length,
    required this.downloadedBytes,
    required this.retries,
  });

  /// Serialises to a JSON-compatible map.
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
  /// Download identifier.
  final String id;

  /// Original request URL.
  final String url;

  /// Inferred filename, or null if not yet probed.
  final String? filename;

  /// Per-download target directory override, or null.
  final String? targetPath;

  /// Unix timestamp (ms) when the download was registered.
  final int addedAt;

  /// Unix timestamp (ms) when the download completed, or null.
  final int? completedAt;

  /// Last error message, or null.
  final String? errorMessage;

  /// Free-form note (see [DownloadOptions.description]).
  final String? description;

  /// Arbitrary key/value data (see [DownloadOptions.metadata]).
  final Map<String, String>? metadata;

  /// Current download state.
  final DownloadState state;

  /// Total file size in bytes, or null when unknown.
  final int? totalBytes;

  /// Bytes downloaded across all chunks.
  final int downloadedBytes;

  /// Progress as a percentage (0–100), or null when total size is unknown.
  final double? percent;

  /// Aggregate download speed in bytes/sec.
  final int totalSpeedBps;

  /// Estimated time remaining in ms, or null when speed/size is unknown.
  final int? etaMs;

  /// Wall-clock elapsed time in ms since [Download.start] was called.
  final int elapsedMs;

  /// Number of chunks currently in the `downloading` state.
  final int activeChunks;

  /// Total number of chunks (including completed and failed ones).
  final int totalChunks;

  /// Descriptions of chunks that are not yet completed or reassigned.
  final List<ChunkDescription> chunks;

  /// Up to the last 10 diagnostic events for this download.
  final List<DiagnosticPayload> recentDiagnostics;

  /// Number of HLS segments downloaded so far. Null for non-HLS downloads.
  final int? hlsSegmentsDone;

  /// Total HLS segment count. Null for non-HLS downloads.
  final int? hlsTotalSegments;

  /// Creates a [DownloadDescription].
  const DownloadDescription({
    required this.id,
    required this.url,
    required this.filename,
    required this.targetPath,
    required this.addedAt,
    required this.completedAt,
    required this.errorMessage,
    this.description,
    this.metadata,
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

  /// Serialises to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'filename': filename,
        'targetPath': targetPath,
        'addedAt': addedAt,
        'completedAt': completedAt,
        'errorMessage': errorMessage,
        'description': description,
        'metadata': metadata,
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
