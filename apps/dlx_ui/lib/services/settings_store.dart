import 'dart:convert';
import 'dart:io';

/// Persisted global settings. Mirrors the manager-level knobs the CLI exposes,
/// stored as a small JSON file next to the cache directory.
class GlobalSettings {
  String targetPath;
  int maxParallel;
  int speedLimit; // bytes/sec; 0 = unlimited
  int targetChunkCount;
  int minChunkSize;
  int maxRetries;
  int requestTimeout;
  bool journal;

  GlobalSettings({
    required this.targetPath,
    this.maxParallel = 3,
    this.speedLimit = 0,
    this.targetChunkCount = 4,
    this.minChunkSize = 1024 * 1024,
    this.maxRetries = 5,
    this.requestTimeout = 30000,
    this.journal = false,
  });

  Map<String, dynamic> toJson() => {
        'targetPath': targetPath,
        'maxParallel': maxParallel,
        'speedLimit': speedLimit,
        'targetChunkCount': targetChunkCount,
        'minChunkSize': minChunkSize,
        'maxRetries': maxRetries,
        'requestTimeout': requestTimeout,
        'journal': journal,
      };

  factory GlobalSettings.fromJson(Map<String, dynamic> j, String fallbackPath) =>
      GlobalSettings(
        targetPath: (j['targetPath'] as String?) ?? fallbackPath,
        maxParallel: (j['maxParallel'] as num?)?.toInt() ?? 3,
        speedLimit: (j['speedLimit'] as num?)?.toInt() ?? 0,
        targetChunkCount: (j['targetChunkCount'] as num?)?.toInt() ?? 4,
        minChunkSize: (j['minChunkSize'] as num?)?.toInt() ?? 1024 * 1024,
        maxRetries: (j['maxRetries'] as num?)?.toInt() ?? 5,
        requestTimeout: (j['requestTimeout'] as num?)?.toInt() ?? 30000,
        journal: (j['journal'] as bool?) ?? false,
      );

  GlobalSettings copy() => GlobalSettings.fromJson(toJson(), targetPath);
}

class SettingsStore {
  final File _file;
  final String _fallbackTargetPath;

  SettingsStore(String path, this._fallbackTargetPath) : _file = File(path);

  Future<GlobalSettings> load() async {
    try {
      if (await _file.exists()) {
        final json = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
        return GlobalSettings.fromJson(json, _fallbackTargetPath);
      }
    } catch (_) {
      /* fall through to defaults */
    }
    return GlobalSettings(targetPath: _fallbackTargetPath);
  }

  Future<void> save(GlobalSettings s) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()));
  }
}
