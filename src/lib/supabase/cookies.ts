import type { CookieOptions } from '@supabase/ssr';

/**
 * The session cookie policy (T10, AC1.4).
 *
 * **`@supabase/ssr` does NOT set `httpOnly` by default, and this file exists
 * because of that.** Its defaults deliberately leave the auth cookies readable
 * by JavaScript, so that `createBrowserClient` can pick the session up on the
 * client. `ARCHITECTURE.md` §6.2 and T02's completion note both describe the
 * server client as using "httpOnly cookies" — that was an assumption about the
 * library, not a property of it, and T10's integration suite is what turned it
 * into a measured fact by asserting the flag on a real `Set-Cookie` header.
 *
 * AC1.4 asks that session tokens are never present in client-readable storage.
 * A non-httpOnly cookie is client-readable storage: `document.cookie` reaches it
 * and so does any injected script. So every cookie this application writes is
 * forced httpOnly here.
 *
 * **The consequence is deliberate and load-bearing:** `createBrowserClient` can
 * no longer see the session. Nothing in T10 asks it to — authentication runs in
 * Server Actions, every protected page is server-rendered, and the browser
 * client is left for anon reads of public reference data. A future task that
 * wants a client-side authenticated Supabase call must route it through a
 * server handler rather than relax this.
 *
 * `sameSite: 'lax'` rather than `'strict'`: the magic-link and email
 * verification flows return the user from their mail client as a cross-site
 * top-level navigation, and `strict` withholds the cookie on exactly that
 * request — the user would land back on the app signed out.
 */

/**
 * Whether the connection this cookie will travel over is HTTPS.
 *
 * **Derived from runtime environment semantics, not from a hostname string.**
 * An earlier version keyed this off whether `NEXT_PUBLIC_SITE_URL` began with
 * `https://`, which was wrong in both directions: that variable describes the
 * *configured canonical* site, not the origin actually serving this request, so
 * a Preview deployment (always HTTPS, different host) and a local HTTPS proxy
 * both got the wrong answer. It also coupled a cookie **security** flag to a
 * public, client-inlined value — a thing that can be changed by whoever edits
 * an env var, with no obvious connection to session security.
 *
 * The rule now:
 *  - **On Vercel** (`VERCEL` is set on every deployment, preview and
 *    production alike) → HTTPS is guaranteed by the platform → `secure`.
 *  - **Otherwise** → fall back to `NODE_ENV === 'production'`, so a
 *    self-hosted production build is secure by default while `next dev` over
 *    plain http is not (a `Secure` cookie is silently discarded by the browser
 *    over http, which would break local development in a way that looks like a
 *    session bug rather than a config one).
 *
 * `VERCEL` is a server-side system variable and is never mirrored into a
 * `NEXT_PUBLIC_*` variable, so this evaluates on the server, where the cookie
 * is actually written.
 */
function connectionIsSecure(): boolean {
  if (process.env.VERCEL) return true;
  return process.env.NODE_ENV === 'production';
}

export function sessionCookieOptions(options: CookieOptions = {}): CookieOptions {
  return {
    ...options,
    httpOnly: true,
    sameSite: 'lax',
    path: options.path ?? '/',
    secure: connectionIsSecure(),
  };
}
