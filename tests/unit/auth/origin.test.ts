/**
 * T10 — deployment origin resolution.
 *
 * The failure this guards against is specific and expensive: a verification or
 * magic link built from the wrong origin lands the user on a different
 * deployment than the one they signed up on, and the email cannot be recalled
 * or re-pointed once sent.
 */
import { describe, expect, it } from 'vitest';

import {
  buildAuthCallbackUrl,
  normaliseDeploymentHost,
  resolveSiteOrigin,
} from '@/lib/auth/origin';

const SITE = 'https://arbitrage-app-swart.vercel.app';
const LOCAL = 'http://localhost:3000';

describe('resolveSiteOrigin — local development', () => {
  it('uses the configured site URL when no Vercel variables are present', () => {
    expect(resolveSiteOrigin({}, LOCAL)).toBe(LOCAL);
  });

  it('keeps the port and the http scheme', () => {
    expect(resolveSiteOrigin({}, 'http://localhost:54321')).toBe('http://localhost:54321');
  });

  it('ignores Vercel deployment variables when the environment is not preview', () => {
    expect(
      resolveSiteOrigin(
        { VERCEL_ENV: 'development', VERCEL_BRANCH_URL: 'x-git-main-y.vercel.app' },
        LOCAL,
      ),
    ).toBe(LOCAL);
  });
});

describe('resolveSiteOrigin — production', () => {
  it('uses the configured site URL, not the deployment URL', () => {
    // Production deployments also have VERCEL_URL set, and it is the immutable
    // per-deployment hostname. Using it would put a URL nobody recognises into
    // a customer's inbox and would change on every deploy.
    expect(
      resolveSiteOrigin(
        {
          VERCEL_ENV: 'production',
          VERCEL_URL: 'arbitrage-r4gqbcvde-zyrus-projects1.vercel.app',
          VERCEL_BRANCH_URL: 'arbitrage-app-git-main-zyrus-projects1.vercel.app',
        },
        SITE,
      ),
    ).toBe(SITE);
  });

  it('strips a trailing slash so paths cannot double up', () => {
    expect(resolveSiteOrigin({ VERCEL_ENV: 'production' }, `${SITE}/`)).toBe(SITE);
    expect(resolveSiteOrigin({}, `${SITE}///`)).toBe(SITE);
  });
});

