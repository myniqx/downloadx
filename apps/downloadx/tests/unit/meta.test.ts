import { describe, expect, it } from 'vitest';

import {
  canResumeAgainst,
  createMeta,
  dehydrateState,
  deleteMeta,
  loadMeta,
  metaPath,
  persistMeta,
  updateMeta,
} from '../../src/meta.js';
import type { ChunkSnapshot, ProbeResult } from '../../src/types.js';
import { makeHarness } from '../helpers/config.js';

function exampleProbe(over: Partial<ProbeResult> = {}): ProbeResult {
  return {
    url: 'https://x/y.bin',
    finalUrl: 'https://x/y.bin',
    totalSize: 1024,
    acceptsRanges: true,
    etag: 'W/"v1"',
    lastModified: null,
    contentType: null,
    filename: 'y.bin',
    ...over,
  };
}

function exampleSnap(over: Partial<ChunkSnapshot> = {}): ChunkSnapshot {
  return {
    id: 'c0',
    offset: 0,
    length: 512,
    downloadedBytes: 0,
    status: 'pending',
    quality: 'good',
    retries: 0,
    ...over,
  };
}

describe('meta persistence', () => {
  it('persistMeta writes via tmp + rename (atomic) and loadMeta reads back', async () => {
    const { fs, io } = makeHarness();
    const meta = createMeta({ id: 'd1', probe: exampleProbe(), chunks: [exampleSnap()] });
    await persistMeta(io, { dir: '/dl', filename: 'y.bin' }, meta);
    expect(fs.hasFile(metaPath(io, { dir: '/dl', filename: 'y.bin' }))).toBe(true);
    // tmp file should not remain after rename.
    expect(fs.hasFile(`${metaPath(io, { dir: '/dl', filename: 'y.bin' })}.tmp`)).toBe(false);
    const loaded = await loadMeta(io, { dir: '/dl', filename: 'y.bin' });
    expect(loaded).not.toBeNull();
    expect(loaded?.id).toBe('d1');
    expect(loaded?.chunks[0]?.id).toBe('c0');
  });

  it('loadMeta returns null when the file is missing', async () => {
    const { io } = makeHarness();
    const loaded = await loadMeta(io, { dir: '/dl', filename: 'missing.bin' });
    expect(loaded).toBeNull();
  });

  it('loadMeta treats a corrupt JSON payload as missing', async () => {
    const { fs, io } = makeHarness();
    await fs.writeFile(
      metaPath(io, { dir: '/dl', filename: 'bad.bin' }),
      new TextEncoder().encode('{not json'),
    );
    const loaded = await loadMeta(io, { dir: '/dl', filename: 'bad.bin' });
    expect(loaded).toBeNull();
  });

  it('loadMeta rejects payloads with wrong schemaVersion', async () => {
    const { fs, io } = makeHarness();
    const target = metaPath(io, { dir: '/dl', filename: 'old.bin' });
    await fs.writeFile(
      target,
      new TextEncoder().encode(JSON.stringify({ schemaVersion: 2, id: 'x' })),
    );
    const loaded = await loadMeta(io, { dir: '/dl', filename: 'old.bin' });
    expect(loaded).toBeNull();
  });

  it('deleteMeta removes the file', async () => {
    const { fs, io } = makeHarness();
    const meta = createMeta({ id: 'd1', probe: exampleProbe(), chunks: [exampleSnap()] });
    await persistMeta(io, { dir: '/dl', filename: 'y.bin' }, meta);
    await deleteMeta(io, { dir: '/dl', filename: 'y.bin' });
    expect(fs.hasFile(metaPath(io, { dir: '/dl', filename: 'y.bin' }))).toBe(false);
  });

  it('updateMeta merges state/chunks and bumps updatedAt', () => {
    const meta = createMeta({
      id: 'd1',
      probe: exampleProbe(),
      chunks: [exampleSnap()],
      now: () => 1_000,
    });
    expect(meta.state).toBe('idle');
    const snaps = [exampleSnap({ status: 'completed', downloadedBytes: 512 })];
    const updated = updateMeta(meta, { state: 'completed', chunks: snaps });
    expect(updated.state).toBe('completed');
    expect(updated.chunks[0]?.status).toBe('completed');
    expect(updated.updatedAt).toBeGreaterThanOrEqual(updated.createdAt);
  });
});

describe('canResumeAgainst', () => {
  it('requires matching total size', () => {
    const meta = createMeta({ id: 'd', probe: exampleProbe({ totalSize: 1024 }), chunks: [] });
    expect(canResumeAgainst(meta, exampleProbe({ totalSize: 2048 }))).toBe(false);
  });

  it('requires matching ETag when both sides have it', () => {
    const meta = createMeta({ id: 'd', probe: exampleProbe({ etag: 'A' }), chunks: [] });
    expect(canResumeAgainst(meta, exampleProbe({ etag: 'B' }))).toBe(false);
    expect(canResumeAgainst(meta, exampleProbe({ etag: 'A' }))).toBe(true);
  });

  it('falls back to Last-Modified when ETag is absent on either side', () => {
    const meta = createMeta({
      id: 'd',
      probe: exampleProbe({ etag: null, lastModified: 'Mon, 01 Jan 2020' }),
      chunks: [],
    });
    expect(
      canResumeAgainst(meta, exampleProbe({ etag: null, lastModified: 'Mon, 01 Jan 2020' })),
    ).toBe(true);
    expect(
      canResumeAgainst(meta, exampleProbe({ etag: null, lastModified: 'Tue, 02 Jan 2020' })),
    ).toBe(false);
  });

  it('accepts when no validators exist on either side and sizes match', () => {
    const bare: ProbeResult = exampleProbe({ etag: null, lastModified: null });
    const meta = createMeta({ id: 'd', probe: bare, chunks: [] });
    expect(canResumeAgainst(meta, bare)).toBe(true);
  });
});

describe('dehydrateState', () => {
  it('rewrites downloading and probing to paused for persistence', () => {
    expect(dehydrateState('downloading')).toBe('paused');
    expect(dehydrateState('probing')).toBe('paused');
  });

  it('preserves terminal and paused states as-is', () => {
    expect(dehydrateState('paused')).toBe('paused');
    expect(dehydrateState('completed')).toBe('completed');
    expect(dehydrateState('error')).toBe('error');
    expect(dehydrateState('cancelled')).toBe('cancelled');
    expect(dehydrateState('idle')).toBe('idle');
  });
});
