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

export interface ListEntry {
  index: number;
  status: string;
  nameOrUrl: string;
}

export interface TestEnv {
  workingDir: string;
  dx: (...args: string[]) => Promise<ExecResult>;
  assertGet: (key: string, expected: string | number | boolean) => Promise<void>;
  assertConfig: (expected: Record<string, string | number | boolean>) => Promise<void>;
  assertList: (checks: { url?: string; status?: string }[]) => Promise<void>;
  cleanup: () => Promise<void>;
}

function parseValue(raw: string): string | number | boolean {
  if (raw === 'true') return true;
  if (raw === 'false') return false;
  const n = Number(raw);
  return Number.isNaN(n) ? raw : n;
}

function parseConfigOutput(stdout: string): Record<string, string | number | boolean> {
  const result: Record<string, string | number | boolean> = {};
  for (const line of stdout.split('\n')) {
    const eq = line.indexOf(' = ');
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    const val = line.slice(eq + 3).trim();
    result[key] = parseValue(val);
  }
  return result;
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
    const { stdout } = await dx('get', key);
    const parsed = parseConfigOutput(stdout);
    expect(parsed[key]).toBe(expected);
  };

  const assertConfig = async (
    expected: Record<string, string | number | boolean>,
  ): Promise<void> => {
    const { stdout } = await dx('get');
    const parsed = parseConfigOutput(stdout);
    for (const [key, val] of Object.entries(expected)) {
      expect(parsed[key], `config key '${key}'`).toBe(val);
    }
  };

  const stripAnsi = (s: string) => s.replace(/\x1b\[[0-9;]*m/g, '');

  function parseList(stdout: string): ListEntry[] {
    if (stdout === 'No downloads.') return [];
    return stdout
      .split('\n')
      .filter((l) => l.trim())
      .map((line) => {
        const clean = stripAnsi(line);
        const m = /^#(\d+)\s+\[(\w+)\s*\]\s+.+?\s{2}(.+)$/.exec(clean);
        if (!m) return null;
        return { index: Number(m[1]), status: m[2]!.toLowerCase(), nameOrUrl: m[3]!.trim() };
      })
      .filter((e): e is ListEntry => e !== null);
  }

  const assertList = async (checks: { url?: string; status?: string }[]): Promise<void> => {
    const { stdout } = await dx('list');
    const entries = parseList(stdout);
    expect(entries.length, `expected ${checks.length} entries, got ${entries.length}`).toBe(checks.length);
    for (let i = 0; i < checks.length; i++) {
      const check = checks[i]!;
      const entry = entries[i]!;
      if (check.url) expect(entry.nameOrUrl, `entry #${i + 1} url`).toContain(check.url);
      if (check.status) expect(entry.status, `entry #${i + 1} status`).toBe(check.status);
    }
  };

  return {
    workingDir,
    dx,
    assertGet,
    assertConfig,
    assertList,
    cleanup: () => rm(workingDir, { recursive: true, force: true }),
  };
}
