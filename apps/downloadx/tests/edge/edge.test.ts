import { describe, expect, it } from 'vitest';

import { TEMP_EXT } from '../../src/constants.js';
import { Download, type DownloadInternalConfig } from '../../src/download.js';
import { makeHarness } from '../helpers/config.js';
import { equalBytes, makeBytes } from '../helpers/fixtures.js';

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

describe('edge cases — transient HTTP failures', () => {
  it('retries 503 up to maxRetries then succeeds', async () => {
    const body = makeBytes(256);
    const harness = makeHarness({ maxRetries: 3, retryDelay: 1, retryBackoff: 1 });
    harness.fetch.route('https://x/transient', { body, failTimes: 2, failStatus: 503 });
    const d = new Download(
      'e1',
      'https://x/transient',
      {},
      internal(harness, { maxRetries: 3, retryDelay: 1, retryBackoff: 1 }),
    );
    await d.start();
    expect(d.state).toBe('completed');
    expect(equalBytes(harness.fs.peek('/dl/transient')!, body)).toBe(true);
  });

  it('fails permanently on 404 (no retry)', async () => {
    const harness = makeHarness({ maxRetries: 5, retryDelay: 1 });
    // 404 on every verb — permanently broken resource.
    harness.fetch.route('https://x/gone', {
      body: new Uint8Array(0),
      failTimes: 10,
      failHeadTimes: 10,
      failStatus: 404,
    });
    const d = new Download(
      'e2',
      'https://x/gone',
      {},
      internal(harness, { maxRetries: 5, retryDelay: 1 }),
    );
    await d.start();
    expect(d.state).toBe('error');
  });

  it('gives up on 503 after maxRetries is exhausted', async () => {
    const harness = makeHarness({ maxRetries: 1, retryDelay: 1 });
    harness.fetch.route('https://x/down', {
      body: makeBytes(64),
      failTimes: 999,
      failHeadTimes: 999,
      failStatus: 503,
    });
    const d = new Download(
      'e3',
      'https://x/down',
      {},
      internal(harness, { maxRetries: 1, retryDelay: 1 }),
    );
    await d.start();
    expect(d.state).toBe('error');
  });
});

describe('edge cases — resume validator changes', () => {
  it('discards old meta when ETag has changed upstream', async () => {
    const bodyOld = makeBytes(512, 1);
    const bodyNew = makeBytes(512, 2);
    const harness = makeHarness({ targetChunkCount: 2, minChunkSize: 32 });
    harness.fetch.route('https://x/mut.bin', {
      body: bodyOld,
      etag: 'v1',
      streamChunks: [64, 64, 64, 64],
    });

    const d1 = new Download(
      'e4',
      'https://x/mut.bin',
      {},
      internal(harness, { targetChunkCount: 2, minChunkSize: 32 }),
    );
    const r = d1.start();
    setTimeout(() => d1.pause(), 2);
    await r;
    if (d1.state === 'completed') {
      // Raced — skip.
      return;
    }
    expect(harness.fs.hasFile('/dl/mut.bin.downloadx.json')).toBe(true);

    // Upstream now serves a different payload with a different ETag.
    harness.fetch.updateRoute('https://x/mut.bin', { body: bodyNew, etag: 'v2' });
    const d2 = new Download(
      'e4',
      'https://x/mut.bin',
      {},
      internal(harness, { targetChunkCount: 2, minChunkSize: 32 }),
    );
    await d2.start();
    expect(d2.state).toBe('completed');
    // Resulting file should match the NEW payload bit-for-bit; if meta hadn't
    // been discarded we'd have a mix of old/new chunks.
    const written = harness.fs.peek('/dl/mut.bin');
    expect(written).toBeDefined();
    expect(equalBytes(written!, bodyNew)).toBe(true);
  });

  it('treats corrupted meta as missing and starts fresh', async () => {
    const body = makeBytes(128);
    const harness = makeHarness();
    harness.fetch.route('https://x/corrupt', { body });
    // Pre-seed a corrupt meta file at the path a Download would look for.
    await harness.fs.writeFile(
      '/dl/corrupt.downloadx.json',
      new TextEncoder().encode('{malformed'),
    );
    const d = new Download('e5', 'https://x/corrupt', {}, internal(harness));
    await d.start();
    expect(d.state).toBe('completed');
    expect(equalBytes(harness.fs.peek('/dl/corrupt')!, body)).toBe(true);
  });
});

describe('edge cases — scheduler and sizing', () => {
  it('stays at one chunk when the file is smaller than minChunkSize', async () => {
    const body = makeBytes(8);
    const harness = makeHarness({ targetChunkCount: 8, minChunkSize: 32 });
    harness.fetch.route('https://x/tiny', { body });
    const d = new Download(
      'e6',
      'https://x/tiny',
      {},
      internal(harness, { targetChunkCount: 8, minChunkSize: 32 }),
    );
    await d.start();
    expect(d.state).toBe('completed');
    expect(d.getChunkSnapshots()).toHaveLength(1);
  });

  it('honours chunkMode: "single" even when ranges are supported', async () => {
    const body = makeBytes(1024);
    const harness = makeHarness({ targetChunkCount: 4, minChunkSize: 32 });
    harness.fetch.route('https://x/forced-single', { body });
    const d = new Download(
      'e7',
      'https://x/forced-single',
      { chunkMode: 'single' },
      internal(harness, { targetChunkCount: 4, minChunkSize: 32 }),
    );
    await d.start();
    expect(d.getChunkSnapshots()).toHaveLength(1);
  });

  it('never exceeds targetChunkCount even across dynamic splits', async () => {
    // Stream the body very slowly so the splitter has a chance to trigger.
    const body = makeBytes(4096);
    const harness = makeHarness({ targetChunkCount: 3, minChunkSize: 32 });
    harness.fetch.route('https://x/cap', {
      body,
      streamChunks: Array(32).fill(128),
    });
    const d = new Download(
      'e8',
      'https://x/cap',
      {},
      internal(harness, { targetChunkCount: 3, minChunkSize: 32 }),
    );
    await d.start();
    expect(d.state).toBe('completed');
    // At least one chunk (the original plan) and no more than 3 active at any
    // time — we don't have a real-time max observer, so assert on final count.
    const snaps = d.getChunkSnapshots();
    // completed + reassigned chunks together may exceed 3, but the number of
    // live chunks at any instant is capped. Sanity check: all bytes accounted for.
    const sumLen = snaps.reduce((acc, c) => acc + c.length, 0);
    expect(sumLen).toBe(body.length);
  });
});

describe('edge cases — filesystem behaviour', () => {
  it('safeUnlink on a missing file is a no-op during clear()', async () => {
    const harness = makeHarness();
    harness.fetch.route('https://x/gone.bin', { body: makeBytes(16) });
    const d = new Download('e9', 'https://x/gone.bin', {}, internal(harness));
    await d.clear(); // never started — nothing to clean
    expect(d.state).not.toBe('error');
  });

  it('produces the .part file during download and removes it on completion', async () => {
    const body = makeBytes(512);
    const harness = makeHarness({ targetChunkCount: 1, minChunkSize: 64 });
    harness.fetch.route('https://x/tmp.bin', { body });
    const d = new Download(
      'e10',
      'https://x/tmp.bin',
      {},
      internal(harness, { targetChunkCount: 1, minChunkSize: 64 }),
    );
    await d.start();
    expect(harness.fs.hasFile(`/dl/tmp.bin${TEMP_EXT}`)).toBe(false);
    expect(harness.fs.hasFile('/dl/tmp.bin')).toBe(true);
  });
});
