import 'dart:convert';

import 'constants.dart';
import 'io.dart';
import 'types.dart';

/// Sidecar JSON persisted under the cache directory:
///   `{cachePath}/{id}.downloadx.json`
///
/// Keyed by download id (not filename) so it can be written before the probe
/// completes. Written atomically: write-to-tmp then rename, so a crash mid
/// [persistMeta] can't corrupt an existing valid meta file.

const _jsonEncoder = JsonEncoder.withIndent('  ');

/// Locates the sidecar meta file for a download on disk.
class MetaLocator {
  /// Directory the meta JSON lives in (usually cachePath).
  final String dir;

  /// Download id — the meta filename is `{id}.downloadx.json`.
  final String id;

  /// Creates a [MetaLocator].
  const MetaLocator({required this.dir, required this.id});
}

/// Returns the absolute path to the meta file described by [locator].
String metaPath(DownloadxIo io, MetaLocator locator) =>
    io.joinPath([locator.dir, '${locator.id}$metaExt']);

String _tmpPath(String target) => '$target.tmp';

int _defaultNow() => DateTime.now().millisecondsSinceEpoch;

/// Meta for a download that has been registered but not probed yet. Probe
/// fields start null/zero and are filled by [applyProbeToMeta].
MetaFile createEmptyMeta(
    {required String id, required String url, int Function()? now}) {
  final ts = (now ?? _defaultNow)();
  return MetaFile(
    schemaVersion: metaSchemaVersion,
    id: id,
    url: url,
    finalUrl: null,
    filename: null,
    totalSize: null,
    acceptsRanges: false,
    etag: null,
    lastModified: null,
    contentType: null,
    createdAt: ts,
    updatedAt: ts,
    state: DownloadState.idle,
    chunks: [],
    addedAt: ts,
    completedAt: null,
    errorMessage: null,
    speedLimit: null,
    targetChunkCount: null,
    targetPath: null,
    minChunkSize: null,
    journal: null,
  );
}

/// Builds a fresh meta directly from a probe result.
MetaFile createMeta({
  required String id,
  required String url,
  required ProbeResult probe,
  required List<ChunkSnapshot> chunks,
  int Function()? now,
}) {
  final meta = createEmptyMeta(id: id, url: url, now: now);
  return applyProbeToMeta(meta, probe, chunks);
}

/// Merges a probe result into an existing meta, returning the same object.
MetaFile applyProbeToMeta(
    MetaFile meta, ProbeResult probe, List<ChunkSnapshot> chunks) {
  meta.finalUrl = probe.finalUrl;
  meta.filename = probe.filename;
  meta.totalSize = probe.totalSize;
  meta.acceptsRanges = probe.acceptsRanges;
  meta.etag = probe.etag;
  meta.lastModified = probe.lastModified;
  meta.contentType = probe.contentType;
  meta.isHls = probe.isHls;
  meta.chunks = chunks;
  meta.updatedAt = _defaultNow();
  return meta;
}

/// Loads and validates a meta file. Returns null when the file is missing or corrupt.
Future<MetaFile?> loadMeta(DownloadxIo io, MetaLocator locator) async {
  final path = metaPath(io, locator);
  if (!await io.exists(path)) return null;
  try {
    final buf = await io.readFile(path);
    final text = utf8.decode(buf);
    final parsed = jsonDecode(text);
    return _validate(parsed);
  } catch (_) {
    // Corrupt meta → treat as missing so a fresh download can start. The old
    // file is left on disk for inspection.
    return null;
  }
}

/// Scans [dir] for `*.downloadx.json` and loads each sequentially. Corrupt or
/// schema-mismatched files are skipped (left on disk).
Future<List<MetaFile>> listMetaFiles(DownloadxIo io, String dir) async {
  if (!await io.exists(dir)) return [];
  final entries = await io.listDir(dir);
  final out = <MetaFile>[];
  for (final name in entries) {
    if (!name.endsWith(metaExt)) continue;
    final id = name.substring(0, name.length - metaExt.length);
    final meta = await loadMeta(io, MetaLocator(dir: dir, id: id));
    if (meta != null) out.add(meta);
  }
  return out;
}

/// Atomically writes [meta] to disk (write-to-tmp then rename).
Future<void> persistMeta(
    DownloadxIo io, MetaLocator locator, MetaFile meta) async {
  await io.mkdir(locator.dir);
  final target = metaPath(io, locator);
  final tmp = _tmpPath(target);
  meta.updatedAt = _defaultNow();
  final encoded = utf8.encode(_jsonEncoder.convert(meta.toJson()));
  await io.writeFile(tmp, encoded);
  await io.rename(tmp, target);
}

/// Deletes the meta file. Silently no-ops when the file does not exist.
Future<void> deleteMeta(DownloadxIo io, MetaLocator locator) async {
  await io.unlink(metaPath(io, locator));
}

/// Decides whether a meta file represents the same remote resource a fresh
/// probe describes. ETag first (strong), then Last-Modified, then total size.
bool canResumeAgainst(MetaFile meta, ProbeResult probe) {
  if (meta.schemaVersion != metaSchemaVersion) return false;
  if (meta.totalSize != probe.totalSize) return false;
  if (meta.etag != null && probe.etag != null) {
    return meta.etag == probe.etag;
  }
  if (meta.lastModified != null && probe.lastModified != null) {
    return meta.lastModified == probe.lastModified;
  }
  // No validators — size match is the only (weak) signal we have.
  return true;
}

