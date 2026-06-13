import { describe, expect, it } from 'vitest';

import { Download, type DownloadInternalConfig } from '../../src/download.js';
import { createDownloadX } from '../../src/downloadX.js';
import type {
  ChunkLifecyclePayload,
  ChunkProgressPayload,
  DownloadCompletedPayload,
  DownloadEventName,
  DownloadProgressPayload,
  DownloadStatePayload,
} from '../../src/types.js';
import { makeHarness } from '../helpers/config.js';
import { collectEvents } from '../helpers/events.js';
import { makeBytes } from '../helpers/fixtures.js';

function internal(
  h: ReturnType<typeof makeHarness>,
  patch: Partial<DownloadInternalConfig> = {},
): DownloadInternalConfig {
  return {
    io: h.io,
    targetPath: h.config.targetPath,
    cachePath: h.config.cachePath ?? h.config.targetPath,
    maxParallel: h.config.maxParallel ?? 3,
    targetChunkCount: h.config.targetChunkCount ?? 4,
    minChunkSize: h.config.minChunkSize ?? 16,
    maxRetries: h.config.maxRetries ?? 2,
    retryDelay: h.config.retryDelay ?? 5,
    retryBackoff: h.config.retryBackoff ?? 1,
    speedSampleWindow: h.config.speedSampleWindow ?? 500,
    speedLimit: h.config.speedLimit ?? 0,
    requestTimeout: h.config.requestTimeout ?? 5_000,
    headers: h.config.headers ?? {},
    ...patch,
  };
}

describe('event payloads — Download', () => {
  it('stateChange fires with previous→current pairs in the right order', async () => {
    const body = makeBytes(128);
    const harness = makeHarness();
    harness.fetch.route('https://x/s.bin', { body });
    const d = new Download('ev1', 'https://x/s.bin', {}, internal(harness));
    const state = collectEvents(d.emitter, 'stateChange');
    await d.start();
    const all = state.stop() as DownloadStatePayload[];
    const names = all.map((p) => p.current);
    expect(names[0]).toBe('probing');
    expect(names).toContain('downloading');
    expect(names[names.length - 1]).toBe('completed');
    // Pairs must be contiguous: each payload.previous equals the prior payload.current.
    for (let i = 1; i < all.length; i += 1) {
      expect(all[i]?.previous).toBe(all[i - 1]?.current);
    }
  });

  it('chunkLifecycle transitions go pending→downloading→completed', async () => {
    const body = makeBytes(256);
    const harness = makeHarness();
    harness.fetch.route('https://x/lf.bin', { body });
    const d = new Download('ev2', 'https://x/lf.bin', {}, internal(harness));
    const lifecycle = collectEvents(d.emitter, 'chunkLifecycle');
    await d.start();
    const payloads = lifecycle.stop() as ChunkLifecyclePayload[];
    // Every chunk must reach completed.
    const perChunk = new Map<string, string[]>();
    for (const p of payloads) {
      const arr = perChunk.get(p.chunkId) ?? [];
      arr.push(p.status);
      perChunk.set(p.chunkId, arr);
    }
    expect(perChunk.size).toBeGreaterThan(0);
    for (const arr of perChunk.values()) {
      expect(arr[arr.length - 1]).toBe('completed');
      expect(arr).toContain('downloading');
    }
  });

  it('chunkProgress payload includes speed readings and monotonically increasing bytes', async () => {
    const body = makeBytes(2048);
    const harness = makeHarness({ targetChunkCount: 2, minChunkSize: 32 });
    harness.fetch.route('https://x/p.bin', { body, streamChunks: Array(8).fill(256) });
    const d = new Download(
      'ev3',
      'https://x/p.bin',
      {},
      internal(harness, { targetChunkCount: 2, minChunkSize: 32 }),
    );
    const progress = collectEvents(d.emitter, 'chunkProgress');
    await d.start();
    const all = progress.stop() as ChunkProgressPayload[];
    expect(all.length).toBeGreaterThan(0);
    for (const p of all) {
      expect(p.downloadId).toBe('ev3');
      expect(p.downloadedBytes).toBeGreaterThan(0);
      expect(p.instantSpeed).toBeGreaterThanOrEqual(0);
      expect(p.windowedSpeed).toBeGreaterThanOrEqual(0);
      expect(['good', 'poor', 'stalled']).toContain(p.quality);
    }
    // Per-chunk, downloadedBytes must be non-decreasing.
    const perChunk = new Map<string, number>();
    for (const p of all) {
      const prev = perChunk.get(p.chunkId) ?? 0;
      expect(p.downloadedBytes).toBeGreaterThanOrEqual(prev);
      perChunk.set(p.chunkId, p.downloadedBytes);
    }
  });

  it('completed payload reports the byte total and non-negative duration', async () => {
    const body = makeBytes(1024);
    const harness = makeHarness();
    harness.fetch.route('https://x/c.bin', { body });
    const d = new Download('ev4', 'https://x/c.bin', {}, internal(harness));
    const completed = collectEvents(d.emitter, 'completed');
    await d.start();
    const payloads = completed.stop() as DownloadCompletedPayload[];
    expect(payloads).toHaveLength(1);
    expect(payloads[0]?.totalBytes).toBe(1024);
    expect(payloads[0]?.durationMs).toBeGreaterThanOrEqual(0);
    expect(payloads[0]?.filename).toBe('c.bin');
  });

  it('progress event reports aggregate total speed and percent', async () => {
    const body = makeBytes(512);
    const harness = makeHarness();
    harness.fetch.route('https://x/agg.bin', { body });
    const d = new Download('ev5', 'https://x/agg.bin', {}, internal(harness));
    const progress = collectEvents(d.emitter, 'progress');
    await d.start();
    const all = progress.stop() as DownloadProgressPayload[];
    expect(all.length).toBeGreaterThan(0);
    const last = all[all.length - 1]!;
    expect(last.downloadedBytes).toBe(512);
    expect(last.totalBytes).toBe(512);
    expect(last.percent).toBe(100);
  });
});

describe('event payloads — DownloadX relay parity', () => {
  it('every event emitted by a Download also fires on the manager with the same payload', async () => {
    const body = makeBytes(256);
    const harness = makeHarness();
    harness.fetch.route('https://x/rel.bin', { body });
    const dlx = createDownloadX(harness.config);

    const eventNames: DownloadEventName[] = [
      'progress',
      'chunkProgress',
      'chunkLifecycle',
      'chunkSplit',
      'chunkQuality',
      'stateChange',
      'error',
      'completed',
    ];

    const d = dlx.addUrl('https://x/rel.bin');

    const downloadBuckets = new Map<DownloadEventName, unknown[]>();
    const managerBuckets = new Map<DownloadEventName, unknown[]>();
    for (const name of eventNames) {
      const localArr: unknown[] = [];
      const mgrArr: unknown[] = [];
      downloadBuckets.set(name, localArr);
      managerBuckets.set(name, mgrArr);
      d.emitter.on(name, (payload) => localArr.push(payload));
      dlx.emitter.on(name, (payload) => mgrArr.push(payload));
    }

    await d.start();

    for (const name of eventNames) {
      const local = downloadBuckets.get(name)!;
      const mgr = managerBuckets.get(name)!;
      expect(mgr.length).toBe(local.length);
      for (let i = 0; i < local.length; i += 1) {
        // Relay uses the same payload object reference; strict equality confirms
        // the manager sees exactly what the Download emitted.
        expect(mgr[i]).toBe(local[i]);
      }
    }
  });
});
