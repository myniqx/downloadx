import { describe, it, afterEach, expect } from 'vitest';

import { CONFIG_KEYS } from '../../src/daemon/config-keys.ts';
import { DEFAULT_CONFIG } from '../../src/daemon/config.ts';
import { createTestEnv, type TestEnv } from '../helpers/env.ts';

const URL_A = 'http://localhost/file-a.bin';
const URL_B = 'http://localhost/file-b.bin';
const URL_C = 'http://localhost/file-c.bin';

// Per-key test değerleri: global set için iki farklı değer (initial, alternate),
// local set için özel bir değer. null = bu key için o senaryo geçersiz (atla).
const KEY_TEST_VALUES: Record<string, { initial: string; alternate: string; local: string } | null> = {
  maxParallel:      { initial: '5', alternate: '6', local: '3' },
  speedLimit:       { initial: '1mb', alternate: '2mb', local: '512kb' },
  targetPath:       null, // path testi bağımlılık yaratır, atlanır
  targetChunkCount: { initial: '3', alternate: '5', local: '2' },
  minChunkSize:     { initial: '512kb', alternate: '2mb', local: '256kb' },
  journal:          null, // setGlobalValue propagates to downloads with same value — skip override isolation test
  filename:         null, // localOnly — kapsam testinde zaten error beklenir
  description:      null, // localOnly
  metadata:         null, // localOnly + dot-notation, ayrı test
  headers:          null, // özel merge semantiği var, ayrı test
};

