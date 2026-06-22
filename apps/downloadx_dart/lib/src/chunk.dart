import 'dart:async';
import 'dart:typed_data';

import 'config.dart';
import 'constants.dart';
import 'events.dart';
import 'io.dart';
import 'retry.dart';
import 'speed_tracker.dart';
import 'types.dart';

/// Immutable configuration passed to a [Chunk] at construction.
class ChunkParams {
  /// Unique identifier for this chunk.
  final String id;

  /// Identifier of the parent download.
  final String downloadId;

  /// The URL to fetch bytes from.
  final String url;

  /// Absolute path of the in-progress `.part` file.
  final String targetFilePath;

  /// Byte offset within the file where this chunk begins.
  final int offset;

  /// Number of bytes this chunk is responsible for.
  final int length;

  /// Bytes already written from a previous session (resume).
  final int initialDownloadedBytes;
  final bool acceptsRanges;

  /// Validators sent as `If-Range` so a changed resource can't be spliced.
  final String? etag;
  final String? lastModified;

  /// Live reference to download config — values read per-retry, not snapshotted.
  final DownloadConfig global;

  /// HLS segment mode. A segment chunk downloads a whole segment file from byte
  /// 0 into its own [targetFilePath] (offset is always 0), is never split, and
  /// — when the segment size is unknown — streams until EOF. Retry, throttle,
  /// speed tracking and resume all behave exactly as for a normal chunk.
  final bool isSegment;

  /// HLS segment: resolved source segment URI (for snapshot persistence).
  final String? uri;

  /// HLS segment: segment duration in seconds (from #EXTINF), for ETA.
  final double? durationSec;
  final EventEmitter emitter;

  /// Optional throttle hook — called with bytes-just-read before write.
  final Future<void> Function(int bytes, CancelToken? signal)? throttle;

  /// Reference speed for quality classification (bytes/sec).
  final double Function() medianSpeedRef;

  /// Clock, overridable for deterministic tests.
  final int Function()? now;

  /// Creates a [ChunkParams].
  const ChunkParams({
    required this.id,
    required this.downloadId,
    required this.url,
    required this.targetFilePath,
    required this.offset,
    required this.length,
    required this.initialDownloadedBytes,
    required this.acceptsRanges,
    this.etag,
    this.lastModified,
    required this.global,
    this.isSegment = false,
    this.uri,
    this.durationSec,
    required this.emitter,
    this.throttle,
    required this.medianSpeedRef,
    this.now,
  });
}

/// A single byte range being downloaded. Chunks are independent; a Download
/// owns many and orchestrates splits/reassignments.
///
/// Each chunk issues one HTTP request per `run()` attempt, streams the body
/// writing to `targetFilePath` at `offset + progress`, emits progress /
/// lifecycle / quality events, and supports abort via [pause]. Chunks are NOT
/// reused — a fresh instance is constructed for every attempt.
class Chunk {
  final String id;
  final String downloadId;
  final int offset;
  int _length;

  ChunkStatus _status = ChunkStatus.pending;
  int _downloadedBytes;
  ChunkQuality _quality = ChunkQuality.good;
  int _retries = 0;
  String? _lastError;

  /// Set when the failure carries scheduling meaning for the Download.
  String? _failureCode;

  final SpeedTracker _tracker;
  CancelToken? _abortController;
  final ChunkParams _params;
  final int Function() _now;

  Chunk(this._params)
      : id = _params.id,
        downloadId = _params.downloadId,
        offset = _params.offset,
        _length = _params.length,
        _downloadedBytes = _params.initialDownloadedBytes,
        _now = _params.now ?? _defaultNow,
        _tracker = SpeedTracker(_params.global.speedSampleWindow, _params.now);

  /// Current byte length of this chunk (may shrink when the tail is split off).
  int get length => _length;

  /// Current lifecycle state.
  ChunkStatus get status => _status;

  /// Bytes written to disk so far (including any resumed progress).
  int get downloadedBytes => _downloadedBytes;

  /// Bytes still to download, clamped to zero.
  int get remainingBytes => (_length - _downloadedBytes).clamp(0, _length);

