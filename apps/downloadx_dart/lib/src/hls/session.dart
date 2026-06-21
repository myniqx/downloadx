import 'dart:async';

import '../config.dart';
import '../io.dart';
import '../retry.dart';
import '../throttle.dart';
import '../types.dart';
import 'parser.dart';
import 'types.dart';

/// Progress callback called after each batch of HLS segments finishes.
/// [done] is the completed segment count; [total] is the total segment count.
typedef HlsProgressCallback = void Function(int done, int total);

/// Result of a successfully completed single-stream HLS download.
class HlsSessionResult {
  /// Ordered local segment file paths ready to be concatenated.
  final List<String> segmentPaths;

  /// The parsed media playlist that was downloaded.
  final HlsMediaPlaylist playlist;

  /// Final concatenated output file path.
  final String outputPath;

  /// Creates an [HlsSessionResult].
  HlsSessionResult({required this.segmentPaths, required this.playlist, required this.outputPath});
}

/// Returned when a master playlist has multiple streams — each stream has been
/// registered as an idle Download via [DlxContext.addUrl]; no segments downloaded.
class HlsMultiStreamResult {
  final List<HlsStream> streams;
  HlsMultiStreamResult({required this.streams});
}

/// Thrown internally when the HLS session is cancelled mid-download.
class HlsCancelledException implements Exception {
  /// Creates an [HlsCancelledException].
  const HlsCancelledException();
}

/// Orchestrates downloading and concatenating HLS segments for a single stream.
class HlsSession {
  /// Download identifier (used for temp segment directory naming).
  final String id;

  /// Manager context providing I/O, config, and the ability to register streams.
  final DlxContext context;

  /// Bandwidth throttle shared with the parent download.
  final Throttle throttle;

  /// Called after each batch of segments completes.
  final HlsProgressCallback onProgress;

  /// Returns true when the parent download has been cancelled.
  final bool Function() isCancelled;

  /// Returns true when the parent download has been paused.
  final bool Function() isPaused;

  static const _maxParallel = 4;

  /// Creates an [HlsSession].
  HlsSession({
    required this.id,
    required this.context,
    required this.throttle,
    required this.onProgress,
    required this.isCancelled,
    required this.isPaused,
  });

  /// Run the HLS session.
  /// - Single stream → downloads segments and returns [HlsSessionResult].
  /// - Multiple streams → registers each as a separate idle Download via
  ///   [context.addUrl] and returns [HlsMultiStreamResult].
  Future<Object> run(String masterUrl, String outputPath, String baseFilename) async {
    final resolution = await _resolvePlaylist(masterUrl);

    if (resolution is _MultiStream) {
      await _registerStreams(resolution.streams, baseFilename, outputPath);
      return HlsMultiStreamResult(streams: resolution.streams);
    }

    final playlist = (resolution as _MediaResult).playlist;
    if (playlist.isLive) {
      throw Exception('Live HLS streams are not supported');
    }

    final segDir = context.io.joinPath([context.cachePath, '$id-hls']);
    await context.io.mkdir(segDir);

    final paths = await _downloadSegments(playlist, segDir);
    await _concatSegments(paths, outputPath);
    return HlsSessionResult(segmentPaths: paths, playlist: playlist, outputPath: outputPath);
  }

  // ---- playlist resolution -------------------------------------------------

  Future<Object> _resolvePlaylist(String url) async {
    final text = await _fetchText(url);
    final result = parsePlaylist(text, url);

    if (result is HlsMediaResult) return _MediaResult(result.playlist);

    final streams = (result as HlsMasterResult).playlist.streams;
    if (streams.isEmpty) throw Exception('HLS master playlist has no streams');

    if (streams.length > 1) return _MultiStream(streams);

    // Single stream — resolve directly.
    final mediaText = await _fetchText(streams[0].uri);
    final mediaResult = parsePlaylist(mediaText, streams[0].uri);
    if (mediaResult is! HlsMediaResult) {
      throw Exception('Expected media playlist, got another master playlist');
    }
    return _MediaResult(mediaResult.playlist);
  }

  Future<void> _registerStreams(
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

  // ---- segment download ----------------------------------------------------

  Future<List<String>> _downloadSegments(
    HlsMediaPlaylist playlist,
    String segDir,
  ) async {
    final segments = playlist.segments;
    final total = segments.length;
    final paths = List<String>.filled(total, '');
    var completedCount = 0;

    for (var i = 0; i < total; i += _maxParallel) {
      _checkCancelled();

      while (isPaused()) {
        _checkCancelled();
        await Future.delayed(const Duration(milliseconds: 200));
      }

      final end = (i + _maxParallel).clamp(0, total);
      final batch = segments.sublist(i, end);

      final batchPaths = await Future.wait(
        List.generate(batch.length, (j) => _downloadSegment(batch[j], i + j, segDir)),
      );

      for (var j = 0; j < batchPaths.length; j++) {
        paths[i + j] = batchPaths[j];
      }

      completedCount += batch.length;
      onProgress(completedCount, total);
    }

    return paths;
  }

  Future<String> _downloadSegment(
    HlsSegment seg,
    int index,
    String segDir,
  ) async {
    final name = 'seg-${index.toString().padLeft(6, '0')}.ts';
    final path = context.io.joinPath([segDir, name]);

    await withRetry(
      (_) async {
        _checkCancelled();

        final init = FetchInit(
          headers: seg.byteRange != null
              ? {
                  'Range':
                      'bytes=${seg.byteRange!.offset}-${seg.byteRange!.offset + seg.byteRange!.length - 1}',
                }
              : null,
        );

        final res = await context.io.fetch(seg.uri, init);
        if (!res.ok) throw HttpStatusError(res.status, res.statusText);

        final buf = await res.bytes();
        await throttle.consume(buf.length);
        await context.io.writeFile(path, buf);
      },
      RetryOptions(
        maxRetries: context.maxRetries,
        retryDelay: context.retryDelay,
        retryBackoff: context.retryBackoff,
      ),
    );

    return path;
  }

  // ---- concat --------------------------------------------------------------

  Future<void> _concatSegments(List<String> segments, String output) async {
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

  void _checkCancelled() {
    if (isCancelled()) throw const HlsCancelledException();
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

// ---- internal discriminated union helpers ----------------------------------

class _MediaResult {
  final HlsMediaPlaylist playlist;
  _MediaResult(this.playlist);
}

class _MultiStream {
  final List<HlsStream> streams;
  _MultiStream(this.streams);
}
