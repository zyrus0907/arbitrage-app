import type { SupabaseClient } from '@supabase/supabase-js';

import type { Database } from '@/types/database';

import type { CurrencyReference, DevDashboardData, RowCount } from './types';

/**
 * Development dashboard — the database reads.
 *
 * Takes a client rather than building one, so the whole read path is
 * exercisable in a unit test with no database and no credentials. The client is
 * built one layer up, in `snapshot.ts`, which is `server-only`.
 *
 * Every read is a count or a public reference row. Nothing here selects a
 * user-identifying column, a deal's identity, or a provider payload — the
 * dashboard's contract with the browser is aggregates plus `currencies`.
 */
export type DevDashboardClient = SupabaseClient<Database>;

/** `head: true` asks Postgres for the count and no rows at all. */
const HEAD_COUNT = { count: 'exact', head: true } as const;

/** A dashboard is not a data export; 25 currency rows is a sample, not a table dump. */
const CURRENCY_LIMIT = 25;

type CountQuery = PromiseLike<{ count: number | null; error: unknown }>;

/**
 * Resolve one count, converting *any* failure into `null`.
 *
 * Both branches matter: `error` covers a query Postgres refused, and the
 * `catch` covers a transport failure that rejects. Neither propagates, because
 * one unreadable table must not blank a page whose whole purpose is showing
 * what the backend currently holds. The error object itself is dropped on the
 * floor here — it can carry a connection string or a provider message, and this
 * value ends up in server-rendered HTML.
 */
async function readCount(query: CountQuery): Promise<RowCount> {
  try {
    const { count, error } = await query;
    if (error) return null;
    return count ?? null;
  } catch {
    return null;
  }
}

type CurrencyRead = { ok: boolean; rows: CurrencyReference[] };

async function readCurrencies(client: DevDashboardClient): Promise<CurrencyRead> {
  try {
    const { data, error } = await client
      .from('currencies')
      .select('code, minor_unit_exponent, name')
      .order('code', { ascending: true })
      .limit(CURRENCY_LIMIT);

    if (error || !data) return { ok: false, rows: [] };

    return {
      ok: true,
      rows: data.map((row) => ({
        code: row.code,
        minorUnitExponent: row.minor_unit_exponent,
        name: row.name,
      })),
    };
  } catch {
    return { ok: false, rows: [] };
  }
}

/** The snapshot a dashboard shows when no query could be attempted at all. */
export function unavailableDevDashboardData(): DevDashboardData {
  return {
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
  };
}

/**
 * Read every dashboard figure in parallel.
 *
 * The `currencies` read doubles as the connectivity probe: it is the one query
 * whose success means a real round trip completed and returned rows. "Backend
 * connected" is therefore never asserted from configuration being present — it
 * is asserted from a query that actually answered.
 */
export async function collectDevDashboardData(
  client: DevDashboardClient,
): Promise<DevDashboardData> {
  try {
    return await readAll(client);
  } catch {
    // `readAll` already converts a failed *query* to `null`, so reaching here
    // means the client itself is unusable. The page still renders.
    return unavailableDevDashboardData();
  }
}

async function readAll(client: DevDashboardClient): Promise<DevDashboardData> {
  const [
    markets,
    retailers,
    retailerProducts,
    marketplaceProducts,
    deals,
    creditPacks,
    creditPurchases,
    profiles,
    draft,
    active,
    retired,
    currencies,
  ] = await Promise.all([
    readCount(client.from('markets').select('*', HEAD_COUNT)),
    readCount(client.from('retailers').select('*', HEAD_COUNT)),
    readCount(client.from('retailer_products').select('*', HEAD_COUNT)),
    readCount(client.from('marketplace_products').select('*', HEAD_COUNT)),
    readCount(client.from('deals').select('*', HEAD_COUNT)),
    readCount(client.from('credit_packs').select('*', HEAD_COUNT)),
    readCount(client.from('credit_purchases').select('*', HEAD_COUNT)),
    readCount(client.from('profiles').select('*', HEAD_COUNT)),
    readCount(client.from('deals').select('*', HEAD_COUNT).eq('status', 'draft')),
    readCount(client.from('deals').select('*', HEAD_COUNT).eq('status', 'active')),
    readCount(client.from('deals').select('*', HEAD_COUNT).eq('status', 'retired')),
    readCurrencies(client),
  ]);

  return {
    backend: currencies.ok ? 'connected' : 'unavailable',
    counts: {
      markets,
      retailers,
      retailerProducts,
      marketplaceProducts,
      deals,
      creditPacks,
      creditPurchases,
      profiles,
    },
    dealLifecycle: { draft, active, retired },
    currencies: currencies.rows,
  };
}
