import { Throttle } from '../../src/throttle.js';
import type { DownloadXConfig, GlobalConfig, InjectedFunctions } from '../../src/types.js';
import { MockFetch } from './mockFetch.js';
import { MockFs } from './mockFs.js';

export interface TestHarness {
  fs: MockFs;
  fetch: MockFetch;
  io: InjectedFunctions;
  config: DownloadXConfig;
  global: GlobalConfig;
}

export interface HarnessOverrides {
  targetPath?: string;
  cachePath?: string;
  maxParallel?: number;
  targetChunkCount?: number;
  minChunkSize?: number;
  maxRetries?: number;
  retryDelay?: number;
  retryBackoff?: number;
  speedSampleWindow?: number;
  speedLimit?: number;
  requestTimeout?: number;
  headers?: Record<string, string>;
  journal?: boolean;
}

export function makeHarness(overrides: HarnessOverrides = {}): TestHarness {
  const fs = new MockFs();
  const fetch = new MockFetch();
  const io: InjectedFunctions = {
    fetch: fetch.fetch,
    ...fs,
    get concatSegments() { return fs.concatSegments; },
  };
  const config: DownloadXConfig = {
    io,
    targetPath: overrides.targetPath ?? '/dl',
    cachePath: overrides.cachePath ?? '/dl',
    maxParallel: overrides.maxParallel ?? 3,
    targetChunkCount: overrides.targetChunkCount ?? 4,
    minChunkSize: overrides.minChunkSize ?? 16,
    maxRetries: overrides.maxRetries ?? 2,
    retryDelay: overrides.retryDelay ?? 5,
    retryBackoff: overrides.retryBackoff ?? 1,
    speedSampleWindow: overrides.speedSampleWindow ?? 500,
    speedLimit: overrides.speedLimit ?? 0,
    requestTimeout: overrides.requestTimeout ?? 5_000,
    ...(overrides.headers !== undefined ? { headers: overrides.headers } : {}),
    ...(overrides.journal !== undefined ? { journal: overrides.journal } : {}),
  };
  const global: GlobalConfig = {
    io,
    targetPath: overrides.targetPath ?? '/dl',
    cachePath: overrides.cachePath ?? '/dl',
    maxParallel: overrides.maxParallel ?? 3,
    speedLimit: overrides.speedLimit ?? 0,
    targetChunkCount: overrides.targetChunkCount ?? 4,
    minChunkSize: overrides.minChunkSize ?? 16,
    maxRetries: overrides.maxRetries ?? 2,
    retryDelay: overrides.retryDelay ?? 5,
    retryBackoff: overrides.retryBackoff ?? 1,
    speedSampleWindow: overrides.speedSampleWindow ?? 500,
    requestTimeout: overrides.requestTimeout ?? 5_000,
    headers: overrides.headers ?? {},
    journal: overrides.journal ?? false,
    sharedThrottle: new Throttle(overrides.speedLimit ?? 0),
  };
  return { fs, fetch, io, config, global };
}
