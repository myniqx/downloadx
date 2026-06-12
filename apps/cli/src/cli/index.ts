import { cmdAdd } from './commands/add.ts';
import { cmdList } from './commands/list.ts';
import { cmdPause, cmdResume, cmdCancel, cmdClear } from './commands/pause.ts';
import { cmdStatus } from './commands/status.ts';
import { cmdWatch } from './commands/watch.ts';
import { ensureDaemon, sendRequest } from './client.ts';

const HELP = `
downloadx — download manager CLI

Usage:
  downloadx add <url> [--path <dir>]   Add and start a download
  downloadx list                        List all downloads
  downloadx status <id> [--json]        Detailed status report for a download
  downloadx pause <id>                  Pause a download
  downloadx resume <id>                 Resume a download
  downloadx cancel <id>                 Cancel a download
  downloadx clear <id>                  Remove a download from list
  downloadx watch [--simple|--json]     Live progress view (--json = NDJSON stream)
  downloadx stop                        Shut down the daemon
`.trim();

export async function runCli(argv: string[]): Promise<void> {
  const [cmd, ...args] = argv;

  switch (cmd) {
    case 'add': {
      const url = args.find((a) => !a.startsWith('--'));
      const pathIdx = args.indexOf('--path');
      const targetPath = pathIdx !== -1 ? args[pathIdx + 1] : undefined;
      if (!url) { console.error('Usage: downloadx add <url> [--path <dir>]'); process.exit(1); }
      await cmdAdd(url, targetPath);
      break;
    }
    case 'list': {
      await cmdList();
      break;
    }
    case 'pause': {
      if (!args[0]) { console.error('Usage: downloadx pause <id>'); process.exit(1); }
      await cmdPause(args[0]);
      break;
    }
    case 'resume': {
      if (!args[0]) { console.error('Usage: downloadx resume <id>'); process.exit(1); }
      await cmdResume(args[0]);
      break;
    }
    case 'cancel': {
      if (!args[0]) { console.error('Usage: downloadx cancel <id>'); process.exit(1); }
      await cmdCancel(args[0]);
      break;
    }
    case 'clear': {
      if (!args[0]) { console.error('Usage: downloadx clear <id>'); process.exit(1); }
      await cmdClear(args[0]);
      break;
    }
    case 'status': {
      const id = args.find((a) => !a.startsWith('--'));
      if (!id) { console.error('Usage: downloadx status <id> [--json]'); process.exit(1); }
      await cmdStatus(id, args.includes('--json'));
      break;
    }
    case 'watch': {
      const simple = args.includes('--simple');
      await cmdWatch(simple, args.includes('--json'));
      break;
    }
    case 'stop': {
      await ensureDaemon();
      await sendRequest({ cmd: 'shutdown' });
      console.log('Daemon stopped.');
      break;
    }
    default: {
      console.log(HELP);
      if (cmd) process.exit(1);
      break;
    }
  }
}
