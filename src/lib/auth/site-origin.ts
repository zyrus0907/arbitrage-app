import 'server-only';

import { resolveSiteOrigin, type OriginEnv } from '@/lib/auth/origin';
import { publicEnv } from '@/lib/env';

/**
 * The server-only binding of the origin resolver to the real environment.
 *
 * `import 'server-only'` is the first line and must stay there: this module
 * reads `VERCEL_ENV`, `VERCEL_BRANCH_URL` and `VERCEL_URL`, which are
 * server-side system variables. They are **not** exposed through any
 * `NEXT_PUBLIC_*` variable, and importing this file from a Client Component
 * fails the build rather than shipping a resolver that would silently return
 * the wrong answer in a browser.
 *
 * The logic itself is in `origin.ts`, pure and unit-tested. This file exists
 * only to supply the environment.
 */
export function siteOrigin(): string {
  // Read as static literals rather than through a loop: `process.env` is
  // special-cased by the bundler, and a dynamic lookup is not always resolved.
  const env: OriginEnv = {
    VERCEL_ENV: process.env.VERCEL_ENV,
    VERCEL_BRANCH_URL: process.env.VERCEL_BRANCH_URL,
    VERCEL_URL: process.env.VERCEL_URL,
  };

  return resolveSiteOrigin(env, publicEnv.NEXT_PUBLIC_SITE_URL);
}