describe('resolveSiteOrigin — preview', () => {
  it('prefers VERCEL_BRANCH_URL', () => {
    expect(
      resolveSiteOrigin(
        {
          VERCEL_ENV: 'preview',
          VERCEL_BRANCH_URL: 'arbitrage-app-git-feat-x-zyrus-projects1.vercel.app',
          VERCEL_URL: 'arbitrage-abc123-zyrus-projects1.vercel.app',
        },
        SITE,
      ),
    ).toBe('https://arbitrage-app-git-feat-x-zyrus-projects1.vercel.app');
  });

  it('falls back to VERCEL_URL when the branch URL is absent', () => {
    expect(
      resolveSiteOrigin(
        { VERCEL_ENV: 'preview', VERCEL_URL: 'arbitrage-abc123-zyrus-projects1.vercel.app' },
        SITE,
      ),
    ).toBe('https://arbitrage-abc123-zyrus-projects1.vercel.app');
  });

  it('falls back to VERCEL_URL when the branch URL is malformed', () => {
    expect(
      resolveSiteOrigin(
        {
          VERCEL_ENV: 'preview',
          VERCEL_BRANCH_URL: 'not a hostname',
          VERCEL_URL: 'arbitrage-abc123-zyrus-projects1.vercel.app',
        },
        SITE,
      ),
    ).toBe('https://arbitrage-abc123-zyrus-projects1.vercel.app');
  });

  it('falls back to the configured site URL when both are missing', () => {
    // System environment variables can be disabled on a Vercel project. That
    // must degrade to a working link, not throw mid-signup.
    expect(resolveSiteOrigin({ VERCEL_ENV: 'preview' }, SITE)).toBe(SITE);
  });

  it('falls back to the configured site URL when both are malformed', () => {
    expect(
      resolveSiteOrigin(
        { VERCEL_ENV: 'preview', VERCEL_BRANCH_URL: '', VERCEL_URL: '///' },
        SITE,
      ),
    ).toBe(SITE);
  });

  it('never emits a duplicated protocol, even if Vercel starts sending one', () => {
    const origin = resolveSiteOrigin(
      { VERCEL_ENV: 'preview', VERCEL_BRANCH_URL: 'https://preview-x-y.vercel.app' },
      SITE,
    );
    expect(origin).toBe('https://preview-x-y.vercel.app');
    expect(origin.match(/https?:\/\//g)).toHaveLength(1);
  });

  it('produces a parseable absolute URL in every preview branch', () => {
    for (const env of [
      { VERCEL_ENV: 'preview', VERCEL_BRANCH_URL: 'a-b-c.vercel.app' },
      { VERCEL_ENV: 'preview', VERCEL_URL: 'd-e-f.vercel.app' },
      { VERCEL_ENV: 'preview' },
    ]) {
      expect(() => new URL(resolveSiteOrigin(env, SITE))).not.toThrow();
    }
  });
});

describe('normaliseDeploymentHost — malformed input fails safely', () => {
  it.each([
    ['undefined', undefined],
    ['null', null],
    ['empty', ''],
    ['whitespace only', '   '],
    ['a path', 'host.vercel.app/evil'],
    ['a query string', 'host.vercel.app?x=1'],
    ['embedded credentials', 'evil.test@host.vercel.app'],
    ['a space', 'not a hostname'],
    ['a bare label with no dot', 'localhost'],
    ['only slashes', '///'],
    ['a wildcard', '*.vercel.app'],
    ['a newline', 'host.vercel.app\nevil'],
    ['a protocol-relative form', '//evil.test'],
    ['a javascript scheme', 'javascript:alert(1)'],
  ])('rejects %s', (_label, value) => {
    expect(normaliseDeploymentHost(value as string | undefined)).toBeNull();
  });

  it.each([
    ['a plain host', 'app.vercel.app', 'app.vercel.app'],
    ['a hyphenated host', 'arbitrage-app-git-main-zyrus-projects1.vercel.app', 'arbitrage-app-git-main-zyrus-projects1.vercel.app'],
    ['a host with a port', 'app.vercel.app:3000', 'app.vercel.app:3000'],
    ['a host with https', 'https://app.vercel.app', 'app.vercel.app'],
    ['a host with a trailing slash', 'app.vercel.app/', 'app.vercel.app'],
    ['surrounding whitespace', '  app.vercel.app  ', 'app.vercel.app'],
  ])('accepts %s', (_label, value, expected) => {
    expect(normaliseDeploymentHost(value)).toBe(expected);
  });
});

describe('buildAuthCallbackUrl', () => {
  it('uses the resolved origin', () => {
    const origin = resolveSiteOrigin(
      { VERCEL_ENV: 'preview', VERCEL_BRANCH_URL: 'preview-x.vercel.app' },
      SITE,
    );
    expect(buildAuthCallbackUrl(origin, '/feed', 'next')).toBe(
      'https://preview-x.vercel.app/auth/callback?next=%2Ffeed',
    );
  });

  it('targets /auth/callback on the production origin', () => {
    expect(buildAuthCallbackUrl(SITE, '/settings', 'next')).toBe(
      `${SITE}/auth/callback?next=%2Fsettings`,
    );
  });

  it('encodes a path carrying a query string', () => {
    expect(buildAuthCallbackUrl(SITE, '/feed?minRoi=30', 'next')).toBe(
      `${SITE}/auth/callback?next=%2Ffeed%3FminRoi%3D30`,
    );
  });

  it('does not double a slash when the origin has a trailing one', () => {
    const origin = resolveSiteOrigin({}, `${SITE}/`);
    expect(buildAuthCallbackUrl(origin, '/feed', 'next')).toBe(
      `${SITE}/auth/callback?next=%2Ffeed`,
    );
  });
});
