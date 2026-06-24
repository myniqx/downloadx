import 'dart:async';
import 'dart:io';

import 'package:downloadx/downloadx.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../dev/demo_io.dart';
import '../models/download_vm.dart';
import 'settings_store.dart';
import 'speed_history.dart';
import 'ws_server.dart';

/// The application's single source of truth. Wraps the [DownloadX] engine,
/// exposes a list of [DownloadVm]s, and drives a steady UI cadence:
///
///  - structural changes (add / remove / state) notify *this* (list rebuilds)
///  - per-download data notifies the matching [DownloadVm] (tile/detail repaint)
///  - a periodic tick advances the speed charts via [ticker] + history buffers
class DownloadService extends ChangeNotifier {
  late final DownloadX manager;
  late final DownloadXConfig _config;
  late final SettingsStore _settingsStore;
  late GlobalSettings settings;

  final List<DownloadVm> downloads = [];
  final Map<String, DownloadVm> _byId = {};

  /// Stacked per-download speed frames for the home-screen chart.
  final SpeedHistory globalSpeedHistory = SpeedHistory();

  /// Ticks ~2–3×/sec; chart widgets listen to repaint without rebuilding lists.
  final ValueNotifier<int> ticker = ValueNotifier(0);

  Timer? _tickTimer;
  late final WsServer _ws;

  Future<void> init() async {
    final defaultTarget = await _resolveDownloadsDir();
    final support = await getApplicationSupportDirectory();
    final sep = Platform.pathSeparator;
    _settingsStore = SettingsStore('${support.path}${sep}settings.json', defaultTarget);
    settings = await _settingsStore.load();

    _config = DownloadXConfig(
      targetPath: settings.targetPath,
      cachePath: '${support.path}${sep}cache',
      maxParallel: settings.maxParallel,
      speedLimit: settings.speedLimit,
      targetChunkCount: settings.targetChunkCount,
      minChunkSize: settings.minChunkSize,
      maxRetries: settings.maxRetries,
      requestTimeout: settings.requestTimeout,
      journal: settings.journal,
    );
    manager = await createDownloadX(_config);

    for (final d in manager.list()) {
      _track(d);
    }
    manager.emitter.on(_onEvent);
    _tickTimer = Timer.periodic(const Duration(milliseconds: 400), (_) => _onTick());

    _ws = WsServer(onMessage: _onWsMessage, onConnect: _onWsConnect);
    await _ws.start();

    notifyListeners();
  }

  // ---- queries ------------------------------------------------------------

  DownloadVm? byId(String id) => _byId[id];

  int get activeCount =>
      downloads.where((vm) => vm.download.state == DownloadState.downloading).length;

  double get totalSpeed {
    var sum = 0.0;
    for (final vm in downloads) {
      if (vm.download.state == DownloadState.downloading) sum += vm.currentSpeed;
    }
    return sum;
  }

  // ---- commands -----------------------------------------------------------

  Future<DownloadVm> addUrl(String url, {DownloadOptions? options, bool autoStart = true}) async {
    final d = await manager.addUrl(url, options ?? const DownloadOptions());
    var vm = _byId[d.id];
    if (vm == null) {
      vm = _track(d);
      notifyListeners();
    }
    if (autoStart) await manager.start(d.id);
    return vm;
  }

  DownloadX _managerFor(DownloadVm vm) =>
      vm.id.startsWith(_demoPrefix) && _demoManager != null
          ? _demoManager!
          : manager;

  Future<void> start(DownloadVm vm) => _managerFor(vm).start(vm.id);
  void pause(DownloadVm vm) => _managerFor(vm).pause(vm.id);

  Future<void> startAll() async {
    await manager.start();
    await _demoManager?.start();
  }

  void pauseAll() {
    manager.pause();
    _demoManager?.pause();
  }

  Future<void> remove(DownloadVm vm) async {
    _byId.remove(vm.id);
    downloads.remove(vm);
    await _managerFor(vm).clear(vm.id);
    vm.dispose();
    notifyListeners();
  }

  // ---- dev demo -----------------------------------------------------------

  static const _demoPrefix = 'demo-';
  DownloadX? _demoManager;

  /// True while the injected demo downloads are present.
  bool get demoActive => downloads.any((vm) => vm.id.startsWith(_demoPrefix));

  /// Toggle: inject two synthetic, slowly-streaming downloads (real engine,
  /// fake I/O) when clean; clear them when present. Dev/debug only.
  Future<void> toggleDemo() async {
    if (demoActive) {
      await _clearDemo();
    } else {
      await _startDemo();
    }
  }

  Future<void> _startDemo() async {
    final m = _demoManager ??= await _createDemoManager();
    final specs = [
      ('https://demo.local/alpha-24mb.bin', '${_demoPrefix}alpha'),
      ('https://demo.local/beta-40mb.bin', '${_demoPrefix}beta'),
      ('https://demo.local/gamma-stream.m3u8', '${_demoPrefix}gamma'),
    ];
    for (final (url, id) in specs) {
      final d = await m.addUrl(url, DownloadOptions(id: id));
      if (_byId[id] == null) _track(d);
    }
    notifyListeners();
    for (final (_, id) in specs) {
      await m.start(id);
    }
  }

  Future<void> _clearDemo() async {
    final m = _demoManager;
    if (m == null) return;
    final demos = downloads.where((vm) => vm.id.startsWith(_demoPrefix)).toList();
    for (final vm in demos) {
      await m.clear(vm.id);
      _byId.remove(vm.id);
      downloads.remove(vm);
      vm.dispose();
    }
    notifyListeners();
  }

