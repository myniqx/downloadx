import 'dart:async';
import 'dart:io';

import 'package:downloadx/downloadx.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/download_vm.dart';
import 'settings_store.dart';
import 'speed_history.dart';

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

  Future<void> start(DownloadVm vm) => manager.start(vm.id);
  void pause(DownloadVm vm) => manager.pause(vm.id);

  Future<void> startAll() => manager.start();
  void pauseAll() => manager.pause();

  Future<void> remove(DownloadVm vm) async {
    await manager.clear(vm.id);
    _byId.remove(vm.id);
    downloads.remove(vm);
    vm.dispose();
    notifyListeners();
  }

  Future<void> applySettings(GlobalSettings s) async {
    settings = s;
    manager.setMaxParallel(s.maxParallel);
    manager.setSpeedLimit(s.speedLimit);
    manager.setTargetChunkCount(s.targetChunkCount);
    manager.setMinChunkSize(s.minChunkSize);
    manager.setTargetPath(s.targetPath);
    manager.setJournal(s.journal);
    // No live setters exist for these — mutate the retained config in place
    // (the engine reads them per attempt, so the change takes effect at once).
    _config.maxRetries = s.maxRetries;
    _config.requestTimeout = s.requestTimeout;
    await _settingsStore.save(s);
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
    // Lifecycle transitions can reorder the list / change badges → refresh now.
    if (e is StateChangeEvent || e is CompletedEvent || e is ErrorEvent) {
      vm.refresh();
      notifyListeners();
    }
  }

  void _onTick() {
    final frame = <String, double>{};
    for (final vm in downloads) {
      vm.tick();
      if (vm.download.state == DownloadState.downloading) {
        vm.refresh();
        frame[vm.id] = vm.currentSpeed;
      }
    }
    globalSpeedHistory.push(frame);
    ticker.value = ticker.value + 1;
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
    super.dispose();
  }
}
