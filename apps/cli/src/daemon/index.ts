import { createServer, type Socket } from 'node:net';
import { mkdir, unlink, writeFile, appendFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';
import { SOCKET_PATH, PID_FILE, LOG_FILE, IPC_DELIMITER, DATA_DIR } from '../constants.ts';
import type { IpcRequest, IpcResponse, IpcEvent, DownloadEntry } from '../ipc.ts';
import { loadState, loadConfig, getDownloads, resolveDownload, getAllIds, getConfigKey, setConfigKey, saveConfig, upsertDownload, parseSpeed } from './store.ts';
import {
  addDownload, pauseDownload, resumeDownload, cancelDownload, clearDownload,
  addEventSink, removeEventSink, restoreDownloads, onAutoShutdown, describeDownload, applyConfig,
} from './manager.ts';

async function log(msg: string): Promise<void> {
  const line = `[${new Date().toISOString()}] ${msg}\n`;
  process.stdout.write(line);
  await appendFile(LOG_FILE, line).catch(() => undefined);
}

function send(socket: Socket, msg: IpcResponse | IpcEvent): void {
  socket.write(JSON.stringify(msg) + IPC_DELIMITER);
}

const CONFIG_KEY_DESCRIPTIONS: Record<string, string> = {
  maxParallel: 'Max concurrent downloads (number, e.g. 3)',
  speedLimit:  'Speed limit, 0 = unlimited. Accepts: 500kb, 3mb, 1.5gb or raw bytes',
  targetPath:  'Directory for completed files (e.g. /home/user/Downloads)',
  cachePath:   'Directory for in-progress .part files (e.g. /tmp/downloadx-cache)',
};

const PER_DOWNLOAD_KEY_OVERRIDES: Record<string, string> = {
  targetPath: 'Target directory for this download when it completes',
};

const PER_DOWNLOAD_KEYS = Object.fromEntries(
  ['speedLimit', 'targetPath'].map((k) => [k, PER_DOWNLOAD_KEY_OVERRIDES[k] ?? CONFIG_KEY_DESCRIPTIONS[k]!])
);

function resolveId(raw: string): string {
  if (raw === 'all') return raw;
  const entry = resolveDownload(raw);
  if (!entry) throw new Error(`No download matching '${raw}'`);
  return entry.id;
}

async function runForIds(ids: string[], fn: (id: string) => Promise<void>): Promise<void> {
  await Promise.all(ids.map(fn));
}

async function handleRequest(socket: Socket, req: IpcRequest): Promise<void> {
  switch (req.cmd) {
    case 'add': {
      const id = randomUUID();
      const entry = await addDownload(id, req.url, req.targetPath ?? null, req.speedLimit ?? null);
      send(socket, { ok: true, data: entry } satisfies IpcResponse<DownloadEntry>);
      break;
    }
    case 'list': {
      send(socket, { ok: true, data: getDownloads() } satisfies IpcResponse<DownloadEntry[]>);
      break;
    }
    case 'status': {
      const resolved = resolveId(req.id);
      const entry = resolveDownload(resolved);
      const desc = describeDownload(resolved);
      send(socket, { ok: true, data: { ...desc, targetPath: entry?.targetPath ?? '' } });
      break;
    }
    case 'pause': {
      const ids = req.id === 'all' ? getAllIds() : [resolveId(req.id)];
      await runForIds(ids, pauseDownload);
      send(socket, { ok: true, data: null });
      break;
    }
    case 'resume': {
      const ids = req.id === 'all' ? getAllIds() : [resolveId(req.id)];
      await runForIds(ids, resumeDownload);
      send(socket, { ok: true, data: null });
      break;
    }
    case 'cancel': {
      const ids = req.id === 'all' ? getAllIds() : [resolveId(req.id)];
      await runForIds(ids, cancelDownload);
      send(socket, { ok: true, data: null });
      break;
    }
    case 'clear': {
      const ids = req.id === 'all' ? getAllIds() : [resolveId(req.id)];
      await runForIds(ids, clearDownload);
      send(socket, { ok: true, data: null });
      break;
    }
    case 'watch': {
      const sink = (event: IpcEvent) => send(socket, event);
      addEventSink(sink);
      socket.once('close', () => removeEventSink(sink));
      send(socket, { ok: true, data: null });
      break;
    }
    case 'set': {
      const activeKeys = req.id ? PER_DOWNLOAD_KEYS : CONFIG_KEY_DESCRIPTIONS;
      const key = req.key?.toLowerCase();

      if (!key) {
        const lines = Object.entries(activeKeys)
          .map(([k, desc]) => `  ${k.padEnd(14)} ${desc}`)
          .join('\n');
        send(socket, { ok: true, data: lines });
        break;
      }

      if (!req.value) {
        const desc = activeKeys[key];
        if (!desc) throw new Error(`Unknown key '${key}'`);
        send(socket, { ok: true, data: `${key}: ${desc}` });
        break;
      }

      if (req.id) {
        const entry = resolveDownload(resolveId(req.id));
        if (!entry) throw new Error(`No download matching '${req.id}'`);
        const canonicalKey = Object.keys(PER_DOWNLOAD_KEYS).find((k) => k.toLowerCase() === key);
        if (canonicalKey === 'speedLimit') {
          const n = req.value === '0' ? 0 : parseSpeed(req.value);
          await upsertDownload({ ...entry, speedLimit: n });
        } else if (canonicalKey === 'targetPath') {
          if (entry.status === 'completed') throw new Error(`Cannot change targetPath of a completed download`);
          await upsertDownload({ ...entry, targetPath: req.value });
        } else if (key === 'cachepath') {
          throw new Error(`cachePath cannot be changed after a download is created`);
        } else {
          throw new Error(`Unknown per-download key '${key}'. Valid: ${Object.keys(PER_DOWNLOAD_KEYS).join(', ')}`);
        }
      } else {
        setConfigKey(key, req.value);
        await saveConfig();
        applyConfig();
      }
      send(socket, { ok: true, data: null });
      break;
    }
    case 'get': {
      send(socket, { ok: true, data: getConfigKey(req.key) });
      break;
    }
    case 'shutdown': {
      send(socket, { ok: true, data: null });
      setTimeout(() => process.exit(0), 200);
      break;
    }
    default: {
      const cmd = (req as { cmd: string }).cmd;
      send(socket, { ok: false, error: `Unknown command: ${cmd}` });
      break;
    }
  }
}

async function startServer(): Promise<void> {
  await mkdir(DATA_DIR, { recursive: true });
  await unlink(SOCKET_PATH).catch(() => undefined);

  const server = createServer((socket) => {
    let buffer = '';

    socket.on('data', (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split(IPC_DELIMITER);
      buffer = lines.pop() ?? '';

      for (const line of lines) {
        if (!line.trim()) continue;
        let req: IpcRequest;
        try {
          req = JSON.parse(line) as IpcRequest;
        } catch {
          send(socket, { ok: false, error: 'Invalid JSON' });
          continue;
        }
        handleRequest(socket, req).catch((err: unknown) => {
          const msg = err instanceof Error ? err.message : String(err);
          send(socket, { ok: false, error: msg });
        });
      }
    });

    socket.on('error', () => { /* client disconnected */ });
  });

  server.listen(SOCKET_PATH, async () => {
    await log(`Daemon started. PID=${process.pid} socket=${SOCKET_PATH}`);
  });

  server.on('error', async (err) => {
    await log(`Server error: ${err.message}`);
    process.exit(1);
  });
}

async function writePid(): Promise<void> {
  await mkdir(dirname(PID_FILE), { recursive: true });
  await writeFile(PID_FILE, String(process.pid), 'utf8');
}

async function cleanup(): Promise<void> {
  await unlink(SOCKET_PATH).catch(() => undefined);
  await unlink(PID_FILE).catch(() => undefined);
}

export async function runDaemon(): Promise<void> {
  process.on('SIGTERM', async () => { await cleanup(); process.exit(0); });
  process.on('SIGINT',  async () => { await cleanup(); process.exit(0); });

  await loadConfig();
  await loadState();
  await writePid();
  await startServer();
  await restoreDownloads(getDownloads());

  onAutoShutdown(async () => {
    await log('All downloads finished, shutting down.');
    await cleanup();
    process.exit(0);
  });

  await log('Daemon ready.');
}
