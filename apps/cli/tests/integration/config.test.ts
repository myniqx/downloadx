import { describe, it, expect, afterEach } from 'vitest';

import { CONFIG_KEYS, LOCAL_KEYS, LOCAL_KEY_MAP } from '../../src/daemon/config-keys.ts';
import { DEFAULT_CONFIG } from '../../src/daemon/config.ts';
import { createTestEnv, type TestEnv } from '../helpers/env.ts';

describe('daemon config persistence', () => {
  let env: TestEnv | null = null;

  afterEach(async () => {
    if (env) {
      await env.cleanup();
      env = null;
    }
  });

  it('default config is correct on fresh start', async () => {
    env = await createTestEnv();
    await env.assertConfig({
      maxParallel: DEFAULT_CONFIG.maxParallel,
      speedLimit: DEFAULT_CONFIG.speedLimit,
      targetChunkCount: DEFAULT_CONFIG.targetChunkCount,
      minChunkSize: DEFAULT_CONFIG.minChunkSize,
      journal: DEFAULT_CONFIG.journal,
    });
  });

  it('global set persists across daemon restart', async () => {
    env = await createTestEnv();

    await env.dx('set', 'maxParallel', '7');
    await env.dx('set', 'speedLimit', '2mb');
    await env.dx('stop');

    await env.assertGet('maxParallel', 7);
    await env.assertGet('speedLimit', 2 * 1024 * 1024);
  });

  it('other global keys keep their default after an unrelated set', async () => {
    env = await createTestEnv();

    await env.dx('set', 'maxParallel', '5');
    await env.dx('stop');

    await env.assertConfig({
      maxParallel: 5,
      speedLimit: DEFAULT_CONFIG.speedLimit,
      targetChunkCount: DEFAULT_CONFIG.targetChunkCount,
      journal: DEFAULT_CONFIG.journal,
    });
  });

  it('all global config keys are gettable', async () => {
    env = await createTestEnv();
    const { stdout } = await env.dx('get', '--json');
    const parsed = JSON.parse(stdout) as Record<string, unknown>;
    for (const def of CONFIG_KEYS.filter((d) => !d.localOnly)) {
      expect(Object.keys(parsed), `key '${def.canonical}' missing from get output`).toContain(def.canonical);
    }
  });

  it('unknown key is rejected by global set', async () => {
    env = await createTestEnv();
    const { stderr } = await env.dx('set', 'nonExistentKey', '999').catch((e: Error) => ({
      stdout: '',
      stderr: e.message,
    }));
    expect(stderr).toBeTruthy();
  });

  it('all global keys persist their non-default values across daemon restart', async () => {
    env = await createTestEnv();

    const customValues: Record<string, string> = {
      maxParallel: '8',
      speedLimit: '1mb',
      targetPath: `${env.workingDir}/custom-downloads`,
      targetChunkCount: '6',
      minChunkSize: '512kb',
      journal: 'false',
      'headers.X-Test': 'hello',
    };

    const expectedParsed: Record<string, unknown> = {
      maxParallel: 8,
      speedLimit: 1024 * 1024,
      targetPath: `${env.workingDir}/custom-downloads`,
      targetChunkCount: 6,
      minChunkSize: 512 * 1024,
      journal: false,
      headers: { 'X-Test': 'hello' },
    };

    for (const [key, value] of Object.entries(customValues)) {
      await env.dx('set', key, value);
    }

    await env.dx('stop');

    await env.assertConfig(expectedParsed);
  });

  it('all local keys are a subset of global keys', () => {
    const globalCanonicals = new Set(CONFIG_KEYS.map((d) => d.canonical));
    for (const def of LOCAL_KEYS) {
      expect(globalCanonicals.has(def.canonical), `LOCAL_KEY '${def.canonical}' not in CONFIG_KEYS`).toBe(true);
    }
  });
});
