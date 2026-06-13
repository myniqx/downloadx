import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import type { DownloadEntry, DaemonConfig } from '../ipc.ts';
import { STATE_FILE, CONFIG_FILE, DOWNLOADS_DIR, CACHE_DIR } from '../constants.ts';

interface State {
  downloads: DownloadEntry[];
}

let state: State = { downloads: [] };

const DEFAULT_CONFIG: DaemonConfig = {
  maxParallel: 3,
  speedLimit: 0,
  targetPath: DOWNLOADS_DIR,
  cachePath: CACHE_DIR,
};

let config: DaemonConfig = { ...DEFAULT_CONFIG };

export function getConfig(): DaemonConfig {
  return config;
}

export async function loadConfig(): Promise<void> {
  try {
    const raw = await readFile(CONFIG_FILE, 'utf8');
    config = { ...DEFAULT_CONFIG, ...JSON.parse(raw) as Partial<DaemonConfig> };
  } catch {
    config = { ...DEFAULT_CONFIG };
  }
}

export async function saveConfig(): Promise<void> {
  await mkdir(dirname(CONFIG_FILE), { recursive: true });
  await writeFile(CONFIG_FILE, JSON.stringify(config, null, 2), 'utf8');
}

const VALID_KEYS = new Set<keyof DaemonConfig>(['maxParallel', 'speedLimit', 'targetPath', 'cachePath']);
const KEY_MAP: Record<string, keyof DaemonConfig> = Object.fromEntries(
  [...VALID_KEYS].map((k) => [k.toLowerCase(), k])
);

export function parseSpeed(value: string): number {
  const m = /^(\d+(?:\.\d+)?)\s*(kb|mb|gb|k|m|g)?$/i.exec(value.trim());
  if (!m) throw new Error(`Invalid speed '${value}'. Examples: 500kb, 3mb, 1.5gb, 1048576`);
  const n = parseFloat(m[1]!);
  switch (m[2]?.toLowerCase()) {
    case 'gb': case 'g': return Math.round(n * 1024 * 1024 * 1024);
    case 'mb': case 'm': return Math.round(n * 1024 * 1024);
    case 'kb': case 'k': return Math.round(n * 1024);
    default: return Math.round(n);
  }
}

export function setConfigKey(key: string, value: string): void {
  const canonical = KEY_MAP[key.toLowerCase()];
  if (!canonical) throw new Error(`Unknown config key '${key}'. Valid keys: ${[...VALID_KEYS].join(', ')}`);
  key = canonical;
  if (key === 'maxParallel') {
    const n = Number(value);
    if (!Number.isInteger(n) || n < 1) throw new Error(`'maxParallel' must be a positive integer`);
    (config as unknown as Record<string, unknown>)[key] = n;
  } else if (key === 'speedLimit') {
    const n = value === '0' ? 0 : parseSpeed(value);
    (config as unknown as Record<string, unknown>)[key] = n;
  } else {
    (config as unknown as Record<string, unknown>)[key] = value;
  }
}

export function getConfigKey(key?: string): DaemonConfig | unknown {
  if (!key) return config;
  const canonical = KEY_MAP[key.toLowerCase()];
  if (!canonical) throw new Error(`Unknown config key '${key}'. Valid keys: ${[...VALID_KEYS].join(', ')}`);
  return config[canonical];
}

function sortByAddedAt(): void {
  state.downloads.sort((a, b) => a.addedAt - b.addedAt);
}

export async function loadState(): Promise<void> {
  try {
    const raw = await readFile(STATE_FILE, 'utf8');
    state = JSON.parse(raw) as State;
    sortByAddedAt();
  } catch {
    state = { downloads: [] };
  }
}

async function persistState(): Promise<void> {
  await mkdir(dirname(STATE_FILE), { recursive: true });
  await writeFile(STATE_FILE, JSON.stringify(state, null, 2), 'utf8');
}

export function getDownloads(): DownloadEntry[] {
  return state.downloads;
}

export function getDownload(id: string): DownloadEntry | undefined {
  return state.downloads.find((d) => d.id === id);
}

// Resolves "#1", "1" (1-based index) or a full UUID to the stored entry.
export function resolveDownload(idOrIndex: string): DownloadEntry | undefined {
  const n = /^#?(\d+)$/.exec(idOrIndex);
  if (n) return state.downloads[Number(n[1]) - 1];
  return state.downloads.find((d) => d.id === idOrIndex || d.id.startsWith(idOrIndex));
}

export function getAllIds(): string[] {
  return state.downloads.map((d) => d.id);
}

export async function upsertDownload(entry: DownloadEntry): Promise<void> {
  const idx = state.downloads.findIndex((d) => d.id === entry.id);
  if (idx === -1) {
    state.downloads.push(entry);
    sortByAddedAt();
  } else {
    state.downloads[idx] = entry;
  }
  await persistState();
}

export async function removeDownload(id: string): Promise<void> {
  state.downloads = state.downloads.filter((d) => d.id !== id);
  await persistState();
}
