import { cmdAdd } from './commands/add.ts';
import { cmdList } from './commands/list.ts';
import { cmdPause, cmdResume, cmdRestart, cmdCancel, cmdClear } from './commands/pause.ts';
import { cmdStatus } from './commands/status.ts';
import { cmdWatch } from './commands/watch.ts';
import { ensureDaemon, sendRequest } from './client.ts';

const HELP = `
downloadx — download manager CLI

Usage:
  downloadx add --url <url> [--path <dir>] [--speed <bytes>]   Add and start a download
  downloadx list                                          List all downloads
  downloadx status --id <#|id> [--json]                  Detailed status for a download
  downloadx pause  --id <#|id> | --all                   Pause one or all downloads
  downloadx resume --id <#|id> | --all                   Resume one or all downloads
  downloadx restart --id <#|id> [--force] | --all        Restart from scratch
  downloadx cancel --id <#|id> | --all                   Cancel one or all downloads
  downloadx clear  --id <#|id> [--force]                 Remove from list (confirms if incomplete)
  downloadx clear  --all [--force]                       Remove all (confirms incomplete ones)
  downloadx clear  --completed                           Remove only completed downloads
  downloadx watch [--simple|--json]                      Live progress view
  downloadx stop                                         Shut down the daemon

  downloadx set <key> <value> [--id <#|id>]              Set a config value
  downloadx get [key] [--id <#|id>]                      Get one or all config values

  Config keys: maxParallel, speedLimit, targetPath, cachePath, targetChunkCount, minChunkSize, journal
  Per-download keys (--id): speedLimit, targetPath, targetChunkCount, minChunkSize, journal
  <#> refers to the index shown by 'list' (e.g. 1, 2, #1, #2)
`.trim();

function cliError(msg: string): never {
  console.error(`error: ${msg}`);
  process.exit(1);
}

function makeArgParser(args: string[]) {
  function argBoolean(flag: string): boolean {
    return args.includes(flag);
  }

  function argString(flag: string): string | undefined {
    const idx = args.indexOf(flag);
    if (idx === -1) return undefined;
    const val = args[idx + 1];
    if (!val || val.startsWith('--')) cliError(`${flag} requires a value`);
    return val;
  }

  const positional = args.filter((a, i) => {
    if (a.startsWith('--')) return false;
    const prev = args[i - 1];
    return !prev?.startsWith('--');
  });

  return { argBoolean, argString, positional };
}

export async function runCli(argv: string[]): Promise<void> {
  const [cmd, ...args] = argv;
  const { argBoolean, argString, positional } = makeArgParser(args);

  const all       = argBoolean('--all');
  const force     = argBoolean('--force');
  const completed = argBoolean('--completed');
  const json      = argBoolean('--json');
  const simple    = argBoolean('--simple');
  const overlayId = argString('--id');

  switch (cmd) {
    case 'add': {
      const url        = argString('--url');
      const targetPath = argString('--path');
      if (!url) cliError('Usage: downloadx add --url <url> [--path <dir>]');
      try { await cmdAdd(url, targetPath); }
      catch (e) { cliError(`Could not add download: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'list': {
      try { await cmdList(); }
      catch (e) { cliError(`Could not list downloads: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'pause': {
      if (!all && !overlayId) cliError('Usage: downloadx pause --id <#|id> | --all');
      try { await cmdPause(all ? 'all' : overlayId!); }
      catch (e) { cliError(`Could not pause: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'resume': {
      if (!all && !overlayId) cliError('Usage: downloadx resume --id <#|id> | --all');
      try { await cmdResume(all ? 'all' : overlayId!); }
      catch (e) { cliError(`Could not resume: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'restart': {
      if (!all && !overlayId) cliError('Usage: downloadx restart --id <#|id> [--force] | --all');
      try { await cmdRestart(all ? '' : overlayId!, { force, all }); }
      catch (e) { cliError(`Could not restart: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'cancel': {
      if (!all && !overlayId) cliError('Usage: downloadx cancel --id <#|id> | --all');
      try { await cmdCancel(all ? 'all' : overlayId!); }
      catch (e) { cliError(`Could not cancel: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'clear': {
      if (!all && !completed && !overlayId) cliError('Usage: downloadx clear --id <#|id> [--force] | --all [--force] | --completed');
      try { await cmdClear(overlayId ?? '', { force, completed, all }); }
      catch (e) { cliError(`Could not clear: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'status': {
      if (!overlayId) cliError('Usage: downloadx status --id <#|id> [--json]');
      try { await cmdStatus(overlayId, json); }
      catch (e) { cliError(`Could not get status: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'watch': {
      try { await cmdWatch(simple, json); }
      catch (e) { cliError(`Watch failed: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'set': {
      const key   = positional[0];
      const value = positional[1];
      try {
        await ensureDaemon();
        const result = await sendRequest<string | null>({ cmd: 'set', key, value, ...(overlayId ? { id: overlayId } : {}) });
        if (result) console.log(result);
        else if (key && value) console.log(`Set ${key} = ${value}${overlayId ? ` for download ${overlayId}` : ''}`);
      } catch (e) { cliError(`${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'get': {
      const key = positional[0];
      try {
        await ensureDaemon();
        const result = await sendRequest({ cmd: 'get', key, ...(overlayId ? { id: overlayId } : {}) });
        if (key) {
          console.log(`${key} = ${result}`);
        } else {
          for (const [k, v] of Object.entries(result as Record<string, unknown>)) {
            console.log(`${k} = ${v}`);
          }
        }
      } catch (e) { cliError(`${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'stop': {
      try {
        await ensureDaemon();
        await sendRequest({ cmd: 'shutdown' });
        console.log('Daemon stopped.');
      } catch (e) { cliError(`Could not stop daemon: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    default: {
      console.log(HELP);
      if (cmd) process.exit(1);
      break;
    }
  }
}
