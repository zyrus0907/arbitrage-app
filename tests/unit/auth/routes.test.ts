/**
 * T10 — the route allowlist.
 *
 * The proxy is default-deny: everything needs a session unless it is on the
 * public list. These tests pin that posture, so a future edit that turns the
 * list into a list of *protected* prefixes — which would fail open for every
 * route someone forgot to add — cannot land quietly.
 */
import { describe, expect, it } from 'vitest';

import { isPublicPath, PUBLIC_PATHS } from '@/lib/auth/routes';

describe('isPublicPath', () => {
  it.each([...PUBLIC_PATHS])('serves %s without a session', (path) => {
    expect(isPublicPath(path)).toBe(true);
  });

  it.each([
    ['the feed', '/feed'],
    ['a deal detail', '/deal/abc'],
    ['settings', '/settings'],
    ['onboarding', '/onboarding'],
    ['the waitlist', '/waitlist'],
    ['credits', '/credits'],
    ['the admin console', '/admin'],
    ['an admin subroute', '/admin/markets'],
    ['the profile API', '/api/v1/profile'],
    ['the account API', '/api/v1/account'],
  ])('requires a session for %s', (_label, path) => {
    expect(isPublicPath(path)).toBe(false);
  });

  it('protects a route nobody has written yet — the point of default-deny', () => {
    expect(isPublicPath('/reports')).toBe(false);
    expect(isPublicPath('/some/deeply/nested/future/route')).toBe(false);
  });

  it('does not treat a public path as a prefix of everything below it', () => {
    // `/sign-in` is public; `/sign-in/secret` is not automatically so.
    expect(isPublicPath('/sign-in/secret')).toBe(false);
  });
});