  /// Qualitative health classification updated after each write.
  ChunkQuality get quality => _quality;

  /// Live speed tracker for this chunk.
  SpeedTracker get speedTracker => _tracker;

  /// Machine-readable failure code set on permanent failure (e.g. `'range-not-honored'`).
  String? get failureCode => _failureCode;

  /// True for HLS segment chunks — never split, written from byte 0.
  bool get isSegment => _params.isSegment;

  /// Human-readable description of the last error, or null.
  String? get lastError => _lastError;

  /// Returns an immutable snapshot of the current chunk state for persistence.
  ChunkSnapshot snapshot() => ChunkSnapshot(
        id: id,
        offset: offset,
        length: _length,
        downloadedBytes: _downloadedBytes,
        status: _status,
        quality: _quality,
        retries: _retries,
        lastError: _lastError,
        // Segment chunks carry extra fields so they can be rebuilt on resume.
        isSegment: _params.isSegment ? true : null,
        targetFilePath: _params.isSegment ? _params.targetFilePath : null,
        uri: _params.isSegment ? _params.uri : null,
        durationSec: _params.isSegment ? _params.durationSec : null,
      );

  /// Shrink this chunk so the tail portion can be given to another chunk.
  /// Returns the byte range removed, or null if too close to completion.
  ByteRange? truncateTail(int minRemaining) {
    // Segment chunks map 1:1 to a segment file and are never split.
    if (isSegment) return null;
    final remaining = remainingBytes;
    if (remaining < minRemaining * 2) return null;
    // Cut the unclaimed half — leave at least `minRemaining` for ourselves.
    final keepFromEnd = remaining ~/ 2;
    final newLength = _length - keepFromEnd;
    final removedOffset = offset + newLength;
    final removedLength = keepFromEnd;
    _length = newLength;
    return ByteRange(offset: removedOffset, length: removedLength);
  }

  /// Fires abort; resume is possible if `run()` is called again afterwards.
  void pause() {
    if (_status == ChunkStatus.completed || _status == ChunkStatus.failed) {
      return;
    }
    _setStatus(ChunkStatus.paused);
    _abortController?.cancel();
  }

  /// Permanent stop — status becomes `failed` with reason.
  void fail(String reason) {
    _lastError = reason;
    _setStatus(ChunkStatus.failed);
    _abortController?.cancel();
  }

  /// Marks this chunk as reassigned (its range was moved to another chunk).
  void markReassigned() {
    _setStatus(ChunkStatus.reassigned);
    _abortController?.cancel();
  }

  /// Aborts the current attempt so the retry loop reissues from the bytes
  /// already written. Used for stall recovery — the abort reason is a
  /// [TransientAbort] (retryable), not an [AbortError].
  void restart(String reason) {
    if (_status != ChunkStatus.downloading) return;
    _abortController?.cancel(TransientAbort('restart: $reason'));
  }

  /// Runs the download. Completes when the chunk finishes, fails permanently,
  /// or is paused / reassigned (status reflects the reason).
  Future<void> run() async {
    if (_status == ChunkStatus.completed) return;
    if (_downloadedBytes >= _length) {
      _setStatus(ChunkStatus.completed);
      return;
    }

    _setStatus(ChunkStatus.downloading);

    try {
      await withRetry<void>(
        (attempt) async {
          await _executeOnce();
        },
        RetryOptions(
          maxRetries: _params.global.maxRetries,
          retryDelay: _params.global.retryDelay,
          retryBackoff: _params.global.retryBackoff,
          onRetry: (info) {
            _retries += 1;
            _lastError = _toMessage(info.error);
            _params.emitter.emit(DiagnosticEvent(
              downloadId,
              DiagnosticPayload(
                downloadId: downloadId,
                chunkId: id,
                level: DiagnosticLevel.warn,
                code: 'chunk-retry',
                message: 'retry #$_retries in ${info.delayMs}ms: $_lastError',
                timestamp: _now(),
                data: {'attempt': info.attempt, 'delayMs': info.delayMs},
              ),
            ));
          },
        ),
      );
      if (_status == ChunkStatus.downloading) {
        _setStatus(ChunkStatus.completed);
      }
    } catch (err) {
      if (_status == ChunkStatus.paused || _status == ChunkStatus.reassigned) {
        return;
      }
      if (err is RangeNotHonoredError) _failureCode = 'range-not-honored';
      _lastError = _toMessage(err);
      _setStatus(ChunkStatus.failed);
      _params.emitter.emit(ErrorEvent(
        downloadId,
        chunkId: id,
        error: err is Exception || err is Error ? err : Exception(_lastError),
        fatal: false,
      ));
    }
  }

