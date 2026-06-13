import { cmdAdd } from './commands/add.ts';
import { cmdList } from './commands/list.ts';
import { cmdPause, cmdResume, cmdCancel, cmdClear } from './commands/pause.ts';
import { cmdStatus } from './commands/status.ts';
import { cmdWatch } from './commands/watch.ts';
import { ensureDaemon, sendRequest } from './client.ts';

const HELP = `
downloadx — download manager CLI

Usage:
  downloadx add <url> [--path <dir>] [--speed <bytes>]   Add and start a download
  downloadx list                                          List all downloads
  downloadx status <#|id> [--json]                       Detailed status for a download
  downloadx pause  <#|id|all>                            Pause one or all downloads
  downloadx resume <#|id|all>                            Resume one or all downloads
  downloadx cancel <#|id|all>                            Cancel one or all downloads
  downloadx clear  <#|id|all>                            Remove one or all from list
  downloadx watch [--simple|--json]                      Live progress view
  downloadx stop                                         Shut down the daemon

  downloadx set <key> <value> [--id <#|id>]              Set a config value
  downloadx get [key]                                    Get one or all config values

  Config keys: maxParallel, speedLimit, targetPath, cachePath
  Per-download keys (--id): speedLimit, targetPath
  <#> refers to the index shown by 'list' (e.g. 1, 2, #1, #2)
`.trim();

function cliError(msg: string): never {
  console.error(`error: ${msg}`);
  process.exit(1);
}

export async function runCli(argv: string[]): Promise<void> {
  const [cmd, ...args] = argv;

  switch (cmd) {
    case 'add': {
      const url = args.find((a) => !a.startsWith('--'));
      const pathIdx = args.indexOf('--path');
      const targetPath = pathIdx !== -1 ? args[pathIdx + 1] : undefined;
      if (!url) cliError('URL required. Usage: downloadx add <url> [--path <dir>]');
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
      if (!args[0]) cliError('Usage: downloadx pause <#|id|all>');
      try { await cmdPause(args[0]); }
      catch (e) { cliError(`Could not pause: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'resume': {
      if (!args[0]) cliError('Usage: downloadx resume <#|id|all>');
      try { await cmdResume(args[0]); }
      catch (e) { cliError(`Could not resume: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'cancel': {
      if (!args[0]) cliError('Usage: downloadx cancel <#|id|all>');
      try { await cmdCancel(args[0]); }
      catch (e) { cliError(`Could not cancel: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'clear': {
      if (!args[0]) cliError('Usage: downloadx clear <#|id|all>');
      try { await cmdClear(args[0]); }
      catch (e) { cliError(`Could not clear: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'status': {
      const id = args.find((a) => !a.startsWith('--'));
      if (!id) cliError('Usage: downloadx status <#|id> [--json]');
      try { await cmdStatus(id, args.includes('--json')); }
      catch (e) { cliError(`Could not get status: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'watch': {
      const simple = args.includes('--simple');
      try { await cmdWatch(simple, args.includes('--json')); }
      catch (e) { cliError(`Watch failed: ${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'set': {
      const idIdx = args.indexOf('--id');
      const id = idIdx !== -1 ? args[idIdx + 1] : undefined;
      if (idIdx !== -1 && !id) cliError('--id requires a value');
      const key = args.find((a) => !a.startsWith('--') && a !== id);
      const value = args.filter((a) => !a.startsWith('--') && a !== id && a !== key)[0];
      try {
        await ensureDaemon();
        const result = await sendRequest<string | null>({ cmd: 'set', key, value, ...(id ? { id } : {}) });
        if (result) console.log(result);
        else if (key && value) console.log(`Set ${key} = ${value}${id ? ` for download ${id}` : ''}`);
      } catch (e) { cliError(`${e instanceof Error ? e.message : e}`); }
      break;
    }
    case 'get': {
      try {
        await ensureDaemon();
        const result = await sendRequest({ cmd: 'get', key: args[0] });
        if (args[0]) {
          console.log(`${args[0]} = ${result}`);
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
