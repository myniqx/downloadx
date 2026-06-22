import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'chunk.dart';
import 'chunk_scheduler.dart';
import 'config.dart';
import 'constants.dart';
import 'events.dart';
import 'hls/session.dart';
import 'io.dart';
import 'key2log.dart';
import 'meta.dart';
import 'probe.dart';
import 'speed_tracker.dart';
import 'throttle.dart';
import 'types.dart';

/// Orchestrates the probe → meta → chunk lifecycle for a single download.
class Download implements GlobalConfig {
  final String id;
  final String url;
  final EventEmitter emitter = EventEmitter();
  final DownloadOptions options;
  final DlxContext _context;

  DownloadState _state = DownloadState.idle;
  ProbeResult? _probe;
  late MetaFile _meta;
  List<Chunk> _chunks = [];
  final AggregateSpeed _aggregate = AggregateSpeed();
  late Throttle _throttle;

  Future<void>? _runningPromise;
  bool _pauseRequested = false;
  bool _cancelRequested = false;
  Timer? _progressTimer;
  int _startedAt = 0;
  int _chunkSeq = 0;
  bool _rangeFallbackDone = false;
  final Map<String, int> _stalledSince = {};
  final List<DiagnosticPayload> _recentDiagnostics = [];
  final List<LogEntry> _logs = [];

  // ---- GlobalConfig delegation -------------------------------------------

  @override
  DownloadxIo get io => _context.io;
  @override
  String get cachePath => _context.cachePath;
  @override
  int get maxParallel => _context.maxParallel;
  @override
  num get speedLimit => _meta.speedLimit ?? _context.speedLimit;
  @override
  Throttle get sharedThrottle => _context.sharedThrottle;

  @override
  int get maxRetries => _context.maxRetries;
  @override
  int get retryDelay => _context.retryDelay;
  @override
  num get retryBackoff => _context.retryBackoff;
  @override
  int get speedSampleWindow => _context.speedSampleWindow;
  @override
  int get requestTimeout => _context.requestTimeout;
  @override
  Map<String, String> get headers {
    final local = _meta.headers;
    if (local == null) return _context.headers;
    return {..._context.headers, ...local};
  }

  @override
  int get targetChunkCount =>
      _meta.targetChunkCount ?? _context.targetChunkCount;
  @override
  String get targetPath => _meta.targetPath ?? _context.targetPath;
  @override
  int get minChunkSize => _meta.minChunkSize ?? _context.minChunkSize;
  @override
  bool get journal => _meta.journal ?? _context.journal;

  // ------------------------------------------------------------------------

  factory Download.fromMeta(MetaFile meta, DlxContext context,
          [List<LogEntry> initialLogs = const []]) =>
      Download._(meta.id, meta.url, const DownloadOptions(), context, meta,
          initialLogs);

  Download(String id, String url, DownloadOptions options, DlxContext context)
      : this._(id, url, options, context, null, const []);

  Download._(this.id, this.url, this.options, this._context,
      MetaFile? initialMeta, List<LogEntry> initialLogs) {
    _throttle = Throttle(options.speedLimit ?? 0);
    _logs.addAll(initialLogs);
    if (initialMeta != null) {
      _meta = initialMeta;
      if (initialMeta.speedLimit != null) {
        _throttle.setCapacity(initialMeta.speedLimit!);
      }
      _state = dehydrateState(initialMeta.state);
      initialMeta.state = _state;
    } else {
      _meta = createEmptyMeta(id: id, url: url);
      if (options.filename != null) _meta.filename = options.filename;
      if (options.targetPath != null) _meta.targetPath = options.targetPath;
      if (options.speedLimit != null) _meta.speedLimit = options.speedLimit;
      if (options.minChunkSize != null) _meta.minChunkSize = options.minChunkSize;
      if (options.journal != null) _meta.journal = options.journal;
      if (options.description != null) _meta.description = options.description;
      if (options.metadata != null) _meta.metadata = options.metadata;
      if (options.headers != null) _meta.headers = options.headers;
      addLog(code: 'download.created', params: {'url': url, 'options': options.toString()});
    }
    emitter.onType<ChunkLifecycleEvent>((payload) {
      if (payload.status == ChunkStatus.completed ||
          payload.status == ChunkStatus.failed ||
          payload.status == ChunkStatus.reassigned) {
        _aggregate.remove(payload.chunkId);
      }
    });
    emitter.onType<DiagnosticEvent>((event) {
      _recentDiagnostics.add(event.payload);
      if (_recentDiagnostics.length > recentDiagnosticsLimit) {
        _recentDiagnostics.removeAt(0);
      }
      _journalWrite(event.payload);
    });
    emitter.onType<StateChangeEvent>((payload) {
      _journalWrite(DiagnosticPayload(
        downloadId: id,
        level: DiagnosticLevel.info,
        code: 'state-change',
        message: '${payload.previous.name} -> ${payload.current.name}',
        timestamp: _nowMs(),
      ));
    });
  }

  /// Current lifecycle state of this download.
  DownloadState get state => _state;

  /// The probe result populated after the initial HEAD/GET, or null before.
  ProbeResult? get probe => _probe;

  /// The sidecar meta file for this download.
  MetaFile get meta => _meta;

