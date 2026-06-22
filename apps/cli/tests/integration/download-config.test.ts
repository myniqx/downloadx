import { describe, it, afterEach } from 'vitest';

import { DEFAULT_CONFIG } from '../../src/daemon/config.ts';
import { createTestEnv, type TestEnv } from '../helpers/env.ts';

const TEST_URL = 'http://localhost/test-file.bin';

describe('per-download config', () => {
  let env: TestEnv | null = null;

  afterEach(async () => {
    if (env) {
      await env.cleanup();
      env = null;
    }
  });

  it('fresh download inherits global config values', async () => {
    env = await createTestEnv();
    await env.dx('add', '--url', TEST_URL);
    await env.assertDownloadConfig('#1', {
      speedLimit: DEFAULT_CONFIG.speedLimit,
      targetChunkCount: DEFAULT_CONFIG.targetChunkCount,
    });
  });

  it('per-download set is reflected in get --id', async () => {
    env = await createTestEnv();
    await env.dx('add', '--url', TEST_URL);
    await env.dx('set', 'speedLimit', '1mb', '--id', '#1');
    await env.dx('set', 'targetChunkCount', '8', '--id', '#1');
    await env.assertDownloadConfig('#1', {
      speedLimit: 1024 * 1024,
      targetChunkCount: 8,
    });
  });

  it('per-download config persists across daemon restart', async () => {
    env = await createTestEnv();
    await env.dx('add', '--url', TEST_URL);
    await env.dx('set', 'speedLimit', '2mb', '--id', '#1');
    await env.dx('set', 'targetChunkCount', '6', '--id', '#1');
    await env.dx('stop');

    await env.assertDownloadConfig('#1', {
      speedLimit: 2 * 1024 * 1024,
      targetChunkCount: 6,
    });
  });

  it('per-download override is independent from global config', async () => {
    env = await createTestEnv();
    await env.dx('add', '--url', TEST_URL);
    await env.dx('set', 'speedLimit', '500kb', '--id', '#1');
    await env.dx('set', 'speedLimit', '3mb');

    await env.assertDownloadConfig('#1', { speedLimit: 500 * 1024 });
    await env.assertGet('speedLimit', 3 * 1024 * 1024);
  });
});
