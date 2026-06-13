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
import type { DownloadEntry, IpcEvent } from '../ipc.ts';
import { upsertDownload, removeDownload, getDownload, getConfig } from './store.ts';

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

function getManager(): DownloadXInstance {
  if (manager) return manager;
  const cfg = getConfig();
  manager = createDownloadX({
    io: makeIo(),
    targetPath: cfg.targetPath,
    cachePath: cfg.cachePath,
    maxParallel: cfg.maxParallel,
    targetChunkCount: cfg.targetChunkCount,
    minChunkSize: cfg.minChunkSize,
    journal: cfg.journal,
    ...(cfg.speedLimit > 0 ? { speedLimit: cfg.speedLimit } : {}),
  });
  return manager;
}

export function applyConfig(): void {
  if (!manager) return;
  const cfg = getConfig();
  manager.setMaxParallel(cfg.maxParallel);
  manager.setTargetPath(cfg.targetPath);
  manager.setCachePath(cfg.cachePath);
  manager.setSpeedLimit(cfg.speedLimit);
  manager.setTargetChunkCount(cfg.targetChunkCount);
  manager.setMinChunkSize(cfg.minChunkSize);
  manager.setJournal(cfg.journal);
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
      const finalTargetPath = stored.targetPath ?? getConfig().targetPath;
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

export async function addDownload(id: string, url: string, targetPath: string | null, speedLimit: number | null): Promise<DownloadEntry> {
  const mgr = getManager();
  const dl = mgr.addUrl(url, { id, ...(speedLimit !== null && speedLimit > 0 ? { speedLimit } : {}) });
  dlRefs.set(id, dl);
  attachListeners(id, dl);

  const entry: DownloadEntry = {
    id,
    url,
    filename: null,
    targetPath,
    cachePath: getConfig().cachePath,
    speedLimit,
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

function entryOptions(entry: DownloadEntry) {
  return {
    id: entry.id,
    ...(entry.speedLimit !== null ? { speedLimit: entry.speedLimit } : {}),
  };
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
  const dl = existing ?? mgr.addUrl(entry.url, entryOptions(entry));
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
  const dl = mgr.addUrl(entry.url, {
    id,
    ...(entry.speedLimit !== null && entry.speedLimit > 0 ? { speedLimit: entry.speedLimit } : {}),
  });
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
    if (!entry.cachePath) {
      await upsertDownload({ ...entry, cachePath: getConfig().cachePath });
    }
    if (entry.status === 'downloading' || entry.status === 'queued') {
      const dl = mgr.addUrl(entry.url, entryOptions(entry));
      dlRefs.set(entry.id, dl);
      attachListeners(entry.id, dl);
      activeCount++;
      void dl.start();
    } else if (entry.status === 'paused') {
      const dl = mgr.addUrl(entry.url, entryOptions(entry));
      dlRefs.set(entry.id, dl);
      attachListeners(entry.id, dl);
    }
  }
}