  Future<void> _executeOnce() async {
    final controller = CancelToken();
    _abortController = controller;

    // Servers without range support always send the body from byte zero, so
    // partial progress cannot be resumed — discard it before re-requesting.
    if (!_params.acceptsRanges && _downloadedBytes > 0) {
      _params.emitter.emit(DiagnosticEvent(
        downloadId,
        DiagnosticPayload(
          downloadId: downloadId,
          chunkId: id,
          level: DiagnosticLevel.info,
          code: 'no-range-restart',
          message:
              'server lacks range support — restarting chunk from byte 0 (discarding $_downloadedBytes bytes)',
          timestamp: _now(),
        ),
      ));
      _downloadedBytes = 0;
    }

    // Idle timer: armed only while waiting on the network, so slow disks or
    // throttle waits can't trip it, and long downloads run as long as data
    // keeps arriving.
    Timer? idleTimer;
    void clearIdle() {
      idleTimer?.cancel();
      idleTimer = null;
    }

    void armIdle() {
      final ms = _params.global.requestTimeout;
      clearIdle();
      idleTimer = Timer(Duration(milliseconds: ms), () {
        controller.cancel(
            TransientAbort('idle timeout: no data received for ${ms}ms'));
      });
    }

    try {
      final rangeStart = offset + _downloadedBytes;
      final headers = <String, String>{..._params.global.headers};
      var rangeSent = false;
      final openEnded = _length == unknownSizeLength;
      if (_params.acceptsRanges) {
        headers['Range'] = openEnded
            ? 'bytes=$rangeStart-'
            : 'bytes=$rangeStart-${offset + _length - 1}';
        rangeSent = true;
        final validator = _params.etag ?? _params.lastModified;
        if (validator != null) {
          headers['If-Range'] = validator;
        }
      }
      armIdle();
      final res = await _awaitOrAbort(
        _params.global.io.fetch(
          _params.url,
          FetchInit(method: 'GET', headers: headers, signal: controller),
        ),
        controller,
      );
      clearIdle();
      if (!res.ok) {
        throw HttpStatusError(res.status, res.statusText);
      }
      // A 200 on a ranged request means the server (or an If-Range mismatch)
      // ignored the range — consuming it would write the whole file at this
      // chunk's offset. The only safe 200 is an open-ended request from 0.
      if (rangeSent && res.status != 206 && !(openEnded && rangeStart == 0)) {
        throw RangeNotHonoredError();
      }
      await _consumeBody(res, controller, armIdle, clearIdle);
    } finally {
      clearIdle();
    }
  }

  Future<void> _consumeBody(
    FetchResponse res,
    CancelToken signal,
    void Function() armIdle,
    void Function() clearIdle,
  ) async {
    final body = res.body;
    if (body == null) {
      // No stream — read whole body. Acceptable fallback for tiny chunks.
      armIdle();
      final all = await _awaitOrAbort(res.bytes(), signal);
      clearIdle();
      final buf = _clampToRemaining(_asUint8(all));
      if (buf.isNotEmpty) await _writeBytes(buf);
      return;
    }
    final iterator = StreamIterator<List<int>>(body);
    try {
      while (true) {
        armIdle();
        final has = await _awaitOrAbort(iterator.moveNext(), signal);
        clearIdle();
        if (!has) break;
        final value = iterator.current;
        if (value.isEmpty) continue;
        // Never write past our end: a split may have shrunk `_length` while
        // this stream was in flight, and a misbehaving server may send more.
        final slice = _clampToRemaining(_asUint8(value));
        if (slice.isNotEmpty) {
          final throttle = _params.throttle;
          if (throttle != null) await throttle(slice.length, signal);
          await _writeBytes(slice);
        }
        // Stop once our (possibly shrunk) range is fully written, or when
        // status flipped during an await (pause / reassign).
        if (_downloadedBytes >= _length || _status != ChunkStatus.downloading) {
          await iterator.cancel();
          return;
        }
      }
    } finally {
      try {
        await iterator.cancel();
      } catch (_) {
        /* ignore */
      }
    }
  }

