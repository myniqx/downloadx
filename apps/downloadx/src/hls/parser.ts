import type { HlsMasterPlaylist, HlsMediaPlaylist, HlsSegment, HlsStream } from './types.js';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function resolveUrl(base: string, ref: string): string {
  if (/^https?:\/\//i.test(ref)) return ref;
  return new URL(ref, base).href;
}

function attrMap(attrLine: string): Map<string, string> {
  const map = new Map<string, string>();
  // Matches KEY=VALUE or KEY="VALUE WITH SPACES"
  const re = /([A-Z0-9_-]+)=("(?:[^"\\]|\\.)*"|[^,]+)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(attrLine)) !== null) {
    map.set(m[1], m[2].replace(/^"|"$/g, ''));
  }
  return map;
}

function isMasterPlaylist(text: string): boolean {
  return text.includes('#EXT-X-STREAM-INF');
}

// ---------------------------------------------------------------------------
// Master playlist parser
// ---------------------------------------------------------------------------

export function parseMasterPlaylist(text: string, baseUrl: string): HlsMasterPlaylist {
  const lines = text.split(/\r?\n/);
  const streams: HlsStream[] = [];
  let pending: Map<string, string> | null = null;

  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line === '#EXTM3U') continue;

    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      pending = attrMap(line.slice('#EXT-X-STREAM-INF:'.length));
      continue;
    }

    if (pending !== null && !line.startsWith('#')) {
      streams.push({
        bandwidth: parseInt(pending.get('BANDWIDTH') ?? '0', 10),
        resolution: pending.get('RESOLUTION') ?? null,
        codecs: pending.get('CODECS') ?? null,
        uri: resolveUrl(baseUrl, line),
      });
      pending = null;
    }
  }

  streams.sort((a, b) => b.bandwidth - a.bandwidth);
  return { streams };
}

// ---------------------------------------------------------------------------
// Media playlist parser
// ---------------------------------------------------------------------------

export function parseMediaPlaylist(text: string, baseUrl: string): HlsMediaPlaylist {
  const lines = text.split(/\r?\n/);
  const segments: HlsSegment[] = [];
  let targetDuration = 0;
  let totalDurationSec = 0;
  let isLive = true;
  let pendingDuration = 0;
  let pendingByteRange: { offset: number; length: number } | null = null;
  let byteRangeOffset = 0;

  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;

    if (line === '#EXTM3U') continue;

    if (line.startsWith('#EXT-X-TARGETDURATION:')) {
      targetDuration = parseInt(line.slice('#EXT-X-TARGETDURATION:'.length), 10);
      continue;
    }

    if (line === '#EXT-X-ENDLIST') {
      isLive = false;
      continue;
    }

    if (line.startsWith('#EXTINF:')) {
      // #EXTINF:<duration>[,<title>]
      const val = line.slice('#EXTINF:'.length).split(',')[0];
      pendingDuration = parseFloat(val);
      continue;
    }

    if (line.startsWith('#EXT-X-BYTERANGE:')) {
      // #EXT-X-BYTERANGE:<length>[@<offset>]
      const val = line.slice('#EXT-X-BYTERANGE:'.length);
      const [lenStr, offStr] = val.split('@');
      const length = parseInt(lenStr, 10);
      const offset = offStr !== undefined ? parseInt(offStr, 10) : byteRangeOffset;
      pendingByteRange = { length, offset };
      byteRangeOffset = offset + length;
      continue;
    }

    if (line.startsWith('#')) continue; // unknown tag

    // URI line
    if (pendingDuration > 0) {
      segments.push({
        uri: resolveUrl(baseUrl, line),
        durationSec: pendingDuration,
        byteRange: pendingByteRange,
      });
      totalDurationSec += pendingDuration;
      pendingDuration = 0;
      pendingByteRange = null;
    }
  }

  return { segments, totalDurationSec, targetDuration, isLive };
}

// ---------------------------------------------------------------------------
// Auto-detect and parse
// ---------------------------------------------------------------------------

export function parsePlaylist(
  text: string,
  baseUrl: string,
): { type: 'master'; playlist: HlsMasterPlaylist } | { type: 'media'; playlist: HlsMediaPlaylist } {
  if (isMasterPlaylist(text)) {
    return { type: 'master', playlist: parseMasterPlaylist(text, baseUrl) };
  }
  return { type: 'media', playlist: parseMediaPlaylist(text, baseUrl) };
}

export function selectBestStream(master: HlsMasterPlaylist): HlsStream | null {
  return master.streams[0] ?? null;
}
