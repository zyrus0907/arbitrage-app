import 'server-only';

import { redirect } from 'next/navigation';

import { ONBOARDING_PATH, SIGN_IN_PATH, WAITLIST_PATH, APP_HOME_PATH } from '@/lib/auth/routes';
import { currentAuthContext, type AuthContext } from '@/lib/auth/session';

/**
 * The gates every protected page runs through (T10).
 *
 * These live in the pages rather than in the `(app)` layout because the layout
 * also wraps `/onboarding` and `/waitlist`. A stage gate in the layout would
 * redirect an un-onboarded user to onboarding, from a layout that wraps
 * onboarding, forever.
 *
 * The authentication gate is in the layout as well as here, so a page that
 * forgot to call one of these still renders nothing for a signed-out visitor.
 * Three independent layers now say no to an unauthenticated request — the
 * proxy, the layout, and RLS on every row the page would have read — and the
 * last of those is the only one that cannot be bypassed by a routing mistake.
 */

/** A verified session, or a redirect to sign-in. */
export async function requireAuth(): Promise<AuthContext> {
  const context = await currentAuthContext();
  // No `next` is attached: the proxy already captured the intended route for a
  // request that arrived without a session, and this path is reached only when
  // the session died mid-render, where there is no reliable pathname to carry.
  if (!context) redirect(SIGN_IN_PATH);
  return context;
}

/** A verified session that has finished onboarding, or a redirect to the step it is on. */
export async function requireOnboarded(): Promise<AuthContext> {
  const context = await requireAuth();
  if (context.stage === 'waitlisted') redirect(WAITLIST_PATH);
  if (context.stage === 'onboarding') redirect(ONBOARDING_PATH);
  return context;
}

/** For the onboarding and waitlist screens themselves: send finished users on. */
export async function requireUnonboarded(): Promise<AuthContext> {
  const context = await requireAuth();
  if (context.stage === 'ready') redirect(APP_HOME_PATH);
  return context;
}
