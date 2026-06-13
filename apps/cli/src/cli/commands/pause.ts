import { createInterface } from 'node:readline';

import type { DownloadEntry } from '../../ipc.ts';
import { ensureDaemon, sendRequest } from '../client.ts';

async function confirm(question: string): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(`${question} [y/N] `, (answer) => {
      rl.close();
      resolve(answer.trim().toLowerCase() === 'y');
    });
  });
}

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

export async function cmdClear(
  target: string,
  opts: { force?: boolean; completed?: boolean; all?: boolean },
): Promise<void> {
  await ensureDaemon();
  const entries = await sendRequest<DownloadEntry[]>({ cmd: 'list' });

  if (opts.all) {
    const toDelete = opts.completed ? entries.filter((e) => e.status === 'completed') : entries;
    const incomplete = toDelete.filter((e) => e.status !== 'completed');

    if (incomplete.length > 0 && !opts.force) {
      const ok = await confirm(
        `${incomplete.length} incomplete download(s) and their .part files will be deleted. Continue?`,
      );
      if (!ok) {
        console.log('Aborted.');
        return;
      }
    }

    await Promise.all(toDelete.map((e) => sendRequest({ cmd: 'clear', id: e.id })));
    console.log(`Cleared ${toDelete.length} download(s).`);
    return;
  }

  if (opts.completed) {
    const done = entries.filter((e) => e.status === 'completed');
    await Promise.all(done.map((e) => sendRequest({ cmd: 'clear', id: e.id })));
    console.log(`Cleared ${done.length} completed download(s).`);
    return;
  }

  const entry = entries.find((e, i) => {
    const idx = target.replace(/^#/, '');
    return e.id === target || e.id.startsWith(target) || String(i + 1) === idx;
  });
  if (!entry) throw new Error(`No download matching '${target}'`);

  if (entry.status !== 'completed' && !opts.force) {
    const ok = await confirm(
      `Download is not finished. Its .part files will be deleted. Continue?`,
    );
    if (!ok) {
      console.log('Aborted.');
      return;
    }
  }

  await sendRequest({ cmd: 'clear', id: entry.id });
  console.log(`Cleared ${entry.id.slice(0, 8)}.`);
}

export async function cmdRestart(
  target: string,
  opts: { force?: boolean; all?: boolean },
): Promise<void> {
  await ensureDaemon();
  const entries = await sendRequest<DownloadEntry[]>({ cmd: 'list' });

  if (opts.all) {
    if (!opts.force) {
      const ok = await confirm(
        `All ${entries.length} download(s) will be restarted from scratch and their .part files deleted. Continue?`,
      );
      if (!ok) {
        console.log('Aborted.');
        return;
      }
    }
    await Promise.all(entries.map((e) => sendRequest({ cmd: 'restart', id: e.id })));
    console.log(`Restarted ${entries.length} download(s).`);
    return;
  }

  const entry = entries.find((e, i) => {
    const idx = target.replace(/^#/, '');
    return e.id === target || e.id.startsWith(target) || String(i + 1) === idx;
  });
  if (!entry) throw new Error(`No download matching '${target}'`);

  if (!opts.force) {
    const name = entry.filename ?? entry.url.split('/').pop() ?? entry.id.slice(0, 8);
    const ok = await confirm(
      `"${name}" will be restarted from scratch and its .part files deleted. Continue?`,
    );
    if (!ok) {
      console.log('Aborted.');
      return;
    }
  }

  await sendRequest({ cmd: 'restart', id: entry.id });
  console.log(`Restarted ${entry.id.slice(0, 8)}.`);
}
