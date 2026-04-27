import { createServer, type Socket } from 'node:net';
import { mkdir, unlink, writeFile, appendFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';
import { SOCKET_PATH, PID_FILE, LOG_FILE, DOWNLOADS_DIR, IPC_DELIMITER, DATA_DIR } from '../constants.ts';
import type { IpcRequest, IpcResponse, IpcEvent, DownloadEntry } from '../ipc.ts';
import { loadState, getDownloads } from './store.ts';
import {
  addDownload, pauseDownload, resumeDownload, cancelDownload, clearDownload,
  addEventSink, removeEventSink, restoreDownloads, onAutoShutdown,
} from './manager.ts';

async function log(msg: string): Promise<void> {
  const line = `[${new Date().toISOString()}] ${msg}\n`;
  process.stdout.write(line);
  await appendFile(LOG_FILE, line).catch(() => undefined);
}

function send(socket: Socket, msg: IpcResponse | IpcEvent): void {
  socket.write(JSON.stringify(msg) + IPC_DELIMITER);
}

async function handleRequest(socket: Socket, req: IpcRequest): Promise<void> {
  switch (req.cmd) {
    case 'add': {
      const id = randomUUID();
      const targetPath = req.targetPath ?? DOWNLOADS_DIR;
      const entry = await addDownload(id, req.url, targetPath);
      send(socket, { ok: true, data: entry } satisfies IpcResponse<DownloadEntry>);
      break;
    }
    case 'list': {
      send(socket, { ok: true, data: getDownloads() } satisfies IpcResponse<DownloadEntry[]>);
      break;
    }
    case 'pause': {
      await pauseDownload(req.id);
      send(socket, { ok: true, data: null });
      break;
    }
    case 'resume': {
      await resumeDownload(req.id);
      send(socket, { ok: true, data: null });
      break;
    }
    case 'cancel': {
      await cancelDownload(req.id);
      send(socket, { ok: true, data: null });
      break;
    }
    case 'clear': {
      await clearDownload(req.id);
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
    case 'unwatch': {
      send(socket, { ok: true, data: null });
      break;
    }
    case 'shutdown': {
      send(socket, { ok: true, data: null });
      setTimeout(() => process.exit(0), 200);
      break;
    }
    case 'start': {
      await resumeDownload(req.id);
      send(socket, { ok: true, data: null });
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
