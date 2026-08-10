import { describe, expect, it } from 'vitest';

import type { Database } from '@/types/database';

/**
 * T04 — the Schema B contract, asserted at the application-test layer.
 *
 * The constraints themselves are tested in the database, by
 * `supabase/tests/database/schema_b.test.sql`. What this file locks down is the
 * thing SQL cannot see: that the *generated* types the application is compiled
 * against still describe the schema T04 specified. A column dropped in a later
 * migration, or a band column quietly given its own enum, would show up here as
 * a typecheck failure rather than as a runtime surprise in T19 or T22.
 *
 * How the two halves fit together:
 *
 *   * The `Equal<keyof Row, …>` assertions below are **compile-time** and exact
 *     in both directions — a missing column and an unannounced extra column
 *     both fail `npm run typecheck`.
 *   * The runtime assertions then reason over the same declared column lists.
 *     They are only meaningful *because* the compile-time half pins those lists
 *     to the generated types; on their own they would be tautologies.
 *
 * `src/types/database.ts` is generated and never hand-edited (T02, RUNBOOK §7).
 */

type Expect<T extends true> = T;
type Equal<A, B> =
  (<T>() => T extends A ? 1 : 2) extends <T>() => T extends B ? 1 : 2 ? true : false;

type Tables = Database['public']['Tables'];
type Enums = Database['public']['Enums'];

// --- deals -----------------------------------------------------------------

const dealColumns = [
  'id',
  'market_id',
  // The two ADR-007 scope keys. Denormalised so a composite foreign key can
  // assert that the retailer product and the listing belong to this market.
  'retailer_id',
  'marketplace_id',
  'retailer_product_id',
  'marketplace_product_id',
  'match_confidence',
  'currency',
  'buy_price_minor',
  'buy_price_tax_treatment',
  'buy_tax_reclaim_minor',
  'inbound_shipping_minor',
  'prep_cost_minor',
  'sell_price_minor',
  'sell_tax_liability_minor',
  'referral_fee_minor',
  'fulfilment_fee_minor',
  'storage_fee_minor',
  'other_fees_minor',
  'surcharges',
  'fee_schedule_id',
  'tax_schedule_id',
  'net_profit_minor',
  'roi_bps',
  'margin_bps',
  'deal_score',
  'demand_band',
  'competition_band',
  'stability_band',
  'confidence_band',
  'score_breakdown',
  'calc_version',
  'score_version',
  'inputs_snapshot',
  'computed_at',
  'expires_at',
  'status',
  // Publish/retire audit (ADR-0009). T04 records who and when; T20A and T33
  // own who is *allowed* to do it.
  'published_at',
  'published_by',
  'retired_at',
  'retired_by',
  'retire_reason',
  'created_at',
  'updated_at',
] as const;

const dealUnlockColumns = [
  'id',
  'user_id',
  'deal_id',
  'credits_spent',
  'unlocked_at',
  'created_at',
  'updated_at',
] as const;

const watchlistItemColumns = [
  'id',
  'user_id',
  'deal_id',
  'marketplace_product_id',
  'target_profit_minor',
  'currency',
  'note',
  'created_at',
  'updated_at',
] as const;

const purchaseRecordColumns = [
  'id',
  'user_id',
  'deal_id',
  'market_id',
  'units',
  'actual_buy_price_minor',
  'currency',
  'expected_profit_minor',
  'purchased_at',
  'outcome',
  'actual_sale_price_minor',
  'actual_profit_minor',
  'notes',
  'inputs_snapshot',
  'created_at',
  'updated_at',
] as const;

const barcodeLookupColumns = [
  'id',
  'user_id',
  'market_id',
  'barcode_raw',
  'gtin14',
  'resolved_marketplace_product_id',
  'credits_spent',
  'result',
  'created_at',
  'updated_at',
] as const;

// Compile-time exactness. Each is `true` only if the generated Row type has
// precisely these columns — no more, no fewer.
const dealsAreExact: Expect<Equal<keyof Tables['deals']['Row'], (typeof dealColumns)[number]>> =
  true;
const dealUnlocksAreExact: Expect<
  Equal<keyof Tables['deal_unlocks']['Row'], (typeof dealUnlockColumns)[number]>
> = true;
const watchlistItemsAreExact: Expect<
  Equal<keyof Tables['watchlist_items']['Row'], (typeof watchlistItemColumns)[number]>
> = true;
const purchaseRecordsAreExact: Expect<
  Equal<keyof Tables['purchase_records']['Row'], (typeof purchaseRecordColumns)[number]>
> = true;
const barcodeLookupsAreExact: Expect<
  Equal<keyof Tables['barcode_lookups']['Row'], (typeof barcodeLookupColumns)[number]>
> = true;

// One shared band enum, reused four times — not four near-identical types.
const demandBandIsComponentBand: Expect<
  Equal<Tables['deals']['Row']['demand_band'], Enums['component_band']>
> = true;
const competitionBandIsComponentBand: Expect<
  Equal<Tables['deals']['Row']['competition_band'], Enums['component_band']>
> = true;
const stabilityBandIsComponentBand: Expect<
  Equal<Tables['deals']['Row']['stability_band'], Enums['component_band']>
> = true;
const confidenceBandIsComponentBand: Expect<
  Equal<Tables['deals']['Row']['confidence_band'], Enums['component_band']>
> = true;

