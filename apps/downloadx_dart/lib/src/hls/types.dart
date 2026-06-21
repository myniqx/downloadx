class HlsStream {
  final int bandwidth;
  final String? resolution;
  final String? codecs;
  final String uri;

  const HlsStream({
    required this.bandwidth,
    required this.resolution,
    required this.codecs,
    required this.uri,
  });
}

class HlsMasterPlaylist {
  /// Sorted by bandwidth descending — [0] is the best quality.
  final List<HlsStream> streams;
  const HlsMasterPlaylist({required this.streams});
}

class HlsByteRange {
  final int offset;
  final int length;
  const HlsByteRange({required this.offset, required this.length});
}

class HlsSegment {
  final String uri;
  final double durationSec;
  final HlsByteRange? byteRange;

  const HlsSegment({
    required this.uri,
    required this.durationSec,
    this.byteRange,
  });
}

class HlsMediaPlaylist {
  final List<HlsSegment> segments;
  final double totalDurationSec;
  final int targetDuration;
  /// True when #EXT-X-ENDLIST is absent — live stream, not supported.
  final bool isLive;

  const HlsMediaPlaylist({
    required this.segments,
    required this.totalDurationSec,
    required this.targetDuration,
    required this.isLive,
  });
}
