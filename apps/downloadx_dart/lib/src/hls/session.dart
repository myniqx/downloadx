import 'dart:async';

import '../config.dart';
import '../io.dart';
import '../retry.dart';
import '../throttle.dart';
import 'parser.dart';
import 'types.dart';

typedef HlsProgressCallback = void Function(int done, int total);

class HlsSessionResult {
  /// Ordered local segment file paths ready to be concatenated.
  final List<String> segmentPaths;
  final HlsMediaPlaylist playlist;
  /// Final concatenated output file path.
  final String outputPath;

  HlsSessionResult({required this.segmentPaths, required this.playlist, required this.outputPath});
}

class HlsCancelledException implements Exception {
  const HlsCancelledException();
}

class HlsSession {
  final String id;
  final GlobalConfig global;
  final Throttle throttle;
  final HlsProgressCallback onProgress;
  final bool Function() isCancelled;
  final bool Function() isPaused;

  static const _maxParallel = 4;

  HlsSession({
    required this.id,
    required this.global,
    required this.throttle,
    required this.onProgress,
    required this.isCancelled,
    required this.isPaused,
  });

  Future<HlsSessionResult> run(String masterUrl, String outputPath) async {
    final playlist = await _resolveMediaPlaylist(masterUrl);

    if (playlist.isLive) {
      throw Exception('Live HLS streams are not supported');
    }

    final segDir = global.io.joinPath([global.cachePath, '$id-hls']);
    await global.io.mkdir(segDir);

    final paths = await _downloadSegments(playlist, segDir);
    await _concatSegments(paths, outputPath);
    return HlsSessionResult(segmentPaths: paths, playlist: playlist, outputPath: outputPath);
  }

  // ---- playlist resolution -------------------------------------------------

  Future<HlsMediaPlaylist> _resolveMediaPlaylist(String url) async {
    final text = await _fetchText(url);
    final result = parsePlaylist(text, url);

    if (result is HlsMediaResult) return result.playlist;

    final master = (result as HlsMasterResult).playlist;
    final best = selectBestStream(master);
    if (best == null) throw Exception('HLS master playlist has no streams');

    final mediaText = await _fetchText(best.uri);
    final mediaResult = parsePlaylist(mediaText, best.uri);
    if (mediaResult is! HlsMediaResult) {
      throw Exception('Expected media playlist, got another master playlist');
    }
    return mediaResult.playlist;
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
    final path = global.io.joinPath([segDir, name]);

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

        final res = await global.io.fetch(seg.uri, init);
        if (!res.ok) throw HttpStatusError(res.status, res.statusText);

        final buf = await res.bytes();
        await throttle.consume(buf.length);
        await global.io.writeFile(path, buf);
      },
      RetryOptions(
        maxRetries: global.maxRetries,
        retryDelay: global.retryDelay,
        retryBackoff: global.retryBackoff,
      ),
    );

    return path;
  }

  // ---- concat --------------------------------------------------------------

  Future<void> _concatSegments(List<String> segments, String output) async {
    final io = global.io;
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
    final res = await global.io.fetch(
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

  Future<void> cleanup(String segDir) async {
    final io = global.io;
    for (var i = 0; ; i++) {
      final p = io.joinPath([segDir, 'seg-${i.toString().padLeft(6, '0')}.ts']);
      if (!await io.exists(p)) break;
      await io.unlink(p).catchError((_) {});
    }
  }
}
