import 'types.dart';

/// Package identity. Kept in one place so it can be changed if the name ever
/// collides; the value drives the meta-file extension, temp-file suffix, and
/// public-facing strings.
const String appName = 'downloadx';

/// Extension appended to produce the sidecar meta file.
const String metaExt = '.downloadx.json';

/// Extension used for in-progress downloads (renamed away on completion).
const String tempExt = '.downloadx.part';

/// Extension used for the NDJSON diagnostic journal sidecar.
const String journalExt = '.downloadx.log';

/// Current meta-file schema version. Bump when breaking the persisted shape.
const int metaSchemaVersion = 3;

/// Config defaults applied when a field is omitted by the consumer. Mirrors
/// the TypeScript `DEFAULT_CONFIG`.
class DefaultConfig {
  static const int maxParallel = 3;
  static const ChunkMode chunkMode = ChunkMode.auto;
  static const int targetChunkCount = 4;

  /// 1 MiB — smaller than this is not worth splitting.
  static const int minChunkSize = 1024 * 1024;
  static const int maxRetries = 5;
  static const int retryDelay = 1000;
  static const num retryBackoff = 2;

  /// ms used by the moving-average hot/slow detector.
  static const int speedSampleWindow = 3000;

  /// bytes/sec; 0 disables throttling.
  static const int speedLimit = 0;

  /// network IDLE timeout — aborts only when no bytes arrive for this long.
  static const int requestTimeout = 30000;
}

/// Sentinel chunk length for downloads whose total size is unknown (no
/// Content-Length). The chunk streams until EOF; [downloadedBytes] never
/// reaches this value, so completion is driven by the stream ending.
///
/// Matches the JavaScript `Number.MAX_SAFE_INTEGER` so persisted meta files
/// are byte-compatible with the TypeScript implementation.
const int unknownSizeLength = 9007199254740991; // 2^53 - 1

/// How long a chunk may stay classified `stalled` before the download aborts
/// its current request and retries it from the bytes already written.
const int stallRecoveryMs = 15000;

/// Threshold ratios used by the chunk-quality classifier.
///
/// A chunk is `poor` when its windowed speed is below [qualityPoorRatio] × the
/// manager's median chunk speed, and `stalled` below [qualityStalledRatio] ×
/// median. Intentionally not user-configurable yet — tune here first.
const double qualityPoorRatio = 0.5;
const double qualityStalledRatio = 0.15;

/// Grace period (ms) before quality is evaluated after a chunk starts.
const int qualityWarmupMs = 1500;

/// HTTP status codes that should never be retried (client errors).
const Set<int> nonRetryableStatus = {
  400,
  401,
  403,
  404,
  405,
  406,
  409,
  410,
  414,
  415,
  416,
  422,
  451,
};

/// HTTP status codes we treat as transient and worth retrying.
const Set<int> retryableStatus = {408, 425, 429, 500, 502, 503, 504};
