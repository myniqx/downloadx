import { ensureDaemon, sendRequest } from '../client.ts';
import type { DownloadEntry } from '../../ipc.ts';

const STATUS_COLOR: Record<string, string> = {
  queued:      '\x1b[90m',
  downloading: '\x1b[36m',
  paused:      '\x1b[33m',
  completed:   '\x1b[32m',
  failed:      '\x1b[31m',
  cancelled:   '\x1b[90m',
};
const RESET = '\x1b[0m';

function fmtBytes(n: number | null): string {
  if (n === null) return '?';
  if (n >= 1e9) return `${(n / 1e9).toFixed(1)} GB`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)} MB`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)} KB`;
  return `${n} B`;
}

export async function cmdList(): Promise<void> {
  await ensureDaemon();
  const downloads = await sendRequest<DownloadEntry[]>({ cmd: 'list' });

  if (downloads.length === 0) {
    console.log('No downloads.');
    return;
  }

  for (const d of downloads) {
    const color = STATUS_COLOR[d.status] ?? '';
    const pct = d.totalBytes ? `${((d.downloadedBytes / d.totalBytes) * 100).toFixed(1)}%` : '?%';
    const size = `${fmtBytes(d.downloadedBytes)} / ${fmtBytes(d.totalBytes)}`;
    const name = d.filename ?? d.url;
    console.log(`${color}[${d.status.toUpperCase().padEnd(11)}]${RESET} ${d.id.slice(0, 8)}  ${pct.padStart(6)}  ${size.padStart(18)}  ${name}`);
  }
}
