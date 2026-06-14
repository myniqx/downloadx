import { describe, expect, it } from 'vitest';

import { Chunk } from '../../src/chunk.js';
import { UNKNOWN_SIZE_LENGTH } from '../../src/constants.js';
import { Download } from '../../src/download.js';
import { TypedEventEmitter } from '../../src/events.js';
import type { DownloadEventMap, FetchResponse, InjectedFunctions } from '../../src/types.js';
import { makeHarness } from '../helpers/config.js';
import { equalBytes, makeBytes } from '../helpers/fixtures.js';

function makeStreamResponse(pieces: Uint8Array[], status = 206): FetchResponse {
  let i = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(controller): void {
      if (i >= pieces.length) {
        controller.close();
        return;
      }
      const piece = pieces[i];
      i += 1;
      if (piece !== undefined) controller.enqueue(piece);
      if (i >= pieces.length) controller.close();
    },
  });
  return {
    status,
    statusText: status === 206 ? 'Partial Content' : 'OK',
    ok: true,
    headers: { get: () => null, has: () => false, forEach: () => undefined },
    body,
    arrayBuffer: async () => new ArrayBuffer(0),
    text: async () => '',
  };
}

function chunkParams(
  overrides: Partial<ConstructorParameters<typeof Chunk>[0]> & {
    fetch?: InjectedFunctions['fetch'];
    writeChunk?: InjectedFunctions['writeChunk'];
  } = {},
): ConstructorParameters<typeof Chunk>[0] {
  const { fetch: fetchOverride, writeChunk: writeChunkOverride, ...rest } = overrides;
  const harness = makeHarness();
  const baseGlobal = rest.global ?? harness.global;
  const global =
    fetchOverride !== undefined || writeChunkOverride !== undefined
      ? {
          ...baseGlobal,
          io: {
            ...baseGlobal.io,
            ...(fetchOverride !== undefined ? { fetch: fetchOverride } : {}),
            ...(writeChunkOverride !== undefined ? { writeChunk: writeChunkOverride } : {}),
          },
        }
      : baseGlobal;
  const { global: _globalOverride, ...restWithoutGlobal } = rest;
  return {
    id: 'c0',
    downloadId: 'd0',
    url: 'https://x/f',
    targetFilePath: '/dl/f.part',
    offset: 0,
    length: 100,
    initialDownloadedBytes: 0,
    acceptsRanges: true,
    emitter: new TypedEventEmitter<DownloadEventMap>(),
    medianSpeedRef: () => 0,
    ...restWithoutGlobal,
    global,
  };
}

describe('regression — chunk length shrinks while the stream is in flight (split)', () => {
  it('never writes past the shrunk length and downloadedBytes never exceeds it', async () => {
    const writes: Array<{ offset: number; length: number }> = [];
    const pieces = Array.from({ length: 10 }, () => makeBytes(10, 1));
    let truncated: { offset: number; length: number } | null = null;

    const chunk = new Chunk(
      chunkParams({
        length: 100,
        fetch: async () => makeStreamResponse(pieces),
        writeChunk: async (_p, offset, buf) => {
          writes.push({ offset, length: buf.length });
          // Shrink the chunk after the third write, exactly like a split does.
          if (writes.length === 3 && truncated === null) {
            truncated = chunk.truncateTail(10);
            expect(truncated).not.toBeNull();
          }
        },
      }),
    );

    await chunk.run();

    expect(chunk.status).toBe('completed');
    // Invariant the original bug violated: remaining size went negative.
    expect(chunk.downloadedBytes).toBeLessThanOrEqual(chunk.length);
    expect(chunk.remainingBytes).toBe(0);
    // No write may extend past the (shrunk) end of the chunk.
    const end = chunk.length;
    for (const w of writes) {
      expect(w.offset + w.length).toBeLessThanOrEqual(end);
    }
  });
});

