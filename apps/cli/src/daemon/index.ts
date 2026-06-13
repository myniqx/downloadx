import { randomUUID } from 'node:crypto';
import { mkdir, unlink, writeFile, appendFile } from 'node:fs/promises';
import { createServer, type Socket } from 'node:net';
import { dirname } from 'node:path';

import { SOCKET_PATH, PID_FILE, LOG_FILE, IPC_DELIMITER, DATA_DIR } from '../constants.ts';
import type { IpcRequest, IpcResponse, IpcEvent, DownloadEntry } from '../ipc.ts';
import { CONFIG_KEYS, LOCAL_KEYS, resolveConfigKey } from './config-keys.ts';
import {
  addDownload,
  pauseDownload,
  resumeDownload,
  restartDownload,
  cancelDownload,
  clearDownload,
  addEventSink,
  removeEventSink,
  restoreDownloads,
  onAutoShutdown,
  describeDownload,
  setDownloadConfig,
  getDownloadConfig,
  initManager,
  setGlobalConfig,
  getGlobalConfig,
} from './manager.ts';
import { loadState, loadConfig, getDownloads, resolveDownload, getAllIds } from './store.ts';

async function log(msg: string): Promise<void> {
  const line = `[${new Date().toISOString()}] ${msg}\n`;
  process.stdout.write(line);
  await appendFile(LOG_FILE, line).catch(() => undefined);
}

function send(socket: Socket, msg: IpcResponse | IpcEvent): void {
  socket.write(JSON.stringify(msg) + IPC_DELIMITER);
}

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
      const entry = await addDownload(id, req.url, req.targetPath ?? null);
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
    case 'restart': {
      const ids = req.id === 'all' ? getAllIds() : [resolveId(req.id)];
      await runForIds(ids, restartDownload);
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
      const isLocal = !!req.id;
      const activeKeys = isLocal ? LOCAL_KEYS : CONFIG_KEYS;

      if (!req.key) {
        const colW = Math.max(...activeKeys.map((d) => d.canonical.length)) + 2;
        const lines = activeKeys
          .map(
            (d) =>
              `  ${d.canonical.padEnd(colW)} ${isLocal ? (d.localDescription ?? d.description) : d.description}`,
          )
          .join('\n');
        send(socket, { ok: true, data: lines });
        break;
      }

      const def = resolveConfigKey(req.key, isLocal);

      if (!req.value) {
        const desc = isLocal ? (def.localDescription ?? def.description) : def.description;
        send(socket, { ok: true, data: `${def.canonical}: ${desc}` });
        break;
      }

      if (isLocal) {
        const entry = resolveDownload(resolveId(req.id!));
        if (!entry) throw new Error(`No download matching '${req.id}'`);
        const parsed = def.parse(req.value);
        const ok = setDownloadConfig(entry.id, def.canonical, parsed);
        if (!ok) throw new Error(`Key '${def.canonical}' is not settable on a download`);
      } else {
        await setGlobalConfig(req.key, req.value, req.override === true);
      }
      send(socket, { ok: true, data: null });
      break;
    }
    case 'get': {
      if (req.id) {
        const entry = resolveDownload(resolveId(req.id));
        if (!entry) throw new Error(`No download matching '${req.id}'`);
        if (!req.key) {
          const all = Object.fromEntries(
            LOCAL_KEYS.map((d) => [d.canonical, getDownloadConfig(entry.id, d.canonical)]),
          );
          send(socket, { ok: true, data: all });
        } else {
          const def = resolveConfigKey(req.key, true);
          send(socket, { ok: true, data: getDownloadConfig(entry.id, def.canonical) });
        }
      } else {
        send(socket, { ok: true, data: getGlobalConfig(req.key) });
      }
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

    socket.on('error', () => {
      /* client disconnected */
    });
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
  process.on('SIGTERM', async () => {
    await cleanup();
    process.exit(0);
  });
  process.on('SIGINT', async () => {
    await cleanup();
    process.exit(0);
  });

  const config = await loadConfig();
  initManager(config);
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
