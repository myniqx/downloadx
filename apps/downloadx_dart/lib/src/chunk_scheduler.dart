import 'chunk.dart';
import 'types.dart';

/// A planned byte range assigned to one chunk before download starts.
class ChunkPlan {
  /// Byte offset from the start of the file.
  final int offset;

  /// Number of bytes this chunk is responsible for.
  final int length;

  /// Bytes already written for this range (non-zero on resume).
  final int downloadedBytes;

  /// Creates a [ChunkPlan] for the given byte range.
  const ChunkPlan({
    required this.offset,
    required this.length,
    required this.downloadedBytes,
  });
}

/// Options for [planChunks].
class PlanOptions {
  /// Total file size in bytes.
  final int totalSize;

  /// Desired number of chunks (may be reduced when file is small).
  final int targetChunkCount;

  /// Minimum bytes per chunk; prevents splitting into too-small pieces.
  final int minChunkSize;

  /// Bytes already placed on disk per offset-sorted plan index (for resume).
  final List<ChunkPlan>? resumeFrom;

  /// Creates a [PlanOptions] with the given parameters.
  const PlanOptions({
    required this.totalSize,
    required this.targetChunkCount,
    required this.minChunkSize,
    this.resumeFrom,
  });
}

/// Divides a [totalSize] byte file into at most `targetChunkCount` contiguous
/// chunks, each no smaller than `minChunkSize` (except the last, which gets the
/// remainder). Single-chunk fallback when the file is smaller than minChunkSize.
List<ChunkPlan> planChunks(PlanOptions opts) {
  final resume = opts.resumeFrom;
  if (resume != null && resume.isNotEmpty) {
    // Preserve the historical plan on resume so offsets line up with disk.
    return resume
        .map((c) => ChunkPlan(
              offset: c.offset,
              length: c.length,
              downloadedBytes: c.downloadedBytes,
            ))
        .toList();
  }
  if (opts.totalSize <= 0) {
    return const [ChunkPlan(offset: 0, length: 0, downloadedBytes: 0)];
  }
  if (opts.totalSize <= opts.minChunkSize || opts.targetChunkCount <= 1) {
    return [ChunkPlan(offset: 0, length: opts.totalSize, downloadedBytes: 0)];
  }
  final count = _min(
    opts.targetChunkCount,
    _max(1, opts.totalSize ~/ opts.minChunkSize),
  );
  final base = opts.totalSize ~/ count;
  final plans = <ChunkPlan>[];
  var offset = 0;
  for (var i = 0; i < count; i += 1) {
    final last = i == count - 1;
    final length = last ? opts.totalSize - offset : base;
    plans.add(ChunkPlan(offset: offset, length: length, downloadedBytes: 0));
    offset += length;
  }
  return plans;
}

/// A chunk selected to donate its tail to a new parallel worker.
class SplitCandidate {
  /// The chunk whose tail will be truncated and reassigned.
  final Chunk chunk;

  /// The slice taken from [chunk]'s tail, to be issued as a new chunk.
  final ByteRange newRange;

  /// Why this split was triggered.
  final SplitReason reason;

  /// Creates a [SplitCandidate].
  const SplitCandidate({
    required this.chunk,
    required this.newRange,
    required this.reason,
  });
}

/// Options for [findSplitCandidate].
class FindSplitOptions {
  /// Currently active chunks to evaluate for splitting.
  final List<Chunk> activeChunks;

  /// Upper bound on total live chunks; no split when already at capacity.
  final int maxChunks;

  /// Minimum bytes a chunk must have remaining to be eligible for splitting.
  final int minChunkSize;

  /// The reason that triggered this split search.
  final SplitReason trigger;

  /// Creates a [FindSplitOptions].
  const FindSplitOptions({
    required this.activeChunks,
    required this.maxChunks,
    required this.minChunkSize,
    required this.trigger,
  });
}

/// Picks the chunk best suited to donate its tail to a new worker.
///
/// Scoring:
///   1. Prefer `stalled` over `poor` over `good` (slower chunks lose more).
///   2. Among equal quality tiers, prefer the one with the most remaining bytes.
///
/// Returns null when already at max chunk count or no chunk has enough
/// remaining bytes to split.
SplitCandidate? findSplitCandidate(FindSplitOptions opts) {
  if (opts.activeChunks.length >= opts.maxChunks) return null;

  final eligible = opts.activeChunks
      .where((c) =>
          c.status == ChunkStatus.downloading &&
          c.remainingBytes >= opts.minChunkSize * 2)
      .toList();
  if (eligible.isEmpty) return null;

  eligible.sort((a, b) => _scoreChunk(b).compareTo(_scoreChunk(a)));
  final pick = eligible.first;

  final newRange = pick.truncateTail(opts.minChunkSize);
  if (newRange == null) return null;

  return SplitCandidate(chunk: pick, newRange: newRange, reason: opts.trigger);
}

double _scoreChunk(Chunk chunk) {
  final qualityWeight = chunk.quality == ChunkQuality.stalled
      ? 3
      : chunk.quality == ChunkQuality.poor
          ? 2
          : 1;
  // Remaining bytes normalised to MiB so the quality multiplier dominates for
  // comparable remainders, but size still breaks ties.
  final remainingMiB = chunk.remainingBytes / (1024 * 1024);
  return qualityWeight * 1000 + remainingMiB;
}

int _min(int a, int b) => a < b ? a : b;
int _max(int a, int b) => a > b ? a : b;
