import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

const rootDir = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  // The test transform is told explicitly to use React's automatic JSX runtime.
  // This is why no React Vite plugin is needed here — nothing under test
  // requires Fast Refresh, and the plugin's Vite version conflicts with the one
  // Vitest bundles.
  esbuild: { jsx: 'automatic' },
  resolve: {
    alias: {
      '@': resolve(rootDir, 'src'),
    },
  },
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: ['./tests/setup.ts'],
    include: ['tests/**/*.test.ts', 'tests/**/*.test.tsx', 'src/**/*.test.ts', 'src/**/*.test.tsx'],
  },
});
