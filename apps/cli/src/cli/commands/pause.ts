import { ensureDaemon, sendRequest } from '../client.ts';

export async function cmdPause(id: string): Promise<void> {
  await ensureDaemon();
  await sendRequest({ cmd: 'pause', id });
  console.log(`Paused ${id}`);
}

export async function cmdResume(id: string): Promise<void> {
  await ensureDaemon();
  await sendRequest({ cmd: 'resume', id });
  console.log(`Resumed ${id}`);
}

export async function cmdCancel(id: string): Promise<void> {
  await ensureDaemon();
  await sendRequest({ cmd: 'cancel', id });
  console.log(`Cancelled ${id}`);
}

export async function cmdClear(id: string): Promise<void> {
  await ensureDaemon();
  await sendRequest({ cmd: 'clear', id });
  console.log(`Cleared ${id}`);
}
