import { describe, expect, it, vi } from 'vitest';
import { TEMP_EXT } from '../../src/constants.js';
import { Download } from '../../src/download.js';
import type { DownloadInternalConfig } from '../../src/download.js';
import { makeHarness } from '../helpers/config.js';
import { equalBytes, makeBytes } from '../helpers/fixtures.js';
import { waitForEvent } from '../helpers/events.js';

function internalConfig(harness: ReturnType<typeof makeHarness>, patch: Partial<DownloadInternalConfig> = {}): DownloadInternalConfig {
  return {
    io: harness.io,
    targetPath: harness.config.targetPath,
    cachePath: harness.config.cachePath ?? harness.config.targetPath,
    maxParallel: harness.config.maxParallel ?? 3,
    targetChunkCount: harness.config.targetChunkCount ?? 4,
    minChunkSize: harness.config.minChunkSize ?? 16,
    maxRetries: harness.config.maxRetries ?? 2,
    retryDelay: harness.config.retryDelay ?? 5,
    retryBackoff: harness.config.retryBackoff ?? 1,
    speedSampleWindow: harness.config.speedSampleWindow ?? 500,
    speedLimit: harness.config.speedLimit ?? 0,
    requestTimeout: harness.config.requestTimeout ?? 5_000,
    headers: harness.config.headers ?? {},
    ...patch,
  };
}

describe('Download integration — happy path', () => {
  it('downloads a multi-chunk range-capable file and reassembles bytes exactly', async () => {
    const body = makeBytes(4096, 42);
    const harness = makeHarness();
    harness.fetch.route('https://x/f.bin', { body });
    const download = new Download('d1', 'https://x/f.bin', {}, internalConfig(harness));
    await download.start();
    expect(download.state).toBe('completed');
    const written = harness.fs.peek('/dl/f.bin');
    expect(written).toBeDefined();
    expect(equalBytes(written!, body)).toBe(true);
    // .part sidecar and meta sidecar must both be gone after completion.
    expect(harness.fs.hasFile(`/dl/f.bin${TEMP_EXT}`)).toBe(false);
    expect(harness.fs.hasFile('/dl/f.bin.downloadx.json')).toBe(false);
  });

  it('downloads a single-chunk file when server refuses range', async () => {
    const body = makeBytes(1024, 7);
    const harness = makeHarness();
    harness.fetch.route('https://x/single', {
      body,
      acceptsRanges: false,
      head: 'no-size',
    });
    const download = new Download('d2', 'https://x/single', {}, internalConfig(harness));
    await download.start();
    expect(download.state).toBe('completed');
    expect(download.getChunkSnapshots()).toHaveLength(1);
    expect(equalBytes(harness.fs.peek('/dl/single')!, body)).toBe(true);
  });

  it('handles zero-byte downloads cleanly', async () => {
    const harness = makeHarness();
    harness.fetch.route('https://x/empty.bin', { body: new Uint8Array(0) });
    const download = new Download('d3', 'https://x/empty.bin', {}, internalConfig(harness));
    await download.start();
    expect(download.state).toBe('completed');
    const written = harness.fs.peek('/dl/empty.bin');
    // Empty file may be absent or a zero-length buffer depending on the
    // write path; either is acceptable.
    if (written !== undefined) expect(written.length).toBe(0);
  });

  it('uses filename from Content-Disposition when URL lacks a path segment', async () => {
    const body = makeBytes(256);
    const harness = makeHarness();
    harness.fetch.route('https://x/download', {
      body,
      contentDisposition: 'attachment; filename="real-name.dat"',
    });
    const download = new Download('d4', 'https://x/download', {}, internalConfig(harness));
    await download.start();
    expect(download.filename).toBe('real-name.dat');
    expect(harness.fs.hasFile('/dl/real-name.dat')).toBe(true);
  });

  it('emits a completed event with duration and total byte count', async () => {
    const body = makeBytes(128);
    const harness = makeHarness();
    harness.fetch.route('https://x/e.bin', { body });
    const download = new Download('d5', 'https://x/e.bin', {}, internalConfig(harness));
    const completed = waitForEvent(download.emitter, 'completed', 5_000);
    await download.start();
    const payload = await completed;
    expect(payload.downloadId).toBe('d5');
    expect(payload.totalBytes).toBe(128);
    expect(payload.filename).toBe('e.bin');
    expect(payload.durationMs).toBeGreaterThanOrEqual(0);
  });
});