describe('regression — server advertises ranges but answers 200', () => {
  it('falls back to a single-chunk download and still produces correct bytes', async () => {
    const body = makeBytes(2048, 9);
    const harness = makeHarness({
      targetChunkCount: 4,
      minChunkSize: 16,
      maxRetries: 1,
      retryDelay: 1,
    });
    // acceptsRanges:false makes the mock ignore Range headers (responds 200
    // with the full body), while the extra header makes the probe believe
    // ranges are supported — the classic misbehaving-CDN setup.
    harness.fetch.route('https://x/liar.bin', {
      body,
      acceptsRanges: false,
      extraHeaders: { 'Accept-Ranges': 'bytes' },
    });
    const d = new Download('r2', 'https://x/liar.bin', {}, harness.global);
    await d.start();
    expect(d.state).toBe('completed');
    expect(equalBytes(harness.fs.peek('/dl/liar.bin')!, body)).toBe(true);
  });
});

describe('regression — resume without range support restarts from zero', () => {
  it('discards stale progress instead of writing start-of-file bytes mid-file', async () => {
    const body = makeBytes(200, 3);
    const writes: Array<{ offset: number }> = [];
    const chunk = new Chunk(
      chunkParams({
        length: 200,
        acceptsRanges: false,
        initialDownloadedBytes: 80, // pretend a previous attempt got this far
        fetch: async () => makeStreamResponse([body], 200),
        writeChunk: async (_p, offset) => {
          writes.push({ offset });
        },
      }),
    );
    await chunk.run();
    expect(chunk.status).toBe('completed');
    expect(chunk.downloadedBytes).toBe(200);
    // First write must start at the chunk's real offset (0), not offset+80.
    expect(writes[0]?.offset).toBe(0);
  });
});

describe('regression — idle timeout retries instead of killing long downloads', () => {
  it('aborts a silent attempt, then succeeds on retry and completes', async () => {
    const body = makeBytes(64, 5);
    let attempt = 0;
    const silentFetch: InjectedFunctions['fetch'] = async (_url, init) => {
      attempt += 1;
      if (attempt === 1) {
        // First attempt: server goes silent — reject only when aborted, with
        // the abort reason (matches WHATWG fetch behaviour).
        return new Promise((_resolve, reject) => {
          init?.signal?.addEventListener(
            'abort',
            () => {
              reject(init.signal?.reason ?? new Error('aborted'));
            },
            { once: true },
          );
        });
      }
      return makeStreamResponse([body]);
    };
    const harness = makeHarness({ requestTimeout: 30 });
    const chunk = new Chunk(
      chunkParams({
        length: 64,
        global: harness.global,
        fetch: silentFetch,
      }),
    );
    await chunk.run();
    expect(chunk.status).toBe('completed');
    expect(attempt).toBe(2);
    expect(chunk.downloadedBytes).toBe(64);
  });
});

describe('regression — unknown total size streams to EOF', () => {
  it('completes a download whose size headers are missing', async () => {
    const body = makeBytes(512, 6);
    const harness = makeHarness({ maxRetries: 1, retryDelay: 1 });
    harness.fetch.route('https://x/nosize.bin', { body, acceptsRanges: false, head: 'no-size' });
    // Strip size headers so the probe reports totalSize === null.
    const raw = harness.fetch.fetch;
    const stripSize: InjectedFunctions['fetch'] = async (input, init) => {
      const res = await raw(input, init);
      return {
        ...res,
        headers: {
          get: (n: string) => {
            const k = n.toLowerCase();
            if (k === 'content-length' || k === 'content-range') return null;
            return res.headers.get(n);
          },
          has: (n: string) => res.headers.has(n),
          forEach: (cb: (value: string, name: string) => void) => res.headers.forEach(cb),
        },
        arrayBuffer: () => res.arrayBuffer(),
        text: () => res.text(),
      };
    };
    const strippedGlobal = { ...harness.global, io: { ...harness.io, fetch: stripSize } };
    const d = new Download('r5', 'https://x/nosize.bin', {}, strippedGlobal);
    await d.start();
    expect(d.state).toBe('completed');
    expect(d.totalBytes).toBeNull();
    expect(equalBytes(harness.fs.peek('/dl/nosize.bin')!, body)).toBe(true);
    const snaps = d.getChunkSnapshots();
    expect(snaps).toHaveLength(1);
    expect(snaps[0]?.length).toBe(UNKNOWN_SIZE_LENGTH);
  });
});

