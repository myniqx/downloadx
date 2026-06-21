import 'dart:async';
import 'dart:typed_data';

import 'package:downloadx/downloadx.dart';

/// Programmable per-URL route for [MockFetch].
class MockRoute {
  /// Full resource body. Null means the route emits no Content-Length and
  /// streams an unknown-size body.
  Uint8List? body;
  bool acceptsRanges;
  String? etag;
  String? lastModified;
  String? contentType;
  String? contentDisposition;

  /// When true the server ignores the Range header and answers 200 with the
  /// whole body (exercises the range-fallback path).
  bool ignoreRange;

  /// HEAD is answered without a Content-Length (forces a ranged-GET probe).
  bool headWithoutLength;

  /// Unknown-size resource: no Content-Length, no range support, body streamed
  /// to EOF (exercises the single open-ended chunk path).
  bool unknownSize;

  /// Number of leading GET attempts that fail with [failStatus] before success.
  int failTimes;
  int failStatus;

  /// Bytes per streamed read (smaller = more reads, exercises clamping).
  int streamChunkSize;

  /// Final URL reported (post-redirect). Null = request URL.
  String? finalUrl;

  /// Overrides the advertised Content-Length (HEAD + 200 responses) without
  /// changing the actual body — lets a test fake a lying server so the final
  /// size verification can be exercised.
  int? advertisedLength;

  /// Whether the body is delivered as a stream (true) or via bytes() (false).
  bool streaming;

  /// When true, every GET streams the first chunk then hangs forever without
  /// emitting more or closing — exercises the network idle-timeout path.
  bool stallForever;

  /// The first [failStreamTimes] GET attempts stream [failStreamAfterBytes]
  /// bytes then error mid-stream (a transient network break). Exercises retry
  /// and — for a no-range resource — the restart-from-zero path.
  int failStreamTimes;
  int failStreamAfterBytes;

  MockRoute({
    this.body,
    this.acceptsRanges = true,
    this.etag,
    this.lastModified,
    this.contentType = 'application/octet-stream',
    this.contentDisposition,
    this.ignoreRange = false,
    this.headWithoutLength = false,
    this.unknownSize = false,
    this.failTimes = 0,
    this.failStatus = 503,
    this.streamChunkSize = 16,
    this.finalUrl,
    this.advertisedLength,
    this.streaming = true,
    this.stallForever = false,
    this.failStreamTimes = 0,
    this.failStreamAfterBytes = 0,
  });
}

class RecordedRequest {
  final String method;
  final String url;
  final Map<String, String> headers;
  RecordedRequest(this.method, this.url, this.headers);
}

/// Records every request and answers per-route, handling Range → 206.
class MockFetch {
  final Map<String, MockRoute> routes = {};
  final List<RecordedRequest> requests = [];
  final Map<String, int> _getAttempts = {};

  void route(String url, MockRoute r) => routes[url] = r;