  /// Total file size in bytes, or null when unknown.
  int? get totalBytes => _probe?.totalSize ?? _meta.totalSize;

  /// Sum of bytes written across all chunks.
  int get downloadedBytes {
    if (_chunks.isEmpty) {
      var sum = 0;
      for (final c in _meta.chunks) {
        sum += c.downloadedBytes;
      }
      return sum;
    }
    var sum = 0;
    for (final c in _chunks) {
      sum += c.downloadedBytes;
    }
    return sum;
  }

  /// Resolved filename (meta → probe → fallback).
  String get filename =>
      _meta.filename ?? _probe?.filename ?? 'download-$id';

  /// Absolute path where the finished file will be written.
  String get targetFilePath => io.joinPath([targetPath, filename]);

  /// Absolute path of the in-progress `.part` file.
  String get partFilePath => io.joinPath([cachePath, '$id$tempExt']);

  /// The persistent log entries for this download.
  List<LogEntry> get logs => List.unmodifiable(_logs);

  @override
  void addLog({
    DiagnosticLevel level = DiagnosticLevel.info,
    required LogCode code,
    Map<String, dynamic>? params,
  }) {
    final timestamp = _nowMs();
    _logs.add(LogEntry(level: level, code: code, params: params, timestamp: timestamp));
    emitter.emit(LogEvent(
      id,
      timestamp: timestamp,
      level: level,
      message: renderLog(code, params),
    ));
  }

  /// Start (or resume) the download. Completes on finish/pause/error.
  Future<void> start() {
    if (_state == DownloadState.completed) return Future.value();

    if (_runningPromise != null) {
      return _runningPromise!;
    }

    _pauseRequested = false;
    _cancelRequested = false;
    _meta.errorMessage = null;
    final p = _execute().whenComplete(() {
      _runningPromise = null;
    });
    _runningPromise = p;
    return p;
  }

  /// Pause the download. Resumes from progress on the next [start] call.
  void pause() {
    if (_state != DownloadState.downloading &&
        _state != DownloadState.probing) {
      return;
    }
    _pauseRequested = true;
    for (final c in _chunks) {
      c.pause();
    }
  }

  /// Cancel the download. Progress is preserved for potential resume.
  void cancel() {
    _cancelRequested = true;
    _pauseRequested = true;
    for (final c in _chunks) {
      c.pause();
    }
  }

  /// Delete the downloaded file and its meta sidecar. Also cancels if running.
  Future<void> clear() async {
    cancel();
    final running = _runningPromise;
    if (running != null) {
      try {
        await running;
      } catch (_) {
        /* ignore */
      }
    }
    await _safeUnlink(partFilePath);
    await deleteMeta(io, MetaLocator(dir: cachePath, id: id))
        .catchError((_) {});
    await deleteLog(io, MetaLocator(dir: cachePath, id: id)).catchError((_) {});
    await _safeUnlink(_journalPath());
    // HLS writes segments to {cachePath}/{id}-hls/ — clean up the directory.
    if (_probe?.isHls == true || _meta.isHls == true) {
      final session = HlsSession(id: id, context: _context);
      await session.cleanup(session.segDir());
    }
  }

  /// Change the speed limit mid-download. 0 = unlimited. null clears the
  /// per-download override.
  void setSpeedLimit(int? bytesPerSec) {
    final old = _meta.speedLimit;
    _throttle.setCapacity(bytesPerSec ?? 0);
    _meta.speedLimit = bytesPerSec;
    addLog(code: 'config.speedLimit', params: {'old': old ?? 0, 'new': bytesPerSec ?? 0, 'scope': ''});
  }

  /// Upper bound on live chunks; takes effect on the next split decision.
  void setTargetChunkCount(int? n) {
    final old = _meta.targetChunkCount;
    _meta.targetChunkCount = n;
    addLog(code: 'config.targetChunkCount', params: {'old': old ?? 0, 'new': n ?? 0, 'scope': ''});
  }

  /// Override the target directory for this download's final file.
  void setTargetPath(String? path) {
    final old = _meta.targetPath;
    _meta.targetPath = path;
    addLog(code: 'config.targetPath', params: {'old': old ?? '', 'new': path ?? '', 'scope': ' (overridden)'});
  }

  /// Minimum bytes remaining before a chunk can be split.
  void setMinChunkSize(int? bytes) {
    final old = _meta.minChunkSize;
    _meta.minChunkSize = bytes;
    addLog(code: 'config.minChunkSize', params: {'old': old ?? 0, 'new': bytes ?? 0, 'scope': ''});
  }

  /// Toggle NDJSON journal writing; takes effect on the next diagnostic event.
  void setJournal(bool? enabled) {
    final old = _meta.journal;
    _meta.journal = enabled;
    addLog(code: 'config.journal', params: {'old': '${old ?? false}', 'new': '${enabled ?? false}', 'scope': ''});
  }

  /// Override the filename. null clears the override (falls back to probe then URL).
  void setFilename(String? name) {
    final old = _meta.filename;
    _meta.filename = name;
    addLog(code: 'config.filename', params: {'old': old ?? '', 'new': name ?? ''});
  }