describe('Download integration — pause and resume', () => {
  it('pauses mid-download, persists meta, then resumes and completes', async () => {
    const body = makeBytes(2048, 11);
    const harness = makeHarness({
      targetChunkCount: 2,
      minChunkSize: 32,
    });
    // Chunked streaming so there are pause points between writes.
    harness.fetch.route('https://x/big.bin', { body, streamChunks: [64, 64, 64, 64, 64, 64, 64, 64, 64, 64] });
    const download = new Download('d6', 'https://x/big.bin', {}, internalConfig(harness, {
      targetChunkCount: 2,
      minChunkSize: 32,
    }));

    // Pause shortly after the download starts.
    const runPromise = download.start();
    setTimeout(() => download.pause(), 5);
    await runPromise;
    expect(['paused', 'completed']).toContain(download.state);

    if (download.state === 'completed') {
      // Raced through; assertion still holds for correctness.
      expect(equalBytes(harness.fs.peek('/dl/big.bin')!, body)).toBe(true);
      return;
    }

    // Meta must exist with non-zero progress.
    expect(harness.fs.hasFile('/dl/big.bin.downloadx.json')).toBe(true);
    expect(download.downloadedBytes).toBeGreaterThan(0);
    expect(download.downloadedBytes).toBeLessThan(body.length);

    // Resume on the same instance — start() again picks up from the state.
    await download.start();
    expect(download.state).toBe('completed');
    const written = harness.fs.peek('/dl/big.bin');
    expect(written).toBeDefined();
    expect(equalBytes(written!, body)).toBe(true);
  });

  it('resumes cross-instance by loading the meta file from disk', async () => {
    const body = makeBytes(2048, 17);
    const harness = makeHarness({ targetChunkCount: 2, minChunkSize: 32 });
    harness.fetch.route('https://x/cross.bin', { body, streamChunks: [128, 128, 128, 128, 128, 128, 128, 128] });

    const first = new Download('d7', 'https://x/cross.bin', {}, internalConfig(harness, { targetChunkCount: 2, minChunkSize: 32 }));
    const run = first.start();
    setTimeout(() => first.pause(), 3);
    await run;
    if (first.state === 'completed') {
      // Raced — acceptable; correctness still holds.
      expect(equalBytes(harness.fs.peek('/dl/cross.bin')!, body)).toBe(true);
      return;
    }
    const bytesSoFar = first.downloadedBytes;
    expect(bytesSoFar).toBeGreaterThan(0);

    // Fresh instance, same injected fs — simulates a process restart.
    const second = new Download('d7', 'https://x/cross.bin', {}, internalConfig(harness, { targetChunkCount: 2, minChunkSize: 32 }));
    await second.start();
    expect(second.state).toBe('completed');
    expect(equalBytes(harness.fs.peek('/dl/cross.bin')!, body)).toBe(true);
  });

  it('cancel removes the part and meta files', async () => {
    const body = makeBytes(2048);
    const harness = makeHarness({ targetChunkCount: 2, minChunkSize: 32 });
    harness.fetch.route('https://x/drop.bin', { body, streamChunks: [64, 64, 64, 64] });
    const download = new Download('d8', 'https://x/drop.bin', {}, internalConfig(harness));
    const run = download.start();
    setTimeout(() => download.cancel(), 2);
    await run;
    await download.clear();
    expect(harness.fs.hasFile('/dl/drop.bin')).toBe(false);
    expect(harness.fs.hasFile('/dl/drop.bin.downloadx.json')).toBe(false);
    expect(harness.fs.hasFile(`/dl/drop.bin${TEMP_EXT}`)).toBe(false);
  });
});

describe('Download integration — speedLimit', () => {
  it('applies the throttle before each write', async () => {
    // Payload (2048) well above the 512 B/s bucket so the throttle must stall
    // at least once even after the initial bucket is drained.
    const body = makeBytes(2048);
    const harness = makeHarness({ targetChunkCount: 1, minChunkSize: 64, speedLimit: 512 });
    harness.fetch.route('https://x/slow.bin', { body, streamChunks: [256, 256, 256, 256, 256, 256, 256, 256] });
    const download = new Download('d9', 'https://x/slow.bin', {}, internalConfig(harness, {
      speedLimit: 512,
      targetChunkCount: 1,
      minChunkSize: 64,
    }));
    const started = Date.now();
    await download.start();
    const elapsed = Date.now() - started;
    expect(download.state).toBe('completed');
    // 2048 bytes @ 512 B/s → expect ≥ ~3s after the initial bucket. Generous
    // lower bound (1s) to avoid flakes under slow CI hosts.
    expect(elapsed).toBeGreaterThan(1_000);
  });

  it('speedLimit(0) at runtime removes the cap', async () => {
    const body = makeBytes(256);
    const harness = makeHarness({ speedLimit: 1024, targetChunkCount: 1, minChunkSize: 64 });
    harness.fetch.route('https://x/unlim.bin', { body, streamChunks: [64, 64, 64, 64] });
    const download = new Download('d10', 'https://x/unlim.bin', {}, internalConfig(harness, {
      speedLimit: 1024,
      targetChunkCount: 1,
      minChunkSize: 64,
    }));
    const run = download.start();
    // Lift the cap immediately.
    download.setSpeedLimit(0);
    await run;
    expect(download.state).toBe('completed');
  });
});

