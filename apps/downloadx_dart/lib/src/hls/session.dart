import 'dart:async';

import '../config.dart';
import '../io.dart';
import '../types.dart';
import 'parser.dart';
import 'types.dart';

/// Resolved media playlist — segments ready to be planned as chunks.
class HlsMediaResolution {
  /// The parsed media playlist.
  final HlsMediaPlaylist playlist;

  /// Creates an [HlsMediaResolution].
  HlsMediaResolution(this.playlist);
}

/// Returned when a master playlist has multiple streams — the caller should
/// register each as a child download; no segments are downloaded in this case.
class HlsMultiStreamResult {
  /// The available variant streams.
  final List<HlsStream> streams;

  /// Creates an [HlsMultiStreamResult].
  HlsMultiStreamResult({required this.streams});
}

/// HLS playlist resolver + segment concatenator. Downloading is no longer the
/// session's job — each segment is downloaded as an `isSegment` Chunk by the
/// owning Download. The session only resolves playlists, registers child
/// downloads for multi-stream masters, concatenates segment files, and cleans
/// them up.
class HlsSession {
  /// Download identifier (used for temp segment directory naming).
  final String id;

  /// Manager context providing I/O, config, and the ability to register streams.
  final DlxContext context;

  /// Creates an [HlsSession].
  HlsSession({required this.id, required this.context});

  // ---- playlist resolution -------------------------------------------------

  /// Fetch and parse the playlist at [url].
  /// - media playlist → [HlsMediaResolution]
  /// - master with >1 stream → [HlsMultiStreamResult]
  /// - master with 1 stream → resolves that stream's media playlist
  /// Throws on live streams (no #EXT-X-ENDLIST).
  Future<Object> resolve(String url) async {
    final text = await _fetchText(url);
    final result = parsePlaylist(text, url);

    if (result is HlsMediaResult) {
      if (result.playlist.isLive) {
        throw Exception('Live HLS streams are not supported');
      }
      return HlsMediaResolution(result.playlist);
    }

    final streams = (result as HlsMasterResult).playlist.streams;
    if (streams.isEmpty) throw Exception('HLS master playlist has no streams');

    if (streams.length > 1) return HlsMultiStreamResult(streams: streams);

    // Single stream — resolve directly.
    final mediaText = await _fetchText(streams[0].uri);
    final mediaResult = parsePlaylist(mediaText, streams[0].uri);
    if (mediaResult is! HlsMediaResult) {
      throw Exception('Expected media playlist, got another master playlist');
    }
    if (mediaResult.playlist.isLive) {
      throw Exception('Live HLS streams are not supported');
    }
    return HlsMediaResolution(mediaResult.playlist);
  }

  /// Register each stream of a multi-stream master as a separate idle download.
  Future<void> registerStreams(
    List<HlsStream> streams,
    String baseFilename,
    String outputPath,
  ) async {
    final dotIndex = baseFilename.lastIndexOf('.');
    final ext = dotIndex >= 0 ? baseFilename.substring(dotIndex) : '.ts';
    final stem = dotIndex >= 0 ? baseFilename.substring(0, dotIndex) : baseFilename;
    final dir = _dirname(outputPath);

    for (var i = 0; i < streams.length; i++) {
      final stream = streams[i];
      final String qualifier;
      if (stream.resolution != null) {
        qualifier = stream.resolution!;
      } else if (stream.bandwidth > 0) {
        qualifier = '${(stream.bandwidth / 1000).round()}kbps';
      } else {
        qualifier = 'stream-${i + 1}';
      }
      final filename = '$stem $qualifier$ext';
      await context.addUrl(
        stream.uri,
        DownloadOptions(filename: filename, targetPath: dir, autoStart: false),
      );
    }
  }

  /// Directory where this download's segment files live.
  String segDir() => context.io.joinPath([context.cachePath, '$id-hls']);

  /// Local file path for segment [index].
  String segPath(int index) =>
      context.io.joinPath([segDir(), 'seg-${index.toString().padLeft(6, '0')}.ts']);

  // ---- concat --------------------------------------------------------------

  /// Concatenate ordered segment files into [output]. Uses io.concatSegments
  /// (e.g. ffmpeg) when available, otherwise a binary append fallback.
  Future<void> concat(List<String> segments, String output) async {
    final io = context.io;
    if (io.concatSegments != null) {
      await io.concatSegments!(segments, output);
      return;
    }
    // Binary concat fallback: read each segment and append to output.
    final parts = <List<int>>[];
    for (final seg in segments) {
      parts.add(await io.readFile(seg));
    }
    final merged = parts.fold<List<int>>([], (acc, p) => acc..addAll(p));
    await io.writeFile(output, merged);
  }

  // ---- helpers -------------------------------------------------------------

  Future<String> _fetchText(String url) async {
    final res = await context.io.fetch(
      url,
      FetchInit(headers: {
        'Accept': 'application/vnd.apple.mpegurl, application/x-mpegurl, */*',
      }),
    );
    if (!res.ok) {
      throw Exception('Failed to fetch playlist: HTTP ${res.status} $url');
    }
    return res.text();
  }

  /// Deletes all segment files written to [segDir] by this session.
  Future<void> cleanup(String segDir) async {
    final io = context.io;
    for (var i = 0; ; i++) {
      final p = io.joinPath([segDir, 'seg-${i.toString().padLeft(6, '0')}.ts']);
      if (!await io.exists(p)) break;
      await io.unlink(p).catchError((_) {});
    }
  }

  static String _dirname(String path) {
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return '/';
    return path.substring(0, idx);
  }
}
