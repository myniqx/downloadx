import { mkdir, rename, unlink, writeFile, readFile, stat, open, appendFile } from 'node:fs/promises';
import { join } from 'node:path';
import {
  createDownloadX,
  type Download,
  type DownloadDescription,
  type DownloadProgressPayload,
  type ChunkProgressPayload,
  type DownloadStatePayload,
  type DownloadCompletedPayload,
  type DownloadErrorPayload,
  type DiagnosticPayload,
} from 'downloadx';
import type { DownloadEntry, IpcEvent } from '../ipc.ts';
import { DOWNLOADS_DIR } from '../constants.ts';
import { upsertDownload, removeDownload, getDownload } from './store.ts';

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

function makeIo(_targetPath: string) {
  return {
    fetch: globalThis.fetch,
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

const managers = new Map<string, DownloadXInstance>();

function getOrCreateManager(targetPath: string): DownloadXInstance {
  const existing = managers.get(targetPath);
  if (existing) return existing;
  const mgr = createDownloadX({ io: makeIo(targetPath), targetPath, maxParallel: 3, targetChunkCount: 4, journal: true });
  managers.set(targetPath, mgr);
  return mgr;
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
    emit({
      event: 'progress',
      id,
      downloadedBytes: p.downloadedBytes,
      totalBytes: p.totalBytes ?? null,
      totalSpeed: p.totalSpeed,
      activeChunks: p.activeChunks,
      percent: p.percent ?? null,
    });
  });

  dl.emitter.on('chunkProgress', (p: ChunkProgressPayload) => {
    emit({
      event: 'chunkProgress',
      id,
      chunkId: p.chunkId,
      offset: p.offset,
      length: p.length,
      downloadedBytes: p.downloadedBytes,
      instantSpeed: p.instantSpeed,
      windowedSpeed: p.windowedSpeed,
      quality: p.quality,
    });
  });

  dl.emitter.on('stateChange', (p: DownloadStatePayload) => {
    const stored = getDownload(id);
    const next = p.current as DownloadEntry['status'];
    if (stored) void upsertDownload({ ...stored, status: next });
    emit({ event: 'stateChange', id, previous: p.previous as DownloadEntry['status'], current: next });
  });

  dl.emitter.on('completed', (p: DownloadCompletedPayload) => {
    const stored = getDownload(id);
    if (stored) {
      void upsertDownload({
        ...stored,
        status: 'completed',
        filename: p.filename,
        totalBytes: p.totalBytes,
        completedAt: Date.now(),
      });
    }
    emit({ event: 'completed', id, filename: p.filename, totalBytes: p.totalBytes, durationMs: p.durationMs });
    onDownloadFinished();
  });

  dl.emitter.on('error', (p: DownloadErrorPayload) => {
    const stored = getDownload(id);
    if (stored && p.fatal) {
      void upsertDownload({ ...stored, status: 'failed', errorMessage: p.error.message });
      onDownloadFinished();
    }
    emit({ event: 'error', id, chunkId: p.chunkId ?? null, message: p.error.message, fatal: p.fatal });
  });

  dl.emitter.on('diagnostic', (p: DiagnosticPayload) => {
    emit({
      event: 'diagnostic',
      id,
      chunkId: p.chunkId ?? null,
      level: p.level,
      code: p.code,
      message: p.message,
      timestamp: p.timestamp,
    });
  });
}

export function describeDownload(id: string): DownloadDescription {
  const dl = dlRefs.get(id);
  if (!dl) throw new Error(`Download ${id} not active`);
  return dl.describe();
}

export async function addDownload(id: string, url: string, targetPath: string): Promise<DownloadEntry> {
  const mgr = getOrCreateManager(targetPath);
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
  const mgr = getOrCreateManager(entry.targetPath);
  const existing = dlRefs.get(id);
  const dl = existing ?? mgr.addUrl(entry.url, { id });
  if (!existing) {
    dlRefs.set(id, dl);
    attachListeners(id, dl);
    activeCount++;
  }
  await dl.start();
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
  for (const entry of entries) {
    if (entry.status === 'downloading' || entry.status === 'queued') {
      const mgr = getOrCreateManager(entry.targetPath ?? DOWNLOADS_DIR);
      const dl = mgr.addUrl(entry.url, { id: entry.id });
      dlRefs.set(entry.id, dl);
      attachListeners(entry.id, dl);
      activeCount++;
      void dl.start();
    } else if (entry.status === 'paused') {
      const mgr = getOrCreateManager(entry.targetPath ?? DOWNLOADS_DIR);
      const dl = mgr.addUrl(entry.url, { id: entry.id });
      dlRefs.set(entry.id, dl);
      attachListeners(entry.id, dl);
    }
  }
}
