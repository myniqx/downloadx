import { defineConfig } from 'tsup';

export default defineConfig({
  entry: ['src/cli.ts'],
  format: ['esm'],
  outDir: 'dist',
  platform: 'node',
  bundle: true,
  splitting: false,
  banner: {
    js: '#!/usr/bin/env node',
  },
});
