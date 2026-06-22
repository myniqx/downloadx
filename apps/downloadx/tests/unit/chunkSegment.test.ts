import { describe, expect, it } from 'vitest';
import { Chunk, type ChunkParams } from '../../src/chunk.js';
import { UNKNOWN_SIZE_LENGTH } from '../../src/constants.js';
import { TypedEventEmitter } from '../../src/events.js';
import type { DownloadEventMap } from '../../src/types.js';
import { makeHarness } from '../helpers/config.js';

/**
 * Phase 1: Chunk.isSegment mode.
 *
 * A segment chunk downloads a whole HLS segment file from byte 0 into its own
 * targetFilePath, is never split, and (when size is unknown) streams until EOF.
 * Retry/throttle/speed/resume behave exactly like a normal chunk — those are
 * already covered by the Download integration suite, so here we focus on the
 * segment-specific guarantees.
 */

const SEG_URL = 'https://cdn/seg-000000.ts';
const SEG_PATH = '/cache/d1-hls/seg-000000.ts';
const PAYLOAD = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);

function makeSegmentChunk(
  overrides: Partial<ChunkParams> = {},
): { chunk: Chunk; emitter: TypedEventEmitter<DownloadEventMap>; harness: ReturnType<typeof makeHarness> } {
  const harness = makeHarness({ cachePath: '/cache' });
  const emitter = new TypedEventEmitter<DownloadEventMap>();
  const chunk = new Chunk({
    id: 'd1-c0',
    downloadId: 'd1',
    url: SEG_URL,
    targetFilePath: SEG_PATH,
    offset: 0,
    length: UNKNOWN_SIZE_LENGTH,
    initialDownloadedBytes: 0,
    // Optimistic resume: segments download from byte 0 with no range, so a
    // server that ignores Range can't splice stale bytes.
    acceptsRanges: false,
    global: harness.global,
    emitter,
    isSegment: true,
    medianSpeedRef: () => 0,
    ...overrides,
  });
  return { chunk, emitter, harness };
}

describe('Chunk segment mode', () => {
  it('downloads an unknown-size segment from byte 0 into its own file', async () => {
    const { chunk, harness } = makeSegmentChunk();
    harness.fetch.route(SEG_URL, { body: PAYLOAD });

    await chunk.run();

    expect(chunk.status).toBe('completed');
    expect(chunk.downloadedBytes).toBe(PAYLOAD.length);
    expect(harness.fs.peek(SEG_PATH)).toEqual(PAYLOAD);
  });

  it('is never split, even when there is plenty of remaining work', () => {
    const { chunk } = makeSegmentChunk({ length: 10_000, initialDownloadedBytes: 0 });
    // A normal chunk this size would happily donate its tail; a segment must not.
    expect(chunk.isSegment).toBe(true);
    expect(chunk.truncateTail(16)).toBeNull();
  });

  it('does not send a Range header (writes from byte 0)', async () => {
    const { chunk, harness } = makeSegmentChunk();
    harness.fetch.route(SEG_URL, { body: PAYLOAD });

    await chunk.run();

    const segCalls = harness.fetch.calls.filter((c) => c.url === SEG_URL);
    expect(segCalls.length).toBeGreaterThan(0);
    for (const call of segCalls) {
      const headers = call.init?.headers ?? {};
      expect(headers['Range']).toBeUndefined();
      expect(headers['range']).toBeUndefined();
    }
  });

  it('restarts from byte 0 when resumed (no-range optimistic behaviour)', async () => {
    // Simulate a resume: some bytes were already written previously.
    const { chunk, harness } = makeSegmentChunk({ initialDownloadedBytes: 3 });
    harness.fetch.route(SEG_URL, { body: PAYLOAD });

    await chunk.run();

    // Discards the 3 stale bytes and writes the full payload from 0.
    expect(chunk.status).toBe('completed');
    expect(chunk.downloadedBytes).toBe(PAYLOAD.length);
    expect(harness.fs.peek(SEG_PATH)).toEqual(PAYLOAD);
  });
});
