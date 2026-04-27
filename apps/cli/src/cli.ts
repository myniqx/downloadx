import { runDaemon } from './daemon/index.ts';
import { runCli } from './cli/index.ts';

const argv = process.argv.slice(2);

if (argv[0] === '--daemon') {
  await runDaemon();
} else {
  await runCli(argv);
}
