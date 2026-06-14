import type { DownloadDescription } from '@downloadx/core';
import type {
  IpcEvent,
  ProgressEvent,
  ChunkProgressEvent,
  ChunkLifecycleEvent,
  StateChangeEvent,
  CompletedEvent,
} from '../../ipc.ts';
import { ensureDaemon, sendRequest, openWatchStream } from '../client.ts';

const RESET = '\x1b[0m';
const BOLD = '\x1b[1m';
const CLEAR_SCREEN = '\x1b[2J\x1b[H';
const HIDE_CURSOR = '\x1b[?25l';
const SHOW_CURSOR = '\x1b[?25h';

// 8 distinct colors for chunks (cycling)
const CHUNK_COLORS = [
  '\x1b[36m', // cyan
  '\x1b[33m', // yellow
  '\x1b[35m', // magenta
  '\x1b[32m', // green
  '\x1b[34m', // blue
  '\x1b[91m', // bright red
  '\x1b[96m', // bright cyan
  '\x1b[93m', // bright yellow
];

const STATUS_COLOR: Record<string, string> = {
  queued: '\x1b[90m',
  downloading: '\x1b[36m',
  paused: '\x1b[33m',
  completed: '\x1b[32m',
  failed: '\x1b[31m',
  cancelled: '\x1b[90m',
};

interface ChunkState {
  chunkId: string;
  offset: number;
  length: number;
  downloadedBytes: number;
  speed: number;
  quality: 'good' | 'poor' | 'stalled';
  colorIdx: number;
}

interface DownloadState {
  entry: DownloadDescription;
  totalBytes: number | null;
  downloadedBytes: number;
  totalSpeed: number;
  percent: number | null;
  chunks: Map<string, ChunkState>;
  chunkColorCounter: number;
}

const state = new Map<string, DownloadState>();
let termWidth = process.stdout.columns ?? 80;

process.stdout.on('resize', () => {
  termWidth = process.stdout.columns ?? 80;
  render();
});

function fmtSpeed(bps: number): string {
  if (bps >= 1e9) return `${(bps / 1e9).toFixed(1)} GB/s`;
  if (bps >= 1e6) return `${(bps / 1e6).toFixed(1)} MB/s`;
  if (bps >= 1e3) return `${(bps / 1e3).toFixed(1)} KB/s`;
  return `${bps.toFixed(0)} B/s`;
}

function fmtBytes(n: number | null): string {
  if (n === null) return '?';
  if (n >= 1e9) return `${(n / 1e9).toFixed(2)} GB`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)} MB`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)} KB`;
  return `${n} B`;
}

function fmtEta(downloaded: number, total: number | null, speed: number): string {
  if (!total || speed === 0) return '?';
  const remaining = total - downloaded;
  const secs = Math.round(remaining / speed);
  const m = Math.floor(secs / 60);
  const s = secs % 60;
  return m > 0 ? `${m}m ${s}s` : `${s}s`;
}

function renderBar(ds: DownloadState, barWidth: number): string {
  const total = ds.totalBytes;
  if (!total || barWidth <= 0) return '·'.repeat(barWidth);

  const cells = new Array<string>(barWidth).fill('·');

  // Mark completed chunks as solid block using their color
  for (const chunk of ds.chunks.values()) {
    const color = CHUNK_COLORS[chunk.colorIdx % CHUNK_COLORS.length]!;
    const startCell = Math.floor((chunk.offset / total) * barWidth);
    const endCell = Math.floor(((chunk.offset + chunk.downloadedBytes) / total) * barWidth);
    const fullEnd = Math.floor(((chunk.offset + chunk.length) / total) * barWidth);

    // Downloaded portion — solid block
    for (let i = startCell; i <= Math.min(endCell, barWidth - 1); i++) {
      cells[i] = `${color}█${RESET}`;
    }
    // Remaining portion of this chunk — faint shade
    for (let i = endCell + 1; i <= Math.min(fullEnd, barWidth - 1); i++) {
      cells[i] = `${color}░${RESET}`;
    }
  }

  return cells.join('');
}

function renderLegend(ds: DownloadState): string {
  const parts: string[] = [];
  let idx = 0;
  for (const chunk of ds.chunks.values()) {
    const color = CHUNK_COLORS[chunk.colorIdx % CHUNK_COLORS.length]!;
    const speed = chunk.speed > 0 ? ` ${fmtSpeed(chunk.speed)}` : '';
    const qual = chunk.quality !== 'good' ? ` (${chunk.quality})` : '';
    parts.push(`${color}█${RESET} c${idx + 1}${speed}${qual}`);
    idx++;
  }
  return parts.join('  ');
}

