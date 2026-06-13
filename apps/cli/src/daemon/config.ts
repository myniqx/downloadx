import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

import { CONFIG_FILE, DOWNLOADS_DIR, CACHE_DIR } from '../constants.ts';
import type { DaemonConfig } from '../ipc.ts';

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
