/**
 * Deployment origin resolution (T10).
 *
 * THE PROBLEM THIS SOLVES
 *
 * `NEXT_PUBLIC_SITE_URL` is a single configured value, but a Vercel Preview
 * deployment does not have a knowable URL at configuration time — it gets a new
 * one per branch and per deployment. Pointing Preview at the production URL
 * would send a preview user's verification link to production, where they would
 * be signed in to the wrong deployment; leaving it unset fails `env.ts`'s
 * required `z.url()` at boot. Neither is acceptable, and no static value can
 * express "this deployment's own origin", so it is resolved at runtime.
 *
 * WHY THE LOGIC LIVES HERE, PURE, AND NOT BEHIND `server-only`
 *
 * The functions below take their environment as an argument and read no
 * globals, so they are unit-testable without a server runtime. The `server-only`
 * boundary is `site-origin.ts`, which is the module that actually reads
 * `process.env` — the same split already used for `grant-key.ts` and
 * `signup-grant.ts`, and for the same reason.
 *
 * **`VERCEL_*` variables are read server-side only and are never mirrored into a
 * `NEXT_PUBLIC_*` variable.** Next.js inlines only `NEXT_PUBLIC_*` into the
 * client bundle, so these values cannot reach a browser; `npm run scan:bundle`
 * asserts that rather than assuming it.
 *
 * REQUEST HEADERS ARE DELIBERATELY NOT A SOURCE. The `Host` and
 * `X-Forwarded-Host` headers are attacker-controlled on many deployments, and
 * an email link built from one is a host-header poisoning primitive — the
 * classic password-reset-link-to-attacker attack. Only Vercel's own injected
 * system variables and the configured site URL are trusted here.
 */

/** The subset of the environment this module reads. */
export type OriginEnv = {
  VERCEL_ENV?: string | undefined;
  VERCEL_BRANCH_URL?: string | undefined;
  VERCEL_URL?: string | undefined;
};

/**
 * Turns a Vercel-supplied host into a bare, validated hostname, or `null`.
 *
 * Vercel documents `VERCEL_URL` and `VERCEL_BRANCH_URL` as **not** including a
 * protocol. A scheme is nevertheless stripped defensively rather than trusted
 * to be absent, because the failure mode if that ever changed is
 * `https://https://…` — a malformed absolute URL in an email nobody can recall.
 *
 * Everything that is not a plain `host[:port]` is rejected: a value containing
 * a path, a query, an `@` (which would relocate the host in a way that reads as
 * legitimate), whitespace or a control character is not something to guess
 * about.
 */
export function normaliseDeploymentHost(value: string | undefined | null): string | null {
  if (typeof value !== 'string') return null;

  let host = value.trim();
  if (host === '') return null;

  host = host.replace(/^https?:\/\//i, '');
  host = host.replace(/\/+$/, '');

  // Bare host, optional port. Rejects paths, credentials, spaces, wildcards and
  // anything with a slash left in it after the trailing-slash trim above.
  if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:\d{1,5})?$/i.test(host)) {
    return null;
  }

  return host;
}

/**
 * The absolute origin this deployment should use for links it sends out.
 *
 *  - **Preview** → `https://<VERCEL_BRANCH_URL>`, falling back to
 *    `https://<VERCEL_URL>`, falling back to `siteUrl`.
 *  - **Anything else** (production, local development) → `siteUrl`.
 *
 * `VERCEL_BRANCH_URL` is preferred over `VERCEL_URL` deliberately: the branch
 * URL is stable across re-deploys of the same branch, while `VERCEL_URL` is
 * unique per deployment. A verification link sitting in someone's inbox stays
 * valid across a re-deploy with the branch URL and dies with the deployment URL.
 *
 * `siteUrl` is the last resort in every path, so a preview with system
 * variables disabled degrades to a working-but-wrong-origin link rather than
 * throwing in the middle of a signup.
 */
export function resolveSiteOrigin(env: OriginEnv, siteUrl: string): string {
  if (env.VERCEL_ENV === 'preview') {
    const host =
      normaliseDeploymentHost(env.VERCEL_BRANCH_URL) ?? normaliseDeploymentHost(env.VERCEL_URL);
    if (host) return `https://${host}`;
  }

  // Normalised so callers can concatenate without worrying about a trailing
  // slash producing `//auth/callback`.
  return siteUrl.replace(/\/+$/, '');
}

/**
 * The absolute URL Supabase returns the browser to after a magic link or an
 * email verification.
 *
 * Built from a resolved origin plus an already-validated same-origin path. The
 * `next` value must have been through `safeRedirectPath` before it reaches
 * here; this function does not re-validate it, it only assembles.
 */
export function buildAuthCallbackUrl(origin: string, next: string, param: string): string {
  const url = new URL('/auth/callback', origin);
  url.searchParams.set(param, next);
  return url.toString();
}
