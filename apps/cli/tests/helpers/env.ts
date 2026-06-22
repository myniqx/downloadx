import { execFile } from 'node:child_process';
import { rm, mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { promisify } from 'node:util';
import { expect } from 'vitest';

const execFileAsync = promisify(execFile);
const CLI = new URL('../../dist/cli.js', import.meta.url).pathname;

export interface ExecResult {
  stdout: string;
  stderr: string;
}

export type ConfigValue = string | number | boolean | null;

export interface TestEnv {
  workingDir: string;
  dx: (...args: string[]) => Promise<ExecResult>;
  assertGet: (key: string, expected: string | number | boolean) => Promise<void>;
  assertConfig: (expected: Record<string, unknown>) => Promise<void>;
  assertDownloadConfig: (id: string, expected: Record<string, ConfigValue>) => Promise<void>;
  assertList: (checks: { url?: string; status?: string }[]) => Promise<void>;
  cleanup: () => Promise<void>;
}

function parseValue(raw: string): ConfigValue {
  if (raw === 'null') return null;
  if (raw === 'true') return true;
  if (raw === 'false') return false;
  const n = Number(raw);
  return Number.isNaN(n) ? raw : n;
}

function parseConfigOutput(stdout: string): Record<string, ConfigValue> {
  try {
    return JSON.parse(stdout) as Record<string, ConfigValue>;
  } catch {
    const result: Record<string, ConfigValue> = {};
    for (const line of stdout.split('\n')) {
      const eq = line.indexOf(' = ');
      if (eq === -1) continue;
      const key = line.slice(0, eq).trim();
      const val = line.slice(eq + 3).trim();
      result[key] = parseValue(val);
    }
    return result;
  }
}

export async function createTestEnv(): Promise<TestEnv> {
  const workingDir = join(tmpdir(), `downloadx-test-${randomUUID()}`);
  await mkdir(workingDir, { recursive: true });

  const dx = async (...args: string[]): Promise<ExecResult> => {
    const { stdout, stderr } = await execFileAsync('node', [CLI, ...args], {
      env: { ...process.env, WORKING_DIR: workingDir },
      timeout: 10_000,
    });
    return { stdout: stdout.trim(), stderr: stderr.trim() };
  };

  const assertGet = async (key: string, expected: string | number | boolean): Promise<void> => {
    const { stdout } = await dx('get', key, '--json');
    const parsed = JSON.parse(stdout) as Record<string, ConfigValue>;
    expect(parsed[key]).toBe(expected);
  };

  const assertConfig = async (expected: Record<string, unknown>): Promise<void> => {
    const { stdout } = await dx('get', '--json');
    const parsed = JSON.parse(stdout) as Record<string, unknown>;
    for (const [key, val] of Object.entries(expected)) {
      expect(parsed[key], `config key '${key}'`).toEqual(val);
    }
  };

  const assertDownloadConfig = async (
    id: string,
    expected: Record<string, ConfigValue>,
  ): Promise<void> => {
    const { stdout } = await dx('get', '--id', id, '--json');
    const parsed = JSON.parse(stdout) as Record<string, ConfigValue>;
    for (const [key, val] of Object.entries(expected)) {
      expect(parsed[key], `download config key '${key}'`).toBe(val);
    }
  };

  const assertList = async (checks: { url?: string; status?: string }[]): Promise<void> => {
    const { stdout } = await dx('list', '--json');
    const entries = JSON.parse(stdout) as { url: string; state: string }[];
    expect(entries.length, `expected ${checks.length} entries, got ${entries.length}`).toBe(checks.length);
    for (let i = 0; i < checks.length; i++) {
      const check = checks[i]!;
      const entry = entries[i]!;
      if (check.url) expect(entry.url, `entry #${i + 1} url`).toContain(check.url);
      if (check.status) expect(entry.state, `entry #${i + 1} status`).toBe(check.status);
    }
  };

  return {
    workingDir,
    dx,
    assertGet,
    assertConfig,
    assertDownloadConfig,
    assertList,
    cleanup: () => rm(workingDir, { recursive: true, force: true }),
  };
}