  /// Set or clear the free-form description.
  void setDescription(String? text) {
    final old = _meta.description;
    _meta.description = text;
    addLog(code: 'config.description', params: {'old': old ?? '', 'new': text ?? ''});
  }

  /// Merge key/value pairs into per-download metadata. null clears all metadata.
  /// Pass {key: null} to remove a single key.
  void setMetadata(Map<String, String?> patch) {
    final current = _meta.metadata ?? {};
    for (final entry in patch.entries) {
      if (entry.value == null) {
        current.remove(entry.key);
      } else {
        current[entry.key] = entry.value!;
      }
    }
    _meta.metadata = current.isEmpty ? null : current;
    addLog(code: 'config.metadata', params: {'patch': patch.toString()});
  }

  /// Clear all metadata.
  void clearMetadata() {
    _meta.metadata = null;
    addLog(code: 'config.metadata', params: {'patch': 'cleared'});
  }

  /// Merge HTTP headers into per-download headers (merged on top of global).
  /// null value for a key removes that header from the local override.
  void setHeaders(Map<String, String?> patch) {
    final current = _meta.headers ?? {};
    for (final entry in patch.entries) {
      if (entry.value == null) {
        current.remove(entry.key);
      } else {
        current[entry.key] = entry.value!;
      }
    }
    _meta.headers = current.isEmpty ? null : current;
    addLog(code: 'config.headers', params: {'patch': patch.toString()});
  }

  /// Clear all per-download header overrides (reverts to global headers).
  void clearHeaders() {
    _meta.headers = null;
    addLog(code: 'config.headers', params: {'patch': 'cleared'});
  }

  /// Pre-allocate the part file to its final size. Requires `io.truncate` and a
  /// known total size; silently no-ops otherwise.
  Future<void> alloc() async {
    final truncate = io.truncate;
    final total = _probe?.totalSize;
    if (truncate == null || total == null || total <= 0) return;
    try {
      await truncate(partFilePath, total);
      addLog(code: 'alloc.completed', params: {'bytes': total});
    } catch (err) {
      addLog(level: DiagnosticLevel.warn, code: 'alloc.failed', params: {'message': err.toString()});
      _diag('warn', 'prealloc-failed', 'disk pre-allocation failed: $err');
    }
  }

  /// Returns snapshots of all current chunks.
  List<ChunkSnapshot> getChunkSnapshots() =>
      _chunks.map((c) => c.snapshot()).toList();

  /// Compact machine-readable status report.
  DownloadDescription describe() {
    final total = totalBytes;
    final downloaded = downloadedBytes;
    final speed = _aggregate.totalSpeed;
    final snaps = getChunkSnapshots();
    final live = snaps
        .where((s) =>
            s.status != ChunkStatus.completed &&
            s.status != ChunkStatus.reassigned)
        .toList();

    // HLS: percent/ETA are segment-based since total bytes are unknown.
    if (_isSegmentMode) {
      final totalSegments = snaps.length;
      final doneSegments = snaps
          .where((s) =>
              s.status == ChunkStatus.completed ||
              s.status == ChunkStatus.reassigned)
          .length;
      final elapsed = _startedAt == 0 ? 0 : _nowMs() - _startedAt;
      return DownloadDescription(
        id: id,
        url: url,
        filename: filename,
        targetPath: _meta.targetPath,
        addedAt: _meta.addedAt,
        completedAt: _meta.completedAt,
        errorMessage: _meta.errorMessage,
        description: _meta.description,
        metadata: _meta.metadata,
        state: _state,
        totalBytes: null,
        downloadedBytes: downloaded,
        percent: totalSegments > 0
            ? (doneSegments / totalSegments * 1000).round() / 10
            : null,
        totalSpeedBps: speed.round(),
        etaMs: doneSegments > 0 && doneSegments < totalSegments
            ? (elapsed / doneSegments * (totalSegments - doneSegments)).round()
            : null,
        elapsedMs: elapsed,
        activeChunks:
            snaps.where((s) => s.status == ChunkStatus.downloading).length,
        totalChunks: totalSegments,
        chunks: live
            .map((s) => ChunkDescription(
                  id: s.id,
                  status: s.status,
                  quality: s.quality,
                  offset: s.offset,
                  length: s.length,
                  downloadedBytes: s.downloadedBytes,
                  retries: s.retries,
                ))
            .toList(),
        recentDiagnostics: List<DiagnosticPayload>.of(_recentDiagnostics),
        hlsSegmentsDone: doneSegments,
        hlsTotalSegments: totalSegments,
      );
    }

    return DownloadDescription(
      id: id,
      url: url,
      filename: filename,
      targetPath: _meta.targetPath,
      addedAt: _meta.addedAt,
      completedAt: _meta.completedAt,
      errorMessage: _meta.errorMessage,
      description: _meta.description,
      metadata: _meta.metadata,
      state: _state,
      totalBytes: total,
      downloadedBytes: downloaded,
      percent: total != null && total > 0
          ? (downloaded / total * 1000).round() / 10
          : null,
      totalSpeedBps: speed.round(),
      etaMs: total != null && speed > 0
          ? ((total - downloaded) / speed * 1000).round()
          : null,
      elapsedMs: _startedAt == 0 ? 0 : _nowMs() - _startedAt,
      activeChunks:
          snaps.where((s) => s.status == ChunkStatus.downloading).length,
      totalChunks: snaps.length,
      chunks: live
          .map((s) => ChunkDescription(
                id: s.id,
                status: s.status,
                quality: s.quality,
                offset: s.offset,
                length: s.length,
                downloadedBytes: s.downloadedBytes,
                retries: s.retries,
              ))
          .toList(),
      recentDiagnostics: List<DiagnosticPayload>.of(_recentDiagnostics),
    );
  }

