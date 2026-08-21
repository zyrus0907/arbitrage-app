import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * T11 finding F2 — production `/` must not execute the service-role dashboard
 * queries for an anonymous caller.
 *
 * The assertion that matters is the negative one: with the gate closed,
 * `getDevDashboardSnapshot` is never called. Asserting on the rendered markup
 * instead would pass just as happily against a page that ran every aggregate
 * query and then declined to print the numbers.
 */
const getDevDashboardSnapshot = vi.fn(async () => {
  throw new Error('the admin snapshot layer must not be reached in production');
});

vi.mock('@/lib/dev-dashboard/snapshot', () => ({ getDevDashboardSnapshot }));

/**
 * The gate is mocked for the page tests, and its `NODE_ENV` wiring is asserted
 * separately below against the real module. Setting `NODE_ENV=production` for
 * the page render would also switch React to the production JSX runtime this
 * file was not transformed against — the page would then fail for a reason that
 * has nothing to do with the finding.
 */
const devDashboardEnabledMock = vi.fn<() => boolean>(() => true);

vi.mock('@/lib/dev-dashboard/enabled', () => ({
  devDashboardEnabled: () => devDashboardEnabledMock(),
}));

const { devDashboardEnabled } = await vi.importActual<typeof import('@/lib/dev-dashboard/enabled')>(
  '@/lib/dev-dashboard/enabled',
);

beforeEach(() => {
  getDevDashboardSnapshot.mockClear();
  devDashboardEnabledMock.mockReturnValue(true);
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.resetModules();
});

describe('dev dashboard gate', () => {
  it('is closed in production and open everywhere else', () => {
    expect(devDashboardEnabled('production')).toBe(false);
    expect(devDashboardEnabled('development')).toBe(true);
    expect(devDashboardEnabled('test')).toBe(true);
    // An unset NODE_ENV is a local process, not a deployment.
    expect(devDashboardEnabled(undefined)).toBe(true);
  });

  it('reads NODE_ENV when given no argument', () => {
    vi.stubEnv('NODE_ENV', 'production');
    expect(devDashboardEnabled()).toBe(false);
  });

  it('has no environment-variable escape hatch that could open it in production', () => {
    vi.stubEnv('ENABLE_DEV_DASHBOARD', 'true');
    vi.stubEnv('DEV_DASHBOARD', '1');
    vi.stubEnv('VERCEL_ENV', 'development');
    expect(devDashboardEnabled('production')).toBe(false);
  });

  it('never calls the admin snapshot layer when the gate is closed', async () => {
    devDashboardEnabledMock.mockReturnValue(false);
    vi.resetModules();

    const { default: HomePage } = await import('@/app/page');
    await HomePage();

    expect(getDevDashboardSnapshot).not.toHaveBeenCalled();
  });

  it('still reaches the dashboard when the gate is open, so the gate is what changed', async () => {
    devDashboardEnabledMock.mockReturnValue(true);
    vi.resetModules();

    const { default: HomePage } = await import('@/app/page');
    await expect(HomePage()).rejects.toThrow(/must not be reached in production/);

    expect(getDevDashboardSnapshot).toHaveBeenCalledTimes(1);
  });
});
