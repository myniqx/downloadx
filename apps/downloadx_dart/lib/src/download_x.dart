import 'config.dart';
import 'constants.dart';
import 'download.dart';
import 'events.dart';
import 'io.dart';
import 'meta.dart';
import 'native_io.dart';
import 'throttle.dart';
import 'types.dart';

/// Manager: a registry of [Download]s with a `maxParallel` queue, event relay,
/// and a manager-wide shared bandwidth throttle.
class DownloadX implements DlxContext {
  final EventEmitter emitter = EventEmitter();

  final Map<String, Download> _downloads = {};
  final Map<String, void Function()> _unrelay = {};
  final List<Download> _queue = [];
  int _maxParallel;
  String _targetPath;
  final String _cachePath;
  final DownloadXConfig _baseConfig;
  final DownloadxIo _io;

  /// Manager-wide bandwidth cap shared by ALL downloads (0 = unlimited).
  /// Per-download `speedLimit` still applies on top.
  final Throttle _sharedThrottle = Throttle(0);

  DownloadX(DownloadXConfig config)
      : _baseConfig = config,
        _io = config.io ?? NativeIo(),
        _maxParallel = config.maxParallel ?? DefaultConfig.maxParallel,
        _targetPath = config.targetPath,
        _cachePath = config.cachePath ?? config.targetPath {
    if (config.speedLimit != null && config.speedLimit! > 0) {
      _sharedThrottle.setCapacity(config.speedLimit!);
    }
  }

  /// Scans `cachePath` for persisted meta files and rebuilds the in-memory
  /// download list. Safe to call multiple times.
  Future<void> restoreFromCache() async {
    final metas = await listMetaFiles(_io, _cachePath);
    for (final meta in metas) {
      if (_downloads.containsKey(meta.id)) continue;
      final download = Download.fromMeta(meta, this);
      final unrelay = download.emitter.pipeTo(emitter);
      _downloads[meta.id] = download;
      _unrelay[meta.id] = unrelay;
    }
  }

  /// Register a new download. Returns the [Download] handle for imperative
  /// control. Pass `autoStart: true` to begin immediately.
  @override
  Future<Download> addUrl(String url,
      [DownloadOptions options = const DownloadOptions()]) async {
    final id = options.id ?? _hashUrl(url);
    final existing = _downloads[id];
    if (existing != null) return existing;
    final download = Download(id, url, options, this);
    final unrelay = download.emitter.pipeTo(emitter);
    _downloads[id] = download;
    _unrelay[id] = unrelay;

    await _io.mkdir(_cachePath);
    await persistMeta(_io, MetaLocator(dir: _cachePath, id: id), download.meta);

    if (options.autoStart == true) {
      // ignore: unawaited_futures
      start(id);
    }
    return download;
  }

  /// Begin a single download (honours maxParallel — queues if full).
  Future<void> start([String? id]) async {
    if (id == null) {
      for (final d in _downloads.values) {
        _enqueue(d);
      }
    } else {
      final d = _downloads[id];
      if (d == null) throw ArgumentError('DownloadX: unknown id $id');
      _enqueue(d);
    }
    _pump();
  }

  /// Pause one (or all, when [id] omitted) downloads.
  void pause([String? id]) {
    if (id == null) {
      for (final d in _downloads.values) {
        d.pause();
      }
      _queue.clear();
      return;
    }
    final d = _downloads[id];
    if (d == null) return;
    d.pause();
    _queue.remove(d);
  }

  /// Cancel and delete the part file, meta sidecar, and journal for one (or
  /// all) downloads. Works on completed downloads too.
  Future<void> clear([String? id]) async {
    if (id == null) {
      await Future.wait(_downloads.values.map((d) => d.clear()));
      for (final unrelay in _unrelay.values) {
        unrelay();
      }
      _unrelay.clear();
      _downloads.clear();
      _queue.clear();
      return;
    }
    final d = _downloads[id];
    if (d == null) return;
    await d.clear();
    _unrelay[id]?.call();
    _unrelay.remove(id);
    _downloads.remove(id);
    _queue.remove(d);
  }

  /// Returns the [Download] with [id], or null when not registered.
  Download? operator [](String id) => _downloads[id];

  /// Returns the [Download] with [id], or null when not registered.
  Download? getDownload(String id) => _downloads[id];

  /// Returns all registered downloads sorted by registration time.
  List<Download> list() {
    final all = _downloads.values.toList();
    all.sort((a, b) => a.meta.addedAt.compareTo(b.meta.addedAt));
    return all;
  }

  /// Compact status reports for every registered download.
  List<DownloadDescription> describeAll() =>
      list().map((d) => d.describe()).toList();

  /// Manager-wide bandwidth cap shared by all downloads. 0 = unlimited.
  void setSpeedLimit(int bytesPerSec) =>
      _sharedThrottle.setCapacity(bytesPerSec);

  @override
  num get speedLimit => _sharedThrottle.capacityBytesPerSec;

  /// Change the maximum number of concurrent downloads. Triggers a queue pump.
  void setMaxParallel(int n) {
    if (n < 1) throw ArgumentError('maxParallel must be >= 1');
    _maxParallel = n;
    _pump();
  }

  @override
  int get maxParallel => _maxParallel;

  /// Change the global target directory for future downloads.
  void setTargetPath(String path) => _targetPath = path;

  @override
  String get targetPath => _targetPath;

  @override
  String get cachePath => _cachePath;

