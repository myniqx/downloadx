import 'types.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _resolveUrl(String base, String ref) {
  if (ref.startsWith('http://') || ref.startsWith('https://')) return ref;
  return Uri.parse(base).resolve(ref).toString();
}

Map<String, String> _attrMap(String attrLine) {
  final map = <String, String>{};
  final re = RegExp(r'([A-Z0-9_-]+)=("(?:[^"\\]|\\.)*"|[^,]+)');
  for (final m in re.allMatches(attrLine)) {
    final key = m.group(1)!;
    var val = m.group(2)!;
    if (val.startsWith('"') && val.endsWith('"')) {
      val = val.substring(1, val.length - 1);
    }
    map[key] = val;
  }
  return map;
}

bool _isMasterPlaylist(String text) => text.contains('#EXT-X-STREAM-INF');

// ---------------------------------------------------------------------------
// Master playlist parser
// ---------------------------------------------------------------------------

/// Parses an HLS master playlist from [text]. [baseUrl] resolves relative URIs.
HlsMasterPlaylist parseMasterPlaylist(String text, String baseUrl) {
  final lines = text.split(RegExp(r'\r?\n'));
  final streams = <HlsStream>[];
  Map<String, String>? pending;

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || line == '#EXTM3U') continue;

    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      pending = _attrMap(line.substring('#EXT-X-STREAM-INF:'.length));
      continue;
    }

    if (pending != null && !line.startsWith('#')) {
      streams.add(HlsStream(
        bandwidth: int.tryParse(pending['BANDWIDTH'] ?? '') ?? 0,
        resolution: pending['RESOLUTION'],
        codecs: pending['CODECS'],
        uri: _resolveUrl(baseUrl, line),
      ));
      pending = null;
    }
  }

  streams.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
  return HlsMasterPlaylist(streams: streams);
}

// ---------------------------------------------------------------------------
// Media playlist parser
// ---------------------------------------------------------------------------

/// Parses an HLS media playlist from [text]. [baseUrl] resolves relative URIs.
HlsMediaPlaylist parseMediaPlaylist(String text, String baseUrl) {
  final lines = text.split(RegExp(r'\r?\n'));
  final segments = <HlsSegment>[];
  var targetDuration = 0;
  var totalDurationSec = 0.0;
  var isLive = true;
  var pendingDuration = 0.0;
  HlsByteRange? pendingByteRange;
  var byteRangeOffset = 0;

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || line == '#EXTM3U') continue;

    if (line.startsWith('#EXT-X-TARGETDURATION:')) {
      targetDuration =
          int.tryParse(line.substring('#EXT-X-TARGETDURATION:'.length)) ?? 0;
      continue;
    }

    if (line == '#EXT-X-ENDLIST') {
      isLive = false;
      continue;
    }

    if (line.startsWith('#EXTINF:')) {
      final val = line.substring('#EXTINF:'.length).split(',').first;
      pendingDuration = double.tryParse(val) ?? 0.0;
      continue;
    }

    if (line.startsWith('#EXT-X-BYTERANGE:')) {
      final val = line.substring('#EXT-X-BYTERANGE:'.length);
      final parts = val.split('@');
      final length = int.tryParse(parts[0]) ?? 0;
      final offset =
          parts.length > 1 ? (int.tryParse(parts[1]) ?? byteRangeOffset) : byteRangeOffset;
      pendingByteRange = HlsByteRange(offset: offset, length: length);
      byteRangeOffset = offset + length;
      continue;
    }

    if (line.startsWith('#')) continue;

    if (pendingDuration > 0) {
      segments.add(HlsSegment(
        uri: _resolveUrl(baseUrl, line),
        durationSec: pendingDuration,
        byteRange: pendingByteRange,
      ));
      totalDurationSec += pendingDuration;
      pendingDuration = 0.0;
      pendingByteRange = null;
    }
  }

  return HlsMediaPlaylist(
    segments: segments,
    totalDurationSec: totalDurationSec,
    targetDuration: targetDuration,
    isLive: isLive,
  );
}

// ---------------------------------------------------------------------------
// Auto-detect and parse
// ---------------------------------------------------------------------------

/// Sealed result type returned by [parsePlaylist].
sealed class HlsParseResult {}

/// Result when [parsePlaylist] detects a master playlist.
class HlsMasterResult extends HlsParseResult {
  /// The parsed master playlist.
  final HlsMasterPlaylist playlist;

  /// Creates an [HlsMasterResult].
  HlsMasterResult(this.playlist);
}

/// Result when [parsePlaylist] detects a media playlist.
class HlsMediaResult extends HlsParseResult {
  /// The parsed media playlist.
  final HlsMediaPlaylist playlist;

  /// Creates an [HlsMediaResult].
  HlsMediaResult(this.playlist);
}

/// Parses [text] as either a master or media playlist and returns the result.
/// [baseUrl] is used to resolve relative segment/stream URIs.
HlsParseResult parsePlaylist(String text, String baseUrl) {
  if (_isMasterPlaylist(text)) {
    return HlsMasterResult(parseMasterPlaylist(text, baseUrl));
  }
  return HlsMediaResult(parseMediaPlaylist(text, baseUrl));
}

/// Returns the highest-bandwidth stream from [master], or null when empty.
HlsStream? selectBestStream(HlsMasterPlaylist master) =>
    master.streams.isEmpty ? null : master.streams.first;