  Future<FetchResponse> call(String url, [FetchInit? init]) async {
    final method = init?.method ?? 'GET';
    final headers = init?.headers ?? const {};
    requests
        .add(RecordedRequest(method, url, Map<String, String>.from(headers)));

    final r = routes[url];
    if (r == null) {
      return MockResponse(
          status: 404, statusText: 'Not Found', headers: MapFetchHeaders());
    }

    if (method == 'HEAD') {
      final h = MapFetchHeaders();
      if (r.acceptsRanges && !r.unknownSize) h.set('accept-ranges', 'bytes');
      if (r.etag != null) h.set('etag', r.etag!);
      if (r.lastModified != null) h.set('last-modified', r.lastModified!);
      if (r.contentType != null) h.set('content-type', r.contentType!);
      if (r.contentDisposition != null) {
        h.set('content-disposition', r.contentDisposition!);
      }
      if (!r.headWithoutLength && !r.unknownSize && r.body != null) {
        h.set('content-length',
            (r.advertisedLength ?? r.body!.length).toString());
      }
      return MockResponse(
        status: 200,
        statusText: 'OK',
        headers: h,
        url: r.finalUrl ?? url,
      );
    }

    // GET — honour failTimes first.
    final attempts = (_getAttempts[url] ?? 0) + 1;
    _getAttempts[url] = attempts;
    if (attempts <= r.failTimes) {
      return MockResponse(
        status: r.failStatus,
        statusText: 'Injected Failure',
        headers: MapFetchHeaders(),
      );
    }

    final rangeHeader = headers['Range'] ?? headers['range'];
    final body = r.body ?? Uint8List(0);
    final erroring = r.failStreamTimes > 0 && attempts <= r.failStreamTimes;
    final errorAfter = erroring ? r.failStreamAfterBytes : null;

    // Unknown size: stream the body with no Content-Length / Accept-Ranges, 200.
    if (r.unknownSize) {
      final h = MapFetchHeaders();
      if (r.contentType != null) h.set('content-type', r.contentType!);
      return MockResponse(
        status: 200,
        statusText: 'OK',
        headers: h,
        url: r.finalUrl ?? url,
        bodyBytes: body,
        streaming: r.streaming,
        streamChunkSize: r.streamChunkSize,
        stall: r.stallForever,
        errorAfter: errorAfter,
      );
    }

    if (rangeHeader != null && r.acceptsRanges && !r.ignoreRange) {
      final parsed = _parseRange(rangeHeader, body.length);
      final start = parsed[0];
      final end = parsed[1];
      final slice = Uint8List.sublistView(body, start, end + 1);
      final h = MapFetchHeaders();
      h.set('content-length', slice.length.toString());
      h.set('content-range', 'bytes $start-$end/${body.length}');
      h.set('accept-ranges', 'bytes');
      if (r.etag != null) h.set('etag', r.etag!);
      if (r.lastModified != null) h.set('last-modified', r.lastModified!);
      return MockResponse(
        status: 206,
        statusText: 'Partial Content',
        headers: h,
        url: r.finalUrl ?? url,
        bodyBytes: slice,
        streaming: r.streaming,
        streamChunkSize: r.streamChunkSize,
        stall: r.stallForever,
        errorAfter: errorAfter,
      );
    }

    // 200 full body (no range, or range ignored).
    final h = MapFetchHeaders();
    h.set('content-length', (r.advertisedLength ?? body.length).toString());
    if (r.acceptsRanges) h.set('accept-ranges', 'bytes');
    if (r.etag != null) h.set('etag', r.etag!);
    if (r.lastModified != null) h.set('last-modified', r.lastModified!);
    return MockResponse(
      status: 200,
      statusText: 'OK',
      headers: h,
      url: r.finalUrl ?? url,
      bodyBytes: body,
      streaming: r.streaming,
      streamChunkSize: r.streamChunkSize,
      stall: r.stallForever,
      errorAfter: errorAfter,
    );
  }

  List<int> _parseRange(String header, int total) {
    // bytes=start-end | bytes=start-
    final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(header)!;
    final start = int.parse(m.group(1)!);
    final endStr = m.group(2)!;
    final end = endStr.isEmpty ? total - 1 : int.parse(endStr);
    return [start, end > total - 1 ? total - 1 : end];
  }
}

class MockResponse implements FetchResponse {
  @override
  final int status;
  @override
  final String statusText;
  @override
  final FetchHeaders headers;
  @override
  final String? url;

  final Uint8List? _bodyBytes;
  final bool _streaming;
  final int _streamChunkSize;
  final bool _stall;
  final int? _errorAfter;

  MockResponse({
    required this.status,
    required this.statusText,
    required this.headers,
    this.url,
    Uint8List? bodyBytes,
    bool streaming = true,
    int streamChunkSize = 16,
    bool stall = false,
    int? errorAfter,
  })  : _bodyBytes = bodyBytes,
        _streaming = streaming,
        _streamChunkSize = streamChunkSize,
        _stall = stall,
        _errorAfter = errorAfter;

  @override
  bool get ok => status >= 200 && status < 300;

  @override
  Stream<List<int>>? get body {
    if (!_streaming) return null;
    final data = _bodyBytes ?? Uint8List(0);
    if (_stall) return _stallStream(data);
    return _emit(data, _streamChunkSize);
  }

  Stream<List<int>> _emit(Uint8List data, int chunkSize) async* {
    var offset = 0;
    while (offset < data.length) {
      final end = (offset + chunkSize).clamp(0, data.length);
      yield Uint8List.sublistView(data, offset, end);
      offset = end;
      // Yield to the event loop so cancellation can interleave.
      await Future<void>.delayed(Duration.zero);
      // Transient mid-stream break: emit up to the threshold, then error.
      if (_errorAfter != null && offset >= _errorAfter) {
        throw Exception('mock stream error after $offset bytes');
      }
    }
  }