  /// Human/LLM-friendly one-screen summary of [describe]. Stable line format.
  String describeText() {
    final d = describe();
    final lines = <String>[];
    final size = d.totalBytes == null
        ? 'unknown size'
        : '${_formatBytes(d.downloadedBytes)} / ${_formatBytes(d.totalBytes!)}';
    final pct = d.percent == null ? '' : ' (${_trimNum(d.percent!)}%)';
    lines.add('${d.filename} [${d.state.name}] $size$pct');
    if (d.state == DownloadState.downloading) {
      final eta = d.etaMs == null ? 'unknown' : _formatDuration(d.etaMs!);
      lines.add(
          'speed ${_formatBytes(d.totalSpeedBps)}/s, ETA $eta, chunks ${d.activeChunks} active / ${d.totalChunks} total');
    }
    for (final c in d.chunks) {
      final chunkPct = c.length > 0 && c.length != unknownSizeLength
          ? '${(c.downloadedBytes / c.length * 100).round()}%'
          : _formatBytes(c.downloadedBytes);
      final retries = c.retries > 0 ? ', retries ${c.retries}' : '';
      lines.add(
          '  ${c.id}: ${c.status.name}/${c.quality.name} $chunkPct$retries');
    }
    final recent = d.recentDiagnostics;
    for (final diag
        in recent.sublist(recent.length > 3 ? recent.length - 3 : 0)) {
      lines.add('  ${diag.level.name}: [${diag.code}] ${diag.message}');
    }
    return lines.join('\n');
  }

  Future<void> _execute() async {
    try {
      if (_probe == null) {
        _setState(DownloadState.probing);
        addLog(code: 'probe.started', params: {'url': url});
        try {
          _probe = await probeUrl(ProbeOptions(
            fetch: io.fetch,
            url: url,
            headers: headers,
            filenameHint: _meta.filename,
          ));
        } catch (err) {
          addLog(level: DiagnosticLevel.error, code: 'probe.error', params: {'message': err.toString()});
          rethrow;
        }
        addLog(code: 'probe.completed', params: {
          'size': _probe!.totalSize ?? -1,
          'ranges': _probe!.acceptsRanges ? 'yes' : 'no',
          'filename': _probe!.filename ?? '',
        });
      }

      if (_probe!.isHls) {
        await _runHls();
        return;
      }

      await _ensureTargetDirs();
      await _loadOrInitMeta();

      if (_cancelRequested) {
        _setState(DownloadState.cancelled);
        return;
      }

      if (_chunks.isEmpty) _instantiateChunksFromMeta();
      // Zero-byte downloads: ensure the .part file exists so rename() has
      // something to move on finalize, then short-circuit.
      if (_probe?.totalSize == 0) {
        await io.writeFile(partFilePath, Uint8List(0));
        await _finalize();
        return;
      }
      if (_isAllComplete()) {
        await _finalize();
        return;
      }

      _setState(DownloadState.downloading);
      _startedAt = _nowMs();

      while (true) {
        await alloc();
        _startProgressTimer();
        await _driveChunks();
        _stopProgressTimer();

        if (_cancelRequested || _pauseRequested) break;

        // Server ignored our Range header (200 instead of 206): chunked bytes
        // would be garbage, so restart once as a single full-body download.
        final rangeNotHonored = _chunks.any((c) =>
            c.status == ChunkStatus.failed &&
            c.failureCode == 'range-not-honored');
        if (rangeNotHonored && !_rangeFallbackDone && _probe != null) {
          _rangeFallbackDone = true;
          addLog(level: DiagnosticLevel.warn, code: 'range.fallback');
          _diag('warn', 'range-fallback',
              'server ignored Range header — restarting as a single-chunk download');
          _probe = _probe!.copyWith(acceptsRanges: false);
          _chunks = [];
          _meta.chunks = [];
          await _safeUnlink(partFilePath);
          await _loadOrInitMeta(forceFresh: true);
          _instantiateChunksFromMeta();
          continue;
        }
        break;
      }

      if (_cancelRequested) {
        _setState(DownloadState.cancelled);
        await _persistCurrentMeta();
        return;
      }
      if (_pauseRequested) {
        _setState(DownloadState.paused);
        await _persistCurrentMeta();
        return;
      }
      if (_isAllComplete()) {
        await _finalize();
        return;
      }
      // Any chunk failed permanently → mark error.
      final hasFailed = _chunks.any((c) => c.status == ChunkStatus.failed);
      if (hasFailed) {
        _setState(DownloadState.error);
        await _persistCurrentMeta();
        return;
      }
      // Shouldn't happen, but be defensive.
      _setState(DownloadState.paused);
      await _persistCurrentMeta();
    } catch (err) {
      _stopProgressTimer();
      _setState(DownloadState.error);
      _meta.errorMessage = err.toString();
      emitter.emit(ErrorEvent(id, error: err, fatal: true));
      await _persistCurrentMeta().catchError((_) {});
    }
  }

