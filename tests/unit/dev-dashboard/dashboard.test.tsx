import { render, screen, within } from '@testing-library/react';
import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';

import { DevDashboard } from '@/components/dev/dev-dashboard';
import { UNANSWERED } from '@/lib/dev-dashboard/format';
import type { DevDashboardSnapshot } from '@/lib/dev-dashboard/types';
import { messages } from '@/messages/en';

const copy = messages.dev;

const POPULATED: DevDashboardSnapshot = {
  backend: 'connected',
  counts: {
    markets: 1,
    retailers: 2,
    retailerProducts: 12345,
    marketplaceProducts: 42,
    deals: 21,
    creditPacks: 3,
    creditPurchases: 4,
    profiles: 1200,
  },
  dealLifecycle: { draft: 7, active: 11, retired: 3 },
  currencies: [
    { code: 'GBP', minorUnitExponent: 2, name: 'Pound Sterling' },
    { code: 'JPY', minorUnitExponent: 0, name: 'Yen' },
  ],
  system: {
    environment: 'development',
    databaseTypesAvailable: true,
    serverCredentialsConfigured: true,
  },
};

const EMPTY: DevDashboardSnapshot = {
  backend: 'connected',
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
  currencies: [],
  system: {
    environment: 'development',
    databaseTypesAvailable: true,
    serverCredentialsConfigured: true,
  },
};

const OFFLINE: DevDashboardSnapshot = {
  backend: 'unavailable',
  counts: {
    markets: null,
    retailers: null,
    retailerProducts: null,
    marketplaceProducts: null,
    deals: null,
    creditPacks: null,
    creditPurchases: null,
    profiles: null,
  },
  dealLifecycle: { draft: null, active: null, retired: null },
  currencies: [],
  system: {
    environment: 'development',
    databaseTypesAvailable: true,
    serverCredentialsConfigured: false,
  },
};

/** The figure rendered in the card whose label is `label`. */
function statValue(label: string): string {
  const term = screen.getByText(label);
  const card = term.closest('div');
  expect(card).not.toBeNull();
  return within(card as HTMLElement)
    .getByRole('definition')
    .textContent?.trim() as string;
}

