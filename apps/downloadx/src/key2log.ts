export const KEY_LOGS = {
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
  'chunk.retry':         'Chunk {id} retry #{attempt}: {message}',
  'chunk.split':         'Chunk {source} split — new chunk {id} takes bytes {offset}–{end}',
  'chunk.stall':         'Chunk {id} stalled for {duration}ms — reissuing request',
  'chunk.fetch.started': 'Chunk {id} fetching {url} bytes {range}',

  'config.speedLimit':        'Speed limit changed: {old} → {new}{scope}',
  'config.targetChunkCount':  'Target chunk count changed: {old} → {new}{scope}',
  'config.targetPath':        'Target path changed: {old} → {new}{scope}',
  'config.minChunkSize':      'Min chunk size changed: {old} → {new}{scope}',
  'config.journal':           'Journal changed: {old} → {new}{scope}',
  'config.filename':          'Filename changed: {old} → {new}',
  'config.description':       'Description changed: {old} → {new}',
  'config.metadata':          'Metadata updated: {patch}',
  'config.headers':           'Headers updated: {patch}',

  'alloc.completed':          'Disk pre-allocated {bytes} bytes',
  'alloc.failed':             'Disk pre-allocation failed: {message}',

  'hls.multi-stream':         'HLS master playlist has {count} streams — registering as separate downloads',
  'hls.streams-registered':   '{count} HLS streams added to download queue',
  'hls.segments-planned':     'HLS playlist has {total} segments ({done} already completed)',
  'hls.concat-started':       'Concatenating {segments} segments into {output}',
  'hls.concat-completed':     'HLS concat completed: {output}',

  'finalize.size-mismatch':   'Size mismatch — expected {expected} bytes, found {actual}',
  'finalize.completed':       'File finalized: {path}',

  'range.fallback':           'Server ignored Range header — restarting as single-chunk download',

  'chunk.no-range-restart':   'Chunk {id} restarting from byte 0 — no range support, discarding {discarded} bytes',
} as const;

export type LogCode = keyof typeof KEY_LOGS;

export function renderLog(code: LogCode, params?: Record<string, string | number>): string {
  let template: string = KEY_LOGS[code];
  if (params === undefined) return template;
  for (const [k, v] of Object.entries(params)) {
    template = template.replaceAll(`{${k}}`, String(v));
  }
  return template;
}