  Future<void> _ensureTargetDirs() async {
    await io.mkdir(targetPath);
    if (cachePath != targetPath) {
      await io.mkdir(cachePath);
    }
  }

  /// Reconciles in-memory meta with a fresh probe. Keeps resumable chunks;
  /// otherwise rebuilds the chunk plan and discards any leftover part file.
  Future<void> _loadOrInitMeta({bool forceFresh = false}) async {
    final probe = _probe;
    if (probe == null) throw StateError('Probe missing — unreachable');
    final locator = MetaLocator(dir: cachePath, id: id);
    final hasResumableChunks = !forceFresh &&
        _meta.chunks.isNotEmpty &&
        canResumeAgainst(_meta, probe);

    if (hasResumableChunks) {
      applyProbeToMeta(_meta, probe, _meta.chunks);
      await persistMeta(io, locator, _meta);
      return;
    }

    // Fresh chunks needed — any partial file can't be trusted.
    if (_meta.chunks.isNotEmpty) {
      await _safeUnlink(partFilePath);
    }
    final mode = options.chunkMode ?? DefaultConfig.chunkMode;
    final chunkCount = mode == ChunkMode.single ||
            !probe.acceptsRanges ||
            probe.totalSize == null
        ? 1
        : (options.targetChunkCount ?? targetChunkCount);
    // Unknown total size: a single open-ended chunk that streams until EOF.
    final plans = probe.totalSize == null
        ? const [
            ChunkPlan(offset: 0, length: unknownSizeLength, downloadedBytes: 0)
          ]
        : planChunks(PlanOptions(
            totalSize: probe.totalSize!,
            targetChunkCount: chunkCount,
            minChunkSize: minChunkSize,
          ));
    final snapshots = <ChunkSnapshot>[];
    for (var i = 0; i < plans.length; i += 1) {
      final p = plans[i];
      snapshots.add(ChunkSnapshot(
        id: '$id-c$i',
        offset: p.offset,
        length: p.length,
        downloadedBytes: p.downloadedBytes,
        status: ChunkStatus.pending,
        quality: ChunkQuality.good,
        retries: 0,
      ));
    }
    applyProbeToMeta(_meta, probe, snapshots);
    await persistMeta(io, locator, _meta);
  }

  void _instantiateChunksFromMeta() {
    final probe = _probe;
    if (probe == null) throw StateError('Probe missing — unreachable');
    final acceptsRanges = probe.acceptsRanges;
    _chunks =
        _meta.chunks.map((snap) => _buildChunk(snap, acceptsRanges)).toList();
    _chunkSeq = _chunkSeq > _chunks.length ? _chunkSeq : _chunks.length;
  }

  Chunk _buildChunk(ChunkSnapshot snap, bool acceptsRanges) {
    // Segment chunks (HLS) download their own URI into their own file from
    // byte 0, never split, and don't use Range (optimistic resume restarts).
    final isSegment = snap.isSegment == true;
    return Chunk(ChunkParams(
      id: snap.id,
      downloadId: id,
      url: isSegment ? (snap.uri ?? url) : (_probe?.finalUrl ?? url),
      targetFilePath:
          isSegment ? (snap.targetFilePath ?? partFilePath) : partFilePath,
      offset: snap.offset,
      length: snap.length,
      initialDownloadedBytes: snap.downloadedBytes,
      acceptsRanges: isSegment ? false : acceptsRanges,
      isSegment: isSegment,
      uri: isSegment ? snap.uri : null,
      durationSec: isSegment ? snap.durationSec?.toDouble() : null,
      etag: _probe?.etag,
      lastModified: _probe?.lastModified,
      global: this,
      emitter: emitter,
      throttle: (bytes, signal) async {
        await sharedThrottle.consume(bytes, signal);
        await _throttle.consume(bytes, signal);
      },
      medianSpeedRef: () => _aggregate.medianWindowedSpeed(),
    ));
  }