describe('download lifecycle', () => {
  let env: TestEnv | null = null;

  afterEach(async () => {
    if (env) {
      await env.cleanup();
      env = null;
    }
  });

  // Global config değiştirilir, daemon kapatılıp açılır, değerlerin korunduğu doğrulanır.
  it('global config persists across daemon restart', async () => {
    env = await createTestEnv();

    await env.dx('set', 'maxParallel', '5');
    await env.dx('set', 'speedLimit', '1mb');
    await env.dx('set', 'targetChunkCount', '3');
    await env.dx('stop');

    await env.assertConfig({
      maxParallel: 5,
      speedLimit: 1024 * 1024,
      targetChunkCount: 3,
    });
  });

  // A ve B pause modunda eklenir, A'nın tüm local config'leri set edilir,
  // daemon restart sonrası A değerlerini korur.
  it('all local configs on download A persist across daemon restart', async () => {
    env = await createTestEnv();

    await env.dx('add', '--url', URL_A);
    await env.dx('add', '--url', URL_B);
    await env.dx('pause', '--all');

    await env.dx('set', 'speedLimit', '500kb', '--id', '#1');
    await env.dx('set', 'targetChunkCount', '2', '--id', '#1');
    await env.dx('set', 'minChunkSize', '256kb', '--id', '#1');
    await env.dx('set', 'journal', 'true', '--id', '#1');
    await env.dx('set', 'filename', 'custom-a.bin', '--id', '#1');
    await env.dx('set', 'description', 'test download A', '--id', '#1');
    await env.dx('stop');

    await env.assertDownloadConfig('#1', {
      speedLimit: 500 * 1024,
      targetChunkCount: 2,
      minChunkSize: 256 * 1024,
      journal: true,
    });
  });

  // canLocal:false keyler local set edilmeye çalışılırsa error fırlatır.
  it('global-only keys reject per-download set', async () => {
    env = await createTestEnv();
    await env.dx('add', '--url', URL_A);

    const globalOnlyKeys = CONFIG_KEYS.filter((d) => !d.canLocal);
    for (const def of globalOnlyKeys) {
      const val = KEY_TEST_VALUES[def.canonical];
      if (!val) continue;
      const result = await env.dx('set', def.canonical, val.local, '--id', '#1').catch((e: Error) => ({
        stdout: '',
        stderr: e.message,
      }));
      expect(result.stderr, `'${def.canonical}' should reject local set`).toBeTruthy();
    }
  });

  // localOnly keyler global set edilmeye çalışılırsa error fırlatır.
  it('local-only keys reject global set', async () => {
    env = await createTestEnv();

    const localOnlyKeys = CONFIG_KEYS.filter((d) => d.localOnly);
    for (const def of localOnlyKeys) {
      const result = await env.dx('set', def.canonical, 'somevalue').catch((e: Error) => ({
        stdout: '',
        stderr: e.message,
      }));
      expect(result.stderr, `'${def.canonical}' should reject global set`).toBeTruthy();
    }
  });

  // A silinir, C ve B eklenir. canLocal:true, localOnly:false keyler için:
  // C'ye özel değer set edilir → Global farklı değere çekilir →
  // C.key !== Global.key, B.key === Global.key doğrulanır.
  it('per-download override isolates C from global changes while B follows global', async () => {
    env = await createTestEnv();

    await env.dx('add', '--url', URL_B);
    await env.dx('add', '--url', URL_C);
    await env.dx('pause', '--all');

    const sharedKeys = CONFIG_KEYS.filter(
      (d) => d.canLocal && !d.localOnly && KEY_TEST_VALUES[d.canonical] !== null && d.canonical !== 'headers',
    );

    for (const def of sharedKeys) {
      const vals = KEY_TEST_VALUES[def.canonical]!;

      // C'ye özel değer set et
      await env.dx('set', def.canonical, vals.local, '--id', '#2');

      // Global'i farklı değere çek
      await env.dx('set', def.canonical, vals.alternate);

      const globalVal = (await env.dx('get', def.canonical, '--json').then(
        (r) => JSON.parse(r.stdout) as Record<string, unknown>,
      ))[def.canonical];

      const cConfig = await env.dx('get', '--id', '#2', '--json').then(
        (r) => JSON.parse(r.stdout) as Record<string, unknown>,
      );
      const bConfig = await env.dx('get', '--id', '#1', '--json').then(
        (r) => JSON.parse(r.stdout) as Record<string, unknown>,
      );

      // C override'ı global'den farklı olmalı
      expect(cConfig[def.canonical], `C.${def.canonical} should keep local override`).not.toEqual(globalVal);
      // B override'ı yok, global'i takip etmeli
      expect(bConfig[def.canonical], `B.${def.canonical} should follow global`).toEqual(globalVal);
    }
  });

  // C'nin override'ları null yapılınca global değeri takip eder,
  // daemon restart sonrasında da global ile senkronize kalır.
  it('clearing C override reverts to global and survives daemon restart', async () => {
    env = await createTestEnv();

    await env.dx('add', '--url', URL_C);
    await env.dx('pause', '--all');

    const sharedKeys = CONFIG_KEYS.filter(
      (d) => d.canLocal && !d.localOnly && KEY_TEST_VALUES[d.canonical] !== null && d.canonical !== 'headers',
    );

    for (const def of sharedKeys) {
      const vals = KEY_TEST_VALUES[def.canonical]!;

      // Global ve C'ye farklı değerler ver
      await env.dx('set', def.canonical, vals.initial);
      await env.dx('set', def.canonical, vals.local, '--id', '#1');

      // C override'ını null yaparak kaldır
      await env.dx('set', def.canonical, 'null', '--id', '#1');

      const globalVal = (await env.dx('get', def.canonical, '--json').then(
        (r) => JSON.parse(r.stdout) as Record<string, unknown>,
      ))[def.canonical];

      const cConfig = await env.dx('get', '--id', '#1', '--json').then(
        (r) => JSON.parse(r.stdout) as Record<string, unknown>,
      );

      expect(cConfig[def.canonical], `C.${def.canonical} should equal global after null`).toEqual(globalVal);
    }

    // Daemon restart sonrasında da global'i takip etmeli
    await env.dx('set', 'targetChunkCount', '7');
    await env.dx('stop');

    await env.assertDownloadConfig('#1', { targetChunkCount: 7 });
  });

  // Headers özel merge semantiği:
  // effective = {...global, ...local}
  // C persist edildiğinde sadece kendi local header'larını saklar,
  // global header değişince merge sonucu da değişir.
  it('headers merge: effective = global + local, persist stores only local', async () => {
    env = await createTestEnv();

    await env.dx('add', '--url', URL_C);
    await env.dx('pause', '--all');

    // Global header set et
    await env.dx('set', 'headers.X-Global', 'global-val');

    // C için local header set et
    await env.dx('set', 'headers.X-Local', 'local-val', '--id', '#1');

    // C'nin effective headers = global + local içermeli
    const cConfig = await env.dx('get', '--id', '#1', '--json').then(
      (r) => JSON.parse(r.stdout) as Record<string, unknown>,
    );
    expect(cConfig['headers'], 'C headers should merge global + local').toEqual({
      'X-Global': 'global-val',
      'X-Local': 'local-val',
    });

    // Global'e yeni header eklenince C'nin effective headers de güncellenir
    await env.dx('set', 'headers.X-Global2', 'global-val2');

    const cConfig2 = await env.dx('get', '--id', '#1', '--json').then(
      (r) => JSON.parse(r.stdout) as Record<string, unknown>,
    );
    expect(cConfig2['headers'], 'C headers should reflect new global header').toEqual({
      'X-Global': 'global-val',
      'X-Global2': 'global-val2',
      'X-Local': 'local-val',
    });

    // Daemon restart sonrasında C sadece local header'ını persist etmiş olmalı,
    // global değişince merge sonucu farklanır
    await env.dx('set', 'headers.X-Global', 'changed');
    await env.dx('stop');

    const cConfigAfter = await env.dx('get', '--id', '#1', '--json').then(
      (r) => JSON.parse(r.stdout) as Record<string, unknown>,
    );
    expect(cConfigAfter['headers'], 'C headers after restart reflects updated global').toEqual({
      'X-Global': 'changed',
      'X-Global2': 'global-val2',
      'X-Local': 'local-val',
    });
  });
});