describe('DevDashboard', () => {
  describe('with a populated database', () => {
    it('renders the page header', () => {
      render(<DevDashboard snapshot={POPULATED} />);

      expect(screen.getByRole('heading', { level: 1, name: copy.title })).toBeInTheDocument();
      expect(screen.getByText(copy.subtitle)).toBeInTheDocument();
    });

    it('reports the backend as connected', () => {
      render(<DevDashboard snapshot={POPULATED} />);

      expect(screen.getByText(copy.backend.connected)).toBeInTheDocument();
      expect(screen.queryByText(copy.backendError.title)).not.toBeInTheDocument();
    });

    it('formats each table count and attaches it to the right label', () => {
      render(<DevDashboard snapshot={POPULATED} />);

      expect(statValue(copy.tables.markets)).toBe('1');
      expect(statValue(copy.tables.retailers)).toBe('2');
      expect(statValue(copy.tables.retailerProducts)).toBe('12,345');
      expect(statValue(copy.tables.marketplaceProducts)).toBe('42');
      expect(statValue(copy.tables.deals)).toBe('21');
      expect(statValue(copy.tables.creditPacks)).toBe('3');
      expect(statValue(copy.tables.creditPurchases)).toBe('4');
      expect(statValue(copy.tables.profiles)).toBe('1,200');
    });

    it('maps the deal lifecycle counts to draft, active and retired', () => {
      render(<DevDashboard snapshot={POPULATED} />);

      expect(statValue(copy.lifecycle.draft)).toBe('7');
      expect(statValue(copy.lifecycle.active)).toBe('11');
      expect(statValue(copy.lifecycle.retired)).toBe('3');
    });

    it('renders each currency with its ISO code and minor-unit exponent', () => {
      render(<DevDashboard snapshot={POPULATED} />);

      const gbp = screen.getByRole('row', { name: /GBP/ });
      expect(within(gbp).getByText('Pound Sterling')).toBeInTheDocument();
      expect(within(gbp).getByText('2')).toBeInTheDocument();

      // A zero-exponent currency renders its zero, rather than being treated as
      // a missing value — the whole reason the exponent is data (§2.2).
      const jpy = screen.getByRole('row', { name: /JPY/ });
      expect(within(jpy).getByText('0')).toBeInTheDocument();

      expect(screen.queryByText(copy.currencies.empty)).not.toBeInTheDocument();
    });

    it('reports system status without naming a variable or a value', () => {
      render(<DevDashboard snapshot={POPULATED} />);

      expect(screen.getByText(copy.system.databaseConnected)).toBeInTheDocument();
      expect(screen.getByText(copy.system.environments.development)).toBeInTheDocument();
      expect(screen.getByText(copy.system.typesAvailable)).toBeInTheDocument();
      expect(screen.getByText(copy.system.credentialsConfigured)).toBeInTheDocument();
    });
  });

  describe('with an empty database', () => {
    it('renders zero counts as zero', () => {
      render(<DevDashboard snapshot={EMPTY} />);

      expect(statValue(copy.tables.deals)).toBe('0');
      expect(statValue(copy.tables.profiles)).toBe('0');
      expect(statValue(copy.lifecycle.active)).toBe('0');
    });

    it('renders an empty currencies table as an empty state, not as rows', () => {
      render(<DevDashboard snapshot={EMPTY} />);

      expect(screen.getByText(copy.currencies.empty)).toBeInTheDocument();
      expect(screen.queryByRole('table')).not.toBeInTheDocument();
    });

    it('still reports the backend as connected', () => {
      render(<DevDashboard snapshot={EMPTY} />);

      expect(screen.getByText(copy.backend.connected)).toBeInTheDocument();
    });
  });

  describe('when the backend is unavailable', () => {
    it('still renders the page', () => {
      render(<DevDashboard snapshot={OFFLINE} />);

      expect(screen.getByRole('heading', { level: 1, name: copy.title })).toBeInTheDocument();
      expect(screen.queryByRole('table')).not.toBeInTheDocument();
    });

    it('does not claim the currencies table is empty when it could not be read', () => {
      render(<DevDashboard snapshot={OFFLINE} />);

      expect(screen.getByText(copy.currencies.unavailable)).toBeInTheDocument();
      expect(screen.queryByText(copy.currencies.empty)).not.toBeInTheDocument();
    });

    it('shows an understated error state instead of a healthy indicator', () => {
      render(<DevDashboard snapshot={OFFLINE} />);

      expect(screen.getByText(copy.backend.unavailable)).toBeInTheDocument();
      expect(screen.queryByText(copy.backend.connected)).not.toBeInTheDocument();
      expect(screen.getByText(copy.backendError.title)).toBeInTheDocument();
      expect(screen.getByText(copy.system.databaseUnavailable)).toBeInTheDocument();
    });

    it('shows unanswered counts as a placeholder rather than a fabricated zero', () => {
      render(<DevDashboard snapshot={OFFLINE} />);

      expect(statValue(copy.tables.deals)).toBe(UNANSWERED);
      expect(statValue(copy.lifecycle.active)).toBe(UNANSWERED);
      expect(screen.queryByText('0')).not.toBeInTheDocument();
    });

    it('exposes no stack trace, connection string or internal detail', () => {
      const markup = renderToStaticMarkup(<DevDashboard snapshot={OFFLINE} />);

      for (const forbidden of [
        'postgres',
        'supabase.co',
        'ECONNREFUSED',
        'service_role',
        'at Object.',
        'Error:',
      ]) {
        expect(markup).not.toContain(forbidden);
      }
    });
  });

  describe('privileged values', () => {
    it('renders no credential into the HTML the browser receives', () => {
      // Values shaped like the real ones. None is passed to the component,
      // which is the point: the snapshot is the entire input, so nothing the
      // process happens to hold can reach the markup.
      const secrets = [
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.service-role-key',
        'sb_secret_do_not_render',
        'postgresql://postgres:hunter2@db.example.supabase.co:5432/postgres',
        'https://abcdefghijklmnop.supabase.co',
      ];

      const markup = [POPULATED, EMPTY, OFFLINE]
        .map((snapshot) => renderToStaticMarkup(<DevDashboard snapshot={snapshot} />))
        .join('\n');

      for (const secret of secrets) {
        expect(markup).not.toContain(secret);
      }
      // Nothing key-shaped, and no environment variable named at all. The word
      // "Supabase" itself is expected — it is the label of a status row.
      expect(markup).not.toMatch(/eyJ[A-Za-z0-9_-]{6,}/);
      expect(markup).not.toMatch(/NEXT_PUBLIC_[A-Z_]+/);
      expect(markup).not.toMatch(/SUPABASE_[A-Z_]+/i);
      expect(markup).not.toMatch(/SERVICE_ROLE/i);
      expect(markup).not.toMatch(/\bsb_(secret|publishable)_/i);
    });
  });
});
