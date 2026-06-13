import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

import { STATE_FILE, CONFIG_FILE, DOWNLOADS_DIR, CACHE_DIR } from '../constants.ts';
import type { DownloadEntry, DaemonConfig } from '../ipc.ts';

interface State {
  downloads: DownloadEntry[];
}

let state: State = { downloads: [] };

export const DEFAULT_CONFIG: DaemonConfig = {
  maxParallel: 3,
  speedLimit: 0,
  targetPath: DOWNLOADS_DIR,
  cachePath: CACHE_DIR,
  targetChunkCount: 4,
  minChunkSize: 1024 * 1024,
  journal: true,
};

export async function loadConfig(): Promise<DaemonConfig> {
  try {
    const raw = await readFile(CONFIG_FILE, 'utf8');
    return { ...DEFAULT_CONFIG, ...(JSON.parse(raw) as Partial<DaemonConfig>) };
  } catch {
    return { ...DEFAULT_CONFIG };
  }
}

export async function saveConfig(config: DaemonConfig): Promise<void> {
  await mkdir(dirname(CONFIG_FILE), { recursive: true });
  await writeFile(CONFIG_FILE, JSON.stringify(config, null, 2), 'utf8');
}

export function parseSpeed(value: string): number {
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
