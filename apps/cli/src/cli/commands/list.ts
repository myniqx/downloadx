import { stat } from 'node:fs/promises';
import { join } from 'node:path';

import type { DownloadDescription } from '@downloadx/core';
import { ensureDaemon, sendRequest } from '../client.ts';

const STATUS_COLOR: Record<string, string> = {
  queued: '\x1b[90m',
  downloading: '\x1b[36m',
  paused: '\x1b[33m',
  completed: '\x1b[32m',
  failed: '\x1b[31m',
  cancelled: '\x1b[90m',
};
const RESET = '\x1b[0m';
const GREEN = '\x1b[32m';
const RED = '\x1b[31m';

function fmtBytes(n: number | null): string {
  if (n === null) return '?';
  if (n >= 1e9) return `${(n / 1e9).toFixed(1)} GB`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)} MB`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)} KB`;
  return `${n} B`;
}

async function fileExists(p: string): Promise<boolean> {
  try {
    await stat(p);
    return true;
  } catch {
    return false;
  }
}

export async function cmdList(): Promise<void> {
  await ensureDaemon();
  const downloads = await sendRequest<DownloadDescription[]>({ cmd: 'list' });

  if (downloads.length === 0) {
    console.log('No downloads.');
    return;
  }

  const indexWidth = String(downloads.length).length;
  for (let i = 0; i < downloads.length; i++) {
    const d = downloads[i]!;
    const color = STATUS_COLOR[d.state] ?? '';
    const idx = `#${String(i + 1).padStart(indexWidth)}`;

    if (d.state === 'completed' && d.filename && d.targetPath) {
      const fullPath = join(d.targetPath, d.filename);
      const exists = await fileExists(fullPath);
      const icon = exists ? `${GREEN}✓${RESET}` : `${RED}✗${RESET}`;
      const deleted = exists ? '' : '  (deleted)';
      console.log(
        `${color}${idx} [${d.state.toUpperCase().padEnd(11)}]${RESET}  ${fmtBytes(d.totalBytes)}  ${icon} ${fullPath}${deleted}`,
      );
    } else {
      const pct = d.percent !== null ? `${d.percent.toFixed(1)}%` : '?%';
      const size = `${fmtBytes(d.downloadedBytes)} / ${fmtBytes(d.totalBytes)}`;
      const name = d.filename ?? d.url;
      console.log(
        `${color}${idx} [${d.state.toUpperCase().padEnd(11)}]${RESET}  ${pct.padStart(6)}  ${size.padStart(18)}  ${name}`,
      );
    }
  }
}