// The retail price basis reuses T03's enum rather than declaring a second
// inclusive/exclusive type.
const buyBasisReusesT03Enum: Expect<
  Equal<Tables['deals']['Row']['buy_price_tax_treatment'], Enums['price_tax_treatment']>
> = true;

// Money is a non-nullable integer minor-unit amount beside a non-nullable
// currency. `string | null` here would mean a currency-free amount was
// representable in the type the application is compiled against, whatever the
// database says (§2.4, §11.2).
const dealCurrencyIsRequired: Expect<Equal<Tables['deals']['Row']['currency'], string>> = true;
const netProfitIsNumber: Expect<Equal<Tables['deals']['Row']['net_profit_minor'], number>> = true;
const roiIsNumber: Expect<Equal<Tables['deals']['Row']['roi_bps'], number>> = true;

// The lifecycle (ADR-0009). `stale` is absent by construction: staleness is
// derived at read time from deals.expires_at and
// marketplace_products.refreshed_at, and a derived fact stored as a state is a
// fact that goes wrong between the runs of whatever writes it.
const dealStatusIsLifecycle: Expect<
  Equal<Enums['deal_status'], 'draft' | 'active' | 'retired'>
> = true;
// `status` is non-nullable on read and optional on insert — the DEFAULT 'draft'
// is what makes a pipeline that forgets it fail closed rather than publish.
const statusIsRequiredOnRead: Expect<Equal<Tables['deals']['Row']['status'], Enums['deal_status']>> =
  true;
const statusIsOptionalOnInsert: Expect<
  Equal<Tables['deals']['Insert']['status'], Enums['deal_status'] | undefined>
> = true;

const tableColumns: ReadonlyArray<readonly [string, readonly string[]]> = [
  ['deals', dealColumns],
  ['deal_unlocks', dealUnlockColumns],
  ['watchlist_items', watchlistItemColumns],
  ['purchase_records', purchaseRecordColumns],
  ['barcode_lookups', barcodeLookupColumns],
];

describe('Schema B (T04) generated types', () => {
  it('describes every T04 table with exactly the columns the task specifies', () => {
    expect([
      dealsAreExact,
      dealUnlocksAreExact,
      watchlistItemsAreExact,
      purchaseRecordsAreExact,
      barcodeLookupsAreExact,
    ]).toEqual([true, true, true, true, true]);
  });

  it('gives all four band columns one shared enum, and reuses T03s price basis', () => {
    expect([
      demandBandIsComponentBand,
      competitionBandIsComponentBand,
      stabilityBandIsComponentBand,
      confidenceBandIsComponentBand,
      buyBasisReusesT03Enum,
    ]).toEqual([true, true, true, true, true]);
  });

  it('types money as a required integer amount beside a required currency', () => {
    expect([dealCurrencyIsRequired, netProfitIsNumber, roiIsNumber]).toEqual([true, true, true]);
  });

  it('types the deal lifecycle as draft | active | retired, defaulting on insert', () => {
    expect([dealStatusIsLifecycle, statusIsRequiredOnRead, statusIsOptionalOnInsert]).toEqual([
      true,
      true,
      true,
    ]);
  });

  it('stores no staleness or freshness state — it is derived from timestamps', () => {
    for (const [, columns] of tableColumns) {
      expect(columns.filter((column) => /stale|fresh/i.test(column))).toEqual([]);
    }

    // The two timestamps staleness is derived from. `refreshed_at` lives on
    // marketplace_products (T03); `expires_at` is the deal's own horizon.
    expect(dealColumns).toContain('expires_at');
    expect(dealColumns).toContain('computed_at');
  });

  it('records who published and who retired, and when', () => {
    expect(dealColumns).toContain('published_at');
    expect(dealColumns).toContain('published_by');
    expect(dealColumns).toContain('retired_at');
    expect(dealColumns).toContain('retired_by');
    expect(dealColumns).toContain('retire_reason');
  });

  // §0.3: adding a marketplace must cost one adapter and some rows. A core
  // column named after Amazon, Keepa, FBA or a tax regime would make that
  // false, and would make it false in the one place the whole application is
  // typed against.
  it.each(tableColumns)('%s names no marketplace, provider, tax regime or currency', (_, columns) => {
    const forbidden = /(amazon|asin|keepa|fba|fbm|ebay|buybox|vat|gst|gbp|usd)/i;
    expect(columns.filter((column) => forbidden.test(column))).toEqual([]);
  });

  it('pairs every money amount on a deal with the currency column it is denominated in', () => {
    const amounts = dealColumns.filter((column) => column.endsWith('_minor'));

    // The itemised breakdown §2.3 requires: costs, revenue, fees and the net.
    expect(amounts.length).toBeGreaterThanOrEqual(11);
    expect(dealColumns).toContain('currency');
  });

  it('carries the frozen provenance that makes a historical figure reproducible', () => {
    // AC6.10 for deals, AC14.3 for the purchase that is judged against them.
    expect(dealColumns).toContain('inputs_snapshot');
    expect(dealColumns).toContain('calc_version');
    expect(dealColumns).toContain('score_version');
    expect(dealColumns).toContain('fee_schedule_id');
    expect(dealColumns).toContain('tax_schedule_id');
    expect(purchaseRecordColumns).toContain('inputs_snapshot');
    expect(purchaseRecordColumns).toContain('expected_profit_minor');
  });
});
