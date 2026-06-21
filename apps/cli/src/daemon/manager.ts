import {
  mkdir,
  rename,
  unlink,
  writeFile,
  readFile,
  stat,
  open,
  appendFile,
  readdir,
} from 'node:fs/promises';
import { join } from 'node:path';

import {
  createDownloadX,
  type Download,
  type DownloadDescription,
  type DownloadOptions,
  type DownloadProgressPayload,
  type ChunkProgressPayload,
  type ChunkLifecyclePayload,
  type DownloadStatePayload,
  type DownloadCompletedPayload,
  type DownloadErrorPayload,
  type DiagnosticPayload,
} from '@downloadx/core';

import type { DaemonConfig, IpcEvent } from '../ipc.ts';
import { CONFIG_KEY_MAP, resolveConfigKey } from './config-keys.ts';
import { saveConfig } from './config.ts';

type EventSink = (event: IpcEvent) => void;
type DownloadXInstance = Awaited<ReturnType<typeof createDownloadX>>;

const sinks = new Set<EventSink>();

export function addEventSink(sink: EventSink): void {
  sinks.add(sink);
}

export function removeEventSink(sink: EventSink): void {
  sinks.delete(sink);
}

function emit(event: IpcEvent): void {
  for (const sink of sinks) sink(event);
}

// Open for random-access writing without ever truncating: 'r+' needs the file
// to exist, 'wx' creates it atomically (and fails instead of truncating when a
// concurrent chunk won the creation race — fall back to 'r+').
async function openRw(p: string) {
  try {
    return await open(p, 'r+');
  } catch {
    try {
      return await open(p, 'wx');
    } catch {
      return open(p, 'r+');
    }
  }
}

function makeIo() {
  return {
    fetch: (globalThis as unknown as { fetch: typeof fetch }).fetch,
    mkdir: async (p: string) => {
      await mkdir(p, { recursive: true });
    },
    exists: async (p: string) => {
      try {
        await stat(p);
        return true;
      } catch {
        return false;
      }
    },
    readFile: async (p: string) => new Uint8Array(await readFile(p)),
    writeFile: async (p: string, buf: Uint8Array) => {
      await writeFile(p, buf);
    },
    writeChunk: async (p: string, offset: number, buf: Uint8Array) => {
      const fh = await openRw(p);
      try {
        await fh.write(buf, 0, buf.length, offset);
      } finally {
        await fh.close();
      }
    },
    rename: async (from: string, to: string) => {
      await rename(from, to);
    },
    unlink: async (p: string) => {
      await unlink(p).catch(() => undefined);
    },
    joinPath: (...segs: string[]) => join(...segs),
    listDir: async (p: string): Promise<string[]> => {
      try {
        return await readdir(p);
      } catch {
        return [];
      }
    },
    truncate: async (p: string, size: number) => {
      const fh = await openRw(p);
      try {
        await fh.truncate(size);
      } finally {
        await fh.close();
      }
    },
    appendFile: async (p: string, buf: Uint8Array) => {
      await appendFile(p, buf);
    },
    fileSize: async (p: string) => (await stat(p)).size,
  };
}

let manager: DownloadXInstance | null = null;

export async function initManager(config: DaemonConfig): Promise<void> {
  manager = await createDownloadX({
    io: makeIo(),
    targetPath: config.targetPath,
    cachePath: config.cachePath,
    maxParallel: config.maxParallel,
    targetChunkCount: config.targetChunkCount,
    minChunkSize: config.minChunkSize,
    journal: config.journal,
    ...(config.speedLimit > 0 ? { speedLimit: config.speedLimit } : {}),
  });
  // Restored downloads need their event sinks wired up too so list/status
  // updates flow through the IPC stream after a daemon restart.
  for (const dl of manager.list()) attachListeners(dl);
}

export function getManager(): DownloadXInstance {
  if (!manager) throw new Error('Manager not initialized');
  return manager;
}

export async function setGlobalConfig(
  key: string,
  rawValue: string,
  override: boolean,
): Promise<void> {
  const def = resolveConfigKey(key, false);
  def.setGlobalValue(getManager(), rawValue, override);
  await saveConfig(getGlobalConfig() as DaemonConfig);
}