  Future<void> _driveChunks() async {
    final runners = <String, Future<void>>{};
    final done = <String>{};

    void launch(Chunk chunk) {
      if (chunk.status == ChunkStatus.completed) return;
      _aggregate.add(chunk.id, chunk.speedTracker);
      runners[chunk.id] = chunk.run().whenComplete(() => done.add(chunk.id));
    }

    // HLS segment downloads can have hundreds of chunks; cap how many run at
    // once so we don't fire one request per segment. The cap is the configured
    // target chunk count. Normal (non-segment) downloads keep their existing
    // behaviour — every planned chunk launches immediately and the dynamic
    // splitter grows them up to targetChunkCount.
    final segmentMode = _chunks.any((c) => c.isSegment);
    final concurrency = segmentMode
        ? (options.targetChunkCount ?? targetChunkCount).clamp(1, 1 << 30)
        : (1 << 30);

    // Launch up to `concurrency` chunks; the rest wait until a slot frees up.
    // A chunk is launchable when it isn't finished and isn't already running.
    // (On resume, chunks may be `paused`, not `pending`, so don't filter on
    // `pending` alone — that would skip resumable chunks.)
    void launchPending() {
      for (final c in _chunks) {
        if (runners.length >= concurrency) break;
        if (c.status == ChunkStatus.completed ||
            c.status == ChunkStatus.reassigned ||
            c.status == ChunkStatus.failed ||
            runners.containsKey(c.id)) {
          continue;
        }
        launch(c);
      }
    }

    launchPending();

    while (runners.isNotEmpty) {
      await Future.any(runners.values);
      for (final id in runners.keys.where(done.contains).toList()) {
        runners.remove(id);
      }

      if (_pauseRequested || _cancelRequested) {
        await Future.wait(runners.values);
        runners.clear();
        break;
      }

      final probe = _probe;
      final splitAllowed = (probe?.acceptsRanges ?? false) &&
          probe?.totalSize != null &&
          !_chunks.any((c) => c.status == ChunkStatus.failed);
      final candidate = splitAllowed
          ? findSplitCandidate(FindSplitOptions(
              activeChunks: _chunks
                  .where((c) =>
                      c.status != ChunkStatus.completed &&
                      c.status != ChunkStatus.failed &&
                      c.status != ChunkStatus.reassigned)
                  .toList(),
              maxChunks: options.targetChunkCount ?? targetChunkCount,
              minChunkSize: minChunkSize,
              trigger: SplitReason.completedReassign,
            ))
          : null;
      if (candidate != null) {
        final newSnap = ChunkSnapshot(
          id: '$id-c$_chunkSeq',
          offset: candidate.newRange.offset,
          length: candidate.newRange.length,
          downloadedBytes: 0,
          status: ChunkStatus.pending,
          quality: ChunkQuality.good,
          retries: 0,
        );
        _chunkSeq += 1;
        final newChunk = _buildChunk(newSnap, _probe?.acceptsRanges ?? false);
        _chunks.add(newChunk);
        addLog(code: 'chunk.split', params: {
          'source': candidate.chunk.id,
          'id': newChunk.id,
          'offset': candidate.newRange.offset,
          'end': candidate.newRange.offset + candidate.newRange.length,
        });
        emitter.emit(ChunkSplitEvent(
          id,
          sourceChunkId: candidate.chunk.id,
          newChunkId: newChunk.id,
          splitOffset: candidate.newRange.offset,
          reason: candidate.reason,
        ));
        _diag(
          'info',
          'chunk-split',
          '${candidate.chunk.id} donated ${candidate.newRange.length} bytes at ${candidate.newRange.offset} to ${newChunk.id}',
          newChunk.id,
        );
        launch(newChunk);
      }

      // Fill any freed slots with still-pending chunks (segment mode). No-op
      // for normal downloads, where every chunk launched up front.
      launchPending();

      await _persistCurrentMeta().catchError((_) {});
    }
  }

