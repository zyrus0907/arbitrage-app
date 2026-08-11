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
    // T09: the integration suite needs a seeded database, a `node` environment
    // and seconds rather than milliseconds. It has its own config and its own
    // CI job (`npm run test:integration`); `npm test` stays runnable with no
    // Docker and no database.
    exclude: ['**/node_modules/**', '**/dist/**', '.next/**', 'tests/integration/**'],
    // T09: raised from vitest's 5000ms default, with the cause measured rather
    // than guessed. The first test in a React file pays a one-off jsdom + React
    // + module-graph warm-up of ~350ms that its siblings do not (they run in
    // 11–130ms). On an idle machine that is 13x inside the default budget; on a
    // contended CI runner executing twelve files in parallel it is not, and it
    // produced two false reds during T08 in exactly the two files whose first
    // test renders a full page. The failure was never a hang, so a larger
    // budget does not mask one — a genuine hang still fails, ten seconds later.
    testTimeout: 15_000,
  },
});
