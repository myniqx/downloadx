"use strict";

import type { DownloadDescription } from '@downloadx/core';
import { LOCAL_KEYS } from '../../daemon/config-keys.ts';
import { ensureDaemon, sendRequest } from '../client.ts';

/**
 * Scans argv for --url and any per-download config flags including dot-notation
 * object keys (--metadata.key value, --header.Key value, --filename name, etc.).
 * Flag names are case-insensitive and matched against LOCAL_KEYS canonical names.
 */
export function parseAddOptions(args: string[]): {
  url: string | undefined;
  options: Record<string, string>;
} {
  const localFlagMap = new Map(LOCAL_KEYS.map((d) => [d.canonical.toLowerCase(), d.canonical]));

  let url: string | undefined;
  const options: Record<string, string> = {};

  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? '';
    if (!arg.startsWith('--')) continue;

    const flag = arg.slice(2);
    const flagLower = flag.toLowerCase();
    const value = args[i + 1];
    if (!value || value.startsWith('--')) continue;

    if (flagLower === 'url') { url = value; i++; continue; }

    const dotIdx = flag.indexOf('.');
    if (dotIdx !== -1) {
      const baseFlag = flag.slice(0, dotIdx).toLowerCase();
      const subKey = flag.slice(dotIdx + 1);
      const canonical = localFlagMap.get(baseFlag);
      if (canonical) { options[`${canonical}.${subKey}`] = value; i++; }
      continue;
    }

    const canonical = localFlagMap.get(flagLower);
    if (canonical) { options[canonical] = value; i++; }
  }

  return { url, options };
}

export async function cmdAdd(
  url: string,
  options: Record<string, string>,
): Promise<void> {
  await ensureDaemon();
  const entry = await sendRequest<DownloadDescription>({
    cmd: 'add',
    url,
    ...(Object.keys(options).length > 0 && { options }),
  });
  console.log(`Added [${entry.id.slice(0, 8)}] ${entry.filename ?? url}`);
}
