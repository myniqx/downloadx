import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:downloadx/downloadx.dart';

/// A dev-only [DownloadxIo] that drives the *real* engine against a synthetic,
/// range-capable resource served slowly in small pieces. Nothing touches the
/// network or disk — but chunk splitting, progress, speed tracking, retries and
/// the speed chart all run for real, so the UI shows genuine live behaviour.
///
/// Part-file writes only track length (no bytes are kept), so memory stays
/// tiny regardless of the synthetic file size.
class DemoIo extends DownloadxIo {
  final Map<String, Uint8List> _files = {}; // meta / journal (small)
  final Map<String, int> _lengths = {}; // part files: length only
  final Set<String> _dirs = {};
  final Random _rng = Random();

  /// Bytes streamed per network read.
  static const int _piece = 32 * 1024;

  /// Base delay per piece (ms) — the synthetic "bandwidth" knob.
  final int baseDelayMs;

  DemoIo({this.baseDelayMs = 140});

  /// Synthetic size for a demo URL: encoded as `...-<n>mb...`, default 16 MiB.
  int _sizeFor(String url) {
    final m = RegExp(r'-(\d+)mb').firstMatch(url);
    final mb = m != null ? int.parse(m.group(1)!) : 16;
    return mb * 1024 * 1024;
  }

  @override
  Future<FetchResponse> fetch(String url, [FetchInit? init]) async {
    final size = _sizeFor(url);
    final method = init?.method ?? 'GET';
    final headers = MapFetchHeaders()
      ..set('accept-ranges', 'bytes')
      ..set('etag', '"demo-$size"')
      ..set('content-type', 'application/octet-stream');

    if (method == 'HEAD') {
      headers.set('content-length', size.toString());
      return _DemoResponse(200, 'OK', headers, url, null, 0, baseDelayMs, _rng);
    }

    final range = init?.headers?['Range'] ?? init?.headers?['range'];
    if (range != null) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
      final start = int.parse(m.group(1)!);
      final endStr = m.group(2)!;
      final end = endStr.isEmpty ? size - 1 : min(int.parse(endStr), size - 1);
      final len = end - start + 1;
      headers
        ..set('content-length', len.toString())
        ..set('content-range', 'bytes $start-$end/$size');
      return _DemoResponse(206, 'Partial Content', headers, url, init?.signal, len,
          baseDelayMs, _rng);
    }

    headers.set('content-length', size.toString());
    return _DemoResponse(200, 'OK', headers, url, init?.signal, size, baseDelayMs, _rng);
  }

  // ---- in-memory file system --------------------------------------------

  @override
  Future<void> writeChunk(String path, int offset, List<int> buffer) async {
    final end = offset + buffer.length;
    final cur = _lengths[path] ?? 0;
    if (end > cur) _lengths[path] = end;
  }

  @override
  Future<List<int>> readFile(String path) async {
    final f = _files[path];
    if (f == null) throw StateError('ENOENT: $path');
    return f;
  }

  @override
  Future<void> writeFile(String path, List<int> buffer) async {
    _files[path] = Uint8List.fromList(buffer);
  }

  @override
  Future<void> mkdir(String path) async => _dirs.add(path);

  @override
  Future<bool> exists(String path) async =>
      _files.containsKey(path) || _lengths.containsKey(path) || _dirs.contains(path);

  @override
  Future<void> rename(String from, String to) async {
    if (_files.containsKey(from)) _files[to] = _files.remove(from)!;
    if (_lengths.containsKey(from)) _lengths[to] = _lengths.remove(from)!;
  }

  @override
  Future<void> unlink(String path) async {
    _files.remove(path);
    _lengths.remove(path);
  }

  @override
  String joinPath(List<String> segments) => segments.where((s) => s.isNotEmpty).join('/');

  @override
  Future<List<String>> listDir(String path) async {
    final prefix = '$path/';
    final names = <String>{};
    for (final key in _files.keys) {
      if (key.startsWith(prefix)) {
        final rest = key.substring(prefix.length);
        if (!rest.contains('/')) names.add(rest);
      }
    }
    return names.toList();
  }

  @override
  Future<void> Function(String path, int size)? get truncate =>
      (path, size) async => _lengths[path] = size;

  @override
  Future<void> Function(String path, List<int> buffer)? get appendFile =>
      (path, buffer) async {
        final existing = _files[path] ?? Uint8List(0);
        final out = Uint8List(existing.length + buffer.length)
          ..setRange(0, existing.length, existing)
          ..setRange(existing.length, existing.length + buffer.length, buffer);
        _files[path] = out;
      };

  @override
  Future<int> Function(String path)? get fileSize =>
      (path) async => _lengths[path] ?? _files[path]?.length ?? 0;
}

class _DemoResponse implements FetchResponse {
  @override
  final int status;
  @override
  final String statusText;
  @override
  final FetchHeaders headers;
  @override
  final String url;

  final CancelToken? _signal;
  final int _bodyLen;
  final int _baseDelayMs;
  final Random _rng;

  _DemoResponse(this.status, this.statusText, this.headers, this.url, this._signal,
      this._bodyLen, this._baseDelayMs, this._rng);

  @override
  bool get ok => status >= 200 && status < 300;

  @override
  Stream<List<int>>? get body {
    if (_bodyLen <= 0) return const Stream<List<int>>.empty();
    return _emit();
  }

  Stream<List<int>> _emit() async* {
    var sent = 0;
    while (sent < _bodyLen) {
      if (_signal?.isCancelled ?? false) return;
      // Jittered delay simulates a varying bandwidth so the chart moves.
      final jitter = _rng.nextInt(_baseDelayMs);
      await Future<void>.delayed(Duration(milliseconds: _baseDelayMs + jitter));
      final n = min(DemoIo._piece, _bodyLen - sent);
      sent += n;
      yield Uint8List(n); // synthetic bytes (content is irrelevant for the demo)
    }
  }

  @override
  Future<List<int>> bytes() async => Uint8List(_bodyLen);

  @override
  Future<String> text() async => '';
}