  /// HLS download via the unified chunk pipeline. Each segment is an isSegment
  /// Chunk written to its own file; segments download through [_driveChunks]
  /// (with concurrency capped at targetChunkCount), then are concatenated into
  /// the final output. The playlist is re-resolved every run so resume picks up
  /// fresh segment URIs and skips already-downloaded segment files.
  Future<void> _runHls() async {
    final baseFilename = filename;
    final outputPath = targetFilePath;
    final session = HlsSession(id: id, context: _context);

    try {
      await _ensureTargetDirs();
      final resolution = await session.resolve(url);

      if (resolution is HlsMultiStreamResult) {
        addLog(code: 'hls.multi-stream', params: {'count': resolution.streams.length});
        await session.registerStreams(resolution.streams, baseFilename, outputPath);
        addLog(code: 'hls.streams-registered', params: {'count': resolution.streams.length});
        _setState(DownloadState.completed);
        _meta.completedAt = _nowMs();
        await _persistCurrentMeta().catchError((_) {});
        return;
      }

      final segments = (resolution as HlsMediaResolution).playlist.segments;
      final segDir = session.segDir();
      await io.mkdir(segDir);

      // Plan each segment as an isSegment chunk. Already-downloaded segment
      // files (present + non-empty) are marked completed so resume skips them.
      final fileSize = io.fileSize;
      final snapshots = <ChunkSnapshot>[];
      for (var i = 0; i < segments.length; i++) {
        final seg = segments[i];
        final segPath = session.segPath(i);
        var done = 0;
        var status = ChunkStatus.pending;
        if (await io.exists(segPath)) {
          int? size;
          if (fileSize != null) {
            try {
              size = await fileSize(segPath);
            } catch (_) {
              size = null;
            }
          }
          if (size != null && size > 0) {
            done = size;
            status = ChunkStatus.completed;
          }
        }
        snapshots.add(ChunkSnapshot(
          id: '$id-c$i',
          offset: 0,
          length: status == ChunkStatus.completed ? done : unknownSizeLength,
          downloadedBytes: done,
          status: status,
          quality: ChunkQuality.good,
          retries: 0,
          isSegment: true,
          targetFilePath: segPath,
          uri: seg.uri,
          durationSec: seg.durationSec,
        ));
      }

      final alreadyDone = snapshots.where((s) => s.status == ChunkStatus.completed).length;
      addLog(code: 'hls.segments-planned', params: {'total': segments.length, 'done': alreadyDone});
      _meta.isHls = true;
      final probe = _probe;
      if (probe != null) {
        applyProbeToMeta(_meta, probe, snapshots);
      } else {
        _meta.chunks = snapshots;
      }
      _chunkSeq = _chunkSeq > snapshots.length ? _chunkSeq : snapshots.length;
      _chunks = snapshots.map((snap) => _buildChunk(snap, false)).toList();
      await _persistCurrentMeta().catchError((_) {});

      if (_cancelRequested) {
        _setState(DownloadState.cancelled);
        await _persistCurrentMeta().catchError((_) {});
        return;
      }

      _setState(DownloadState.downloading);
      _startedAt = _nowMs();
      _startProgressTimer();
      await _driveChunks();
      _stopProgressTimer();

      if (_cancelRequested) {
        _setState(DownloadState.cancelled);
        await _persistCurrentMeta().catchError((_) {});
        return;
      }
      if (_pauseRequested) {
        _setState(DownloadState.paused);
        await _persistCurrentMeta().catchError((_) {});
        return;
      }
      final failed =
          _chunks.where((c) => c.status == ChunkStatus.failed).toList();
      if (failed.isNotEmpty) {
        _setState(DownloadState.error);
        _meta.errorMessage =
            failed.first.lastError ?? 'segment download failed';
        await _persistCurrentMeta().catchError((_) {});
        emitter.emit(ErrorEvent(
          id,
          error: Exception(_meta.errorMessage),
          fatal: true,
        ));
        return;
      }

      // All segments downloaded — concat into the final output and clean up.
      final segmentPaths = List.generate(_chunks.length, session.segPath);
      addLog(code: 'hls.concat-started', params: {'segments': segmentPaths.length, 'output': outputPath});
      await session.concat(segmentPaths, outputPath);
      await session.cleanup(segDir);
      addLog(code: 'hls.concat-completed', params: {'output': outputPath});

      _setState(DownloadState.completed);
      _meta.completedAt = _nowMs();
      await _persistCurrentMeta().catchError((_) {});
      emitter.emit(CompletedEvent(
        id,
        filename: filename,
        totalBytes: downloadedBytes,
        durationMs: _startedAt == 0 ? 0 : _nowMs() - _startedAt,
      ));
    } catch (err) {
      _stopProgressTimer();
      if (_cancelRequested) {
        _setState(DownloadState.cancelled);
        await _persistCurrentMeta().catchError((_) {});
        return;
      }
      if (_pauseRequested) {
        _setState(DownloadState.paused);
        await _persistCurrentMeta().catchError((_) {});
        return;
      }
      _setState(DownloadState.error);
      _meta.errorMessage = err.toString();
      emitter.emit(ErrorEvent(id, error: err, fatal: true));
      await _persistCurrentMeta().catchError((_) {});
    }
  }

  Future<void> _finalize() async {
    final expected = _probe?.totalSize;
    final fileSize = io.fileSize;
    if (expected != null && expected > 0 && fileSize != null) {
      int? actual;
      try {
        actual = await fileSize(partFilePath);
      } catch (_) {
        actual = null;
      }
      if (actual != null && actual != expected) {
        addLog(level: DiagnosticLevel.error, code: 'finalize.size-mismatch', params: {'expected': expected, 'actual': actual});
        _diag('error', 'size-mismatch',
            'assembled file is $actual bytes, expected $expected');
        final msg =
            'size mismatch after download: expected $expected bytes, found $actual';
        _setState(DownloadState.error);
        _meta.errorMessage = msg;
        emitter.emit(ErrorEvent(id, error: Exception(msg), fatal: true));
        await _persistCurrentMeta().catchError((_) {});
        return;
      }
    }
    await io.rename(partFilePath, targetFilePath);
    addLog(code: 'finalize.completed', params: {'path': targetFilePath});
    _setState(DownloadState.completed);
    _meta.completedAt = _nowMs();
    await _persistCurrentMeta().catchError((_) {});
    emitter.emit(CompletedEvent(
      id,
      filename: filename,
      totalBytes: downloadedBytes,
      durationMs: _startedAt == 0 ? 0 : _nowMs() - _startedAt,
    ));
  }

  bool _isAllComplete() {
    if (_chunks.isEmpty) return false;
    return _chunks.every((c) =>
        c.status == ChunkStatus.completed ||
        c.status == ChunkStatus.reassigned);
  }

  void _setState(DownloadState next) {
    if (_state == next) return;
    final prev = _state;
    _state = next;
    _meta.state = dehydrateState(next);
    emitter.emit(StateChangeEvent(id, previous: prev, current: next));
    if (next == DownloadState.downloading && prev == DownloadState.paused) {
      addLog(code: 'download.resumed');
    } else if (next == DownloadState.downloading) {
      addLog(code: 'download.started');
    } else if (next == DownloadState.paused) {
      addLog(code: 'download.paused');
    } else if (next == DownloadState.cancelled) {
      addLog(code: 'download.cancelled');
    } else if (next == DownloadState.error) {
      addLog(level: DiagnosticLevel.error, code: 'download.error', params: {'message': _meta.errorMessage ?? 'unknown error'});
    }
  }