  Future<DownloadX> _createDemoManager() async {
    final m = await createDownloadX(DownloadXConfig(
      io: DemoIo(),
      targetPath: '/demo/downloads',
      cachePath: '/demo/cache',
      maxParallel: settings.maxParallel,
      speedLimit: settings.speedLimit,
      targetChunkCount: settings.targetChunkCount,
      minChunkSize: settings.minChunkSize,
    ));
    m.emitter.on(_onEvent);
    return m;
  }

  Future<void> applySettings(GlobalSettings s) async {
    settings = s;
    manager.setMaxParallel(s.maxParallel);
    manager.setSpeedLimit(s.speedLimit);
    manager.setTargetChunkCount(s.targetChunkCount);
    manager.setMinChunkSize(s.minChunkSize);
    manager.setTargetPath(s.targetPath);
    manager.setJournal(s.journal);
    _demoManager?.setMaxParallel(s.maxParallel);
    _demoManager?.setSpeedLimit(s.speedLimit);
    _demoManager?.setTargetChunkCount(s.targetChunkCount);
    _demoManager?.setMinChunkSize(s.minChunkSize);
    // No live setters exist for these — mutate the retained config in place
    // (the engine reads them per attempt, so the change takes effect at once).
    _config.maxRetries = s.maxRetries;
    _config.requestTimeout = s.requestTimeout;
    await _settingsStore.save(s);
    _broadcastOptions();
    notifyListeners();
  }

  // ---- internals ----------------------------------------------------------

  DownloadVm _track(Download d) {
    final vm = DownloadVm(d);
    downloads.add(vm);
    _byId[d.id] = vm;
    return vm;
  }

  void _onEvent(DownloadEvent e) {
    final vm = _byId[e.downloadId];
    if (vm == null) return;
    vm.onEvent(e);
    if (e is StateChangeEvent || e is CompletedEvent || e is ErrorEvent) {
      vm.refresh();
      notifyListeners();
      _broadcastProgress();
    } else if (e is ProgressEvent) {
      // HLS progress events carry segment counts but no byte percent —
      // refresh the vm so the tile repaints with the latest segment data.
      vm.refresh();
    }
  }

  static const _fileExtensions = [
    'zip','gz','tar','rar','7z','bz2','xz','zst',
    'iso','dmg','img','pkg','exe','msi','deb','rpm','apk',
    'pdf','epub','mobi','djvu','torrent',
    'mp4','mkv','avi','mov','webm','flv','wmv','m4v','ts','m3u8',
    'mp3','flac','aac','wav','ogg','opus','m4a',
  ];

  Map<String, dynamic> _buildHandshake() => {
    'type': 'handshake',
    'coreVersion': '0.2.0',
    'serverType': 'ui',
    'options': {
      'fileExtensions': _fileExtensions,
      'browseMonitor': true,
    },
  };

  void _onWsConnect(WebSocket socket) {
    _ws.send(socket, _buildHandshake());
  }

  void _broadcastOptions() {
    _ws.broadcast({
      'type': 'options',
      'options': {
        'fileExtensions': _fileExtensions,
        'browseMonitor': true,
      },
    });
  }

  void _broadcastProgress() {
    _ws.broadcast({
      'type': 'progress',
      'downloads': downloads.map((vm) {
        final total = vm.download.totalBytes;
        final done = vm.download.downloadedBytes;
        final pct = (total != null && total > 0) ? done / total * 100 : null;
        return {
          'id': vm.id,
          'filename': vm.download.filename,
          'state': vm.download.state.name,
          'percent': pct,
          'speed': vm.currentSpeed,
        };
      }).toList(),
    });
  }

  void _onWsMessage(Map<String, dynamic> msg, WebSocket socket) {
    switch (msg['action']) {
      case 'add-url':
        final url = msg['url'] as String?;
        if (url != null) {
          final options = DownloadOptions(
            filename: msg['filename'] as String?,
          );
          addUrl(url, options: options);
        }
      case 'list':
        _ws.send(socket, {
          'action': 'list',
          'downloads': downloads.map((vm) {
            final total = vm.download.totalBytes;
            final done = vm.download.downloadedBytes;
            final pct = (total != null && total > 0) ? done / total * 100 : null;
            return {
              'id': vm.id,
              'filename': vm.download.filename,
              'state': vm.download.state.name,
              'percent': pct,
              'speed': vm.currentSpeed,
            };
          }).toList(),
        });
    }
  }

  void _onTick() {
    final frame = <String, double>{};
    bool anyActive = false;
    for (final vm in downloads) {
      vm.tick();
      if (vm.download.state == DownloadState.downloading) {
        vm.refresh();
        frame[vm.id] = vm.currentSpeed;
        anyActive = true;
      }
    }
    final limit = settings.speedLimit > 0 ? settings.speedLimit.toDouble() : null;
    globalSpeedHistory.push(frame, speedLimit: limit);
    ticker.value = ticker.value + 1;
    if (anyActive) _broadcastProgress();
  }

  Future<String> _resolveDownloadsDir() async {
    try {
      final d = await getDownloadsDirectory();
      if (d != null) return '${d.path}${Platform.pathSeparator}dlx';
    } catch (_) {
      /* unsupported on some platforms (e.g. Android) */
    }
    final docs = await getApplicationDocumentsDirectory();
    return '${docs.path}${Platform.pathSeparator}dlx-downloads';
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    ticker.dispose();
    _ws.stop();
    super.dispose();
  }
}
