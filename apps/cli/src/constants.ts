import { homedir } from 'node:os';
import { join } from 'node:path';

const XDG_DATA_HOME = process.env['XDG_DATA_HOME'] ?? join(homedir(), '.local', 'share');
export const DATA_DIR = join(XDG_DATA_HOME, 'downloadx');

export const SOCKET_PATH = join(DATA_DIR, 'daemon.sock');
export const PID_FILE = join(DATA_DIR, 'daemon.pid');
export const LOG_FILE = join(DATA_DIR, 'daemon.log');
export const STATE_FILE = join(DATA_DIR, 'state.json');
export const DOWNLOADS_DIR = join(DATA_DIR, 'downloads');

export const IPC_DELIMITER = '\n';
export const DAEMON_STARTUP_TIMEOUT_MS = 5_000;
export const DAEMON_STARTUP_POLL_MS = 100;
