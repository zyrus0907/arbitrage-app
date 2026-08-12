/**
 * T10 — open-redirect defence (testing requirement 7).
 *
 * The `?next=` parameter and the auth callback both take a destination from the
 * user. This suite is the proof that neither can be pointed off-origin. Each
 * case names the trick it represents, because a bare list of strings stops
 * being maintainable the moment someone wants to relax one of these rules.
 */
import { describe, expect, it } from 'vitest';

import { safeRedirectPath, signInUrlFor } from '@/lib/auth/redirect';

const FALLBACK = '/feed';

describe('safeRedirectPath — accepts same-origin paths', () => {
  it.each([
    ['a plain path', '/settings'],
    ['a nested path', '/deal/abc-123'],
    ['a path with a query string', '/feed?minRoi=30'],
    ['a path with a fragment', '/settings#costs'],
    ['a path with an encoded space', '/deal/a%20b'],
    ['the root', '/'],
  ])('%s', (_label, value) => {
    expect(safeRedirectPath(value, FALLBACK)).toBe(value);
  });
});

describe('safeRedirectPath — rejects anything that could leave the origin', () => {
  it.each([
    ['an absolute https URL', 'https://evil.test/steal'],
    ['an absolute http URL', 'http://evil.test/steal'],
    ['our own origin spelled absolutely', 'https://arbitrage.test/feed'],
    ['a protocol-relative URL', '//evil.test/steal'],
    ['a protocol-relative URL with a path', '//evil.test'],
    ['a backslash protocol-relative URL', '/\\evil.test/steal'],
    ['a double backslash', '\\\\evil.test'],
    ['a backslash anywhere in the path', '/feed\\..\\evil'],
    ['a javascript: scheme', 'javascript:alert(1)'],
    ['a data: scheme', 'data:text/html,<script>alert(1)</script>'],
    ['an uppercase scheme', 'JAVASCRIPT:alert(1)'],
    ['a scheme-relative mailto', 'mailto:someone@evil.test'],
    ['a bare relative path', 'settings'],
    ['a parent-relative path', '../admin'],
    ['an empty string', ''],
    ['a double-encoded protocol-relative URL', '%252f%252fevil.test'],
    ['a single-encoded protocol-relative URL', '%2f%2fevil.test'],
    ['malformed percent-encoding', '/feed%zz'],
  ])('%s', (_label, value) => {
    expect(safeRedirectPath(value, FALLBACK)).toBe(FALLBACK);
  });

  it('rejects a newline that would split the Location header', () => {
    expect(safeRedirectPath('/feed\nSet-Cookie: a=b', FALLBACK)).toBe(FALLBACK);
    expect(safeRedirectPath('/feed\r\nLocation: https://evil.test', FALLBACK)).toBe(FALLBACK);
    // The encoded form, which survives one decode into the raw character.
    expect(safeRedirectPath('/feed%0aSet-Cookie:%20a=b', FALLBACK)).toBe(FALLBACK);
  });

  it('rejects a null byte', () => {
    expect(safeRedirectPath('/feed\u0000/x', FALLBACK)).toBe(FALLBACK);
  });

  it.each([null, undefined, 123, {}, []])('rejects the non-string %s', (value) => {
    expect(safeRedirectPath(value as never, FALLBACK)).toBe(FALLBACK);
  });
});

describe('safeRedirectPath — refuses to bounce back into the auth flow', () => {
  it.each(['/sign-in', '/sign-up', '/auth/callback', '/auth/sign-out'])(
    'rejects %s as a return target',
    (value) => {
      expect(safeRedirectPath(value, FALLBACK)).toBe(FALLBACK);
    },
  );

  it('rejects an auth route carrying a query string', () => {
    expect(safeRedirectPath('/sign-in?next=/feed', FALLBACK)).toBe(FALLBACK);
  });

  it('allows a path that merely starts with the same characters', () => {
    expect(safeRedirectPath('/sign-in-help', FALLBACK)).toBe('/sign-in-help');
  });
});

describe('signInUrlFor', () => {
  it('carries a safe intended route through sign-in (AC1.3)', () => {
    expect(signInUrlFor('/settings')).toBe('/sign-in?next=%2Fsettings');
  });

  it('preserves a query string in the intended route', () => {
    expect(signInUrlFor('/feed?minRoi=30')).toBe('/sign-in?next=%2Ffeed%3FminRoi%3D30');
  });

  it('drops a hostile intended route rather than storing it in a shareable URL', () => {
    expect(signInUrlFor('https://evil.test')).toBe('/sign-in');
    expect(signInUrlFor('//evil.test')).toBe('/sign-in');
  });
});