function render(): void {
  const lines: string[] = [];
  lines.push(CLEAR_SCREEN);
  lines.push(`${BOLD}downloadx watch${RESET}  ${new Date().toLocaleTimeString()}`);
  lines.push('');

  if (state.size === 0) {
    lines.push('\x1b[90mNo active downloads.\x1b[0m');
  }

  for (const [, ds] of state) {
    const { entry } = ds;
    const name = entry.filename ?? entry.url.split('/').pop() ?? entry.url;
    const statusColor = STATUS_COLOR[entry.state] ?? '';
    const pct = ds.percent !== null ? `${ds.percent.toFixed(1)}%` : '?%';
    const speed = ds.totalSpeed > 0 ? `↓ ${fmtSpeed(ds.totalSpeed)}` : '';
    const eta = fmtEta(ds.downloadedBytes, ds.totalBytes, ds.totalSpeed);
    const size = `${fmtBytes(ds.downloadedBytes)} / ${fmtBytes(ds.totalBytes)}`;

    const header = `${statusColor}${entry.id.slice(0, 8)}${RESET}  ${BOLD}${name}${RESET}  [${entry.state}]`;
    const meta = `${pct.padStart(6)}  ${size}  ${speed}  ETA ${eta}`;
    lines.push(header);
    lines.push(meta);

    const barWidth = Math.max(20, termWidth - 4);
    lines.push(`  [${renderBar(ds, barWidth)}]`);

    const legend = renderLegend(ds);
    if (legend) lines.push(`  ${legend}`);
    lines.push('');
  }

  lines.push('\x1b[90mPress Ctrl+C to exit watch mode (downloads continue in background)\x1b[0m');
  process.stdout.write(lines.join('\n'));
}

export async function cmdWatch(simple: boolean, json = false): Promise<void> {
  await ensureDaemon();

  if (json) {
    // NDJSON stream: one self-contained event per line. Stable interface for
    // scripts and LLM/agent consumers — no ANSI, no cursor control.
    const close = openWatchStream(
      (event) => {
        console.log(JSON.stringify(event));
      },
      (err) => {
        console.error(JSON.stringify({ event: 'streamError', message: err.message }));
        process.exit(1);
      },
    );
    process.on('SIGINT', () => {
      close();
      process.exit(0);
    });
    return;
  }

  const downloads = await sendRequest<DownloadDescription[]>({ cmd: 'list' });
  for (const entry of downloads) {
    state.set(entry.id, {
      entry,
      totalBytes: entry.totalBytes,
      downloadedBytes: entry.downloadedBytes,
      totalSpeed: entry.totalSpeedBps,
      percent: entry.percent,
      chunks: new Map(),
      chunkColorCounter: 0,
    });
  }

  if (simple) {
    const close = openWatchStream(
      (event) => {
        if (event.event === 'progress') {
          const e = event as ProgressEvent;
          console.log(
            `[${e.downloadId.slice(0, 8)}] ${e.percent?.toFixed(1) ?? '?'}% @ ${fmtSpeed(e.totalSpeed)}`,
          );
        } else if (event.event === 'completed') {
          const e = event as CompletedEvent;
          console.log(
            `[${e.downloadId.slice(0, 8)}] Completed: ${e.filename} (${fmtBytes(e.totalBytes)})`,
          );
        } else if (event.event === 'stateChange') {
          const e = event as StateChangeEvent;
          console.log(`[${e.downloadId.slice(0, 8)}] ${e.previous} → ${e.current}`);
        }
      },
      (err) => {
        console.error(err.message);
        process.exit(1);
      },
    );
    process.on('SIGINT', () => {
      close();
      process.exit(0);
    });
    return;
  }

  process.stdout.write(HIDE_CURSOR);

  const onExit = () => {
    process.stdout.write(SHOW_CURSOR);
    process.exit(0);
  };
  process.on('SIGINT', onExit);

  render();
  const renderInterval = setInterval(render, 200);

  const close = openWatchStream(
    (event: IpcEvent) => {
      switch (event.event) {
        case 'progress': {
          const e = event as ProgressEvent;
          const ds = state.get(e.downloadId);
          if (ds) {
            ds.downloadedBytes = e.downloadedBytes;
            ds.totalBytes = e.totalBytes;
            ds.totalSpeed = e.totalSpeed;
            ds.percent = e.percent;
          }
          break;
        }
        case 'chunkProgress': {
          const e = event as ChunkProgressEvent;
          const ds = state.get(e.downloadId);
          if (ds) {
            const existing = ds.chunks.get(e.chunkId);
            ds.chunks.set(e.chunkId, {
              chunkId: e.chunkId,
              offset: e.offset,
              length: e.length,
              downloadedBytes: e.downloadedBytes,
              speed: e.windowedSpeed,
              quality: e.quality,
              colorIdx: existing?.colorIdx ?? ds.chunkColorCounter++,
            });
          }
          break;
        }
        case 'chunkLifecycle': {
          const e = event as ChunkLifecycleEvent;
          if (e.status === 'completed' || e.status === 'reassigned') {
            const ds = state.get(e.downloadId);
            if (ds) ds.chunks.delete(e.chunkId);
          }
          break;
        }
        case 'stateChange': {
          const e = event as StateChangeEvent;
          const ds = state.get(e.downloadId);
          if (ds) ds.entry.state = e.current;
          break;
        }
        case 'completed': {
          const e = event as CompletedEvent;
          const ds = state.get(e.downloadId);
          if (ds) {
            ds.entry.state = 'completed';
            ds.entry.filename = e.filename;
            ds.totalBytes = e.totalBytes;
            ds.downloadedBytes = e.totalBytes;
            ds.percent = 100;
          }
          break;
        }
        case 'error': {
          break;
        }
      }
    },
    (err) => {
      clearInterval(renderInterval);
      process.stdout.write(SHOW_CURSOR);
      console.error(err.message);
      process.exit(1);
    },
  );

  process.on('SIGINT', () => {
    clearInterval(renderInterval);
    close();
    onExit();
  });
}
