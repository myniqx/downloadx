import 'io.dart';
import 'io_fetch.dart';
import 'types.dart';

/// Options for [probeUrl].
class ProbeOptions {
  /// Fetch function used to issue HEAD and range GET requests.
  final FetchFn fetch;

  /// The URL to probe.
  final String url;

  /// Extra HTTP headers merged into the probe requests.
  final Map<String, String>? headers;

  /// Cancellation token; fires abort into the in-flight probe request.
  final CancelToken? signal;

  /// Optional filename override; takes precedence over inference.
  final String? filenameHint;

  /// Creates a [ProbeOptions].
  const ProbeOptions({
    required this.fetch,
    required this.url,
    this.headers,
    this.signal,
    this.filenameHint,
  });
}

/// Probes a URL to determine size, range support, validators, and filename.
///
/// Strategy:
///   1. Try a HEAD request (cheap, many CDNs answer correctly).
///   2. If HEAD fails / lacks size, fall back to a `Range: bytes=0-0` GET,
///      which every range-capable server understands.
///   3. The GET body is not consumed — we only need headers.
Future<ProbeResult> probeUrl(ProbeOptions opts) async {
  final headResult = await _tryHead(opts);
  if (headResult != null && headResult.usable) {
    return _finalize(opts, headResult);
  }
  final rangeResult = await _tryRangeGet(opts);
  return _finalize(opts, rangeResult);
}

class _ProbeRaw {
  int status;
  String finalUrl;
  int? totalSize;
  bool acceptsRanges;
  String? etag;
  String? lastModified;
  String? contentType;
  String? contentDisposition;
  bool usable;
  _ProbeRaw({
    required this.status,
    required this.finalUrl,
    required this.totalSize,
    required this.acceptsRanges,
    required this.etag,
    required this.lastModified,
    required this.contentType,
    required this.contentDisposition,
    required this.usable,
  });
}

Future<_ProbeRaw?> _tryHead(ProbeOptions opts) async {
  try {
    final init = FetchInit(
      method: 'HEAD',
      headers: {...?opts.headers},
      signal: opts.signal,
    );
    final res = await opts.fetch(opts.url, init);
    if (!res.ok) {
      final raw = _extract(opts.url, res);
      raw.usable = false;
      return raw;
    }
    final raw = _extract(opts.url, res);
    // HEAD is trusted only if it tells us the size; otherwise fall through to
    // a ranged GET which forces the origin to commit.
    raw.usable = raw.totalSize != null;
    return raw;
  } catch (_) {
    return null;
  }
}

Future<_ProbeRaw> _tryRangeGet(ProbeOptions opts) async {
  final init = FetchInit(
    method: 'GET',
    headers: {...?opts.headers, 'Range': 'bytes=0-0'},
    signal: opts.signal,
  );
  final res = await opts.fetch(opts.url, init);
  // Drain the body so the connection can be reused without buffering it all.
  final body = res.body;
  if (body != null) {
    try {
      await body.listen(null).cancel();
    } catch (_) {
      /* ignore */
    }
  }
  // Refuse to produce a result for failed responses. 416 is special: the
  // server rejected our range but the resource is reachable, so treat it as
  // "no range support" rather than a hard failure.
  if (!res.ok && res.status != 206 && res.status != 416) {
    throw Exception('probe: HTTP ${res.status} ${res.statusText}');
  }
  final raw = _extract(opts.url, res);
  raw.acceptsRanges = raw.acceptsRanges || res.status == 206;
  raw.usable = true;
  return raw;
}

_ProbeRaw _extract(String url, FetchResponse res) {
  final contentLength = _parseIntHeader(res.headers.get('content-length'));
  final contentRange = res.headers.get('content-range');
  final totalSize = contentRange != null
      ? _parseContentRangeTotal(contentRange)
      : contentLength;
  final acceptRanges = res.headers.get('accept-ranges');
  final acceptsRanges =
      acceptRanges != null && acceptRanges.toLowerCase().contains('bytes');

  final resUrl = res.url;
  return _ProbeRaw(
    status: res.status,
    // Post-redirect URL when exposed — chunk requests then skip the redirect.
    finalUrl: (resUrl != null && resUrl.isNotEmpty) ? resUrl : url,
    totalSize: totalSize,
    acceptsRanges: acceptsRanges,
    etag: res.headers.get('etag'),
    lastModified: res.headers.get('last-modified'),
    contentType: res.headers.get('content-type'),
    contentDisposition: res.headers.get('content-disposition'),
    usable: false,
  );
}

ProbeResult _finalize(ProbeOptions opts, _ProbeRaw raw) {
  final filename = opts.filenameHint ??
      filenameFromDisposition(raw.contentDisposition) ??
      filenameFromUrl(opts.url) ??
      'download-${DateTime.now().millisecondsSinceEpoch}';

  final ct = raw.contentType?.toLowerCase() ?? '';
  final isHls = ct.contains('mpegurl') ||
      ct.contains('x-m3u8') ||
      opts.url.split('?').first.toLowerCase().endsWith('.m3u8');

  return ProbeResult(
    url: opts.url,
    finalUrl: raw.finalUrl,
    totalSize: raw.totalSize,
    acceptsRanges: raw.acceptsRanges,
    etag: raw.etag,
    lastModified: raw.lastModified,
    contentType: raw.contentType,
    filename: filename,
    isHls: isHls,
  );
}

int? _parseIntHeader(String? value) {
  if (value == null) return null;
  final n = int.tryParse(value);
  return (n != null && n >= 0) ? n : null;
}

/// Parses the "total" segment of a `Content-Range: bytes 0-0/12345` header.
int? _parseContentRangeTotal(String value) {
  final match = RegExp(r'/(\d+|\*)$').firstMatch(value.trim());
  if (match == null) return null;
  final total = match.group(1);
  if (total == null || total == '*') return null;
  final n = int.tryParse(total);
  return (n != null && n >= 0) ? n : null;
}

/// Extracts filename from `Content-Disposition`, honouring RFC 5987 `filename*`.
String? filenameFromDisposition(String? value) {
  if (value == null) return null;
  // RFC 5987: filename*=UTF-8''encoded — takes precedence.
  final star =
      RegExp(r"filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)", caseSensitive: false)
          .firstMatch(value);
  final starGroup = star?.group(1);
  if (starGroup != null && starGroup.isNotEmpty) {
    try {
      return Uri.decodeComponent(starGroup.trim());
    } catch (_) {
      /* fall through */
    }
  }
  final plain =
      RegExp(r'filename\s*=\s*("([^"]+)"|([^;]+))', caseSensitive: false)
          .firstMatch(value);
  final picked = plain?.group(2) ?? plain?.group(3);
  if (picked == null) return null;
  return picked.trim();
}

/// Last path segment of the URL, URL-decoded. Returns null if not derivable.
String? filenameFromUrl(String url) {
  try {
    final parsed = Uri.parse(url);
    final segments = parsed.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;
    final last = segments.last;
    return Uri.decodeComponent(last);
  } catch (_) {
    return null;
  }
}
