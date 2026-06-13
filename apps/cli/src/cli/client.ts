import { connect } from 'node:net';
import { spawn } from 'node:child_process';
import { unlink } from 'node:fs/promises';
import { SOCKET_PATH, IPC_DELIMITER, DAEMON_STARTUP_TIMEOUT_MS, DAEMON_STARTUP_POLL_MS, IPC_REQUEST_TIMEOUT_MS } from '../constants.ts';
import type { IpcRequest, IpcResponse, IpcEvent } from '../ipc.ts';

function canConnect(): Promise<boolean> {
  return new Promise((resolve) => {
    const s = connect(SOCKET_PATH);
    s.once('connect', () => { s.destroy(); resolve(true); });
    s.once('error', () => resolve(false));
  });
}

async function waitForDaemon(): Promise<void> {
  const deadline = Date.now() + DAEMON_STARTUP_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (await canConnect()) return;
    await new Promise((r) => setTimeout(r, DAEMON_STARTUP_POLL_MS));
  }
  throw new Error(`Daemon did not start within ${DAEMON_STARTUP_TIMEOUT_MS / 1000}s. Check logs: ~/.local/share/downloadx/daemon.log`);
}

export async function ensureDaemon(): Promise<void> {
  if (await canConnect()) return;
  await unlink(SOCKET_PATH).catch(() => undefined);

  // process.execPath = real binary path in compiled mode, bun path in script mode
  const isBinary = !process.argv[1]?.endsWith('.ts') && !process.argv[1]?.endsWith('.js');
  const spawnArgs = isBinary ? ['--daemon'] : [process.argv[1]!, '--daemon'];
  const child = spawn(process.execPath, spawnArgs, {
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

    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error('Daemon did not respond in time'));
    }, IPC_REQUEST_TIMEOUT_MS);

    const done = (fn: () => void) => { clearTimeout(timer); socket.destroy(); fn(); };

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
        if (msg.ok) done(() => resolve(msg.data));
        else done(() => reject(new Error(msg.error)));
        return;
      }
    });

    socket.on('error', (err) => done(() => reject(err)));
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
