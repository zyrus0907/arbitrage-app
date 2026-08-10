import { describe, expect, it } from 'vitest';

import {
  collectDevDashboardData,
  unavailableDevDashboardData,
  type DevDashboardClient,
} from '@/lib/dev-dashboard/collect';

/**
 * The dashboard's read path, exercised with no database and no credentials.
 *
 * The fake below is deliberately hostile: every failure it simulates carries a
 * connection string and a key-shaped token in its message, so a test that
 * passes proves the snapshot cannot leak one.
 */
const LEAKY_ERROR = {
  message:
    'connect ECONNREFUSED postgresql://postgres:sup3r-s3cret@db.example.supabase.co:5432/postgres',
  hint: 'service_role key eyJhbGciOiJIUzI1NiJ9.not-a-real-key',
};

type FakeSpec = {
  counts?: Record<string, number>;
  statusCounts?: Record<string, number>;
  currencies?: Array<{ code: string; minor_unit_exponent: number; name: string }>;
  /** Tables whose reads resolve with a Postgrest error. */
  errorOn?: string[];
  /** Tables whose reads reject, as a dropped connection does. */
  rejectOn?: string[];
};

function createFakeClient(spec: FakeSpec = {}) {
  const tablesQueried: string[] = [];
  const statusFilters: string[] = [];

  const client = {
    from(table: string) {
      tablesQueried.push(table);
      const errors = spec.errorOn?.includes(table) ?? false;
      const rejects = spec.rejectOn?.includes(table) ?? false;
      const rejection = () => Promise.reject(new Error(LEAKY_ERROR.message));

      return {
        select(_columns: string, options?: { count: 'exact'; head: true }) {
          if (options?.head === true) {
            const result = errors
              ? { count: null, error: LEAKY_ERROR }
              : { count: spec.counts?.[table] ?? 0, error: null };

            return {
              eq(_column: string, value: string) {
                statusFilters.push(value);
                if (rejects) return rejection();
                return Promise.resolve(
                  errors
                    ? { count: null, error: LEAKY_ERROR }
                    : { count: spec.statusCounts?.[value] ?? 0, error: null },
                );
              },
              then(onfulfilled?: (value: unknown) => unknown, onrejected?: (r: unknown) => unknown) {
                if (rejects) return rejection().then(onfulfilled, onrejected);
                return Promise.resolve(result).then(onfulfilled, onrejected);
              },
            };
          }

          const rows = errors
            ? { data: null, error: LEAKY_ERROR }
            : { data: spec.currencies ?? [], error: null };
          const builder = {
            order: () => builder,
            limit: () => (rejects ? rejection() : Promise.resolve(rows)),
          };
          return builder;
        },
      };
    },
  };

  return {
    client: client as unknown as DevDashboardClient,
    tablesQueried,
    statusFilters,
  };
}

