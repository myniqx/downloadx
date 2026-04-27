import { connect } from 'node:net';
import { spawn } from 'node:child_process';
import { stat } from 'node:fs/promises';
import { SOCKET_PATH, IPC_DELIMITER, DAEMON_STARTUP_TIMEOUT_MS, DAEMON_STARTUP_POLL_MS } from '../constants.ts';
import type { IpcRequest, IpcResponse, IpcEvent } from '../ipc.ts';

async function socketExists(): Promise<boolean> {
  try { await stat(SOCKET_PATH); return true; } catch { return false; }
}

async function waitForDaemon(): Promise<void> {
  const deadline = Date.now() + DAEMON_STARTUP_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (await socketExists()) return;
    await new Promise((r) => setTimeout(r, DAEMON_STARTUP_POLL_MS));
  }
  throw new Error('Daemon did not start in time');
}

export async function ensureDaemon(): Promise<void> {
  if (await socketExists()) return;

  const child = spawn(process.execPath, [process.argv[1]!, '--daemon'], {
    detached: true,
    stdio: ['ignore', 'ignore', 'ignore'],
  });
  child.unref();
  await waitForDaemon();
}

export function sendRequest<T = unknown>(req: IpcRequest): Promise<T> {
  return new Promise((resolve, reject) => {
    const socket = connect(SOCKET_PATH);
    let buffer = '';

    socket.on('connect', () => {
      socket.write(JSON.stringify(req) + IPC_DELIMITER);
    });

    socket.on('data', (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split(IPC_DELIMITER);
      buffer = lines.pop() ?? '';

      for (const line of lines) {
        if (!line.trim()) continue;
        const msg = JSON.parse(line) as IpcResponse<T>;
        socket.destroy();
        if (msg.ok) resolve(msg.data);
        else reject(new Error(msg.error));
        return;
      }
    });

    socket.on('error', reject);
  });
}

export function openWatchStream(
  onEvent: (event: IpcEvent) => void,
  onError: (err: Error) => void,
): () => void {
  const socket = connect(SOCKET_PATH);
  let buffer = '';

  socket.on('connect', () => {
    socket.write(JSON.stringify({ cmd: 'watch' } satisfies IpcRequest) + IPC_DELIMITER);
  });

  socket.on('data', (chunk) => {
    buffer += chunk.toString();
    const lines = buffer.split(IPC_DELIMITER);
    buffer = lines.pop() ?? '';

    for (const line of lines) {
      if (!line.trim()) continue;
      const msg = JSON.parse(line) as IpcResponse | IpcEvent;
      if ('event' in msg) onEvent(msg as IpcEvent);
    }
  });

  socket.on('error', onError);

  return () => socket.destroy();
}
