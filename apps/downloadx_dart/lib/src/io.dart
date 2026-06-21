import 'dart:async';

/// Cancellation / abort primitives
/// ---------------------------------------------------------------------------
///
/// The engine needs WHATWG-`AbortSignal`-style semantics: a single token that
/// can be cancelled with a *reason*, where the reason decides whether an
/// interrupted request is retried (idle timeout / stall restart) or treated as
/// deliberate user intent (pause / cancel) and never retried.

/// Thrown when an operation is aborted by deliberate user intent (pause /
/// cancel). The retry loop never retries this — mirrors a DOM `AbortError`.
class AbortError implements Exception {
  final String message;
  const AbortError([this.message = 'Aborted']);
  @override
  String toString() => 'AbortError: $message';
}

/// Abort reason carrying *transient* meaning: the request should be retried
/// from the bytes already written. Used for idle-timeout and stall-restart.
class TransientAbort implements Exception {
  final String message;
  const TransientAbort(this.message);
  @override
  String toString() => 'TransientAbort: $message';
}

/// A composable cancellation token. Combines the roles of `AbortController`
/// and `AbortSignal` from the WHATWG spec into one object.
class CancelToken {
  bool _cancelled = false;
  Object _reason = const AbortError();
  final _completer = Completer<void>();
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  /// The reason this token was cancelled with. Only meaningful once cancelled.
  Object get reason => _reason;

  /// Completes (never errors) the moment the token is cancelled. Useful for
  /// racing against an in-flight network read.
  Future<void> get whenCancelled => _completer.future;

  /// Cancel the token. [reason] defaults to an [AbortError] (user intent).
  void cancel([Object? reason]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason ?? const AbortError();
    for (final l in List<void Function()>.of(_listeners)) {
      try {
        l();
      } catch (_) {
        /* listener errors must never break cancellation */
      }
    }
    _listeners.clear();
    if (!_completer.isCompleted) _completer.complete();
  }

  /// Register a callback fired on cancellation. Returns a disposer. If already
  /// cancelled, the callback runs synchronously.
  void Function() onCancel(void Function() fn) {
    if (_cancelled) {
      fn();
      return () {};
    }
    _listeners.add(fn);
    return () => _listeners.remove(fn);
  }
}

/// HTTP request options passed to [DownloadxIo.fetch].
class FetchInit {
  final String? method;
  final Map<String, String>? headers;
  final CancelToken? signal;
  final List<int>? body;

  const FetchInit({this.method, this.headers, this.signal, this.body});
}

/// Case-insensitive response header view.
abstract class FetchHeaders {
  String? get(String name);
  bool has(String name);
  void forEach(void Function(String value, String name) cb);
}

/// A simple case-insensitive [FetchHeaders] backed by a map.
class MapFetchHeaders implements FetchHeaders {
  final Map<String, String> _map = {};

  MapFetchHeaders([Map<String, String>? initial]) {
    if (initial != null) {
      initial.forEach((k, v) => _map[k.toLowerCase()] = v);
    }
  }

  void set(String name, String value) => _map[name.toLowerCase()] = value;

  @override
  String? get(String name) => _map[name.toLowerCase()];

  @override
  bool has(String name) => _map.containsKey(name.toLowerCase());

  @override
  void forEach(void Function(String value, String name) cb) =>
      _map.forEach((k, v) => cb(v, k));
}

/// Minimal WHATWG-`Response`-shaped abstraction the engine consumes.
abstract class FetchResponse {
  int get status;
  String get statusText;
  bool get ok;
  FetchHeaders get headers;

  /// Streaming body, or null when the implementation buffers instead.
  Stream<List<int>>? get body;

  /// Final URL after redirects, when the fetcher exposes it.
  String? get url;

  /// Read the whole body into a buffer (the streaming alternative).
  Future<List<int>> bytes();
  Future<String> text();
}

/// Full set of functions the engine needs from the host environment.
///
/// The default implementation ([NativeIo]) talks to real disk and the network
/// via `dart:io`, so a Flutter / Dart consumer never has to provide anything.
/// Tests inject an in-memory implementation; advanced backends (S3, IndexedDB,
/// a database) can provide their own.
abstract class DownloadxIo {
  Future<FetchResponse> fetch(String url, [FetchInit? init]);

  /// Random-access write — writes [buffer] to [path] starting at [offset]
  /// **without truncating** the file.
  Future<void> writeChunk(String path, int offset, List<int> buffer);

  /// Read a file fully (used for meta JSON).
  Future<List<int>> readFile(String path);

  /// Write a file fully (used for meta JSON; atomicity is the caller's job).
  Future<void> writeFile(String path, List<int> buffer);

  /// Create directory recursively. Must not throw if it already exists.
  Future<void> mkdir(String path);

  /// Whether a file or directory exists.
  Future<bool> exists(String path);

  /// Rename (move) a file.
  Future<void> rename(String from, String to);

  /// Delete a file. Must not throw if the file does not exist.
  Future<void> unlink(String path);

  /// Join path segments using the target platform separator.
  String joinPath(List<String> segments);

  /// List entries inside a directory. Plain names, no paths.
  Future<List<String>> listDir(String path);

  /// Optional: enables disk pre-allocation (`Download.alloc`). Null = absent.
  Future<void> Function(String path, int size)? get truncate => null;

  /// Optional: enables the NDJSON event journal sidecar. Null = absent.
  Future<void> Function(String path, List<int> buffer)? get appendFile => null;

  /// Optional: enables final size verification before rename. Null = absent.
  Future<int> Function(String path)? get fileSize => null;

  /// Optional: concatenates HLS segment files into a single output file. Falls back to binary concat if absent.
  Future<void> Function(List<String> segments, String output)? get concatSegments => null;
}
