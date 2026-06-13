import { describe, expect, it } from 'vitest';

import type { Chunk } from '../../src/chunk.js';
import { findSplitCandidate, planChunks } from '../../src/chunkScheduler.js';

describe('planChunks', () => {
  it('returns a single empty chunk for zero-size files', () => {
    const plans = planChunks({ totalSize: 0, targetChunkCount: 4, minChunkSize: 16 });
    expect(plans).toEqual([{ offset: 0, length: 0, downloadedBytes: 0 }]);
  });

  it('falls back to one chunk when total is below minChunkSize', () => {
    const plans = planChunks({ totalSize: 10, targetChunkCount: 4, minChunkSize: 64 });
    expect(plans).toEqual([{ offset: 0, length: 10, downloadedBytes: 0 }]);
  });

  it('divides into targetChunkCount pieces with the tail absorbing remainder', () => {
    const plans = planChunks({ totalSize: 1003, targetChunkCount: 4, minChunkSize: 16 });
    expect(plans).toHaveLength(4);
    const total = plans.reduce((acc, p) => acc + p.length, 0);
    expect(total).toBe(1003);
    expect(plans[0]?.offset).toBe(0);
    expect(plans[1]?.offset).toBe(plans[0]!.length);
  });

  it('caps chunk count so no chunk is below minChunkSize', () => {
    const plans = planChunks({ totalSize: 100, targetChunkCount: 8, minChunkSize: 30 });
    // floor(100/30) = 3 → at most three chunks.
    expect(plans).toHaveLength(3);
  });

  it('returns the resumeFrom plan verbatim when provided', () => {
    const prior = [
      { offset: 0, length: 100, downloadedBytes: 50 },
      { offset: 100, length: 100, downloadedBytes: 0 },
    ];
    const plans = planChunks({
      totalSize: 200,
      targetChunkCount: 4,
      minChunkSize: 16,
      resumeFrom: prior,
    });
    expect(plans).toEqual(prior);
    // returned plans are independent copies
    expect(plans).not.toBe(prior);
  });
});

interface FakeChunk {
  status: string;
  remainingBytes: number;
  quality: string;
  truncated?: { offset: number; length: number } | null;
}

function makeFake(over: Partial<FakeChunk>): Chunk {
  const base: FakeChunk = {
    status: 'downloading',
    remainingBytes: 1024,
    quality: 'good',
    ...over,
  };
  const truncateTail = (_min: number): { offset: number; length: number } | null => {
    if (base.truncated !== undefined) return base.truncated;
    // Default behaviour: split exactly in half from the tail.
    const len = Math.floor(base.remainingBytes / 2);
    const removed = { offset: 10_000, length: len };
    base.remainingBytes -= len;
    return removed;
  };
  return {
    status: base.status,
    remainingBytes: base.remainingBytes,
    quality: base.quality,
    truncateTail,
  } as unknown as Chunk;
}

describe('findSplitCandidate', () => {
  it('returns null when the pool is full', () => {
    const chunks = [makeFake({}), makeFake({})];
    const r = findSplitCandidate({
      activeChunks: chunks,
      maxChunks: 2,
      minChunkSize: 100,
      trigger: 'completed-reassign',
    });
    expect(r).toBeNull();
  });

  it('ignores chunks that are not downloading', () => {
    const chunks = [makeFake({ status: 'paused' })];
    const r = findSplitCandidate({
      activeChunks: chunks,
      maxChunks: 4,
      minChunkSize: 100,
      trigger: 'completed-reassign',
    });
    expect(r).toBeNull();
  });

  it('ignores chunks with not enough remaining bytes (< 2x minChunkSize)', () => {
    const chunks = [makeFake({ remainingBytes: 150 })];
    const r = findSplitCandidate({
      activeChunks: chunks,
      maxChunks: 4,
      minChunkSize: 100,
      trigger: 'completed-reassign',
    });
    expect(r).toBeNull();
  });

  it('prefers stalled over poor over good; ties broken by remaining size', () => {
    const good = makeFake({ remainingBytes: 10_000, quality: 'good' });
    const poor = makeFake({ remainingBytes: 5_000, quality: 'poor' });
    const stalled = makeFake({ remainingBytes: 1_000, quality: 'stalled' });
    const r = findSplitCandidate({
      activeChunks: [good, poor, stalled],
      maxChunks: 10,
      minChunkSize: 100,
      trigger: 'completed-reassign',
    });
    expect(r?.chunk).toBe(stalled);
  });

  it('propagates the trigger reason to the returned candidate', () => {
    const c = makeFake({});
    const r = findSplitCandidate({
      activeChunks: [c],
      maxChunks: 10,
      minChunkSize: 100,
      trigger: 'slow',
    });
    expect(r?.reason).toBe('slow');
  });
});