  void _startProgressTimer() {
    if (_progressTimer != null) return;
    _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _emitProgress();
      _recoverStalledChunks();
    });
  }

  void _recoverStalledChunks() {
    final now = _nowMs();
    for (final c in _chunks) {
      if (c.status == ChunkStatus.downloading &&
          c.quality == ChunkQuality.stalled) {
        final since = _stalledSince[c.id];
        if (since == null) {
          _stalledSince[c.id] = now;
        } else if (now - since >= stallRecoveryMs) {
          _stalledSince.remove(c.id);
          addLog(level: DiagnosticLevel.warn, code: 'chunk.stall', params: {'id': c.id, 'duration': now - since});
          _diag('warn', 'stall-recovery',
              'chunk stalled for ${now - since}ms — reissuing request', c.id);
          c.restart('stalled');
        }
      } else {
        _stalledSince.remove(c.id);
      }
    }
  }

  void _stopProgressTimer() {
    if (_progressTimer != null) {
      _progressTimer!.cancel();
      _progressTimer = null;
    }
    _emitProgress();
  }

  /// True when this download is running in HLS segment mode.
  bool get _isSegmentMode =>
      _chunks.isNotEmpty && _chunks.any((c) => c.isSegment);

  void _emitProgress() {
    final downloaded = downloadedBytes;
    final speed = _aggregate.totalSpeed;

    if (_isSegmentMode) {
      // HLS: progress is segment-based, not byte-based (total size unknown).
      final totalSegments = _chunks.length;
      final doneSegments = _chunks
          .where((c) =>
              c.status == ChunkStatus.completed ||
              c.status == ChunkStatus.reassigned)
          .length;
      final elapsed = _startedAt == 0 ? 0 : _nowMs() - _startedAt;
      emitter.emit(ProgressEvent(
        id,
        totalBytes: null,
        downloadedBytes: downloaded,
        totalSpeed: speed,
        activeChunks:
            _chunks.where((c) => c.status == ChunkStatus.downloading).length,
        percent:
            totalSegments > 0 ? doneSegments / totalSegments * 100 : null,
        etaMs: doneSegments > 0 && doneSegments < totalSegments
            ? (elapsed / doneSegments * (totalSegments - doneSegments)).round()
            : null,
        hlsSegmentsDone: doneSegments,
        hlsTotalSegments: totalSegments,
      ));
      return;
    }

    final total = totalBytes;
    emitter.emit(ProgressEvent(
      id,
      totalBytes: total,
      downloadedBytes: downloaded,
      totalSpeed: speed,
      activeChunks:
          _chunks.where((c) => c.status == ChunkStatus.downloading).length,
      percent: total != null && total > 0 ? downloaded / total * 100 : null,
      etaMs: total != null && speed > 0 && total >= downloaded
          ? ((total - downloaded) / speed * 1000).round()
          : null,
    ));
  }

  void _diag(String level, String code, String message,
      [String? chunkId, Map<String, dynamic>? data]) {
    emitter.emit(DiagnosticEvent(
      id,
      DiagnosticPayload(
        downloadId: id,
        chunkId: chunkId,
        level: _levelFromString(level),
        code: code,
        message: message,
        timestamp: _nowMs(),
        data: data,
      ),
    ));
  }

  String _journalPath() => io.joinPath([cachePath, '$id$journalExt']);

  void _journalWrite(DiagnosticPayload payload) {
    if (journal != true) return;
    final append = io.appendFile;
    if (append == null) return;
    final line = utf8.encode('${jsonEncode(payload.toJson())}\n');
    append(_journalPath(), line).catchError((_) {});
  }

  Future<void> _persistCurrentMeta() async {
    final locator = MetaLocator(dir: cachePath, id: id);
    _meta.state = dehydrateState(_state);
    if (_chunks.isNotEmpty) _meta.chunks = getChunkSnapshots();
    await persistMeta(io, locator, _meta);
    await persistLogs(io, locator, _logs).catchError((_) {});
  }

  Future<void> _safeUnlink(String path) async {
    try {
      if (await io.exists(path)) await io.unlink(path);
    } catch (_) {
      /* ignore */
    }
  }
}

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

DiagnosticLevel _levelFromString(String s) => switch (s) {
      'warn' => DiagnosticLevel.warn,
      'error' => DiagnosticLevel.error,
      _ => DiagnosticLevel.info,
    };

String _formatBytes(int n) {
  if (n >= 1000000000) return '${(n / 1e9).toStringAsFixed(2)} GB';
  if (n >= 1000000) return '${(n / 1e6).toStringAsFixed(1)} MB';
  if (n >= 1000) return '${(n / 1e3).toStringAsFixed(1)} KB';
  return '$n B';
}

String _formatDuration(int ms) {
  final secs = (ms / 1000).round();
  if (secs < 60) return '${secs}s';
  final mins = secs ~/ 60;
  if (mins < 60) return '${mins}m ${secs % 60}s';
  return '${mins ~/ 60}h ${mins % 60}m';
}

String _trimNum(double n) {
  if (n == n.roundToDouble()) return n.toInt().toString();
  return n.toString();
}