  /// Slice [buf] so the write cannot exceed this chunk's current length.
  Uint8List _clampToRemaining(Uint8List buf) {
    final remaining = _length - _downloadedBytes;
    if (remaining <= 0) return Uint8List(0);
    return buf.length > remaining
        ? Uint8List.sublistView(buf, 0, remaining)
        : buf;
  }

  Future<void> _writeBytes(Uint8List buf) async {
    final writeOffset = offset + _downloadedBytes;
    await _params.global.io
        .writeChunk(_params.targetFilePath, writeOffset, buf);
    _downloadedBytes += buf.length;
    _tracker.record(buf.length);
    _updateQuality();
    _params.emitter.emit(_chunkProgressEvent());
    _params.emitter.emit(_chunkQualityEvent());
  }

  void _updateQuality() {
    if (!_tracker.hasWarmedUp(qualityWarmupMs)) {
      _quality = ChunkQuality.good;
      return;
    }
    final median = _params.medianSpeedRef();
    final mine = _tracker.windowedSpeed;
    if (median <= 0 || mine <= 0) {
      _quality = ChunkQuality.good;
      return;
    }
    final ratio = mine / median;
    if (ratio < qualityStalledRatio) {
      _quality = ChunkQuality.stalled;
    } else if (ratio < qualityPoorRatio) {
      _quality = ChunkQuality.poor;
    } else {
      _quality = ChunkQuality.good;
    }
  }

  ChunkProgressEvent _chunkProgressEvent() => ChunkProgressEvent(
        downloadId,
        chunkId: id,
        offset: offset,
        length: _length,
        downloadedBytes: _downloadedBytes,
        instantSpeed: _tracker.instantSpeed,
        windowedSpeed: _tracker.windowedSpeed,
        quality: _quality,
      );

  ChunkQualityEvent _chunkQualityEvent() => ChunkQualityEvent(
        downloadId,
        chunkId: id,
        offset: offset,
        length: _length,
        downloadedBytes: _downloadedBytes,
        instantSpeed: _tracker.instantSpeed,
        windowedSpeed: _tracker.windowedSpeed,
        quality: _quality,
      );

  void _setStatus(ChunkStatus next) {
    if (_status == next) return;
    _status = next;
    _params.emitter
        .emit(ChunkLifecycleEvent(downloadId, chunkId: id, status: next));
  }
}

/// Completes with [future], or throws [token]'s reason if it cancels first.
Future<T> _awaitOrAbort<T>(Future<T> future, CancelToken token) {
  if (token.isCancelled) return Future<T>.error(token.reason);
  final completer = Completer<T>();
  final dispose = token.onCancel(() {
    if (!completer.isCompleted) completer.completeError(token.reason);
  });
  future.then((v) {
    dispose();
    if (!completer.isCompleted) completer.complete(v);
  }, onError: (Object e, StackTrace st) {
    dispose();
    if (!completer.isCompleted) completer.completeError(e, st);
  });
  return completer.future;
}

Uint8List _asUint8(List<int> data) =>
    data is Uint8List ? data : Uint8List.fromList(data);

String _toMessage(Object err) {
  if (err is HttpStatusError) return err.message;
  if (err is AbortError) return err.message;
  if (err is TransientAbort) return err.message;
  return err.toString();
}

int _defaultNow() => DateTime.now().millisecondsSinceEpoch;
