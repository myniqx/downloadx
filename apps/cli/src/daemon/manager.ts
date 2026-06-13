import { mkdir, rename, unlink, writeFile, readFile, stat, open, appendFile } from 'node:fs/promises';
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
import type { DownloadEntry, DaemonConfig, IpcEvent } from '../ipc.ts';
import { upsertDownload, removeDownload, getDownload, saveConfig, parseSpeed } from './store.ts';

type EventSink = (event: IpcEvent) => void;
type DownloadXInstance = ReturnType<typeof createDownloadX>;

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
    mkdir: async (p: string) => { await mkdir(p, { recursive: true }); },
    exists: async (p: string) => { try { await stat(p); return true; } catch { return false; } },
    readFile: async (p: string) => new Uint8Array(await readFile(p)),
    writeFile: async (p: string, buf: Uint8Array) => { await writeFile(p, buf); },
    writeChunk: async (p: string, offset: number, buf: Uint8Array) => {
      const fh = await openRw(p);
      try { await fh.write(buf, 0, buf.length, offset); } finally { await fh.close(); }
    },
    rename: async (from: string, to: string) => { await rename(from, to); },
    unlink: async (p: string) => { await unlink(p).catch(() => undefined); },
    joinPath: (...segs: string[]) => join(...segs),
    truncate: async (p: string, size: number) => {
      const fh = await openRw(p);
      try { await fh.truncate(size); } finally { await fh.close(); }
    },
    appendFile: async (p: string, buf: Uint8Array) => { await appendFile(p, buf); },
    fileSize: async (p: string) => (await stat(p)).size,
  };
}

let manager: DownloadXInstance | null = null;

export function initManager(config: DaemonConfig): void {
  manager = createDownloadX({
    io: makeIo(),
    targetPath: config.targetPath,
    cachePath: config.cachePath,
    maxParallel: config.maxParallel,
    targetChunkCount: config.targetChunkCount,
    minChunkSize: config.minChunkSize,
    journal: config.journal,
    ...(config.speedLimit > 0 ? { speedLimit: config.speedLimit } : {}),
  });
}

function getManager(): DownloadXInstance {
  if (!manager) throw new Error('Manager not initialized');
  return manager;
}

const GLOBAL_CONFIG_KEYS = ['maxParallel', 'speedLimit', 'targetPath', 'cachePath', 'targetChunkCount', 'minChunkSize', 'journal'] as const;
type GlobalConfigKey = typeof GLOBAL_CONFIG_KEYS[number];

const GLOBAL_KEY_MAP: Record<string, GlobalConfigKey> = Object.fromEntries(
  GLOBAL_CONFIG_KEYS.map((k) => [k.toLowerCase(), k])
);

export function setGlobalConfig(key: string, rawValue: string, override: boolean): void {
  const canonical = GLOBAL_KEY_MAP[key.toLowerCase()];
  if (!canonical) throw new Error(`Unknown config key '${key}'. Valid keys: ${GLOBAL_CONFIG_KEYS.join(', ')}`);
  const mgr = getManager();

  if (canonical === 'maxParallel') {
    const n = Number(rawValue);
    if (!Number.isInteger(n) || n < 1) throw new Error(`'maxParallel' must be a positive integer`);
    mgr.setMaxParallel(n);
  } else if (canonical === 'speedLimit') {
    mgr.setSpeedLimit(rawValue === '0' ? 0 : parseSpeed(rawValue));
  } else if (canonical === 'targetPath') {
    mgr.setTargetPath(rawValue);
  } else if (canonical === 'cachePath') {
    mgr.setCachePath(rawValue);
  } else if (canonical === 'targetChunkCount') {
    const n = Number(rawValue);
    if (!Number.isInteger(n) || n < 1) throw new Error(`'targetChunkCount' must be a positive integer`);
    mgr.setTargetChunkCount(n, override);
  } else if (canonical === 'minChunkSize') {
    mgr.setMinChunkSize(parseSpeed(rawValue), override);
  } else if (canonical === 'journal') {
    if (rawValue !== 'true' && rawValue !== 'false') throw new Error(`'journal' must be 'true' or 'false'`);
    mgr.setJournal(rawValue === 'true', override);
  }
}

