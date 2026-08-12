/**
 * T10 — authentication, session, onboarding and account deletion, over HTTP.
 *
 * This suite runs the real application against the local Supabase stack and
 * asserts on real responses: status codes, `Location` headers and `Set-Cookie`
 * flags. That is deliberate. Almost every T10 criterion is a statement about
 * HTTP — "redirected and returned to the intended route", "httpOnly cookies",
 * "sign-out clears access", "an old session cannot continue" — and none of them
 * can be proved by calling a function with a hand-built request, because the
 * hand-built request is exactly where the mistake would be.
 *
 * WHAT IS PROVED WHERE, STATED SO NOTHING LOOKS COVERED THAT IS NOT
 *
 *   * The DATABASE mechanism of account deletion — the scrub, the retention,
 *     the tombstone constraint, idempotency, the guard on `auth.users` — is in
 *     `supabase/tests/database/account_deletion.test.sql`, 63 assertions,
 *     because those are catalogue and constraint facts. This file proves the
 *     HTTP route drives that mechanism and that the session dies with it.
 *   * `safeRedirectPath`'s full hostile-input matrix is in
 *     `tests/unit/auth/redirect.test.ts`. This file proves the callback route
 *     actually calls it.
 *
 * REQUIRES a seeded local stack (`npm run db:reset`). Like T09's suite, it
 * cannot fully tear itself down: its users acquire ledger rows, which are
 * append-only and ON DELETE RESTRICT, so the users become undeletable except
 * through the T10 mechanism — which is itself one of the things under test.
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import {
  CookieJar,
  locationPath,
  request,
  startAppServer,
  type AppServer,
} from './app-server';
import { localStack } from './supabase-local';

const stack = localStack();

let server: AppServer;
let service: SupabaseClient;

/** A namespace so a failed run is identifiable and cannot collide with T09's. */
const RUN = `t10-${Date.now()}`;
const password = 'correct horse battery staple';

type Fixture = { id: string; email: string };

async function createUser(label: string): Promise<Fixture> {
  const email = `${RUN}-${label}@t10.test`;
  const { data, error } = await service.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (error || !data.user) throw new Error(`Could not create ${label}: ${error?.message}`);
  return { id: data.user.id, email };
}

/**
 * Establishes a real browser session in `jar`, by driving the actual callback
 * route with a real one-time token.
 *
 * This is the magic-link flow end to end (§6.1) rather than a shortcut around
 * it: `generateLink` produces the same `token_hash` Supabase would have emailed,
 * and `/auth/callback` verifies it and writes the cookies. So establishing a
 * session and testing the callback are the same act, which is the right way
 * round — a helper that set cookies by some other means would be proving
 * nothing about the code that ships.
 */
async function signIn(jar: CookieJar, email: string, next = '/feed'): Promise<Response> {
  const { data, error } = await service.auth.admin.generateLink({ type: 'magiclink', email });
  if (error || !data.properties) throw new Error(`Could not mint a link: ${error?.message}`);

  return request(
    server,
    `/auth/callback?token_hash=${encodeURIComponent(data.properties.hashed_token)}` +
      `&type=magiclink&next=${encodeURIComponent(next)}`,
    { jar },
  );
}

/** The Supabase auth cookies `@supabase/ssr` sets, by convention `sb-*-auth-token*`. */
function authCookieNames(jar: CookieJar): string[] {
  return jar.names().filter((name) => name.startsWith('sb-'));
}

let userA: Fixture;
let userB: Fixture;
let userDeleted: Fixture;

