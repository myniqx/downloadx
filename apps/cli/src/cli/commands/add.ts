"use strict";

import type { DownloadDescription } from '@downloadx/core';
import { LOCAL_KEYS } from '../../daemon/config-keys.ts';
import { ensureDaemon, sendRequest } from '../client.ts';

/**
 * Scans argv for --url, --filename, and any per-download config flags
 * (--speedLimit, --targetPath, --targetChunkCount, --minChunkSize, --journal).
 * Flag names are case-insensitive and matched against LOCAL_KEYS.
 */
export function parseAddOptions(args: string[]): {
  url: string | undefined;
  filename: string | undefined;
  options: Record<string, string>;
} {
  const localFlagMap = new Map(LOCAL_KEYS.map((d) => [d.canonical.toLowerCase(), d.canonical]));

  let url: string | undefined;
  let filename: string | undefined;
  const options: Record<string, string> = {};

  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? '';
    if (!arg.startsWith('--')) continue;

    const flag = arg.slice(2).toLowerCase();
    const value = args[i + 1];
    if (!value || value.startsWith('--')) continue;

    if (flag === 'url') { url = value; i++; continue; }
    if (flag === 'filename') { filename = value; i++; continue; }

    const canonical = localFlagMap.get(flag);
    if (canonical) { options[canonical] = value; i++; }
  }

  return { url, filename, options };
}

export async function cmdAdd(
  url: string,
  filename: string | undefined,
  options: Record<string, string>,
): Promise<void> {
  await ensureDaemon();
  const entry = await sendRequest<DownloadDescription>({
    cmd: 'add',
    url,
    ...(filename !== undefined && { filename }),
    ...(Object.keys(options).length > 0 && { options }),
  });
  console.log(`Added [${entry.id.slice(0, 8)}] ${entry.filename ?? url}`);
}
