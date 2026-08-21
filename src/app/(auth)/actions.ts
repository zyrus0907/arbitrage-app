'use server';

/**
 * Auth mutations as Server Actions (§5.1 permits Server Actions for simple
 * mutations; T10).
 *
 * WHY SERVER ACTIONS RATHER THAN CALLING SUPABASE FROM THE BROWSER
 *
 * AC1.4 requires that no session token is ever present in `localStorage` or any
 * client-readable storage. `@supabase/ssr`'s browser client keeps tokens in
 * cookies rather than `localStorage`, but those cookies are written by
 * JavaScript and are therefore **not** httpOnly and are readable by any script
 * on the page. Performing the sign-in on the server means the token is set by a
 * `Set-Cookie` header with `httpOnly`, and client JavaScript — ours or an
 * injected script's — cannot read it at all. That is a materially stronger
 * property than "not in localStorage", and it is why `src/lib/supabase/
 * browser.ts` is not used for authentication anywhere in T10.
 *
 * Cookie flags are `@supabase/ssr`'s defaults applied through Next's cookie
 * jar: `httpOnly`, `sameSite=lax`, `path=/`, and `secure` whenever the site URL
 * is https. `sameSite=lax` rather than `strict` is required, not lax discipline:
 * the magic-link and email-verification flows return the user from their mail
 * client as a cross-site top-level navigation, and `strict` would withhold the
 * cookie on exactly that request.
 */
import { redirect } from 'next/navigation';

import { buildAuthCallbackUrl } from '@/lib/auth/origin';
import { safeRedirectPath } from '@/lib/auth/redirect';
import { APP_HOME_PATH, RETURN_TO_PARAM } from '@/lib/auth/routes';
import { siteOrigin } from '@/lib/auth/site-origin';
import type { AuthFormState } from '@/lib/forms/state';
import { createClient } from '@/lib/supabase/server';
import { credentialsSchema, magicLinkSchema } from '@/lib/validation/profile';
import { messages } from '@/messages/en';


/**
 * The absolute URL Supabase sends the user back to.
 *
 * The origin comes from `siteOrigin()`, which resolves THIS deployment rather
 * than a single configured URL — on a Preview deployment that is the branch URL,
 * so a preview signup is verified against the preview it started on instead of
 * being handed to production. Both parts are server-controlled: the origin is
 * Vercel's own injected system variable or the configured site URL, never a
 * request header, and the `next` path is validated by `safeRedirectPath` before
 * it is assembled in. So this URL can be neither pointed at another origin nor
 * pushed outside Supabase's redirect allow-list.
 */
function callbackUrl(next: string): string {
  const safeNext = safeRedirectPath(next, APP_HOME_PATH);
  return buildAuthCallbackUrl(siteOrigin(), safeNext, RETURN_TO_PARAM);
}

function firstIssue(error: { issues: { message: string }[] }): string {
  return error.issues[0]?.message ?? messages.auth.errors.invalidInput;
}

export async function signInWithPassword(
  _state: AuthFormState,
  formData: FormData,
): Promise<AuthFormState> {
  const parsed = credentialsSchema.safeParse({
    email: formData.get('email'),
    password: formData.get('password'),
  });
  if (!parsed.success) return { error: firstIssue(parsed.error) };

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword(parsed.data);

  if (error) {
    // Deliberately one message for "no such account" and "wrong password".
    // Distinguishing them turns the sign-in form into an account-enumeration
    // oracle, and the user cannot act differently on the two answers anyway.
    return { error: messages.auth.errors.invalidCredentials };
  }

  redirect(safeRedirectPath(formData.get('next')?.toString(), APP_HOME_PATH));
}

export async function signUpWithPassword(
  _state: AuthFormState,
  formData: FormData,
): Promise<AuthFormState> {
  const parsed = credentialsSchema.safeParse({
    email: formData.get('email'),
    password: formData.get('password'),
  });
  if (!parsed.success) return { error: firstIssue(parsed.error) };

  const next = safeRedirectPath(formData.get('next')?.toString(), APP_HOME_PATH);
  const supabase = await createClient();

  const { data, error } = await supabase.auth.signUp({
    ...parsed.data,
    options: { emailRedirectTo: callbackUrl(next) },
  });

  // T11/F9: Supabase's own message is not passed through. It distinguishes
  // "already registered", "password rejected by policy" and "rate limited", and
  // the first of those turns this form into the account-enumeration oracle that
  // `signInWithPassword` above is deliberately built not to be. The client-side
  // Zod schema has already told the user about anything they can actually fix.
  if (error) return { error: messages.auth.errors.signUpFailed };

  // With email confirmation required (AC1.1), `signUp` returns a user and no
  // session: the account exists, the verification email is on its way, and
  // there is nothing to redirect into yet. With confirmation disabled the
  // session is live immediately and the user goes straight to onboarding.
  // Both are handled rather than assumed, because the setting differs between
  // the local stack and the hosted project today.
  if (data.session) redirect(next);
  redirect('/check-email');
}

export async function signInWithMagicLink(
  _state: AuthFormState,
  formData: FormData,
): Promise<AuthFormState> {
  const parsed = magicLinkSchema.safeParse({ email: formData.get('email') });
  if (!parsed.success) return { error: firstIssue(parsed.error) };

  const next = safeRedirectPath(formData.get('next')?.toString(), APP_HOME_PATH);
  const supabase = await createClient();

  const { error } = await supabase.auth.signInWithOtp({
    email: parsed.data.email,
    options: { emailRedirectTo: callbackUrl(next) },
  });

  // Same non-enumeration rule as sign-in: whether or not the address has an
  // account, the answer is "check your email".
  if (error && error.status !== 400) return { error: error.message };
  redirect('/check-email');
}
