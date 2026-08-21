/**
 * The development dashboard's runtime gate (T11 finding F2).
 *
 * `/` served the dashboard to anonymous callers in every environment, and the
 * dashboard's data layer runs service-role aggregate queries. In production
 * that is an unauthenticated caller causing privileged reads — row counts,
 * deal-lifecycle totals and credential-configuration status — with no session
 * involved at all.
 *
 * THE GATE IS `NODE_ENV`, AND DELIBERATELY NOTHING MORE.
 *
 * There is no `ENABLE_DEV_DASHBOARD` escape hatch, because an escape hatch is
 * exactly the thing that gets set in a production environment "temporarily".
 * `NODE_ENV` is inlined by Next at build time, so a production build cannot be
 * talked into `true` by an environment variable at runtime.
 *
 * This module reads `process.env.NODE_ENV` directly rather than importing
 * `@/lib/env`: `tests/unit/dev-dashboard/isolation.test.ts` asserts that
 * `snapshot.ts` is the only module in this directory that touches the
 * environment module, and that boundary is worth more than the type wrapper.
 *
 * The gate must be checked BEFORE the snapshot module is imported — see
 * `src/app/page.tsx`. Rendering the queries and then hiding the markup would
 * leave the privileged reads happening on every anonymous production request,
 * which is the finding, not a fix for it.
 */
export function devDashboardEnabled(nodeEnv: string | undefined = process.env.NODE_ENV): boolean {
  return nodeEnv !== 'production';
}
