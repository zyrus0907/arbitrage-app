import { type EmailOtpType } from '@supabase/supabase-js';
import { NextResponse, type NextRequest } from 'next/server';

import { safeRedirectPath } from '@/lib/auth/redirect';
import { APP_HOME_PATH, RETURN_TO_PARAM, SIGN_IN_PATH } from '@/lib/auth/routes';
import { createClient } from '@/lib/supabase/server';

/**
 * The auth callback — where Supabase returns the browser after email
 * verification (AC1.1) and after a magic link (§6.1).
 *
 * THIS ROUTE IS THE OPEN-REDIRECT SURFACE OF THE WHOLE APPLICATION, and it is
 * written accordingly. It runs immediately after a successful authentication,
 * which is the moment a user is least likely to look at the address bar, and it
 * takes a destination from the query string.
 *
 * Every destination is passed through `safeRedirectPath`, which accepts only a
 * same-origin path — never an absolute URL, not even to our own host — and is
 * unit-tested against protocol-relative, backslash, scheme-bearing,
 * double-encoded and control-character payloads. A rejected target does not
 * fail the request: the user is authenticated and lands on the app home,
 * because failing a legitimate sign-in to punish a malformed `next` would be
 * the wrong trade.
 *
 * Two exchange shapes are handled because Supabase uses both:
 *   - `?token_hash=&type=` — the current email-link format, verified with
 *     `verifyOtp`.
 *   - `?code=` — the PKCE authorization code, exchanged for a session.
 *
 * An implicit-flow `#access_token=...` fragment is deliberately NOT handled.
 * A fragment never reaches the server, so handling it would require reading the
 * token in client JavaScript and posting it back — which is precisely the
 * client-readable-token path AC1.4 forbids.
 */
export async function GET(request: NextRequest) {
  const { searchParams, origin } = request.nextUrl;

  const next = safeRedirectPath(searchParams.get(RETURN_TO_PARAM), APP_HOME_PATH);
  const tokenHash = searchParams.get('token_hash');
  const type = searchParams.get('type') as EmailOtpType | null;
  const code = searchParams.get('code');

  // Supabase reports a failed link (expired, already used) in the query string
  // rather than as an exception. Surfaced as a sign-in error rather than a
  // blank screen.
  const providerError = searchParams.get('error_description') ?? searchParams.get('error');
  if (providerError) {
    return NextResponse.redirect(new URL(signInWithError(next), origin));
  }

  const supabase = await createClient();

  if (tokenHash && type) {
    const { error } = await supabase.auth.verifyOtp({ token_hash: tokenHash, type });
    if (!error) return NextResponse.redirect(new URL(next, origin));
    return NextResponse.redirect(new URL(signInWithError(next), origin));
  }

  if (code) {
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) return NextResponse.redirect(new URL(next, origin));
    return NextResponse.redirect(new URL(signInWithError(next), origin));
  }

  return NextResponse.redirect(new URL(signInWithError(next), origin));
}

/**
 * Builds the failure destination. `next` is re-validated on the way out even
 * though it was validated on the way in — this string is about to be
 * concatenated into a URL, and validating at the point of use is what survives
 * someone later moving the parse.
 */
function signInWithError(next: string): string {
  const safeNext = safeRedirectPath(next, '');
  const params = new URLSearchParams({ error: 'link' });
  if (safeNext) params.set(RETURN_TO_PARAM, safeNext);
  return `${SIGN_IN_PATH}?${params.toString()}`;
}
