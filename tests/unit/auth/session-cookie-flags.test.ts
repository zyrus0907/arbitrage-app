import { afterEach, describe, expect, it, vi } from 'vitest';

import { sessionCookieOptions } from '@/lib/supabase/cookies';

/**
 * T11 finding F11 — explicit regression coverage for the session cookie's
 * `Secure` flag in a production-like and a Vercel-like environment.
 *
 * The flags themselves were already correct; what was missing was a test that
 * would notice them becoming wrong. `connectionIsSecure()` is derived from
 * `VERCEL` and `NODE_ENV`, and both of those are exactly the kind of condition
 * that gets "simplified" by someone who has only ever run the app locally —
 * where the correct answer is `secure: false` and the incorrect one is
 * invisible.
 *
 * The integration suite asserts the flags on a real `Set-Cookie` header from a
 * running server, but it necessarily runs against the local HTTP stack, so the
 * one case it can never cover is the deployed one. These are those cases.
 */
afterEach(() => {
  vi.unstubAllEnvs();
});

describe('session cookie flags', () => {
  it('is httpOnly, lax and path-rooted in every environment (AC1.4)', () => {
    for (const env of ['development', 'test', 'production']) {
      vi.stubEnv('NODE_ENV', env);
      const options = sessionCookieOptions();
      expect(options.httpOnly).toBe(true);
      expect(options.sameSite).toBe('lax');
      expect(options.path).toBe('/');
    }
  });

  it('is Secure on a Vercel production deployment', () => {
    vi.stubEnv('VERCEL', '1');
    vi.stubEnv('VERCEL_ENV', 'production');
    vi.stubEnv('NODE_ENV', 'production');

    expect(sessionCookieOptions().secure).toBe(true);
  });

  it('is Secure on a Vercel preview deployment, which is HTTPS but not production', () => {
    // The regression this pins: keying `secure` off NODE_ENV alone would ship a
    // non-Secure session cookie to every preview URL.
    vi.stubEnv('VERCEL', '1');
    vi.stubEnv('VERCEL_ENV', 'preview');
    vi.stubEnv('NODE_ENV', 'development');

    expect(sessionCookieOptions().secure).toBe(true);
  });

  it('is Secure in a self-hosted production build with no Vercel variables', () => {
    vi.stubEnv('VERCEL', '');
    vi.stubEnv('NODE_ENV', 'production');

    expect(sessionCookieOptions().secure).toBe(true);
  });

  it('is not Secure under `next dev` over plain http, where a Secure cookie would be discarded', () => {
    vi.stubEnv('VERCEL', '');
    vi.stubEnv('NODE_ENV', 'development');

    expect(sessionCookieOptions().secure).toBe(false);
  });

  it('does not let a caller downgrade the security flags', () => {
    vi.stubEnv('VERCEL', '1');

    const options = sessionCookieOptions({
      httpOnly: false,
      sameSite: 'none',
      secure: false,
    } as Parameters<typeof sessionCookieOptions>[0]);

    expect(options.httpOnly).toBe(true);
    expect(options.sameSite).toBe('lax');
    expect(options.secure).toBe(true);
  });

  it('is not made Secure by a public variable that merely claims https', () => {
    // The rejected earlier design: a client-inlined, freely editable value
    // deciding a session security flag.
    vi.stubEnv('VERCEL', '');
    vi.stubEnv('NODE_ENV', 'development');
    vi.stubEnv('NEXT_PUBLIC_SITE_URL', 'https://app.example.com');

    expect(sessionCookieOptions().secure).toBe(false);
  });
});
