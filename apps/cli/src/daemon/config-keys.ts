import type { Download, DownloadX, GlobalConfig } from '@downloadx/core';

export type ConfigKeyDef = {
  canonical: string;
  description: string;
  canLocal: boolean;
  localOnly?: boolean;
  localDescription?: string;
  getValue: (cfg: GlobalConfig) => unknown;
  setGlobalValue: (manager: DownloadX, raw: string, override: boolean) => void;
  setLocalValue: (dl: Download, raw: string) => void;
  parse: (raw: string) => unknown;
};

export const CONFIG_KEYS: ConfigKeyDef[] = [
  {
    canonical: 'maxParallel',
    description: 'Max concurrent downloads (number, e.g. 3)',
    canLocal: false,
    getValue: (cfg) => cfg.maxParallel,
    setGlobalValue(manager, raw) {
      manager.setMaxParallel(this.parse(raw) as number);
    },
    setLocalValue() {
      throw new Error(`'maxParallel' is not a per-download setting`);
    },
    parse(raw) {
      const n = Number(raw);
      if (!Number.isInteger(n) || n < 1) throw new Error(`'maxParallel' must be a positive integer`);
      return n;
    },
  },
  {
    canonical: 'speedLimit',
    description: 'Speed limit, 0 = unlimited. Accepts: 500kb, 3mb, 1.5gb or raw bytes',
    canLocal: true,
    getValue: (cfg) => cfg.speedLimit,
    setGlobalValue(manager, raw) {
      manager.setSpeedLimit(parseByteSize(raw));
    },
    setLocalValue(dl, raw) {
      dl.setSpeedLimit(this.parse(raw) as number | null);
    },
    parse: parseByteSize,
  },
  {
    canonical: 'targetPath',
    description: 'Directory for completed files (e.g. /home/user/Downloads)',
    canLocal: true,
    localDescription: 'Target directory for this download when it completes',
    getValue: (cfg) => cfg.targetPath,
    setGlobalValue(manager, raw) {
      manager.setTargetPath(raw);
    },
    setLocalValue(dl, raw) {
      dl.setTargetPath(raw);
    },
    parse(raw) {
      return raw === 'null' ? null : raw;
    },
  },
  {
    canonical: 'targetChunkCount',
    description: 'Target number of parallel chunks per download (number, e.g. 4)',
    canLocal: true,
    getValue: (cfg) => cfg.targetChunkCount,
    setGlobalValue(manager, raw, override) {
      manager.setTargetChunkCount(this.parse(raw) as number, override);
    },
    setLocalValue(dl, raw) {
      dl.setTargetChunkCount(this.parse(raw) as number);
    },
    parse(raw) {
      if (raw === 'null') return null;
      const n = Number(raw);
      if (!Number.isInteger(n) || n < 1) throw new Error(`'targetChunkCount' must be a positive integer`);
      return n;
    },
  },
  {
    canonical: 'minChunkSize',
    description: 'Minimum chunk size before splitting stops. Accepts: 500kb, 1mb (default: 1mb)',
    canLocal: true,
    getValue: (cfg) => cfg.minChunkSize,
    setGlobalValue(manager, raw, override) {
      manager.setMinChunkSize(parseByteSize(raw), override);
    },
    setLocalValue(dl, raw) {
      dl.setMinChunkSize(parseByteSize(raw));
    },
    parse: parseByteSize,
  },
  {
    canonical: 'journal',
    description: 'Write NDJSON diagnostic log next to each download (true or false)',
    canLocal: true,
    getValue: (cfg) => cfg.journal,
    setGlobalValue(manager, raw, override) {
      manager.setJournal(this.parse(raw) as boolean, override);
    },
    setLocalValue(dl, raw) {
      dl.setJournal(this.parse(raw) as boolean);
    },
    parse(raw) {
      if (raw === 'null') return null;
      if (raw !== 'true' && raw !== 'false') throw new Error(`'journal' must be 'true' or 'false'`);
      return raw === 'true';
    },
  },
  {
    canonical: 'filename',
    description: 'Override filename for this download (local only)',
    canLocal: true,
    localOnly: true,
    getValue: () => undefined,
    setGlobalValue() { throw new Error(`'filename' is not a global setting`); },
    setLocalValue(dl, raw) { dl.setFilename(this.parse(raw) as string | null); },
    parse(raw) { return raw === 'null' ? null : raw; },
  },
  {
    canonical: 'description',
    description: 'Free-form note attached to this download (local only)',
    canLocal: true,
    localOnly: true,
    getValue: () => undefined,
    setGlobalValue() { throw new Error(`'description' is not a global setting`); },
    setLocalValue(dl, raw) { dl.setDescription(this.parse(raw) as string | null); },
    parse(raw) { return raw === 'null' ? null : raw; },
  },
  {
    canonical: 'metadata',
    description: 'Arbitrary key/value data. Use dot-notation: set metadata.key value. null clears all.',
    canLocal: true,
    localOnly: true,
    getValue: () => undefined,
    setGlobalValue() { throw new Error(`'metadata' is not a global setting`); },
    setLocalValue(dl, raw) { dl.setMetadata(this.parse(raw) as Record<string, string | null> | null); },
    parse(raw) {
      if (raw === 'null') return null;
      const eqIdx = raw.indexOf('=');
      if (eqIdx !== -1) {
        const k = raw.slice(0, eqIdx);
        const v = raw.slice(eqIdx + 1);
        return { [k]: v === 'null' ? null : v };
      }
      return JSON.parse(raw) as Record<string, string>;
    },
  },
  {
    canonical: 'headers',
    description: 'HTTP headers. Use dot-notation: set headers.Authorization "Bearer x". null clears.',
    canLocal: true,
    getValue: (cfg) => cfg.headers,
    setGlobalValue(manager, raw) { manager.setHeaders(this.parse(raw) as Record<string, string | null> | null); },
    setLocalValue(dl, raw) { dl.setHeaders(this.parse(raw) as Record<string, string | null> | null); },
    parse(raw) {
      if (raw === 'null') return null;
      const eqIdx = raw.indexOf('=');
      if (eqIdx !== -1) {
        const k = raw.slice(0, eqIdx);
        const v = raw.slice(eqIdx + 1);
        return { [k]: v === 'null' ? null : v };
      }
      return JSON.parse(raw) as Record<string, string>;
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
  if (!local && def.localOnly) {
    throw new Error(`'${def.canonical}' can only be set per-download (use --id)`);
  }
  return def;
}

function parseByteSize(raw: string): number | null {
  if (raw === 'null') return null;
  if (raw === '0') return 0;
  const m = /^(\d+(?:\.\d+)?)\s*(kb|mb|gb|k|m|g)?$/i.exec(raw.trim());
  if (!m) throw new Error(`Invalid size '${raw}'. Examples: 500kb, 3mb, 1.5gb, 1048576`);
  const n = parseFloat(m[1]!);
  switch (m[2]?.toLowerCase()) {
    case 'gb': case 'g': return Math.round(n * 1024 * 1024 * 1024);
    case 'mb': case 'm': return Math.round(n * 1024 * 1024);
    case 'kb': case 'k': return Math.round(n * 1024);
    default: return Math.round(n);
  }
}
