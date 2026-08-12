/**
 * The route map, expressed as data so the proxy, the layouts and the tests all
 * read the same list (ARCHITECTURE.md §4.3).
 *
 * WHY AN ALLOWLIST RATHER THAN A LIST OF PROTECTED PREFIXES
 *
 * T10 and §6.1 say "middleware protects `/(app)/*` and `/admin/*`". A route
 * group is a source-tree convention: `src/app/(app)/settings/page.tsx` serves
 * `/settings`, and the parentheses never reach the URL. So the proxy cannot
 * match on `(app)` and must be given the paths in some other form.
 *
 * The obvious form is a list of protected prefixes. It is also the wrong one:
 * the day someone adds `src/app/(app)/reports/` and forgets to extend the list,
 * the new route is public and nothing goes red. The failure is silent and it
 * fails open.
 *
 * So this is inverted to match the default-deny posture the database already
 * takes (ADR-004): **everything requires a session unless it appears below.**
 * Forgetting to register a new public page produces a redirect to sign-in — a
 * visible, reported, fail-closed mistake. That trade is the whole point.
 */

/** Paths served to a visitor with no session. Everything else needs one. */
export const PUBLIC_PATHS = [
  '/', // marketing landing (dev dashboard until T28 replaces it)
  '/sign-in',
  '/sign-up',
  '/check-email',
  '/auth/callback',
  '/auth/sign-out',
] as const;

/** Prefixes served without a session — public subtrees rather than exact paths. */
export const PUBLIC_PREFIXES = ['/legal/'] as const;

export const SIGN_IN_PATH = '/sign-in';
export const ONBOARDING_PATH = '/onboarding';
export const WAITLIST_PATH = '/waitlist';
/** Where a signed-in, onboarded user lands. */
export const APP_HOME_PATH = '/feed';

/**
 * The query parameter carrying the originally-requested route through sign-in
 * (AC1.3). Read back only through `safeRedirectPath`, never used raw.
 */
export const RETURN_TO_PARAM = 'next';

export function isPublicPath(pathname: string): boolean {
  if ((PUBLIC_PATHS as readonly string[]).includes(pathname)) return true;
  return (PUBLIC_PREFIXES as readonly string[]).some((prefix) => pathname.startsWith(prefix));
}