beforeAll(async () => {
  service = createClient(stack.url, stack.serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  [userA, userB, userDeleted] = await Promise.all([
    createUser('a'),
    createUser('b'),
    createUser('doomed'),
  ]);

  server = await startAppServer();
}, 180_000);

afterAll(async () => {
  await server?.stop();
});

// ===========================================================================
// 1. Protected routes and the logged-out redirect (requirement 1, AC1.3)
// ===========================================================================

describe('an unauthenticated visitor', () => {
  it.each([
    ['/feed'],
    ['/settings'],
    ['/onboarding'],
    ['/waitlist'],
    // Not a route anyone has written. Default-deny means it is protected
    // anyway, which is the property that keeps a future page from shipping
    // public because someone forgot a list entry.
    ['/reports/quarterly'],
  ])('is redirected away from %s', async (path) => {
    const response = await request(server, path);
    expect(response.status).toBe(307);
    expect(locationPath(response)).toBe(`/sign-in?next=${encodeURIComponent(path)}`);
  });

  it('has the intended route preserved including its query string (AC1.3)', async () => {
    const response = await request(server, '/feed?minRoi=30&sort=score');
    expect(locationPath(response)).toBe(
      `/sign-in?next=${encodeURIComponent('/feed?minRoi=30&sort=score')}`,
    );
  });

  it.each([['/'], ['/sign-in'], ['/sign-up'], ['/check-email']])(
    'can still reach the public route %s',
    async (path) => {
      const response = await request(server, path);
      expect(response.status).toBe(200);
    },
  );

  it('gets a 401 envelope from the API rather than an HTML redirect', async () => {
    const response = await request(server, '/api/v1/profile');
    expect(response.status).toBe(401);
    const body = await response.json();
    expect(body).toMatchObject({ ok: false, error: { code: 'UNAUTHENTICATED' } });
  });

  it('cannot delete an account through the API', async () => {
    const response = await request(server, '/api/v1/account', { method: 'DELETE' });
    expect(response.status).toBe(401);
  });
});

// ===========================================================================
// 2. Sign-in, session cookies and access (requirements 2, 4, AC1.4)
// ===========================================================================

describe('signing in', () => {
  const jar = new CookieJar();

  it('succeeds and lands on the requested route (requirement 4)', async () => {
    const response = await signIn(jar, userA.email, '/feed');
    expect(response.status).toBe(307);
    expect(locationPath(response)).toBe('/feed');
  });

  it('sets the session in httpOnly cookies and nothing else (AC1.4)', () => {
    const authCookies = jar.received.filter((c) => c.name.startsWith('sb-') && c.value !== '');
    expect(authCookies.length).toBeGreaterThan(0);

    for (const cookie of authCookies) {
      // The single most important assertion in this file. Not httpOnly means
      // any injected script can read the session token, and "not in
      // localStorage" would be a distinction without a difference.
      expect(cookie.httpOnly, `${cookie.name} must be httpOnly`).toBe(true);
      expect(cookie.path).toBe('/');
      // `lax`, not `strict`: the magic-link and verification flows return the
      // user from their mail client as a cross-site top-level navigation, and
      // `strict` would withhold the cookie on exactly that request.
      expect(cookie.sameSite?.toLowerCase()).toBe('lax');
    }
  });

  it('can then reach a protected route (requirement 2)', async () => {
    const response = await request(server, '/onboarding', { jar });
    expect(response.status).toBe(200);
  });

  it('is recognised on the app routes rather than bounced to sign-in', async () => {
    // The session is accepted: /feed sends this user to onboarding because they
    // have not finished it — NOT to sign-in, which is what an unrecognised
    // session would produce.
    const response = await request(server, '/feed', { jar });
    expect(response.status).toBe(307);
    expect(locationPath(response)).toBe('/onboarding');
  });

  it('reads its own profile through the API', async () => {
    const response = await request(server, '/api/v1/profile', { jar });
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.ok).toBe(true);
    expect(body.data.profile.id).toBe(userA.id);
  });
});

// ===========================================================================
// 3. Invalid, forged and expired sessions (requirement 3)
// ===========================================================================