export function getGlobalConfig(key?: string): DaemonConfig | unknown {
  const manager = getManager()
  if (!key) {
    return Object.fromEntries(
      [...CONFIG_KEY_MAP.values()].map((def) => [def.canonical, def.getValue(manager)]),
    ) as unknown as DaemonConfig;
  }
  const def = resolveConfigKey(key, false);
  return def.getValue(manager);
}

export function getDownloads(): Download[] {
  return getManager().list()
}

export function getAllIds(): string[] {
  return getManager()
    .list()
    .map((d) => d.id);
}

/** Resolves "#1", "1" (1-based index), a prefix or a full id to a download. */
export function resolveDownload(idOrIndex: string): Download | undefined {
  const entries = getDownloads();
  const n = /^#?(\d+)$/.exec(idOrIndex);
  if (n) return entries[Number(n[1]) - 1];
  return entries.find((d) => d.id === idOrIndex || d.id.startsWith(idOrIndex));
}

let activeCount = 0;
let shutdownCallback: (() => void) | null = null;

export function onAutoShutdown(cb: () => void): void {
  shutdownCallback = cb;
}

function onDownloadFinished(): void {
  activeCount = Math.max(0, activeCount - 1);
  if (activeCount === 0 && shutdownCallback) shutdownCallback();
}

function attachListeners(dl: Download): void {
  dl.emitter.on('progress', (p: DownloadProgressPayload) => {
    emit({ ...p, event: 'progress' });
  });

  dl.emitter.on('chunkProgress', (p: ChunkProgressPayload) => {
    emit({ ...p, event: 'chunkProgress' });
  });

  dl.emitter.on('chunkLifecycle', (p: ChunkLifecyclePayload) => {
    emit({ ...p, event: 'chunkLifecycle' });
  });

  dl.emitter.on('stateChange', (p: DownloadStatePayload) => {
    emit({ ...p, event: 'stateChange' });
  });

  dl.emitter.on('completed', (p: DownloadCompletedPayload) => {
    emit({ ...p, event: 'completed' });
    onDownloadFinished();
  });

  dl.emitter.on('error', (p: DownloadErrorPayload) => {
    if (p.fatal) onDownloadFinished();
    const { error, ...rest } = p;
    emit({ ...rest, event: 'error', message: error.message });
  });

  dl.emitter.on('diagnostic', (p: DiagnosticPayload) => {
    emit({ ...p, event: 'diagnostic' });
  });
}

/*
export function setDownloadConfig(id: string, key: string, rawValue: string): void {
  const dl = getManager().get(id);
  if (!dl) throw new Error(`Download ${id} not active`);
  const def = resolveConfigKey(key, true);
  def.setLocalValue(dl, def.parse(rawValue));
}

export function getDownloadConfig(id: string, key: string): unknown {
  const dl = getManager().get(id);
  if (!dl) throw new Error(`Download ${id} not active`);
  const def = resolveConfigKey(key, true);
  return def.getValue(dl);
}
*/
export async function addDownload(
  url: string,
  options: DownloadOptions,
): Promise<DownloadDescription> {
  const mgr = getManager();
  const dl = await mgr.addUrl(url, options);
  attachListeners(dl);
  activeCount++;
  void dl.start();
  return dl.describe();
}

export async function pauseDownload(id: string): Promise<void> {
  const dl = getManager().get(id);
  if (!dl) throw new Error(`Download ${id} not active`);
  dl.pause();
}

export async function resumeDownload(id: string): Promise<void> {
  const dl = getManager().get(id);
  if (!dl) throw new Error(`Download ${id} not found`);
  activeCount++;
  void dl.start();
}

export async function restartDownload(id: string): Promise<void> {
  const mgr = getManager();
  const existing = mgr.get(id);
  if (!existing) throw new Error(`Download ${id} not found`);
  const url = existing.url;
  await mgr.clear(id);
  const dl = await mgr.addUrl(url, { id });
  attachListeners(dl);
  activeCount++;
  void dl.start();
}

export async function cancelDownload(id: string): Promise<void> {
  const dl = getManager().get(id);
  if (dl) dl.cancel();
}

export async function clearDownload(id: string): Promise<void> {
  await getManager().clear(id);
}
