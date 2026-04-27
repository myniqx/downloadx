import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import type { DownloadEntry } from '../ipc.ts';
import { STATE_FILE } from '../constants.ts';

interface State {
  downloads: DownloadEntry[];
}

let state: State = { downloads: [] };

export async function loadState(): Promise<void> {
  try {
    const raw = await readFile(STATE_FILE, 'utf8');
    state = JSON.parse(raw) as State;
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

export async function upsertDownload(entry: DownloadEntry): Promise<void> {
  const idx = state.downloads.findIndex((d) => d.id === entry.id);
  if (idx === -1) {
    state.downloads.push(entry);
  } else {
    state.downloads[idx] = entry;
  }
  await persistState();
}

export async function removeDownload(id: string): Promise<void> {
  state.downloads = state.downloads.filter((d) => d.id !== id);
  await persistState();
}
