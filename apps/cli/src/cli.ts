import { runCli } from './cli/index.ts';
import { runDaemon } from './daemon/index.ts';

const argv = process.argv.slice(2);

try {
  if (argv[0] === '--daemon') {
    await runDaemon();
  } else {
    await runCli(argv);
  }
} catch (err) {
  const msg = err instanceof Error ? err.message : String(err);
  console.error(`error: ${msg}`);
  process.exit(1);
}
