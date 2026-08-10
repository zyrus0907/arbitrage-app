/**
 * The only place user-facing copy lives (ARCHITECTURE.md §4.2, §13).
 *
 * Components read keys from here rather than embedding strings, so translation
 * later is a data exercise rather than a rewrite. No currency symbol, no date
 * format and no country name belongs in this file.
 */
export const messages = {
  app: {
    name: 'Arbitrage',
    tagline: 'Defensible numbers for retail arbitrage.',
  },
  /**
   * Development dashboard. Internal tooling, not product copy — this block is
   * removed with `src/components/dev/` and `src/lib/dev-dashboard/`.
   */
  dev: {
    badge: 'Dev',
    title: 'Arbitrage App',
    subtitle: 'Development Dashboard',
    backend: {
      connected: 'Backend connected',
      unavailable: 'Backend unavailable',
    },
    backendError: {
      title: 'The database did not answer.',
      body: 'Counts and reference data are unavailable for this request. Diagnostic detail is deliberately not shown here — check the server logs.',
    },
    tables: {
      heading: 'Tables',
      description: 'Live row counts, read server-side on every request.',
      markets: 'Markets',
      retailers: 'Retailers',
      retailerProducts: 'Retailer products',
      marketplaceProducts: 'Marketplace products',
      deals: 'Deals',
      creditPacks: 'Credit packs',
      creditPurchases: 'Credit purchases',
      profiles: 'Users / profiles',
    },
    lifecycle: {
      heading: 'Deal lifecycle',
      description: 'Counted from deals.status. A deal starts as a draft, may be published, and retirement is terminal.',
      draft: 'Draft',
      active: 'Active',
      retired: 'Retired',
    },
    currencies: {
      heading: 'Reference data',
      description: 'Minor-unit exponents come from the database, never from an assumed hundredth.',
      code: 'ISO code',
      name: 'Name',
      exponent: 'Minor unit exponent',
      empty: 'No currency rows in this database yet.',
      unavailable: 'Currency rows could not be read.',
    },
    system: {
      heading: 'System',
      database: 'Supabase database',
      databaseConnected: 'Connected',
      databaseUnavailable: 'Error',
      environment: 'Environment',
      environments: {
        development: 'Development',
        test: 'Test',
        production: 'Production',
      },
      types: 'Database types',
      typesAvailable: 'Available',
      typesUnavailable: 'Unavailable',
      credentials: 'Server credentials',
      credentialsConfigured: 'Configured',
      credentialsMissing: 'Missing',
    },
    footer:
      'Development tooling. Read-only, rendered on the server, and safe to remove — it is not part of the product interface.',
  },
} as const;

export type Messages = typeof messages;