export function getGlobalConfig(key?: string): DaemonConfig | unknown {
  const mgr = getManager();
  const cfg = mgr.getConfig();
  const snapshot: DaemonConfig = {
    maxParallel:      cfg.maxParallel,
    speedLimit:       cfg.speedLimit,
    targetPath:       cfg.targetPath,
    cachePath:        cfg.cachePath,
    targetChunkCount: cfg.targetChunkCount,
    minChunkSize:     cfg.minChunkSize,
    journal:          cfg.journal,
  };
  if (!key) return snapshot;
  const canonical = GLOBAL_KEY_MAP[key.toLowerCase()];
  if (!canonical) throw new Error(`Unknown config key '${key}'. Valid keys: ${GLOBAL_CONFIG_KEYS.join(', ')}`);
  return snapshot[canonical];
}

export async function persistConfig(): Promise<void> {
  const cfg = getGlobalConfig() as DaemonConfig;
  await saveConfig(cfg);
}

const dlRefs = new Map<string, Download>();

let activeCount = 0;
let shutdownCallback: (() => void) | null = null;

export function onAutoShutdown(cb: () => void): void {
  shutdownCallback = cb;
}

function onDownloadFinished(): void {
  activeCount = Math.max(0, activeCount - 1);
  if (activeCount === 0 && shutdownCallback) shutdownCallback();
}

function attachListeners(id: string, dl: Download): void {
  dl.emitter.on('progress', (p: DownloadProgressPayload) => {
    const stored = getDownload(id);
    if (stored) {
      void upsertDownload({
        ...stored,
        downloadedBytes: p.downloadedBytes,
        totalBytes: p.totalBytes ?? stored.totalBytes,
      });
    }
    emit({ ...p, event: 'progress' });
  });

  dl.emitter.on('chunkProgress', (p: ChunkProgressPayload) => {
    emit({ ...p, event: 'chunkProgress' });
  });

  dl.emitter.on('chunkLifecycle', (p: ChunkLifecyclePayload) => {
    emit({ ...p, event: 'chunkLifecycle' });
  });

  dl.emitter.on('stateChange', (p: DownloadStatePayload) => {
    const stored = getDownload(id);
    if (stored) void upsertDownload({ ...stored, status: p.current });
    emit({ ...p, event: 'stateChange' });
  });

  dl.emitter.on('completed', (p: DownloadCompletedPayload) => {
    const stored = getDownload(id);
    if (stored) {
      const finalTargetPath = stored.targetPath ?? getManager().targetPath;
      void upsertDownload({
        ...stored,
        status: 'completed',
        filename: p.filename,
        totalBytes: p.totalBytes,
        completedAt: Date.now(),
        targetPath: finalTargetPath,
      });
    }
    emit({ ...p, event: 'completed' });
    onDownloadFinished();
  });

  dl.emitter.on('error', (p: DownloadErrorPayload) => {
    const stored = getDownload(id);
    if (stored && p.fatal) {
      void upsertDownload({ ...stored, status: 'failed', errorMessage: p.error.message });
      onDownloadFinished();
    }
    const { error, ...rest } = p;
    emit({ ...rest, event: 'error', message: error.message });
  });

  dl.emitter.on('diagnostic', (p: DiagnosticPayload) => {
    emit({ ...p, event: 'diagnostic' });
  });
}

export function setDownloadConfig(id: string, key: string, value: unknown): boolean {
  const dl = dlRefs.get(id);
  if (!dl) throw new Error(`Download ${id} not active`);
  return dl.set(key, value);
}

export function getDownloadConfig<T>(id: string, key: string): T | undefined {
  const dl = dlRefs.get(id);
  if (!dl) throw new Error(`Download ${id} not active`);
  return dl.get<T>(key);
}