/// Maps a raw download state onto what should be persisted on pause/crash.
DownloadState dehydrateState(DownloadState state) {
  // `downloading`/`probing` are never durable — if we crashed we were paused.
  if (state == DownloadState.downloading || state == DownloadState.probing) {
    return DownloadState.paused;
  }
  return state;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

MetaFile _validate(dynamic value) {
  if (value is! Map) throw const FormatException('meta: not an object');
  final v = value.cast<String, dynamic>();
  if (v['schemaVersion'] != metaSchemaVersion) {
    throw FormatException(
        'meta: unsupported schemaVersion ${v['schemaVersion']}');
  }
  _assertString(v, 'id');
  _assertString(v, 'url');
  _assertNullableString(v, 'finalUrl');
  _assertNullableString(v, 'filename');
  _assertNullableNumber(v, 'totalSize');
  _assertBoolean(v, 'acceptsRanges');
  _assertNullableString(v, 'etag');
  _assertNullableString(v, 'lastModified');
  _assertNullableString(v, 'contentType');
  _assertNumber(v, 'createdAt');
  _assertNumber(v, 'updatedAt');
  _assertString(v, 'state');
  if (v['chunks'] is! List) {
    throw const FormatException('meta: chunks must be array');
  }
  final chunks = <ChunkSnapshot>[];
  final rawChunks = v['chunks'] as List;
  for (var i = 0; i < rawChunks.length; i += 1) {
    chunks.add(_validateChunk(rawChunks[i], i));
  }
  _assertNumber(v, 'addedAt');
  _assertNullableNumber(v, 'completedAt');
  _assertNullableString(v, 'errorMessage');
  _assertNullableNumber(v, 'speedLimit');
  _assertNullableNumber(v, 'targetChunkCount');
  _assertNullableString(v, 'targetPath');
  final minChunkSize = v['minChunkSize'];
  final journal = v['journal'];
  final isHls = v['isHls'];
  final description = v['description'];
  final metadata = v['metadata'];

  return MetaFile(
    schemaVersion: metaSchemaVersion,
    id: v['id'] as String,
    url: v['url'] as String,
    finalUrl: v['finalUrl'] as String?,
    filename: v['filename'] as String?,
    totalSize: (v['totalSize'] as num?)?.toInt(),
    acceptsRanges: v['acceptsRanges'] as bool,
    etag: v['etag'] as String?,
    lastModified: v['lastModified'] as String?,
    contentType: v['contentType'] as String?,
    createdAt: (v['createdAt'] as num).toInt(),
    updatedAt: (v['updatedAt'] as num).toInt(),
    state: downloadStateFromString(v['state'] as String),
    chunks: chunks,
    addedAt: (v['addedAt'] as num).toInt(),
    completedAt: (v['completedAt'] as num?)?.toInt(),
    errorMessage: v['errorMessage'] as String?,
    speedLimit: (v['speedLimit'] as num?)?.toInt(),
    targetChunkCount: (v['targetChunkCount'] as num?)?.toInt(),
    targetPath: v['targetPath'] as String?,
    minChunkSize: minChunkSize is num ? minChunkSize.toInt() : null,
    journal: journal is bool ? journal : null,
    isHls: isHls is bool ? isHls : false,
    description: description is String ? description : null,
    metadata: _asStringMap(metadata),
  );
}

/// Returns a `Map<String, String>` when [value] is a plain map whose values are
/// all strings, otherwise null. Used for the optional `metadata` field.
Map<String, String>? _asStringMap(dynamic value) {
  if (value is! Map) return null;
  final out = <String, String>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! String) return null;
    out[entry.key as String] = entry.value as String;
  }
  return out;
}

ChunkSnapshot _validateChunk(dynamic value, int index) {
  if (value is! Map) throw FormatException('meta: chunk[$index] not an object');
  final c = value.cast<String, dynamic>();
  _assertString(c, 'id');
  _assertNumber(c, 'offset');
  _assertNumber(c, 'length');
  _assertNumber(c, 'downloadedBytes');
  _assertString(c, 'status');
  _assertString(c, 'quality');
  _assertNumber(c, 'retries');
  // Optional HLS segment fields — validated only when present so old metas and
  // normal chunks remain valid.
  if (c.containsKey('isSegment') && c['isSegment'] != null && c['isSegment'] is! bool) {
    throw FormatException('meta: chunk[$index].isSegment must be boolean');
  }
  if (c.containsKey('targetFilePath') &&
      c['targetFilePath'] != null &&
      c['targetFilePath'] is! String) {
    throw FormatException('meta: chunk[$index].targetFilePath must be string');
  }
  if (c.containsKey('uri') && c['uri'] != null && c['uri'] is! String) {
    throw FormatException('meta: chunk[$index].uri must be string');
  }
  if (c.containsKey('durationSec') && c['durationSec'] != null && c['durationSec'] is! num) {
    throw FormatException('meta: chunk[$index].durationSec must be number');
  }
  return ChunkSnapshot.fromJson(c);
}

void _assertString(Map<String, dynamic> o, String key) {
  if (o[key] is! String) throw FormatException('meta: $key must be string');
}

void _assertNullableString(Map<String, dynamic> o, String key) {
  final v = o[key];
  if (v != null && v is! String) {
    throw FormatException('meta: $key must be string|null');
  }
}

void _assertNumber(Map<String, dynamic> o, String key) {
  if (o[key] is! num) throw FormatException('meta: $key must be number');
}

void _assertNullableNumber(Map<String, dynamic> o, String key) {
  final v = o[key];
  if (v != null && v is! num) {
    throw FormatException('meta: $key must be number|null');
  }
}

void _assertBoolean(Map<String, dynamic> o, String key) {
  if (o[key] is! bool) throw FormatException('meta: $key must be boolean');
}
