/**
 * Parses a human-friendly size/speed string into bytes.
 * Accepts: `500kb`, `3mb`, `1.5gb`, or raw `1048576`. Case-insensitive.
 */
function parseSpeed(value: string): number {
  const m = /^(\d+(?:\.\d+)?)\s*(kb|mb|gb|k|m|g)?$/i.exec(value.trim());
  if (!m) throw new Error(`Invalid speed '${value}'. Examples: 500kb, 3mb, 1.5gb, 1048576`);
  const n = parseFloat(m[1]!);
  switch (m[2]?.toLowerCase()) {
    case 'gb':
    case 'g':
      return Math.round(n * 1024 * 1024 * 1024);
    case 'mb':
    case 'm':
      return Math.round(n * 1024 * 1024);
    case 'kb':
    case 'k':
      return Math.round(n * 1024);
    default:
      return Math.round(n);
  }
}

export type ConfigKeyDef = {
  canonical: string;
  description: string;
  canLocal: boolean;
  localDescription?: string;
  parse: (raw: string) => unknown;
};

export const CONFIG_KEYS: ConfigKeyDef[] = [
  {
    canonical: 'maxParallel',
    description: 'Max concurrent downloads (number, e.g. 3)',
    canLocal: false,
    parse(raw) {
      const n = Number(raw);
      if (!Number.isInteger(n) || n < 1)
        throw new Error(`'maxParallel' must be a positive integer`);
      return n;
    },
  },
  {
    canonical: 'speedLimit',
    description: 'Speed limit, 0 = unlimited. Accepts: 500kb, 3mb, 1.5gb or raw bytes',
    canLocal: true,
    parse(raw) {
      return raw === '0' ? 0 : parseSpeed(raw);
    },
  },
  {
    canonical: 'targetPath',
    description: 'Directory for completed files (e.g. /home/user/Downloads)',
    canLocal: true,
    localDescription: 'Target directory for this download when it completes',
    parse(raw) {
      return raw;
    },
  },
  {
    canonical: 'cachePath',
    description: 'Directory for in-progress .part files (e.g. /tmp/downloadx-cache)',
    canLocal: false,
    parse(raw) {
      return raw;
    },
  },
  {
    canonical: 'targetChunkCount',
    description: 'Target number of parallel chunks per download (number, e.g. 4)',
    canLocal: true,
    parse(raw) {
      const n = Number(raw);
      if (!Number.isInteger(n) || n < 1)
        throw new Error(`'targetChunkCount' must be a positive integer`);
      return n;
    },
  },
  {
    canonical: 'minChunkSize',
    description: 'Minimum chunk size before splitting stops. Accepts: 500kb, 1mb (default: 1mb)',
    canLocal: true,
    parse(raw) {
      return parseSpeed(raw);
    },
  },
  {
    canonical: 'journal',
    description: 'Write NDJSON diagnostic log next to each download (true or false)',
    canLocal: true,
    parse(raw) {
      if (raw !== 'true' && raw !== 'false') throw new Error(`'journal' must be 'true' or 'false'`);
      return raw === 'true';
    },
  },
];

export const CONFIG_KEY_MAP = new Map(CONFIG_KEYS.map((def) => [def.canonical.toLowerCase(), def]));

export const LOCAL_KEYS = CONFIG_KEYS.filter((d) => d.canLocal);

export const LOCAL_KEY_MAP = new Map(LOCAL_KEYS.map((def) => [def.canonical.toLowerCase(), def]));

export function resolveConfigKey(raw: string, local: boolean): ConfigKeyDef {
  const map = local ? LOCAL_KEY_MAP : CONFIG_KEY_MAP;
  const def = map.get(raw.toLowerCase());
  if (!def) {
    const valid = [...map.values()].map((d) => d.canonical).join(', ');
    const scope = local ? 'per-download' : 'global';
    throw new Error(`Unknown ${scope} key '${raw}'. Valid: ${valid}`);
  }
  return def;
}
