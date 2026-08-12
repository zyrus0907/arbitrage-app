import { createServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';

import { requirePublicSupabaseEnv } from '@/lib/env';
import { sessionCookieOptions } from '@/lib/supabase/cookies';
import type { Database } from '@/types/database';

/**
 * Server Supabase client — ARCHITECTURE.md §6.2, row 2.
 *
 * Anon key **plus the caller's session**, read from and written back to the
 * request cookie jar. It does **not** bypass RLS: every query still runs as the
 * signed-in user (or as `anon` when there is no session), which is what makes
 * RLS the real authorisation boundary rather than a formality.
 *
 * App Router notes:
 *  - `cookies()` is async in Next.js 16, so this factory is async.
 *  - `@supabase/ssr` requires the `getAll`/`setAll` cookie interface; the
 *    single-cookie `get`/`set`/`remove` form is removed.
 *  - Server Components may not mutate cookies. The `setAll` write is therefore
 *    wrapped in a try/catch: in a Server Component the refreshed token is
 *    simply not persisted, and the session refresh done by the middleware
 *    (T10) covers that case. Swallowing the error here is deliberate, not an
 *    oversight — see `docs/DECISIONS.md` ADR-0004.
 */
export async function createClient() {
  const { url, anonKey } = requirePublicSupabaseEnv();
  const cookieStore = await cookies();

  return createServerClient<Database>(url, anonKey, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          for (const { name, value, options } of cookiesToSet) {
            // httpOnly is forced here, not inherited: @supabase/ssr's defaults
            // leave the auth cookies readable by JavaScript. See cookies.ts.
            cookieStore.set(name, value, sessionCookieOptions(options));
          }
        } catch {
          // Called from a Server Component, where the cookie jar is read-only.
        }
      },
    },
  });
}

export type ServerClient = Awaited<ReturnType<typeof createClient>>;
