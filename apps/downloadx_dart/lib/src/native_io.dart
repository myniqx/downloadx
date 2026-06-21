import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'io.dart';

/// Default [DownloadxIo] backed by `dart:io` — real disk and a real
/// `HttpClient`. A Flutter / Dart consumer gets this automatically and never
/// has to inject anything.
class NativeIo extends DownloadxIo {
  final HttpClient _client;

  /// Creates a [NativeIo]. Provide [client] to override the HTTP client.
  NativeIo({HttpClient? client})
      : _client = client ?? (HttpClient()..autoUncompress = false);

  @override
  Future<FetchResponse> fetch(String url, [FetchInit? init]) async {
    final method = init?.method ?? 'GET';
    final request = await _client.openUrl(method, Uri.parse(url));
    // Disable transparent gzip so byte ranges and Content-Length stay accurate.
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    init?.headers?.forEach((k, v) => request.headers.set(k, v));
    request.followRedirects = true;

    final signal = init?.signal;
    var aborted = false;
    void Function()? disposeAbort;
    if (signal != null) {
      disposeAbort = signal.onCancel(() {
        aborted = true;
        request.abort(signal.reason);
      });
    }

    if (init?.body != null) {
      request.add(init!.body!);
    }

    try {
      final response = await request.close();
      disposeAbort?.call();
      return _NativeResponse(response, _finalUrl(url, response));
    } catch (e) {
      disposeAbort?.call();
      if (aborted && signal != null) throw signal.reason;
      rethrow;
    }
  }

  String _finalUrl(String original, HttpClientResponse response) {
    if (response.redirects.isEmpty) return original;
    final last = response.redirects.last.location;
    return last.isAbsolute
        ? last.toString()
        : Uri.parse(original).resolveUri(last).toString();
  }

  @override
  Future<void> writeChunk(String path, int offset, List<int> buffer) async {
    // Random-access write without ever truncating. `FileMode.append` opens for
    // writing, creates the file if missing, and — despite the name — supports
    // `setPosition` + `writeFrom` at an arbitrary offset on every platform Dart
    // targets, leaving existing bytes (and any gap, zero-filled) intact. This
    // is the Dart equivalent of the README's `r+ → wx` `openRw`.
    final handle = await File(path).open(mode: FileMode.append);
    try {
      await handle.setPosition(offset);
      await handle
          .writeFrom(buffer is Uint8List ? buffer : Uint8List.fromList(buffer));
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  @override
  Future<List<int>> readFile(String path) => File(path).readAsBytes();

  @override
  Future<void> writeFile(String path, List<int> buffer) async {
    await File(path).writeAsBytes(buffer, flush: true);
  }

  @override
  Future<void> mkdir(String path) async {
    await Directory(path).create(recursive: true);
  }

  @override
  Future<bool> exists(String path) async {
    return await File(path).exists() || await Directory(path).exists();
  }

  @override
  Future<void> rename(String from, String to) async {
    await File(from).rename(to);
  }

  @override
  Future<void> unlink(String path) async {
    final f = File(path);
    if (await f.exists()) {
      await f.delete();
    }
  }

  @override
  String joinPath(List<String> segments) {
    if (segments.isEmpty) return '';
    final sep = Platform.pathSeparator;
    final buf = StringBuffer(segments.first);
    for (var i = 1; i < segments.length; i += 1) {
      final s = segments[i];
      if (s.isEmpty) continue;
      final endsWithSep = buf.isNotEmpty && buf.toString().endsWith(sep);
      if (!endsWithSep && !s.startsWith(sep)) buf.write(sep);
      buf.write(s);
    }
    return buf.toString();
  }

  @override
  Future<List<String>> listDir(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return [];
    final out = <String>[];
    await for (final entity in dir.list()) {
      out.add(entity.uri.pathSegments.where((s) => s.isNotEmpty).last);
    }
    return out;
  }

  @override
  Future<void> Function(String path, int size)? get truncate =>
      (String path, int size) async {
        // Pre-allocate by setting the file length. `FileMode.append` opens
        // without truncating to zero (and creates if missing), so existing
        // bytes are preserved — `truncate(size)` only extends with zeros or
        // trims the tail. Using `FileMode.write` here would wipe a resumed
        // part file every time `alloc()` runs.
        final handle = await File(path).open(mode: FileMode.append);
        try {
          await handle.truncate(size);
        } finally {
          await handle.close();
        }
      };

  @override
  Future<void> Function(String path, List<int> buffer)? get appendFile =>
      (String path, List<int> buffer) async {
        final handle = await File(path).open(mode: FileMode.append);
        try {
          await handle.writeFrom(buffer);
          await handle.flush();
        } finally {
          await handle.close();
        }
      };

  @override
  Future<int> Function(String path)? get fileSize =>
      (String path) async => File(path).length();
}

/// Wraps an `HttpClientResponse` as a [FetchResponse].
class _NativeResponse implements FetchResponse {
  final HttpClientResponse _res;
  final String _finalUrl;
  final MapFetchHeaders _headers = MapFetchHeaders();
  Stream<List<int>>? _bodyStream;

  _NativeResponse(this._res, this._finalUrl) {
    _res.headers.forEach((name, values) {
      _headers.set(name, values.join(', '));
    });
    _bodyStream = _res;
  }

  @override
  int get status => _res.statusCode;

  @override
  String get statusText => _res.reasonPhrase;

  @override
  bool get ok => status >= 200 && status < 300;

  @override
  FetchHeaders get headers => _headers;

  @override
  Stream<List<int>>? get body => _bodyStream;

  @override
  String? get url => _finalUrl;

  @override
  Future<List<int>> bytes() async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in _res) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<String> text() async {
    final b = await bytes();
    return String.fromCharCodes(b);
  }
}
