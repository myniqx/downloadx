import type { DownloadEntry } from '../../ipc.ts';
import { ensureDaemon, sendRequest } from '../client.ts';

export async function cmdAdd(url: string, targetPath?: string): Promise<void> {
  await ensureDaemon();
  const entry = await sendRequest<DownloadEntry>({
    cmd: 'add',
    url,
    ...(targetPath ? { targetPath } : {}),
  });
  console.log(`Added [${entry.id.slice(0, 8)}] ${url}`);
}