  /// Upper bound on live chunks per download. Only updates downloads still
  /// carrying the old global value; pass `override` to force all.
  void setTargetChunkCount(int n, {bool override = false}) {
    final old = _baseConfig.targetChunkCount ?? DefaultConfig.targetChunkCount;
    _baseConfig.targetChunkCount = n;
    for (final dl in _downloads.values) {
      if (override || dl.targetChunkCount == old) dl.setTargetChunkCount(n);
    }
  }

  @override
  int get targetChunkCount =>
      _baseConfig.targetChunkCount ?? DefaultConfig.targetChunkCount;

  /// Minimum bytes remaining before a chunk can be split. Only updates
  /// downloads still carrying the old global value; pass `override` to force all.
  void setMinChunkSize(int bytes, {bool override = false}) {
    final old = _baseConfig.minChunkSize ?? DefaultConfig.minChunkSize;
    _baseConfig.minChunkSize = bytes;
    for (final dl in _downloads.values) {
      if (override || dl.minChunkSize == old) dl.setMinChunkSize(bytes);
    }
  }

  @override
  int get minChunkSize =>
      _baseConfig.minChunkSize ?? DefaultConfig.minChunkSize;

  /// Toggle NDJSON journal writing. Only updates downloads still carrying the
  /// old global value; pass `override` to force all.
  void setJournal(bool enabled, {bool override = false}) {
    final old = _baseConfig.journal ?? false;
    _baseConfig.journal = enabled;
    for (final dl in _downloads.values) {
      if (override || dl.journal == old) dl.setJournal(enabled);
    }
  }

  @override
  bool get journal => _baseConfig.journal ?? false;

  @override
  DownloadxIo get io => _io;

  @override
  Map<String, String> get headers => _baseConfig.headers ?? const {};

  @override
  int get maxRetries => _baseConfig.maxRetries ?? DefaultConfig.maxRetries;

  @override
  int get retryDelay => _baseConfig.retryDelay ?? DefaultConfig.retryDelay;

  @override
  num get retryBackoff =>
      _baseConfig.retryBackoff ?? DefaultConfig.retryBackoff;

  @override
  int get speedSampleWindow =>
      _baseConfig.speedSampleWindow ?? DefaultConfig.speedSampleWindow;

  @override
  int get requestTimeout =>
      _baseConfig.requestTimeout ?? DefaultConfig.requestTimeout;

  @override
  Throttle get sharedThrottle => _sharedThrottle;

  /// Returns the current effective global config as a JSON-compatible map.
  Map<String, Object?> getConfig() => {
        'targetPath': _targetPath,
        'cachePath': _cachePath,
        'maxParallel': _maxParallel,
        'speedLimit': _sharedThrottle.capacityBytesPerSec,
        'targetChunkCount': targetChunkCount,
        'minChunkSize': minChunkSize,
        'maxRetries': maxRetries,
        'retryDelay': retryDelay,
        'retryBackoff': retryBackoff,
        'speedSampleWindow': speedSampleWindow,
        'requestTimeout': requestTimeout,
        'chunkMode': (_baseConfig.chunkMode ?? DefaultConfig.chunkMode).name,
        'journal': journal,
        'headers': headers,
      };

  void _enqueue(Download download) {
    if (download.state == DownloadState.completed ||
        download.state == DownloadState.downloading) {
      return;
    }
    if (_queue.contains(download)) return;
    _queue.add(download);
  }

  void _pump() {
    final active = _downloads.values
        .where((d) =>
            d.state == DownloadState.downloading ||
            d.state == DownloadState.probing)
        .length;
    var slots = _maxParallel - active;
    if (slots < 0) slots = 0;
    while (slots > 0 && _queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      slots -= 1;
      // A slot frees up on completion — wake up anyone else in the queue.
      next.start().whenComplete(_pump);
    }
  }
}

/// Build a [DownloadX] and rehydrate any persisted downloads in `cachePath`.
/// Restored downloads stay in their last persisted state (no autostart).
Future<DownloadX> createDownloadX(DownloadXConfig config) async {
  final dx = DownloadX(config);
  await dx.restoreFromCache();
  return dx;
}

/// Deterministic 16-char id from a URL. FNV-1a folded into hex (no crypto
/// dependency). Byte-for-byte compatible with the TypeScript implementation.
String _hashUrl(String url) {
  var h1 = 0x811c9dc5;
  var h2 = 0x01000193;
  for (var i = 0; i < url.length; i += 1) {
    final code = url.codeUnitAt(i);
    h1 = _imul32(h1 ^ code, 0x01000193);
    h2 = _imul32(h2 + code, 0x85ebca6b);
  }
  final hex = h1.toRadixString(16).padLeft(8, '0') +
      h2.toRadixString(16).padLeft(8, '0');
  return hex.substring(0, 16);
}

/// 32-bit integer multiply with the same low-32-bit result as JS `Math.imul`,
/// returned unsigned (matching the TS code's `>>> 0`).
int _imul32(int a, int b) {
  a &= 0xffffffff;
  b &= 0xffffffff;
  final aLo = a & 0xffff;
  final aHi = (a >>> 16) & 0xffff;
  final bLo = b & 0xffff;
  final bHi = (b >>> 16) & 0xffff;
  final lo = aLo * bLo;
  final mid = ((aHi * bLo) + (aLo * bHi)) & 0xffffffff;
  return (lo + ((mid << 16) & 0xffffffff)) & 0xffffffff;
}
