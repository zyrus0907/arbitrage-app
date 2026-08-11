import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

const rootDir = dirname(fileURLToPath(import.meta.url));

/**
 * T09 — the integration suite's own configuration.
 *
 * It is separate from `vitest.config.ts` for three reasons, none of them
 * cosmetic:
 *
 *   * ENVIRONMENT. The unit suite runs in `jsdom` because it renders React.
 *     These tests are HTTP clients talking to PostgREST and must run in `node`;
 *     jsdom supplies a `fetch` wired to a fake origin and a CORS model that has
 *     nothing to do with the thing under test.
 *   * PRECONDITIONS. `npm test` must stay runnable with no database — a
 *     developer checking a formatter should not need Docker. These tests fail
 *     loudly without a seeded stack, which is correct for them and wrong for
 *     the unit suite, so the two cannot share an include list.
 *   * TIME. Creating users, building a deal fixture and making ~90 round trips
 *     is seconds, not milliseconds.
 *
 * `npm test` therefore excludes `tests/integration/**` and CI runs this config
 * as its own job, after `supabase start` and `supabase db reset`.
 */
export default defineConfig({
  resolve: {
    alias: {
      '@': resolve(rootDir, 'src'),
    },
  },
  test: {
    globals: true,
    environment: 'node',
    include: ['tests/integration/**/*.test.ts'],
    // Sequential on purpose. The suite creates users, writes fixture rows and
    // asserts exact row counts against a shared database; two files racing each
    // other would produce failures that look like RLS defects and are not.
    fileParallelism: false,
    testTimeout: 30_000,
    hookTimeout: 120_000,
  },
});