describe('collectDevDashboardData', () => {
  it('reports the real count for each of the eight tables', async () => {
    const { client, tablesQueried } = createFakeClient({
      counts: {
        markets: 1,
        retailers: 2,
        retailer_products: 12345,
        marketplace_products: 42,
        deals: 21,
        credit_packs: 3,
        credit_purchases: 4,
        profiles: 1200,
      },
    });

    const data = await collectDevDashboardData(client);

    expect(data.counts).toEqual({
      markets: 1,
      retailers: 2,
      retailerProducts: 12345,
      marketplaceProducts: 42,
      deals: 21,
      creditPacks: 3,
      creditPurchases: 4,
      profiles: 1200,
    });
    // The counts come from the tables they claim to, not from a stand-in.
    expect(tablesQueried).toContain('retailer_products');
    expect(tablesQueried).toContain('marketplace_products');
    expect(tablesQueried).toContain('credit_purchases');
    expect(tablesQueried).toContain('profiles');
  });

  it('maps deal lifecycle counts to draft, active and retired', async () => {
    const { client, statusFilters } = createFakeClient({
      counts: { deals: 21 },
      statusCounts: { draft: 7, active: 11, retired: 3 },
    });

    const data = await collectDevDashboardData(client);

    expect(data.dealLifecycle).toEqual({ draft: 7, active: 11, retired: 3 });
    // Filtered on the real status values, and on no others.
    expect(statusFilters.sort()).toEqual(['active', 'draft', 'retired']);
  });

  it('returns currency reference rows in the shape the table renders', async () => {
    const { client } = createFakeClient({
      currencies: [
        { code: 'GBP', minor_unit_exponent: 2, name: 'Pound Sterling' },
        { code: 'JPY', minor_unit_exponent: 0, name: 'Yen' },
      ],
    });

    const data = await collectDevDashboardData(client);

    expect(data.backend).toBe('connected');
    expect(data.currencies).toEqual([
      { code: 'GBP', minorUnitExponent: 2, name: 'Pound Sterling' },
      { code: 'JPY', minorUnitExponent: 0, name: 'Yen' },
    ]);
  });

  it('reports an empty database as zero and connected, not as a failure', async () => {
    const { client } = createFakeClient({ currencies: [] });

    const data = await collectDevDashboardData(client);

    expect(data.backend).toBe('connected');
    expect(Object.values(data.counts)).toEqual([0, 0, 0, 0, 0, 0, 0, 0]);
    expect(data.dealLifecycle).toEqual({ draft: 0, active: 0, retired: 0 });
    expect(data.currencies).toEqual([]);
  });

  it('reports an unanswered count as null rather than zero', async () => {
    const { client } = createFakeClient({
      counts: { markets: 5 },
      errorOn: ['deals'],
    });

    const data = await collectDevDashboardData(client);

    expect(data.counts.markets).toBe(5);
    expect(data.counts.deals).toBeNull();
    expect(data.dealLifecycle).toEqual({ draft: null, active: null, retired: null });
    // One unreadable table is not a dead backend.
    expect(data.backend).toBe('connected');
  });

  it('marks the backend unavailable when the probe query errors', async () => {
    const { client } = createFakeClient({ errorOn: ['currencies'] });

    const data = await collectDevDashboardData(client);

    expect(data.backend).toBe('unavailable');
    expect(data.currencies).toEqual([]);
  });

  it('resolves rather than rejects when every read fails', async () => {
    const { client } = createFakeClient({
      rejectOn: [
        'markets',
        'retailers',
        'retailer_products',
        'marketplace_products',
        'deals',
        'credit_packs',
        'credit_purchases',
        'profiles',
        'currencies',
      ],
    });

    const data = await collectDevDashboardData(client);

    expect(data.backend).toBe('unavailable');
    expect(Object.values(data.counts).every((count) => count === null)).toBe(true);
  });

  it('survives a client that is structurally broken', async () => {
    const broken = {
      from() {
        throw new Error(LEAKY_ERROR.message);
      },
    } as unknown as DevDashboardClient;

    await expect(collectDevDashboardData(broken)).resolves.toEqual(unavailableDevDashboardData());
  });

  it('never carries an error message, credential or connection string into the snapshot', async () => {
    const { client } = createFakeClient({
      errorOn: ['currencies', 'deals'],
      rejectOn: ['profiles'],
    });

    const serialised = JSON.stringify(await collectDevDashboardData(client));

    expect(serialised).not.toContain('postgres');
    expect(serialised).not.toContain('sup3r-s3cret');
    expect(serialised).not.toContain('eyJ');
    expect(serialised).not.toContain('service_role');
    expect(serialised).not.toContain('ECONNREFUSED');
  });
});

describe('unavailableDevDashboardData', () => {
  it('describes a backend that answered nothing at all', () => {
    const data = unavailableDevDashboardData();

    expect(data.backend).toBe('unavailable');
    expect(Object.values(data.counts).every((count) => count === null)).toBe(true);
    expect(Object.values(data.dealLifecycle).every((count) => count === null)).toBe(true);
    expect(data.currencies).toEqual([]);
  });
});