describe('a session that is not valid', () => {
  it('is refused rather than crashing the request', async () => {
    const response = await request(server, '/feed', {
      cookieHeader: 'sb-127-auth-token=not-a-real-token',
    });
    expect(response.status).toBe(307);
    expect(locationPath(response)).toMatch(/^\/sign-in/);
  });

  it('is refused when the token is well-formed JSON but bogus', async () => {
    const forged = Buffer.from(
      JSON.stringify({ access_token: 'x.y.z', refresh_token: 'nope' }),
    ).toString('base64');
    const response = await request(server, '/settings', {
      cookieHeader: `sb-127-auth-token=base64-${forged}`,
    });
    expect(response.status).toBe(307);
    expect(locationPath(response)).toMatch(/^\/sign-in/);
  });

  it('does not leak a 500 from the API either', async () => {
    const response = await request(server, '/api/v1/profile', {
      cookieHeader: 'sb-127-auth-token=garbage',
    });
    expect(response.status).toBe(401);
  });
});

describe('invalid credentials (requirement 5)', () => {
  it('are refused and produce no session', async () => {
    const anon = createClient(stack.url, stack.anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await anon.auth.signInWithPassword({
      email: userA.email,
      password: 'not the password',
    });
    expect(error).not.toBeNull();
    expect(data.session).toBeNull();
  });

  it('an unknown address is refused the same way, so the form is not an enumeration oracle', async () => {
    const anon = createClient(stack.url, stack.anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error } = await anon.auth.signInWithPassword({
      email: `${RUN}-nobody@t10.test`,
      password,
    });
    expect(error).not.toBeNull();
    expect(error?.status).toBe(400);
  });

  it('a used or bogus callback token does not create a session', async () => {
    const jar = new CookieJar();
    const response = await request(
      server,
      '/auth/callback?token_hash=not-a-real-hash&type=magiclink&next=%2Ffeed',
      { jar },
    );
    expect(locationPath(response)).toMatch(/^\/sign-in\?/);
    expect(locationPath(response)).toContain('error=link');
    expect(authCookieNames(jar)).toEqual([]);
  });
});

// ===========================================================================
// 4. The callback is not an open redirect (requirement 7)
// ===========================================================================

describe('the auth callback', () => {
  it.each([
    ['an absolute URL', 'https://evil.test/steal'],
    ['a protocol-relative URL', '//evil.test/steal'],
    ['a backslash trick', '/\\evil.test/steal'],
    ['a javascript scheme', 'javascript:alert(1)'],
    ['a double-encoded protocol-relative URL', '%252f%252fevil.test'],
  ])('refuses to send the user off-origin via %s', async (_label, hostile) => {
    const jar = new CookieJar();
    const response = await signIn(jar, userB.email, hostile);

    const location = response.headers.get('location') ?? '';
    expect(location).not.toContain('evil.test');
    // The user is still signed in — a hostile `next` must not fail a genuine
    // authentication, it must be replaced.
    expect(locationPath(response)).toBe('/feed');
  });

  it('honours a legitimate same-origin destination', async () => {
    const jar = new CookieJar();
    const response = await signIn(jar, userB.email, '/settings');
    expect(locationPath(response)).toBe('/settings');
  });

  it('refuses to bounce back into the auth flow', async () => {
    const jar = new CookieJar();
    const response = await signIn(jar, userB.email, '/sign-in');
    expect(locationPath(response)).toBe('/feed');
  });
});

// ===========================================================================
// 5. Sign-out (requirement 6)
// ===========================================================================

describe('signing out', () => {
  it('clears the cookies and access with them', async () => {
    const jar = new CookieJar();
    await signIn(jar, userA.email);
    expect((await request(server, '/onboarding', { jar })).status).toBe(200);

    const out = await request(server, '/auth/sign-out', { method: 'POST', jar });
    expect(out.status).toBe(303);
    expect(authCookieNames(jar)).toEqual([]);

    const after = await request(server, '/onboarding', { jar });
    expect(after.status).toBe(307);
    expect(locationPath(after)).toMatch(/^\/sign-in/);
  });

  it('is not reachable by GET — a GET sign-out is CSRF-able and prefetchable', async () => {
    const jar = new CookieJar();
    await signIn(jar, userA.email);
    const response = await request(server, '/auth/sign-out', { jar });
    expect(response.status).toBe(405);
    // Still signed in.
    expect((await request(server, '/onboarding', { jar })).status).toBe(200);
  });
});

// ===========================================================================
// 6. Profile authorisation (requirements 8–13, 15)
// ===========================================================================

describe('the profile', () => {
  let clientA: SupabaseClient;
  let clientB: SupabaseClient;

  beforeAll(async () => {
    const make = async (email: string) => {
      const client = createClient(stack.url, stack.anonKey, {
        auth: { persistSession: false, autoRefreshToken: false },
      });
      const { error } = await client.auth.signInWithPassword({ email, password });
      if (error) throw error;
      return client;
    };
    clientA = await make(userA.email);
    clientB = await make(userB.email);
  });

  it('is created exactly once for a new auth user (requirement 8)', async () => {
    const { data } = await service.from('profiles').select('id').eq('id', userA.id);
    expect(data).toHaveLength(1);
  });

  it('is not duplicated when signup is retried (requirement: no duplicate init state)', async () => {
    // `handle_new_user` is `insert ... on conflict (id) do nothing`, so a
    // replayed signup cannot produce a second profile or fail the account
    // creation. Replaying exactly that statement is the closest thing to
    // re-firing the trigger without inventing a second auth user.
    const before = stack
      .sql(`select count(*) from public.profiles where id = '${userA.id}'`)
      .trim();

    stack.sql(`insert into public.profiles (id) values ('${userA.id}') on conflict (id) do nothing`);

    const after = stack
      .sql(`select count(*) from public.profiles where id = '${userA.id}'`)
      .trim();

    expect(before).toBe('1');
    expect(after).toBe('1');

    // And the credit state is untouched: no second signup grant, because the
    // grant is keyed on the user id rather than on the request.
    const { data } = await service
      .from('credit_ledger')
      .select('id')
      .eq('user_id', userA.id)
      .eq('reason', 'signup_grant');
    expect((data ?? []).length).toBeLessThanOrEqual(1);
  });

  it('can be read by its owner (requirement 9)', async () => {
    const { data, error } = await clientA.from('profiles').select('*').eq('id', userA.id);
    expect(error).toBeNull();
    expect(data).toHaveLength(1);
  });

  it('cannot be read by anyone else (requirement 10)', async () => {
    const { data, error } = await clientA.from('profiles').select('*').eq('id', userB.id);
    // RLS filters rather than refusing: the grant exists, the policy excludes
    // the row. An error here would mean the grant went missing.
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it('is invisible in BOTH directions, not just one (requirement 10)', async () => {
    // Asserted from B as well as from A. A one-directional check would still
    // pass if the policy were accidentally written as a comparison that happens
    // to exclude one specific user rather than as `id = auth.uid()`.
    const { data, error } = await clientB.from('profiles').select('*').eq('id', userA.id);
    expect(error).toBeNull();
    expect(data).toEqual([]);

    const { data: own } = await clientB.from('profiles').select('id');
    expect(own?.map((row) => row.id)).toEqual([userB.id]);
  });

  it('cannot be written by anyone else (requirement 10)', async () => {
    const { data } = await clientA
      .from('profiles')
      .update({ display_name: 'hijacked' })
      .eq('id', userB.id)
      .select();
    expect(data ?? []).toEqual([]);

    const { data: victim } = await service
      .from('profiles')
      .select('display_name')
      .eq('id', userB.id)
      .single();
    expect(victim?.display_name).not.toBe('hijacked');
  });

  it('accepts an update to an allowed field (requirement 11)', async () => {
    const response = await requestAsUser(userA.email, '/api/v1/profile', {
      method: 'PATCH',
      body: JSON.stringify({ tax_registered: true, tax_scheme: 'simplified' }),
    });
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.data.profile.tax_registered).toBe(true);
    expect(body.data.profile.tax_scheme).toBe('simplified');
  });

  it('refuses a credit_balance update at the API (requirement 12)', async () => {
    const response = await requestAsUser(userA.email, '/api/v1/profile', {
      method: 'PATCH',
      body: JSON.stringify({ credit_balance: 9999 }),
    });
    expect(response.status).toBe(400);
    const body = await response.json();
    expect(body.error.code).toBe('VALIDATION_FAILED');
  });

  it('refuses a credit_balance update at the database too (requirement 12)', async () => {
    const before = await service
      .from('profiles')
      .select('credit_balance')
      .eq('id', userA.id)
      .single();

    const { error } = await clientA
      .from('profiles')
      .update({ credit_balance: 9999 })
      .eq('id', userA.id);

    // A privilege error from T06's column-level grant — not a policy filter,
    // and not a silently ignored write.
    expect(error?.code).toBe('42501');
    expect(error?.message).toMatch(/permission denied/i);

    const after = await service
      .from('profiles')
      .select('credit_balance')
      .eq('id', userA.id)
      .single();
    expect(after.data?.credit_balance).toBe(before.data?.credit_balance);
  });

  it('refuses to let a user reassign ownership of their row (requirement 13)', async () => {
    const { error } = await clientA
      .from('profiles')
      .update({ id: userB.id })
      .eq('id', userA.id);
    expect(error).not.toBeNull();

    const { data } = await service.from('profiles').select('id').eq('id', userA.id);
    expect(data).toHaveLength(1);
  });

  it('refuses an invalid enum value (requirement 15)', async () => {
    const response = await requestAsUser(userA.email, '/api/v1/profile', {
      method: 'PATCH',
      body: JSON.stringify({ default_fulfilment: 'teleportation' }),
    });
    expect(response.status).toBe(400);
  });

  it('refuses an invalid country code (requirement 15)', async () => {
    const response = await requestAsUser(userA.email, '/api/v1/profile', {
      method: 'PATCH',
      body: JSON.stringify({ country_code: 'Great Britain' }),
    });
    expect(response.status).toBe(400);
  });

  it('refuses a market the user is not allowed to select (requirement 15)', async () => {
    // The seeded second market is `planned` and inactive, so T06's policy makes
    // it invisible — and therefore unselectable. This is the assertion that
    // proves validation is against rows the user may actually use, not against
    // "is it a uuid".
    const { data: hidden } = await service
      .from('markets')
      .select('id')
      .eq('launch_status', 'planned')
      .limit(1)
      .single();
    expect(hidden?.id).toBeDefined();

    const response = await requestAsUser(userA.email, '/api/v1/profile', {
      method: 'PATCH',
      body: JSON.stringify({ default_market_id: hidden!.id }),
    });
    expect(response.status).toBe(400);
  });

  it('refuses a money value that is not an integer count of minor units', async () => {
    const response = await requestAsUser(userA.email, '/api/v1/profile', {
      method: 'PATCH',
      body: JSON.stringify({ prep_cost_per_unit_minor: 12.5 }),
    });
    expect(response.status).toBe(400);
  });

  it('refuses a cost assumption with no currency', async () => {
    const response = await requestAsUser(userA.email, '/api/v1/profile', {
      method: 'PATCH',
      body: JSON.stringify({ default_budget_minor: 5000, assumption_currency: null }),
    });
    expect(response.status).toBe(400);
  });

  it('persists onboarding completion (requirement 14)', async () => {
    const { data: market } = await clientA
      .from('markets')
      .select('id, currency, source_country_code')
      .limit(1)
      .single();
    expect(market).not.toBeNull();

    const { error } = await clientA
      .from('profiles')
      .update({
        country_code: market!.source_country_code,
        default_market_id: market!.id,
        assumption_currency: market!.currency,
        default_budget_minor: 250000,
        prep_cost_per_unit_minor: 45,
        inbound_shipping_per_unit_minor: 120,
        onboarded_at: new Date().toISOString(),
      })
      .eq('id', userA.id);
    expect(error).toBeNull();

    const response = await requestAsUser(userA.email, '/api/v1/profile');
    const body = await response.json();
    expect(body.data.stage).toBe('ready');
    expect(body.data.profile.onboarded_at).not.toBeNull();
    expect(body.data.profile.assumption_currency).toBe(market!.currency);
  });

  it('lets an onboarded user reach the app home rather than onboarding', async () => {
    const jar = new CookieJar();
    await signIn(jar, userA.email);
    const response = await request(server, '/feed', { jar });
    expect(response.status).toBe(200);
  });
});

/** Signs a user in with a fresh jar and issues one request as them. */
async function requestAsUser(
  email: string,
  path: string,
  init: RequestInit = {},
): Promise<Response> {
  const jar = new CookieJar();
  await signIn(jar, email);
  return request(server, path, {
    ...init,
    jar,
    headers: { 'content-type': 'application/json', ...(init.headers as object) },
  });
}

// ===========================================================================
// 7. The signup credit grant (AC10.6)
// ===========================================================================

describe('the signup grant', () => {
  it('lands in the ledger exactly once, however many times the app boots', async () => {
    const jar = new CookieJar();
    await signIn(jar, userDeleted.email);

    // Three renders of the authenticated shell, which is where the grant is
    // completed. A non-deterministic idempotency key would produce three rows.
    await request(server, '/onboarding', { jar });
    await request(server, '/onboarding', { jar });
    await request(server, '/onboarding', { jar });

    const { data: ledger } = await service
      .from('credit_ledger')
      .select('id, delta, reason, idempotency_key')
      .eq('user_id', userDeleted.id);

    const grants = (ledger ?? []).filter((row) => row.reason === 'signup_grant');
    expect(grants).toHaveLength(1);
    expect(grants[0]?.delta).toBe(5);
    expect(grants[0]?.idempotency_key).toBe(`signup_grant:v1:${userDeleted.id}`);
  });

  it('reconciles with the cached balance (AC10.8)', async () => {
    const { data: ledger } = await service
      .from('credit_ledger')
      .select('delta')
      .eq('user_id', userDeleted.id);
    const { data: profile } = await service
      .from('profiles')
      .select('credit_balance')
      .eq('id', userDeleted.id)
      .single();

    const sum = (ledger ?? []).reduce((total, row) => total + row.delta, 0);
    expect(profile?.credit_balance).toBe(sum);
  });
});

// ===========================================================================
// 8. Account deletion over HTTP (requirements 16–24)
// ===========================================================================

describe('deleting an account', () => {
  const jar = new CookieJar();
  let staleCookies: string;

  it('is refused for a live account by a plain auth deletion (requirement 16)', async () => {
    const { error } = await service.auth.admin.deleteUser(userDeleted.id);
    expect(error).not.toBeNull();

    const { data } = await service.from('profiles').select('id').eq('id', userDeleted.id);
    expect(data).toHaveLength(1);
  });

  it('succeeds through the T10 route, and reports what it kept (requirement 17)', async () => {
    await signIn(jar, userDeleted.email);
    staleCookies = jar.snapshot();

    const response = await request(server, '/api/v1/account', { method: 'DELETE', jar });
    expect(response.status).toBe(200);

    const body = await response.json();
    expect(body.ok).toBe(true);
    expect(body.data.alreadyDeleted).toBe(false);
    expect(body.data.financialRowsRetained.ledgerEntries).toBeGreaterThan(0);
  });

  it('keeps the ledger rows (requirement 18)', async () => {
    const { data } = await service
      .from('credit_ledger')
      .select('delta, reason')
      .eq('user_id', userDeleted.id);
    expect((data ?? []).length).toBeGreaterThan(0);
    expect(data?.some((row) => row.reason === 'signup_grant')).toBe(true);
  });

  it('keeps the balance reconcilable — the history is not falsified', async () => {
    const { data: ledger } = await service
      .from('credit_ledger')
      .select('delta')
      .eq('user_id', userDeleted.id);
    const { data: profile } = await service
      .from('profiles')
      .select('credit_balance, deleted_at')
      .eq('id', userDeleted.id)
      .single();

    const sum = (ledger ?? []).reduce((total, row) => total + row.delta, 0);
    expect(profile?.credit_balance).toBe(sum);
    expect(profile?.deleted_at).not.toBeNull();
  });

  it('removes the personal fields (requirement 20)', async () => {
    const { data } = await service
      .from('profiles')
      .select('*')
      .eq('id', userDeleted.id)
      .single();

    expect(data?.display_name).toBeNull();
    expect(data?.country_code).toBeNull();
    expect(data?.default_market_id).toBeNull();
    expect(data?.locale).toBeNull();
    expect(data?.timezone).toBeNull();
    expect(data?.assumption_currency).toBeNull();
    expect(data?.onboarded_at).toBeNull();
    expect(data?.tax_registered).toBe(false);
  });

  it('removes authentication access entirely (requirement 21)', async () => {
    const { data, error } = await service.auth.admin.getUserById(userDeleted.id);
    // Either a 404 error or no user — both mean the auth record is gone.
    expect(error !== null || data?.user === null).toBe(true);
  });

  it('leaves nothing in the retained rows that identifies the person', async () => {
    const { data } = await service
      .from('profiles')
      .select('*')
      .eq('id', userDeleted.id)
      .single();

    const serialised = JSON.stringify(data ?? {});
    expect(serialised).not.toContain(userDeleted.email);
    expect(serialised).not.toContain(RUN);
  });

  it('refuses the old session, which is still inside its token lifetime (requirement 22)', async () => {
    // The JWT has not expired — the account it names has ceased to exist. This
    // is why the app calls getUser() rather than getSession(): a signature check
    // alone would still accept this token.
    const response = await request(server, '/feed', { cookieHeader: staleCookies });
    expect(response.status).toBe(307);
    expect(locationPath(response)).toMatch(/^\/sign-in/);
  });

  it('refuses the old session at the API too (requirement 22)', async () => {
    const response = await request(server, '/api/v1/profile', { cookieHeader: staleCookies });
    expect(response.status).toBe(401);
  });

  it('cannot be signed into again', async () => {
    const anon = createClient(stack.url, stack.anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await anon.auth.signInWithPassword({
      email: userDeleted.email,
      password,
    });
    expect(error).not.toBeNull();
    expect(data.session).toBeNull();
  });

  it('is safe to retry (requirement 23)', async () => {
    // Directly against the RPC, because the HTTP route is no longer reachable
    // for this subject — there is no session left to authenticate, which is
    // itself the correct behaviour.
    const { data, error } = await service.rpc('pseudonymise_account', {
      p_user: userDeleted.id,
    });
    expect(error).toBeNull();
    const row = Array.isArray(data) ? data[0] : data;
    expect(row?.already_deleted).toBe(true);
    expect(row?.ledger_retained).toBeGreaterThan(0);
  });

  it('leaves unrelated users completely unaffected (requirement 24)', async () => {
    const { data } = await service
      .from('profiles')
      .select('deleted_at, onboarded_at')
      .eq('id', userA.id)
      .single();
    expect(data?.deleted_at).toBeNull();
    expect(data?.onboarded_at).not.toBeNull();

    const jar = new CookieJar();
    await signIn(jar, userA.email);
    const response = await request(server, '/feed', { jar });
    expect(response.status).toBe(200);
  });
});
