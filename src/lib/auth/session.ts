import 'server-only';

/**
 * The authoritative server-side session check (T10).
 *
 * Every protected surface goes through here — the `(app)` layout, both API
 * route handlers, and the Server Actions. The proxy is an optimisation in front
 * of it, never a substitute for it: Next's own documentation says Proxy is not
 * a full authorization solution, and a protected page that trusted the proxy
 * alone would serve its content to anyone who reached it by a path the matcher
 * did not cover.
 *
 * `getUser()`, never `getSession()`. `getSession()` reads the cookie and
 * believes it. `getUser()` revalidates the token against the Auth server, which
 * is what makes these true rather than aspirational:
 *
 *   - a deleted account's still-unexpired JWT is refused (T10 deletion
 *     requirement 22),
 *   - a forged or tampered cookie is refused,
 *   - a session revoked elsewhere stops working here.
 *
 * The cost is one HTTP call per protected request. That is the correct trade
 * for the boundary that decides whether someone else's data is rendered.
 */
import { createClient } from '@/lib/supabase/server';
import { loadProfile, profileStage, type Profile, type ProfileStage } from '@/services/profile';

export type AuthedUser = {
  id: string;
  email: string | null;
  /** AC1.2 depends on this: an unverified account may not spend credits. */
  emailVerified: boolean;
};

export type AuthContext = {
  user: AuthedUser;
  profile: Profile;
  stage: ProfileStage;
};

/** The verified user, or `null`. Never throws for an absent session. */
export async function currentUser(): Promise<AuthedUser | null> {
  const supabase = await createClient();
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser();

  if (error || !user) return null;

  return {
    id: user.id,
    email: user.email ?? null,
    emailVerified: Boolean(user.email_confirmed_at ?? user.confirmed_at),
  };
}

/**
 * The verified user together with their profile and the stage they are in.
 *
 * Returns `null` when there is no session **or when the profile row is a
 * tombstone**. The tombstone case is deliberate defence in depth: after
 * `deleteAccount` the auth user is gone and `getUser()` already fails, but
 * between the scrub and the auth deletion — and for any retry window in
 * between — a live JWT could still resolve. Refusing a tombstoned subject here
 * closes that window without depending on the ordering of two network calls.
 */
export async function currentAuthContext(): Promise<AuthContext | null> {
  const user = await currentUser();
  if (!user) return null;

  const supabase = await createClient();
  const profile = await loadProfile(supabase, user.id);
  if (!profile.ok) return null;

  const stage = profileStage(profile.data);
  if (stage === 'deleted') return null;

  return { user, profile: profile.data, stage };
}