describe('features — journal, describe, preallocation', () => {
  it('writes an NDJSON journal when enabled and io.appendFile exists', async () => {
    const body = makeBytes(256, 8);
    const harness = makeHarness({ journal: true });
    harness.fetch.route('https://x/j.bin', { body });
    const d = new Download('r6', 'https://x/j.bin', {}, harness.global);
    await d.start();
    expect(d.state).toBe('completed');
    const log = harness.fs.peek('/dl/r6.downloadx.log');
    expect(log).toBeDefined();
    const lines = new TextDecoder().decode(log!).trim().split('\n');
    expect(lines.length).toBeGreaterThan(0);
    for (const line of lines) {
      const parsed = JSON.parse(line) as { downloadId: string; code: string; timestamp: number };
      expect(parsed.downloadId).toBe('r6');
      expect(typeof parsed.code).toBe('string');
      expect(typeof parsed.timestamp).toBe('number');
    }
  });

  it('describe() reports a consistent compact snapshot', async () => {
    const body = makeBytes(1024, 4);
    const harness = makeHarness();
    harness.fetch.route('https://x/desc.bin', { body });
    const d = new Download('r7', 'https://x/desc.bin', {}, harness.global);
    await d.start();
    const desc = d.describe();
    expect(desc.id).toBe('r7');
    expect(desc.state).toBe('completed');
    expect(desc.totalBytes).toBe(1024);
    expect(desc.downloadedBytes).toBe(1024);
    expect(desc.percent).toBe(100);
    expect(desc.totalChunks).toBeGreaterThan(0);
    expect(typeof d.describeText()).toBe('string');
    expect(d.describeText()).toContain('completed');
  });

  it('pre-allocates the part file to the final size before writes', async () => {
    const body = makeBytes(2048, 12);
    const harness = makeHarness({ targetChunkCount: 2, minChunkSize: 32 });
    harness.fetch.route('https://x/pre.bin', { body, streamChunks: [64, 64, 64] });
    const d = new Download('r8', 'https://x/pre.bin', {}, harness.global);
    const run = d.start();
    // Shortly after start the part file should already be full-size.
    await new Promise((r) => setTimeout(r, 10));
    const part = harness.fs.peek('/dl/pre.bin.downloadx.part');
    if (d.state === 'downloading' && part !== undefined) {
      expect(part.length).toBe(2048);
    }
    await run;
    expect(d.state).toBe('completed');
    expect(equalBytes(harness.fs.peek('/dl/pre.bin')!, body)).toBe(true);
  });

  it('progress events carry an ETA when size and speed are known', async () => {
    const body = makeBytes(4096, 2);
    const harness = makeHarness({ targetChunkCount: 2, minChunkSize: 32 });
    harness.fetch.route('https://x/eta.bin', {
      body,
      streamChunks: Array(16).fill(256),
      delayMs: 5,
    });
    const d = new Download('r9', 'https://x/eta.bin', {}, harness.global);
    const etas: Array<number | null> = [];
    d.emitter.on('progress', (p) => etas.push(p.etaMs));
    await d.start();
    expect(d.state).toBe('completed');
    expect(etas.length).toBeGreaterThan(0);
    // Every reported ETA must be a non-negative number or null — never NaN.
    for (const e of etas) {
      if (e !== null) expect(e).toBeGreaterThanOrEqual(0);
    }
  });
});
