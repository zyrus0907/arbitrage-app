import Link from 'next/link';

import { requireAuth } from '@/lib/auth/guards';
import { hasServiceRoleKey } from '@/lib/env';
import { createAdminClient } from '@/lib/supabase/admin';
import { messages } from '@/messages/en';
import { ensureSignupGrant } from '@/services/credits/signup-grant';

/**
 * The authenticated shell (§4.3).
 *
 * Two responsibilities, both server-side:
 *
 * 1. **The authoritative auth gate.** `requireAuth` calls `getUser()`, which
 *    revalidates the token with the Auth server, and refuses a tombstoned
 *    profile. The proxy has usually done this already; this is the layer that
 *    makes the guarantee, because it is inside the render rather than in front
 *    of it.
 *
 * 2. **The signup credit grant (AC10.6),** completed here rather than only in
 *    the sign-up action so a request that failed midway does not silently cost
 *    the user their five credits. It runs only while the account is not yet
 *    onboarded, which every user passes through exactly once, so an onboarded
 *    user pays no round-trip for it on every page. The call is idempotent on a
 *    key derived from the user id, so running it here, in the action, or twice
 *    in the same second all produce exactly one ledger row.
 */
export const dynamic = 'force-dynamic';

export default async function AppLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const { user, profile } = await requireAuth();

  if (profile.onboarded_at === null && hasServiceRoleKey()) {
    // Failure is not fatal to the page: the user can still use the app, the
    // next render retries, and the alternative — blocking the whole authed
    // surface on a credit grant — is worse for a five-credit trial. The
    // `hasServiceRoleKey` check is the same reasoning one level up: an
    // environment with no service-role key should render a degraded app, not
    // throw out of a layout and take every authenticated route with it.
    await ensureSignupGrant(createAdminClient(), user.id);
  }

  return (
    <div className="mx-auto flex min-h-dvh w-full max-w-3xl flex-col px-6 py-8">
      <header className="mb-8 flex items-center justify-between gap-4 border-b border-black/10 pb-4 dark:border-white/15">
        <Link href="/" className="text-sm font-semibold tracking-tight">
          {messages.app.name}
        </Link>
        <nav className="flex items-center gap-4 text-sm">
          <Link className="underline-offset-4 hover:underline" href="/settings">
            {messages.settings.title}
          </Link>
          {/* POST, not a link: a GET sign-out is CSRF-able and prefetchable. */}
          <form action="/auth/sign-out" method="post">
            <button type="submit" className="underline-offset-4 hover:underline">
              {messages.auth.signOut}
            </button>
          </form>
        </nav>
      </header>
      <main className="flex-1">{children}</main>
    </div>
  );
}