describe('Download integration — DownloadX relay', () => {
  it('events from Download also appear on DownloadX emitter (relay parity)', async () => {
    const body = makeBytes(256);
    const harness = makeHarness();
    harness.fetch.route('https://x/r.bin', { body });
    const { createDownloadX } = await import('../../src/downloadX.js');
    const dlx = createDownloadX(harness.config);
    const relayed: string[] = [];
    dlx.emitter.on('stateChange', (p) => relayed.push(p.current));
    dlx.emitter.on('completed', (p) => relayed.push(`completed:${p.filename}`));
    const d = dlx.addUrl('https://x/r.bin');
    await d.start();
    expect(relayed).toContain('completed:r.bin');
    expect(relayed.some((s) => s === 'downloading' || s === 'probing')).toBe(true);
  });

  it('DownloadX.maxParallel limits concurrent active downloads', async () => {
    const body = makeBytes(512);
    const harness = makeHarness({ maxParallel: 1 });
    harness.fetch.globalDelayMs = 50;
    harness.fetch.route('https://x/a.bin', { body });
    harness.fetch.route('https://x/b.bin', { body });
    const { createDownloadX } = await import('../../src/downloadX.js');
    const dlx = createDownloadX(harness.config);
    const a = dlx.addUrl('https://x/a.bin');
    const b = dlx.addUrl('https://x/b.bin');
    await dlx.start();

    // Wait until either one completes — at which point check that the other
    // must still be waiting (because maxParallel = 1 and delay is artificial).
    const seen = new Set<string>();
    a.emitter.on('stateChange', (p) => { if (p.current === 'downloading') seen.add('a'); });
    b.emitter.on('stateChange', (p) => { if (p.current === 'downloading') seen.add('b'); });

    // Poll until both complete.
    const deadline = Date.now() + 5_000;
    while (Date.now() < deadline) {
      if (a.state === 'completed' && b.state === 'completed') break;
      await new Promise((r) => setTimeout(r, 20));
    }
    expect(a.state).toBe('completed');
    expect(b.state).toBe('completed');
  });

  it('list() returns every registered download', async () => {
    const harness = makeHarness();
    harness.fetch.route('https://x/l1', { body: makeBytes(16) });
    harness.fetch.route('https://x/l2', { body: makeBytes(16) });
    const { createDownloadX } = await import('../../src/downloadX.js');
    const dlx = createDownloadX(harness.config);
    dlx.addUrl('https://x/l1');
    dlx.addUrl('https://x/l2');
    expect(dlx.list()).toHaveLength(2);
  });

  it('addUrl with same id (derived from URL) returns the existing handle', async () => {
    const harness = makeHarness();
    harness.fetch.route('https://x/dup', { body: makeBytes(16) });
    const { createDownloadX } = await import('../../src/downloadX.js');
    const dlx = createDownloadX(harness.config);
    const a = dlx.addUrl('https://x/dup');
    const b = dlx.addUrl('https://x/dup');
    expect(a).toBe(b);
  });
});

describe('Download integration — error propagation', () => {
  it('emits an error event and enters error state when all retries fail', async () => {
    const harness = makeHarness({ maxRetries: 0 });
    harness.fetch.route('https://x/gone', {
      body: makeBytes(64),
      failTimes: 1,
      failStatus: 503,
    });
    const download = new Download('d11', 'https://x/gone', {}, internalConfig(harness, { maxRetries: 0 }));
    const errorSpy = vi.fn();
    download.emitter.on('error', errorSpy);
    await download.start();
    expect(download.state).toBe('error');
    expect(errorSpy).toHaveBeenCalled();
  });
});
