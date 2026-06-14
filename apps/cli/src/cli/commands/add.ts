import type { DownloadDescription } from '@downloadx/core';
import { ensureDaemon, sendRequest } from '../client.ts';

export async function cmdAdd(url: string, targetPath?: string): Promise<void> {
  await ensureDaemon();
  const entry = await sendRequest<DownloadDescription>({
    cmd: 'add',
    url,
    ...(targetPath ? { targetPath } : {}),
  });
  console.log(`Added [${entry.id.slice(0, 8)}] ${url}`);
}
