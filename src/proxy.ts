/**
 * Session refresh and the logged-out redirect (T10, AC1.3, AC1.4, §6.1).
 *
 * WHY `proxy.ts` AND NOT `middleware.ts`
 *
 * T10 and `src/app/(app)/README.md` both name `src/middleware.ts`. This repo is
 * on Next.js 16, where Middleware was renamed to Proxy and the file convention
 * is `proxy.ts` at the same level as `app/` — see
 * `node_modules/next/dist/docs/01-app/01-getting-started/16-proxy.md`. The
 * functionality is unchanged; the filename is not. Following the framework the
 * repo actually depends on beats following the task description's filename, and
 * the deviation is recorded in ADR-0017.
 *
 * WHAT THIS FILE IS RESPONSIBLE FOR, AND WHAT IT IS NOT
 *
 * Next's own guidance is explicit that Proxy "should not be used as a full
 * session management or authorization solution" and is for optimistic checks.
 * That is exactly the split taken here, and it is a security property rather
 * than a style preference:
 *
 *   * PROXY (this file) — refreshes the Supabase session so a token that
 *     expired between requests is renewed and written back as httpOnly cookies,
 *     and bounces a request with no session at all to sign-in with `?next=`.
 *     It performs no database query and makes no authorization decision beyond
 *     "is there a user".
 *
 *   * LAYOUT (`src/app/(app)/layout.tsx`) — the authoritative check. It calls
 *     `getUser()` again on the server, loads the profile, and enforces the
 *     onboarding gate and the tombstone gate before rendering anything. A
 *     protected page therefore never depends on the proxy having run: if this
 *     file were deleted tomorrow, every protected route would still refuse to
 *     render for an unauthenticated caller. The proxy improves the experience;
 *     the layout and RLS provide the guarantee.
 *
 * `getUser()` is used rather than `getSession()`. `getSession()` returns
 * whatever the cookie says without verifying it; `getUser()` revalidates the
 * token with the Auth server. That difference is what makes a deleted account's
 * still-unexpired JWT fail here rather than sail through (T10 deletion
 * requirement: an old session cannot continue accessing protected content).
 */
import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';

import { signInUrlFor } from '@/lib/auth/redirect';
import { isPublicPath } from '@/lib/auth/routes';
import { requirePublicSupabaseEnv } from '@/lib/env';
import { sessionCookieOptions } from '@/lib/supabase/cookies';
import type { Database } from '@/types/database';

export async function proxy(request: NextRequest) {
  const { pathname, search } = request.nextUrl;

  // The anon key and nothing else. There is no service-role key in this file,
  // and there must never be one: the proxy bundle runs on every matched request
  // and is the least contained place in the application.
  const { url, anonKey } = requirePublicSupabaseEnv();

  let response = NextResponse.next({ request });

  const supabase = createServerClient<Database>(url, anonKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet) {
        // Two writes, both required. The request copy is what any Server
        // Component rendered downstream in THIS request will read; the response
        // copy is what the browser stores for the next one. Writing only the
        // response leaves the current render using the stale token.
        for (const { name, value } of cookiesToSet) {
          request.cookies.set(name, value);
        }
        response = NextResponse.next({ request });
        for (const { name, value, options } of cookiesToSet) {
          // Forced httpOnly — @supabase/ssr does not do this for us (AC1.4).
          response.cookies.set(name, value, sessionCookieOptions(options));
        }
      },
    },
  });

  // Refreshes the session as a side effect when the access token has expired.
  // The result is deliberately not trusted for anything but the redirect below.
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // API routes are never redirected. A JSON client that asked for
  // `/api/v1/profile` and received a 307 to an HTML sign-in page gets a parse
  // error where it should have got a 401 it can act on. The handlers do their
  // own authentication and return the §5.2 failure envelope, so the only thing
  // the proxy owes them is the refreshed cookie jar.
  const isApi = pathname.startsWith('/api/');

  if (!user && !isApi && !isPublicPath(pathname)) {
    const redirect = NextResponse.redirect(
      new URL(signInUrlFor(`${pathname}${search}`), request.url),
    );
    // Carry any cookie the refresh attempt just cleared. Without this, a
    // request that fails to refresh keeps presenting the same dead cookie on
    // every subsequent request and never settles.
    for (const cookie of response.cookies.getAll()) {
      redirect.cookies.set(cookie);
    }
    return redirect;
  }

  return response;
}

export const config = {
  /**
   * Everything except Next's build output, the favicon and static image
   * requests. Auth routes are matched deliberately — `/auth/callback` needs the
   * refreshed cookie jar as much as any other route, and `isPublicPath` is what
   * keeps it from being redirected.
   */
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)'],
};
