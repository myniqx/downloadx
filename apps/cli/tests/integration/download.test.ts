import { describe, it, afterEach } from 'vitest';

import { createTestEnv, type TestEnv } from '../helpers/env.ts';

const TEST_URL = 'http://localhost/test-file.bin';

describe('download management', () => {
  let env: TestEnv | null = null;

  afterEach(async () => {
    if (env) {
      await env.cleanup();
      env = null;
    }
  });

  it('added download appears in list', async () => {
    env = await createTestEnv();

    await env.dx('add', '--url', TEST_URL);

    await env.assertList([{ url: TEST_URL }]);
  });

  it('download persists in list after daemon restart', async () => {
    env = await createTestEnv();

    await env.dx('add', '--url', TEST_URL);
    await env.dx('stop');

    await env.assertList([{ url: TEST_URL }]);
  });

  it('multiple downloads appear in correct order', async () => {
    env = await createTestEnv();

    const urls = [
      'http://localhost/file-a.bin',
      'http://localhost/file-b.bin',
      'http://localhost/file-c.bin',
    ];

    for (const url of urls) {
      await env.dx('add', '--url', url);
    }

    await env.assertList(urls.map((url) => ({ url })));
  });

  it('list is empty on fresh start', async () => {
    env = await createTestEnv();
    await env.assertList([]);
  });
});
