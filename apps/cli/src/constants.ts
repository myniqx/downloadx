import { homedir } from 'node:os';
import { join } from 'node:path';

export const DATA_DIR =
  process.env['WORKING_DIR'] ??
  join(process.env['XDG_DATA_HOME'] ?? join(homedir(), '.local', 'share'), 'downloadx');

export const SOCKET_PATH = join(DATA_DIR, 'daemon.sock');
export const PID_FILE = join(DATA_DIR, 'daemon.pid');
export const LOG_FILE = join(DATA_DIR, 'daemon.log');
export const CONFIG_FILE = join(DATA_DIR, 'config.json');
export const DOWNLOADS_DIR = join(DATA_DIR, 'downloads');
export const CACHE_DIR = join(DATA_DIR, 'cache');

export const IPC_DELIMITER = '\n';
export const DAEMON_STARTUP_TIMEOUT_MS = 5_000;
export const DAEMON_STARTUP_POLL_MS = 100;
export const IPC_REQUEST_TIMEOUT_MS = 10_000;
