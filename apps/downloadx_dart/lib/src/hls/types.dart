/// A single variant stream entry from an HLS master playlist.
class HlsStream {
  /// Peak bandwidth in bits/sec.
  final int bandwidth;

  /// Resolution string (e.g. `'1920x1080'`), or null when absent.
  final String? resolution;

  /// Codec string (e.g. `'avc1.42c01e,mp4a.40.2'`), or null when absent.
  final String? codecs;

  /// Absolute URI of the media playlist for this stream.
  final String uri;

  /// Creates an [HlsStream].
  const HlsStream({
    required this.bandwidth,
    required this.resolution,
    required this.codecs,
    required this.uri,
  });
}

/// Parsed HLS master playlist containing one or more variant streams.
class HlsMasterPlaylist {
  /// Sorted by bandwidth descending — [0] is the best quality.
  final List<HlsStream> streams;

  /// Creates an [HlsMasterPlaylist].
  const HlsMasterPlaylist({required this.streams});
}

/// A byte-range within a segment file (used with `#EXT-X-BYTERANGE`).
class HlsByteRange {
  /// Byte offset within the segment resource.
  final int offset;

  /// Number of bytes to read.
  final int length;

  /// Creates an [HlsByteRange].
  const HlsByteRange({required this.offset, required this.length});
}

/// A single media segment from an HLS media playlist.
class HlsSegment {
  /// Absolute URI of the segment.
  final String uri;

  /// Segment duration in seconds (from `#EXTINF`).
  final double durationSec;

  /// Byte range within the segment URI, or null for the full resource.
  final HlsByteRange? byteRange;

  /// Creates an [HlsSegment].
  const HlsSegment({
    required this.uri,
    required this.durationSec,
    this.byteRange,
  });
}

/// Parsed HLS media playlist.
class HlsMediaPlaylist {
  /// Ordered list of segments to download.
  final List<HlsSegment> segments;

  /// Sum of all segment durations in seconds.
  final double totalDurationSec;

  /// `#EXT-X-TARGETDURATION` value in seconds.
  final int targetDuration;

  /// True when #EXT-X-ENDLIST is absent — live stream, not supported.
  final bool isLive;

  /// Creates an [HlsMediaPlaylist].
  const HlsMediaPlaylist({
    required this.segments,
    required this.totalDurationSec,
    required this.targetDuration,
    required this.isLive,
  });
}
