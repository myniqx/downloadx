/// Log code → default English template map.
/// Placeholders use {name} syntax for runtime interpolation.
const Map<String, String> keyLogs = {
  'download.created':    'Download created from {url} with options: {options}',
  'download.started':    'Download started',
  'download.resumed':    'Download resumed',
  'download.paused':     'Download paused',
  'download.cancelled':  'Download cancelled',
  'download.completed':  'Download completed — {bytes} bytes in {duration}',
  'download.error':      'Download failed: {message}',

  'probe.started':       'Probing {url}',
  'probe.completed':     'Probe complete — size: {size}, ranges: {ranges}, filename: {filename}',
  'probe.error':         'Probe failed: {message}',

  'chunk.initialized':   'Chunk {id} initialized: bytes {offset}–{end}',
  'chunk.completed':     'Chunk {id} completed — {bytes} bytes written',
  'chunk.failed':        'Chunk {id} failed: {message}',
  'chunk.retry':         'Chunk {id} retry #{attempt} (delay: {delayMs}ms): {message}',
  'chunk.split':         'Chunk {source} split — donated {length} bytes at {offset} to new chunk {id} (range {offset}–{end})',
  'chunk.stall':         'Chunk {id} stalled for {duration}ms — reissuing request',
  'chunk.fetch.started': 'Chunk {id} fetching {url} bytes {range}',
  'chunk.no-range-restart': 'Chunk {id} restarting from byte 0 — no range support, discarding {discarded} bytes',

  'config.speedLimit':       'Speed limit changed: {old} → {new}{scope}',
  'config.targetChunkCount': 'Target chunk count changed: {old} → {new}{scope}',
  'config.targetPath':       'Target path changed: {old} → {new}{scope}',
  'config.minChunkSize':     'Min chunk size changed: {old} → {new}{scope}',
  'config.journal':          'Journal changed: {old} → {new}{scope}',
  'config.filename':         'Filename changed: {old} → {new}',
  'config.description':      'Description changed: {old} → {new}',
  'config.metadata':         'Metadata updated: {patch}',
  'config.headers':          'Headers updated: {patch}',

  'alloc.completed':     'Disk pre-allocated {bytes} bytes',
  'alloc.failed':        'Disk pre-allocation failed: {message}',

  'hls.multi-stream':      'HLS master playlist has {count} streams — registering as separate downloads',
  'hls.streams-registered': '{count} HLS streams added to download queue',
  'hls.segments-planned':  'HLS playlist has {total} segments ({done} already completed)',
  'hls.concat-started':    'Concatenating {segments} segments into {output}',
  'hls.concat-completed':  'HLS concat completed: {output}',

  'finalize.size-mismatch': 'Size mismatch — expected {expected} bytes, found {actual}',
  'finalize.completed':     'File finalized: {path}',

  'range.fallback': 'Server ignored Range header — restarting as single-chunk download',
};

typedef LogCode = String;

String renderLog(LogCode code, [Map<String, dynamic>? params]) {
  String template = keyLogs[code] ?? code;
  if (params == null) return template;
  for (final entry in params.entries) {
    template = template.replaceAll('{${entry.key}}', '${entry.value}');
  }
  return template;
}
