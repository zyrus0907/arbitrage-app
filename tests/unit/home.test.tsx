import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import { messages } from '@/messages/en';

/**
 * T01's smoke test — "the home route renders" — retargeted at the development
 * dashboard that now occupies `/`.
 *
 * The snapshot module is mocked rather than stubbed at the client level: it is
 * `server-only`, so importing it under a test runner is exactly the failure
 * that module exists to cause. The mock keeps this a route test; the dashboard's
 * own behaviour is covered in `tests/unit/dev-dashboard/`.
 */
vi.mock('@/lib/dev-dashboard/snapshot', () => ({
  getDevDashboardSnapshot: vi.fn(async () => ({
    backend: 'connected' as const,
    counts: {
      markets: 0,
      retailers: 0,
      retailerProducts: 0,
      marketplaceProducts: 0,
      deals: 0,
      creditPacks: 0,
      creditPurchases: 0,
      profiles: 0,
    },
    dealLifecycle: { draft: 0, active: 0, retired: 0 },
    currencies: [{ code: 'GBP', minorUnitExponent: 2, name: 'Pound Sterling' }],
    system: {
      environment: 'development' as const,
      databaseTypesAvailable: true,
      serverCredentialsConfigured: true,
    },
  })),
}));

const { default: HomePage } = await import('@/app/page');

describe('home route', () => {
  it('renders its heading', async () => {
    render(await HomePage());

    expect(
      screen.getByRole('heading', { level: 1, name: messages.dev.title }),
    ).toBeInTheDocument();
  });

  it('renders copy from the message catalogue', async () => {
    render(await HomePage());

    expect(screen.getByText(messages.dev.subtitle)).toBeInTheDocument();
    expect(screen.getByText(messages.dev.footer)).toBeInTheDocument();
  });

  it('renders the snapshot the server produced', async () => {
    render(await HomePage());

    expect(screen.getByText(messages.dev.backend.connected)).toBeInTheDocument();
    expect(screen.getByRole('row', { name: /GBP/ })).toBeInTheDocument();
  });
});
