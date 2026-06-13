import { stat } from 'node:fs/promises';
import { join } from 'node:path';
import { ensureDaemon, sendRequest } from '../client.ts';
import type { DownloadDescription } from '@downloadx/core';

type StatusData = DownloadDescription & { targetPath: string };

const GREEN = '\x1b[32m';
const RED   = '\x1b[31m';
const RESET = '\x1b[0m';

async function fileExists(p: string): Promise<boolean> {
  try { await stat(p); return true; } catch { return false; }
}

function fmtBytes(n: number | null): string {
  if (n === null) return '?';
  if (n >= 1e9) return `${(n / 1e9).toFixed(2)} GB`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)} MB`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)} KB`;
  return `${n} B`;
}

function fmtMs(ms: number | null): string {
  if (ms === null) return '?';
  const secs = Math.round(ms / 1000);
  if (secs < 60) return `${secs}s`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ${secs % 60}s`;
  return `${Math.floor(mins / 60)}h ${mins % 60}m`;
}

export async function cmdStatus(id: string, json: boolean): Promise<void> {
  await ensureDaemon();
  const desc = await sendRequest<StatusData>({ cmd: 'status', id });

  if (json) {
    console.log(JSON.stringify(desc, null, 2));
    return;
  }

  const pct = desc.percent === null ? '' : ` (${desc.percent}%)`;
  console.log(`${desc.filename} [${desc.state}] ${fmtBytes(desc.downloadedBytes)} / ${fmtBytes(desc.totalBytes)}${pct}`);

  if (desc.state === 'completed' && desc.filename) {
    const fullPath = join(desc.targetPath, desc.filename);
    const exists = await fileExists(fullPath);
    const icon = exists ? `${GREEN}✓${RESET}` : `${RED}✗${RESET}`;
    const note = exists ? '' : '  (deleted)';
    console.log(`File: ${icon} ${fullPath}${note}`);
  }

  if (desc.state === 'downloading') {
    console.log(`speed ${fmtBytes(desc.totalSpeedBps)}/s  ETA ${fmtMs(desc.etaMs)}  chunks ${desc.activeChunks} active / ${desc.totalChunks} total`);
  }
  for (const c of desc.chunks) {
    const chunkPct = c.length > 0 && c.length !== Number.MAX_SAFE_INTEGER
      ? `${Math.round((c.downloadedBytes / c.length) * 100)}%`
      : fmtBytes(c.downloadedBytes);
    const retries = c.retries > 0 ? `  retries ${c.retries}` : '';
    console.log(`  ${c.id}: ${c.status}/${c.quality} ${chunkPct}${retries}`);
  }
  for (const d of desc.recentDiagnostics) {
    console.log(`  ${new Date(d.timestamp).toISOString()} ${d.level} [${d.code}] ${d.message}`);
  }
}