  /// Emits the first chunk then never emits or closes — but the underlying
  /// `StreamController` is cleanly cancellable, so the consumer's idle-timeout
  /// abort tears it down without hanging.
  Stream<List<int>> _stallStream(Uint8List data) {
    final controller = StreamController<List<int>>();
    final first = data.isEmpty
        ? Uint8List(0)
        : Uint8List.sublistView(data, 0,
            data.length < _streamChunkSize ? data.length : _streamChunkSize);
    scheduleMicrotask(() {
      if (first.isNotEmpty && !controller.isClosed) controller.add(first);
    });
    return controller.stream;
  }

  @override
  Future<List<int>> bytes() async => _bodyBytes ?? Uint8List(0);

  @override
  Future<String> text() async =>
      String.fromCharCodes(_bodyBytes ?? Uint8List(0));
}

/// In-memory [DownloadxIo]: a map-backed file system plus a [MockFetch].
class MockIo extends DownloadxIo {
  final Map<String, Uint8List> files = {};
  final Set<String> dirs = {};
  final MockFetch fetcher;

  /// Toggle optional capabilities on/off to test feature gating.
  bool enableTruncate;
  bool enableAppend;
  bool enableFileSize;

  /// Injectable concat callback — set in tests to verify it's called.
  Future<void> Function(List<String> segments, String output)? concatSegmentsOverride;

  MockIo({
    MockFetch? fetcher,
    this.enableTruncate = true,
    this.enableAppend = true,
    this.enableFileSize = true,
  }) : fetcher = fetcher ?? MockFetch();

  @override
  Future<void> Function(List<String> segments, String output)? get concatSegments =>
      concatSegmentsOverride;

  @override
  Future<FetchResponse> fetch(String url, [FetchInit? init]) =>
      fetcher.call(url, init);

  @override
  Future<void> writeChunk(String path, int offset, List<int> buffer) async {
    final existing = files[path] ?? Uint8List(0);
    final needed = offset + buffer.length;
    final out = Uint8List(needed > existing.length ? needed : existing.length);
    out.setRange(0, existing.length, existing);
    out.setRange(offset, offset + buffer.length, buffer);
    files[path] = out;
  }

  @override
  Future<List<int>> readFile(String path) async {
    final f = files[path];
    if (f == null) throw StateError('ENOENT: $path');
    return f;
  }

  @override
  Future<void> writeFile(String path, List<int> buffer) async {
    files[path] = Uint8List.fromList(buffer);
  }

  @override
  Future<void> mkdir(String path) async {
    dirs.add(path);
  }

  @override
  Future<bool> exists(String path) async =>
      files.containsKey(path) || dirs.contains(path);

  @override
  Future<void> rename(String from, String to) async {
    final f = files.remove(from);
    if (f == null) throw StateError('ENOENT: $from');
    files[to] = f;
  }

  @override
  Future<void> unlink(String path) async {
    files.remove(path);
  }

  @override
  String joinPath(List<String> segments) =>
      segments.where((s) => s.isNotEmpty).join('/');

  @override
  Future<List<String>> listDir(String path) async {
    final prefix = '$path/';
    final names = <String>{};
    for (final key in files.keys) {
      if (key.startsWith(prefix)) {
        final rest = key.substring(prefix.length);
        if (!rest.contains('/')) names.add(rest);
      }
    }
    return names.toList();
  }

  @override
  Future<void> Function(String path, int size)? get truncate => enableTruncate
      ? (String path, int size) async {
          final existing = files[path] ?? Uint8List(0);
          final out = Uint8List(size);
          out.setRange(
              0, existing.length > size ? size : existing.length, existing);
          files[path] = out;
        }
      : null;

  @override
  Future<void> Function(String path, List<int> buffer)? get appendFile =>
      enableAppend
          ? (String path, List<int> buffer) async {
              final existing = files[path] ?? Uint8List(0);
              final out = Uint8List(existing.length + buffer.length);
              out.setRange(0, existing.length, existing);
              out.setRange(existing.length, out.length, buffer);
              files[path] = out;
            }
          : null;

  @override
  Future<int> Function(String path)? get fileSize => enableFileSize
      ? (String path) async => (files[path] ?? Uint8List(0)).length
      : null;
}

/// Deterministic byte buffer: value at index i is `i % 256`.
Uint8List deterministicBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i += 1) {
    out[i] = i % 256;
  }
  return out;
}