export function describeDownload(id: string): DownloadDescription {
  const dl = dlRefs.get(id);
  if (dl) return dl.describe();
  const entry = getDownload(id);
  if (!entry) throw new Error(`Download ${id} not found`);
  return {
    id: entry.id,
    url: entry.url,
    filename: entry.filename ?? '',
    state: entry.status as DownloadDescription['state'],
    totalBytes: entry.totalBytes ?? null,
    downloadedBytes: entry.downloadedBytes,
    percent: entry.totalBytes ? Math.round((entry.downloadedBytes / entry.totalBytes) * 100) : null,
    totalSpeedBps: 0,
    etaMs: null,
    elapsedMs: entry.completedAt ? entry.completedAt - entry.addedAt : Date.now() - entry.addedAt,
    activeChunks: 0,
    totalChunks: 0,
    chunks: [],
    recentDiagnostics: [],
  };
}

export async function addDownload(id: string, url: string, targetPath: string | null): Promise<DownloadEntry> {
  const mgr = getManager();
  const dl = mgr.addUrl(url, { id });
  dlRefs.set(id, dl);
  attachListeners(id, dl);

  const entry: DownloadEntry = {
    id,
    url,
    filename: null,
    targetPath,
    status: 'queued',
    addedAt: Date.now(),
    completedAt: null,
    totalBytes: null,
    downloadedBytes: 0,
    errorMessage: null,
  };

  await upsertDownload(entry);
  activeCount++;
  void dl.start();
  return entry;
}

export async function pauseDownload(id: string): Promise<void> {
  const dl = dlRefs.get(id);
  if (!dl) throw new Error(`Download ${id} not active`);
  await dl.pause();
}

export async function resumeDownload(id: string): Promise<void> {
  const entry = getDownload(id);
  if (!entry) throw new Error(`Download ${id} not found`);
  const mgr = getManager();
  const existing = dlRefs.get(id);
  const dl = existing ?? mgr.addUrl(entry.url, { id: entry.id });
  if (!existing) {
    dlRefs.set(id, dl);
    attachListeners(id, dl);
    activeCount++;
  }
  await dl.start();
}

export async function restartDownload(id: string): Promise<void> {
  const entry = getDownload(id);
  if (!entry) throw new Error(`Download ${id} not found`);
  const existing = dlRefs.get(id);
  if (existing) {
    await existing.clear();
    dlRefs.delete(id);
  }
  const mgr = getManager();
  const dl = mgr.addUrl(entry.url, { id });
  dlRefs.set(id, dl);
  attachListeners(id, dl);
  await upsertDownload({
    ...entry,
    status: 'queued',
    filename: null,
    totalBytes: null,
    downloadedBytes: 0,
    completedAt: null,
    errorMessage: null,
  });
  activeCount++;
  void dl.start();
}

export async function cancelDownload(id: string): Promise<void> {
  const dl = dlRefs.get(id);
  if (dl) await dl.cancel();
  const entry = getDownload(id);
  if (entry) await upsertDownload({ ...entry, status: 'cancelled' });
}

export async function clearDownload(id: string): Promise<void> {
  const dl = dlRefs.get(id);
  if (dl) await dl.clear();
  dlRefs.delete(id);
  await removeDownload(id);
}

export async function restoreDownloads(entries: DownloadEntry[]): Promise<void> {
  const mgr = getManager();
  for (const entry of entries) {
    if (entry.status === 'downloading' || entry.status === 'queued') {
      const dl = mgr.addUrl(entry.url, { id: entry.id });
      dlRefs.set(entry.id, dl);
      attachListeners(entry.id, dl);
      activeCount++;
      void dl.start();
    } else if (entry.status === 'paused') {
      const dl = mgr.addUrl(entry.url, { id: entry.id });
      dlRefs.set(entry.id, dl);
      attachListeners(entry.id, dl);
    }
  }
}
