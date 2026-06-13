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
  type DownloadProgressPayload,
  type ChunkProgressPayload,
  type ChunkLifecyclePayload,
  type DownloadStatePayload,
  type DownloadCompletedPayload,
  type DownloadErrorPayload,
  type DiagnosticPayload,
} from '@downloadx/core';

import type { DaemonConfig, DownloadEntry, IpcEvent } from '../ipc.ts';
import { resolveConfigKey } from './config-keys.ts';
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

function getManager(): DownloadXInstance {
  if (!manager) throw new Error('Manager not initialized');
  return manager;
}

type GlobalConfigKey =
  | 'maxParallel'
  | 'speedLimit'
  | 'targetPath'
  | 'cachePath'
  | 'targetChunkCount'
  | 'minChunkSize'
  | 'journal';

export async function setGlobalConfig(
  key: string,
  rawValue: string,
  override: boolean,
): Promise<void> {
  const def = resolveConfigKey(key, false);
  const parsed = def.parse(rawValue);
  const canonical = def.canonical as GlobalConfigKey;
  const mgr = getManager();

  if (canonical === 'maxParallel') mgr.setMaxParallel(parsed as number);
  else if (canonical === 'speedLimit') mgr.setSpeedLimit(parsed as number);
  else if (canonical === 'targetPath') mgr.setTargetPath(parsed as string);
  else if (canonical === 'cachePath') mgr.setCachePath(parsed as string);
  else if (canonical === 'targetChunkCount') mgr.setTargetChunkCount(parsed as number, override);
  else if (canonical === 'minChunkSize') mgr.setMinChunkSize(parsed as number, override);
  else if (canonical === 'journal') mgr.setJournal(parsed as boolean, override);

  const cfg = getGlobalConfig() as DaemonConfig;
  await saveConfig(cfg);
}

export function getGlobalConfig(key?: string): DaemonConfig | unknown {
  const mgr = getManager();
  const cfg = mgr.getConfig();
  const snapshot: DaemonConfig = {
    maxParallel: cfg.maxParallel,
    speedLimit: cfg.speedLimit,
    targetPath: cfg.targetPath,
    cachePath: cfg.cachePath,
    targetChunkCount: cfg.targetChunkCount,
    minChunkSize: cfg.minChunkSize,
    journal: cfg.journal,
  };
  if (!key) return snapshot;
  const def = resolveConfigKey(key, false);
  return snapshot[def.canonical as GlobalConfigKey];
}

function toEntry(dl: Download): DownloadEntry {
  const meta = dl.meta;
  const total = dl.totalBytes;
  return {
    id: dl.id,
    url: dl.url,
    filename: meta.filename,
    targetPath: meta.targetPath,
    status: dl.state,
    addedAt: meta.addedAt,
    completedAt: meta.completedAt,
    totalBytes: total,
    downloadedBytes: dl.downloadedBytes,
    errorMessage: meta.errorMessage,
  };
}

export function getDownload(id: string): DownloadEntry | undefined {
  const dl = getManager().get(id);
  return dl ? toEntry(dl) : undefined;
}

export function getDownloads(): DownloadEntry[] {
  return getManager()
    .list()
    .map(toEntry)
    .sort((a, b) => a.addedAt - b.addedAt);
}

export function getAllIds(): string[] {
  return getManager()
    .list()
    .sort((a, b) => a.meta.addedAt - b.meta.addedAt)
    .map((d) => d.id);
}

/** Resolves "#1", "1" (1-based index), a prefix or a full id to a stored entry. */
export function resolveDownload(idOrIndex: string): DownloadEntry | undefined {
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

export function setDownloadConfig(id: string, key: string, value: unknown): boolean {
  const dl = getManager().get(id);
  if (!dl) throw new Error(`Download ${id} not active`);
  return dl.set(key, value);
}

export function getDownloadConfig<T>(id: string, key: string): T | undefined {
  const dl = getManager().get(id);
  if (!dl) throw new Error(`Download ${id} not active`);
  return dl.get<T>(key);
}

export function describeDownload(id: string): DownloadDescription {
  const dl = getManager().get(id);
  if (!dl) throw new Error(`Download ${id} not found`);
  return dl.describe();
}

export async function addDownload(
  url: string,
  targetPath: string | null,
): Promise<DownloadEntry> {
  const mgr = getManager();
  const dl = await mgr.addUrl(url);
  if (targetPath !== null) dl.setTargetPath(targetPath);
  attachListeners(dl);
  activeCount++;
  void dl.start();
  return toEntry(dl);
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
  await existing.clear();
  await mgr.remove(id);
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
