-- T04 — Schema B database tests (pgTAP), run by `npm run db:test`.
--
-- These assert the properties T04's acceptance criteria name, in the database
-- rather than through the application: the full column sets, the deal lifecycle
-- (ADR-0009), the live-pair unique index, the score and money constraints, enum
-- reuse, the privilege posture, and — the reason this task exists — that a
-- cross-market deal cannot be written by ANY path: single insert, update,
-- multi-row insert, INSERT ... SELECT from a staging table, or upsert.
--
-- pgTAP is created inside this transaction and rolled back with it, so the test
-- extension never appears in a migration and never reaches the hosted project.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog, pg_temp;

select plan(139);

-- ---------------------------------------------------------------------------
-- A. The five tables exist, and nothing marketplace-specific arrived with them
-- ---------------------------------------------------------------------------

select has_table('public', 'deals',            'deals exists');
select has_table('public', 'deal_unlocks',     'deal_unlocks exists');
select has_table('public', 'watchlist_items',  'watchlist_items exists');
select has_table('public', 'purchase_records', 'purchase_records exists');
select has_table('public', 'barcode_lookups',  'barcode_lookups exists');

-- The core schema stays marketplace-agnostic (§2.3, T03/T04 both). ASIN is one
-- possible value of marketplace_products.external_id and appears nowhere as a
-- schema concept; "Amazon", "Keepa", "FBA", "VAT" and "GBP" are data, not
-- identifiers. retailer_products.asin_hint is Schema A's one deliberate
-- exception — a retailer-supplied matching hint — and is not in scope here.
select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and (c.relname ~* '(amazon|asin|keepa|fba|ebay)')),
  0,
  'no marketplace-specific core table exists');

select is(
  (select count(*)::int
     from information_schema.columns
    where table_schema = 'public'
      and table_name in ('deals', 'deal_unlocks', 'watchlist_items',
                         'purchase_records', 'barcode_lookups')
      and (column_name ~* '(amazon|asin|keepa|fba|fbm|ebay|buybox|vat|gbp|gst)')),
  0,
  'no Schema B column names a marketplace, a provider, a tax regime or a currency');

-- ---------------------------------------------------------------------------
-- B. Full column sets (T04 enumerates them because "matches §2.3" reads loosely)
-- ---------------------------------------------------------------------------
--
-- columns_are is exact in both directions: a missing column fails, and so does
-- an unannounced extra one. retailer_id and marketplace_id are the two beyond
-- §2.3's list — the denormalised parent keys ADR-007's preferred mechanism
-- requires — and the five publish/retire audit columns are the product decision
-- recorded in ADR-0009. All are declared here rather than allowed to appear
-- quietly.

select columns_are('public', 'deals', array[
  'id', 'market_id', 'retailer_id', 'marketplace_id',
  'retailer_product_id', 'marketplace_product_id', 'match_confidence', 'currency',
  'buy_price_minor', 'buy_price_tax_treatment', 'buy_tax_reclaim_minor',
  'inbound_shipping_minor', 'prep_cost_minor',
  'sell_price_minor', 'sell_tax_liability_minor',
  'referral_fee_minor', 'fulfilment_fee_minor', 'storage_fee_minor',
  'other_fees_minor', 'surcharges', 'fee_schedule_id', 'tax_schedule_id',
  'net_profit_minor', 'roi_bps', 'margin_bps', 'deal_score',
  'demand_band', 'competition_band', 'stability_band', 'confidence_band',
  'score_breakdown',
  'calc_version', 'score_version', 'inputs_snapshot',
  'computed_at', 'expires_at', 'status',
  'published_at', 'published_by', 'retired_at', 'retired_by', 'retire_reason',
  'created_at', 'updated_at'
], 'deals carries every T04 column, the two ADR-007 scope keys and the ADR-0009 audit columns');

select columns_are('public', 'deal_unlocks', array[
  'id', 'user_id', 'deal_id', 'credits_spent', 'unlocked_at',
  'created_at', 'updated_at'
], 'deal_unlocks carries every column T04 enumerates');

select columns_are('public', 'watchlist_items', array[
  'id', 'user_id', 'deal_id', 'marketplace_product_id', 'target_profit_minor',
  'currency', 'note', 'created_at', 'updated_at'
], 'watchlist_items carries every column T04 enumerates');

select columns_are('public', 'purchase_records', array[
  'id', 'user_id', 'deal_id', 'market_id', 'units', 'actual_buy_price_minor',
  'currency', 'expected_profit_minor', 'purchased_at', 'outcome',
  'actual_sale_price_minor', 'actual_profit_minor', 'notes', 'inputs_snapshot',
  'created_at', 'updated_at'
], 'purchase_records carries every column T04 enumerates, including the frozen snapshot');

select columns_are('public', 'barcode_lookups', array[
  'id', 'user_id', 'market_id', 'barcode_raw', 'gtin14',
  'resolved_marketplace_product_id', 'credits_spent', 'result',
  'created_at', 'updated_at'
], 'barcode_lookups carries every column T04 enumerates');

-- ---------------------------------------------------------------------------
-- C. Enum discipline (T04: inventory before creating, no near-duplicates)
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typtype = 'e'),
  14,
  'fourteen enum types exist: T03''s nine, T04''s three and T05''s two');

select is(
  (select string_agg(e.enumlabel, '|' order by e.enumsortorder)
     from pg_type t join pg_enum e on e.enumtypid = t.oid
    where t.typname = 'component_band'),
  'low|medium|high',
  'component_band is the low|medium|high domain §2.3 gives the band columns');

-- The requirement in one assertion: ONE shared type, reused four times.
select is(
  (select count(distinct udt_name)::int
     from information_schema.columns
    where table_schema = 'public' and table_name = 'deals'
      and column_name in ('demand_band', 'competition_band', 'stability_band', 'confidence_band')),
  1,
  'all four band columns share one enum type, not four near-identical ones');

select is(
  (select count(*)::int
     from information_schema.columns
    where table_schema = 'public' and table_name = 'deals'
      and column_name in ('demand_band', 'competition_band', 'stability_band', 'confidence_band')
      and udt_name = 'component_band'),
  4,
  'and that shared type is component_band');

-- Reuse rather than a second inclusive/exclusive type.
select is(
  (select udt_name
     from information_schema.columns
    where table_schema = 'public' and table_name = 'deals'
      and column_name = 'buy_price_tax_treatment'),
  'price_tax_treatment',
  'the retail price basis reuses T03''s price_tax_treatment enum');

-- The general form of the rule, so a future task cannot add a near-duplicate
-- either: no two enum types in public may carry an identical set of labels.
select ok(
  not exists (
    select 1
      from (select array_agg(e.enumlabel order by e.enumlabel) as labels
              from pg_type t
              join pg_enum e on e.enumtypid = t.oid
              join pg_namespace n on n.oid = t.typnamespace
             where n.nspname = 'public'
             group by t.oid) s
     group by s.labels
    having count(*) > 1),
  'no two enum types share an identical label set — no near-duplicates exist');

-- ---------------------------------------------------------------------------
-- C2. Staleness is not a state (ADR-0009)
-- ---------------------------------------------------------------------------

select is(
  (select string_agg(e.enumlabel, '|' order by e.enumsortorder)
     from pg_type t join pg_enum e on e.enumtypid = t.oid
    where t.typname = 'deal_status'),
  'draft|active|retired',
  'deal_status is exactly draft | active | retired, in lifecycle order');

select is(
  (select count(*)::int
     from pg_type t join pg_enum e on e.enumtypid = t.oid
     join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and e.enumlabel = 'stale'),
  0,
  'no enum type anywhere in public carries a "stale" value');

-- Nor a boolean or timestamp standing in for one. Staleness is derived from
-- deals.expires_at and marketplace_products.refreshed_at at read time.
select is(
  (select count(*)::int
     from information_schema.columns
    where table_schema = 'public'
      and table_name in ('deals', 'deal_unlocks', 'watchlist_items',
                         'purchase_records', 'barcode_lookups')
      and column_name ~* '(stale|fresh)'),
  0,
  'and no Schema B column stores staleness or freshness as a stored fact');

select has_column('public', 'deals', 'expires_at',
  'the freshness horizon deals.expires_at exists — staleness is derived from it');

-- ---------------------------------------------------------------------------
-- Fixtures: two markets, in two countries, on two marketplaces, two currencies
-- ---------------------------------------------------------------------------
-- This is the shape T04's cross-market tests require. Everything below is
-- scoped to market A or market B and never to both. Several product pairs exist
-- per market because the live-pair unique index means one pair can hold only
-- one non-retired deal, and different sections need their own.

insert into public.countries
  (code, name, default_currency, default_locale, tax_regime, retail_price_display, timezone_default, active)
values
  ('AA', 'Testland',  'GBP', 'en-AA', 'vat',       'inclusive', 'UTC', true),
  ('BB', 'Otherland', 'USD', 'en-BB', 'sales_tax', 'exclusive', 'UTC', true);

insert into public.marketplaces
  (id, provider, code, country_code, currency, domain, adapter_key, active)
values
  ('10000000-0000-0000-0000-00000000000a', 'testprovider', 'test_aa', 'AA', 'GBP',
   'example.test', 'testadapter', true),
  ('10000000-0000-0000-0000-00000000000b', 'testprovider', 'test_bb', 'BB', 'USD',
   'example.test', 'testadapter', true);

insert into public.markets
  (id, slug, source_country_code, marketplace_id, currency, active, launch_status)
values
  ('20000000-0000-0000-0000-00000000000a', 'aa', 'AA',
   '10000000-0000-0000-0000-00000000000a', 'GBP', true, 'beta'),
  ('20000000-0000-0000-0000-00000000000b', 'bb', 'BB',
   '10000000-0000-0000-0000-00000000000b', 'USD', true, 'planned');

insert into public.retailers
  (id, name, slug, market_id, country_code, currency, source_type, price_display, active)
values
  ('30000000-0000-0000-0000-00000000000a', 'Retailer A', 'retailer-a',
   '20000000-0000-0000-0000-00000000000a', 'AA', 'GBP', 'curated', 'inclusive', true),
  ('30000000-0000-0000-0000-00000000000b', 'Retailer B', 'retailer-b',
   '20000000-0000-0000-0000-00000000000b', 'BB', 'USD', 'curated', 'exclusive', true);

insert into public.retailer_products
  (id, retailer_id, retailer_sku, gtin14, price_minor, currency, price_tax_treatment)
values
  ('40000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-00000000000a',
   'SKU-A1', '00012345678905', 1299, 'GBP', 'inclusive'),
  ('40000000-0000-0000-0000-0000000000a2', '30000000-0000-0000-0000-00000000000a',
   'SKU-A2', '00012345678912', 1399, 'GBP', 'inclusive'),
  ('40000000-0000-0000-0000-0000000000a3', '30000000-0000-0000-0000-00000000000a',
   'SKU-A3', '00012345678929', 1499, 'GBP', 'inclusive'),
  ('40000000-0000-0000-0000-0000000000b1', '30000000-0000-0000-0000-00000000000b',
   'SKU-B1', '00012345678905', 1499, 'USD', 'exclusive'),
  ('40000000-0000-0000-0000-0000000000b2', '30000000-0000-0000-0000-00000000000b',
   'SKU-B2', '00012345678912', 1599, 'USD', 'exclusive');

insert into public.marketplace_products
  (id, marketplace_id, external_id, currency, gtins, provider_key)
values
  ('50000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a',
   'EXT-A1', 'GBP', array['00012345678905'], 'testadapter'),
  ('50000000-0000-0000-0000-0000000000a2', '10000000-0000-0000-0000-00000000000a',
   'EXT-A2', 'GBP', array['00012345678912'], 'testadapter'),
  ('50000000-0000-0000-0000-0000000000a3', '10000000-0000-0000-0000-00000000000a',
   'EXT-A3', 'GBP', array['00012345678929'], 'testadapter'),
  ('50000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b',
   'EXT-B1', 'USD', array['00012345678905'], 'testadapter'),
  ('50000000-0000-0000-0000-0000000000b2', '10000000-0000-0000-0000-00000000000b',
   'EXT-B2', 'USD', array['00012345678912'], 'testadapter');

insert into public.fee_schedules
  (id, marketplace_id, version, effective_from, currency)
values
  ('60000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a',
   'test.v1', date '2026-01-01', 'GBP'),
  ('60000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b',
   'test.v1', date '2026-01-01', 'USD');

insert into public.tax_schedules
  (id, country_code, regime, standard_rate_bps, effective_from)
values
  ('70000000-0000-0000-0000-00000000000a', 'AA', 'vat',       2000, date '2026-01-01'),
  ('70000000-0000-0000-0000-00000000000b', 'BB', 'sales_tax',  700, date '2026-01-01');

insert into auth.users (id, email)
values ('90000000-0000-0000-0000-00000000000a', 'schema-b-a@example.test'),
       ('90000000-0000-0000-0000-00000000000b', 'schema-b-b@example.test');

-- A deal-writing helper, so each assertion below reads as the one thing it is
-- testing rather than as forty columns. It omits `status` entirely unless a
-- caller names one, so every ordinary insert exercises the DEFAULT 'draft'.
-- Created inside the transaction and rolled back with it.
create function public._deal_sql(
  p_id          uuid,
  p_market      uuid,
  p_retailer    uuid,
  p_marketplace uuid,
  p_rp          uuid,
  p_mp          uuid,
  p_currency    text default 'GBP',
  p_fee         uuid default '60000000-0000-0000-0000-00000000000a',
  p_tax         uuid default '70000000-0000-0000-0000-00000000000a',
  p_score       integer default 72,
  p_status      text default null,
  p_suffix      text default ''
) returns text
language sql
as $fn$
  select format($sql$
    insert into public.deals (
      id, market_id, retailer_id, marketplace_id,
      retailer_product_id, marketplace_product_id, match_confidence, currency,
      buy_price_minor, buy_price_tax_treatment,
      sell_price_minor, fee_schedule_id, tax_schedule_id,
      net_profit_minor, roi_bps, margin_bps, deal_score,
      demand_band, competition_band, stability_band, confidence_band,
      score_breakdown, calc_version, score_version, inputs_snapshot%s
    ) values (
      %L, %L, %L, %L,
      %L, %L, 0.99, %L,
      1299, 'inclusive',
      2599, %L, %L,
      640, 4200, 2461, %s,
      'high', 'medium', 'high', 'high',
      '{"version":"score.v1"}'::jsonb, 'calc.v1', 'score.v1', '{"marketId":"test"}'::jsonb%s
    ) %s$sql$,
    case when p_status is null then '' else ', status' end,
    p_id, p_market, p_retailer, p_marketplace, p_rp, p_mp, p_currency,
    p_fee, p_tax, p_score,
    case when p_status is null then '' else format(', %L', p_status) end,
    p_suffix);
$fn$;

-- ---------------------------------------------------------------------------
-- D. A correctly-scoped deal in each market is accepted, and they coexist
-- ---------------------------------------------------------------------------

select lives_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-00000000000a',
    '20000000-0000-0000-0000-00000000000a',
    '30000000-0000-0000-0000-00000000000a',
    '10000000-0000-0000-0000-00000000000a',
    '40000000-0000-0000-0000-0000000000a1',
    '50000000-0000-0000-0000-0000000000a1'),
  'a correctly-scoped deal in market A is accepted');

select lives_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-00000000000b',
    '20000000-0000-0000-0000-00000000000b',
    '30000000-0000-0000-0000-00000000000b',
    '10000000-0000-0000-0000-00000000000b',
    '40000000-0000-0000-0000-0000000000b1',
    '50000000-0000-0000-0000-0000000000b1',
    'USD',
    '60000000-0000-0000-0000-00000000000b',
    '70000000-0000-0000-0000-00000000000b'),
  'a correctly-scoped deal in market B is accepted');

-- Both are published, so the sections below exercise the state a user can see.
update public.deals set status = 'active'
 where id in ('80000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-00000000000b');

select is(
  (select count(*)::int from public.deals),
  2,
  'the two market-scoped deals coexist without interfering');

select is(
  (select count(distinct currency)::int from public.deals),
  2,
  'and they are denominated in their own market currencies, not a shared one');

-- ---------------------------------------------------------------------------
-- E. Cross-market rejection (ADR-007) — insert
-- ---------------------------------------------------------------------------

-- Rule 1: the deal claims market B while its retailer product belongs to a
-- retailer in market A.
select throws_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-0000000000c1',
    '20000000-0000-0000-0000-00000000000b',  -- market B
    '30000000-0000-0000-0000-00000000000a',  -- retailer A
    '10000000-0000-0000-0000-00000000000b',
    '40000000-0000-0000-0000-0000000000a1',  -- retailer product A
    '50000000-0000-0000-0000-0000000000b2',
    'USD',
    '60000000-0000-0000-0000-00000000000b',
    '70000000-0000-0000-0000-00000000000b'),
  '23503',
  null,
  'a deal whose market differs from its retailer product''s market is rejected');

-- Rule 1, the subtler half: the market and retailer agree, but the retailer
-- product belongs to a different retailer.
select throws_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-0000000000c2',
    '20000000-0000-0000-0000-00000000000a',
    '30000000-0000-0000-0000-00000000000a',  -- retailer A
    '10000000-0000-0000-0000-00000000000a',
    '40000000-0000-0000-0000-0000000000b1',  -- but retailer B's product
    '50000000-0000-0000-0000-0000000000a2'),
  '23503',
  'insert or update on table "deals" violates foreign key constraint "deals_retailer_product_fkey"',
  'a deal cannot borrow another retailer''s product to stay inside its market');

-- Rule 2: the marketplace product belongs to a marketplace other than the one
-- the deal's market resolves to.
select throws_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-0000000000c3',
    '20000000-0000-0000-0000-00000000000a',  -- market A → marketplace A
    '30000000-0000-0000-0000-00000000000a',
    '10000000-0000-0000-0000-00000000000a',
    '40000000-0000-0000-0000-0000000000a2',
    '50000000-0000-0000-0000-0000000000b2'), -- marketplace B's listing
  '23503',
  'insert or update on table "deals" violates foreign key constraint "deals_marketplace_product_fkey"',
  'a deal whose marketplace product sits on another marketplace is rejected');

-- Rule 2, stated the other way: the denormalised marketplace_id cannot be bent
-- to match the listing, because the market must resolve to it too.
select throws_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-0000000000c4',
    '20000000-0000-0000-0000-00000000000a',  -- market A
    '30000000-0000-0000-0000-00000000000a',
    '10000000-0000-0000-0000-00000000000b',  -- claims marketplace B
    '40000000-0000-0000-0000-0000000000a2',
    '50000000-0000-0000-0000-0000000000b2'),
  '23503',
  'insert or update on table "deals" violates foreign key constraint "deals_market_marketplace_fkey"',
  'the deal''s marketplace must be the one its market resolves to');

-- ---------------------------------------------------------------------------
-- F. Cross-market rejection — UPDATE, not only INSERT
-- ---------------------------------------------------------------------------

select throws_ok(
  $$update public.deals
       set market_id = '20000000-0000-0000-0000-00000000000b'
     where id = '80000000-0000-0000-0000-00000000000a'$$,
  '23503',
  null,
  'moving a valid deal''s market_id to the other market is rejected');

select throws_ok(
  $$update public.deals
       set marketplace_product_id = '50000000-0000-0000-0000-0000000000b1'
     where id = '80000000-0000-0000-0000-00000000000a'$$,
  '23503',
  null,
  'repointing a valid deal at another marketplace''s listing is rejected');

select throws_ok(
  $$update public.deals
       set retailer_product_id = '40000000-0000-0000-0000-0000000000b1'
     where id = '80000000-0000-0000-0000-00000000000a'$$,
  '23503',
  null,
  'repointing a valid deal at another market''s retailer product is rejected');

-- Rewriting every scope key at once to a consistent market B row is not a
-- violation — it is a different, internally consistent deal. The constraint
-- exists to forbid disagreement, not to freeze the row. A separate deal on its
-- own product pair is used so the move cannot collide with market B's deal.
select lives_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-0000000000c5',
    '20000000-0000-0000-0000-00000000000a',
    '30000000-0000-0000-0000-00000000000a',
    '10000000-0000-0000-0000-00000000000a',
    '40000000-0000-0000-0000-0000000000a3',
    '50000000-0000-0000-0000-0000000000a3'),
  'a third deal is created in market A, on its own product pair');

update public.deals set status = 'active' where id = '80000000-0000-0000-0000-0000000000c5';

select lives_ok(
  $$update public.deals
       set market_id = '20000000-0000-0000-0000-00000000000b',
           retailer_id = '30000000-0000-0000-0000-00000000000b',
           marketplace_id = '10000000-0000-0000-0000-00000000000b',
           retailer_product_id = '40000000-0000-0000-0000-0000000000b2',
           marketplace_product_id = '50000000-0000-0000-0000-0000000000b2',
           currency = 'USD',
           fee_schedule_id = '60000000-0000-0000-0000-00000000000b',
           tax_schedule_id = '70000000-0000-0000-0000-00000000000b'
     where id = '80000000-0000-0000-0000-0000000000c5'$$,
  'a wholesale, internally consistent move to the other market is permitted');

-- ---------------------------------------------------------------------------
-- G. The deal lifecycle (ADR-0009): draft → active → retired, retired terminal
-- ---------------------------------------------------------------------------
--
-- One deal is walked through its whole life on the (A2, A2) product pair.

select lives_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-000000000d01',
    '20000000-0000-0000-0000-00000000000a',
    '30000000-0000-0000-0000-00000000000a',
    '10000000-0000-0000-0000-00000000000a',
    '40000000-0000-0000-0000-0000000000a2',
    '50000000-0000-0000-0000-0000000000a2'),
  'a deal can be inserted without naming a status at all');

select is(
  (select status::text from public.deals where id = '80000000-0000-0000-0000-000000000d01'),
  'draft',
  'and it lands as draft — a newly computed deal is invisible until published (AC3.3)');

select is(
  (select published_at is null and retired_at is null
     from public.deals where id = '80000000-0000-0000-0000-000000000d01'),
  true,
  'with neither audit timestamp set');

-- Fail closed: not even an explicit request can create a published deal.
select throws_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-000000000d02',
    '20000000-0000-0000-0000-00000000000a',
    '30000000-0000-0000-0000-00000000000a',
    '10000000-0000-0000-0000-00000000000a',
    '40000000-0000-0000-0000-0000000000a2',
    '50000000-0000-0000-0000-0000000000a2',
    'GBP', '60000000-0000-0000-0000-00000000000a', '70000000-0000-0000-0000-00000000000a',
    72, 'active'),
  '23514',
  'a deal must be created as draft, not active',
  'inserting a deal directly as active is rejected — publication is always a later act');

select throws_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-000000000d03',
    '20000000-0000-0000-0000-00000000000a',
    '30000000-0000-0000-0000-00000000000a',
    '10000000-0000-0000-0000-00000000000a',
    '40000000-0000-0000-0000-0000000000a2',
    '50000000-0000-0000-0000-0000000000a2',
    'GBP', '60000000-0000-0000-0000-00000000000a', '70000000-0000-0000-0000-00000000000a',
    72, 'retired'),
  '23514',
  'a deal must be created as draft, not retired',
  'nor directly as retired');

-- draft → draft: a recompute rewriting a draft in place is normal.
select lives_ok(
  $$update public.deals set status = 'draft', deal_score = 74
     where id = '80000000-0000-0000-0000-000000000d01'$$,
  'draft -> draft is permitted — recomputing an unpublished deal is routine');

-- draft → active, with an explicit actor.
select lives_ok(
  $$update public.deals
       set status = 'active', published_by = '90000000-0000-0000-0000-00000000000a'
     where id = '80000000-0000-0000-0000-000000000d01'$$,
  'draft -> active is permitted');

select ok(
  (select published_at is not null from public.deals
    where id = '80000000-0000-0000-0000-000000000d01'),
  'and published_at is stamped even though the caller did not supply one');

select is(
  (select published_by from public.deals where id = '80000000-0000-0000-0000-000000000d01'),
  '90000000-0000-0000-0000-00000000000a'::uuid,
  'while the actor the caller did supply is recorded as given');

select lives_ok(
  $$update public.deals set status = 'active', deal_score = 75
     where id = '80000000-0000-0000-0000-000000000d01'$$,
  'active -> active is permitted — a published deal can be recomputed in place');

select throws_ok(
  $$update public.deals set status = 'draft'
     where id = '80000000-0000-0000-0000-000000000d01'$$,
  '23514',
  'deal status transition active -> draft is not permitted',
  'active -> draft is rejected — a published deal cannot be unpublished into a draft');

select lives_ok(
  $$update public.deals
       set status = 'retired',
           retired_by = '90000000-0000-0000-0000-00000000000a',
           retire_reason = 'superseded_in_test'
     where id = '80000000-0000-0000-0000-000000000d01'$$,
  'active -> retired is permitted');

select ok(
  (select retired_at is not null and published_at is not null
     from public.deals where id = '80000000-0000-0000-0000-000000000d01'),
  'retired_at is stamped, and published_at survives — the row still records that it was once live');

select throws_ok(
  $$update public.deals set status = 'active'
     where id = '80000000-0000-0000-0000-000000000d01'$$,
  '23514',
  'deal status transition retired -> active is not permitted',
  'retired -> active is rejected — retirement is permanent');

select throws_ok(
  $$update public.deals set status = 'draft'
     where id = '80000000-0000-0000-0000-000000000d01'$$,
  '23514',
  'deal status transition retired -> draft is not permitted',
  'retired -> draft is rejected — retired is terminal in both directions');

select lives_ok(
  $$update public.deals set retire_reason = 'superseded_in_test_corrected'
     where id = '80000000-0000-0000-0000-000000000d01'$$,
  'a retired deal can still have its other columns corrected — terminal is about state, not the row');

-- The audit columns cannot be made to disagree with the state.
select throws_ok(
  $$update public.deals set retire_reason = 'not retired though'
     where id = '80000000-0000-0000-0000-00000000000a'$$,
  '23514',
  null,
  'a retire reason on a deal that is not retired is rejected');

select throws_ok(
  $$update public.deals set retired_at = now()
     where id = '80000000-0000-0000-0000-00000000000a'$$,
  '23514',
  null,
  'a retirement timestamp on a deal that is not retired is rejected');

-- ---------------------------------------------------------------------------
-- H. One LIVE deal per product pair (partial unique index on status <> retired)
-- ---------------------------------------------------------------------------

select throws_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-000000000e01',
    '20000000-0000-0000-0000-00000000000a',
    '30000000-0000-0000-0000-00000000000a',
    '10000000-0000-0000-0000-00000000000a',
    '40000000-0000-0000-0000-0000000000a1',
    '50000000-0000-0000-0000-0000000000a1'),
  '23505',
  null,
  'a draft cannot be created for a pair that already has an active deal');

-- The pair whose only deal is retired is free again: this is the replacement
-- path a recompute takes after a bad deal is retired.
select lives_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-000000000e02',
    '20000000-0000-0000-0000-00000000000a',
    '30000000-0000-0000-0000-00000000000a',
    '10000000-0000-0000-0000-00000000000a',
    '40000000-0000-0000-0000-0000000000a2',
    '50000000-0000-0000-0000-0000000000a2'),
  'a retired deal does not block a fresh draft for the same product pair');

select throws_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-000000000e03',
    '20000000-0000-0000-0000-00000000000a',
    '30000000-0000-0000-0000-00000000000a',
    '10000000-0000-0000-0000-00000000000a',
    '40000000-0000-0000-0000-0000000000a2',
    '50000000-0000-0000-0000-0000000000a2'),
  '23505',
  null,
  'but two non-retired deals for one pair are rejected — draft and draft included');

select is(
  (select count(*)::int from public.deals
    where retailer_product_id = '40000000-0000-0000-0000-0000000000a2'
      and marketplace_product_id = '50000000-0000-0000-0000-0000000000a2'),
  2,
  'leaving exactly one retired and one live deal for that pair');

-- draft → retired directly, without ever being published.
select lives_ok(
  $$update public.deals set status = 'retired', retire_reason = 'never published'
     where id = '80000000-0000-0000-0000-000000000e02'$$,
  'draft -> retired is permitted — a deal can be discarded before it is ever seen');

select ok(
  (select retired_at is not null and published_at is null
     from public.deals where id = '80000000-0000-0000-0000-000000000e02'),
  'and it carries a retirement timestamp with no publication timestamp');

select has_index('public', 'deals', 'deals_live_pair_uniq',
  'the live-deal-per-pair index exists');

select matches(
  (select pg_get_indexdef(i.indexrelid)
     from pg_index i where i.indexrelid = 'public.deals_live_pair_uniq'::regclass),
  'WHERE \(status <> ''retired''',
  'and its predicate is status <> retired, so history never blocks a replacement');

-- ---------------------------------------------------------------------------
-- I. Bulk and upsert paths bypass neither the cross-market rules nor the lifecycle
-- ---------------------------------------------------------------------------
--
-- This is why ADR-0008 prefers declarative enforcement and why the lifecycle
-- trigger fires per row rather than per statement: T19's pipeline writes deals
-- in bulk as the service role, and T20 loads admin CSV. A guarantee that only
-- holds for single-row inserts is not a guarantee.

-- Multi-row insert: one good row, one cross-market row. The statement fails as
-- a whole and neither row lands.
select throws_ok(
  $$insert into public.deals (
      id, market_id, retailer_id, marketplace_id,
      retailer_product_id, marketplace_product_id, match_confidence, currency,
      buy_price_minor, buy_price_tax_treatment, sell_price_minor,
      fee_schedule_id, tax_schedule_id, net_profit_minor, roi_bps, margin_bps,
      deal_score, demand_band, competition_band, stability_band, confidence_band,
      score_breakdown, calc_version, score_version, inputs_snapshot
    ) values
    ('80000000-0000-0000-0000-000000000f01',
     '20000000-0000-0000-0000-00000000000a', '30000000-0000-0000-0000-00000000000a',
     '10000000-0000-0000-0000-00000000000a', '40000000-0000-0000-0000-0000000000a3',
     '50000000-0000-0000-0000-0000000000a3', 0.99, 'GBP', 1299, 'inclusive', 2599,
     '60000000-0000-0000-0000-00000000000a', '70000000-0000-0000-0000-00000000000a',
     640, 4200, 2461, 70, 'high', 'medium', 'high', 'high',
     '{}'::jsonb, 'calc.v1', 'score.v1', '{}'::jsonb),
    ('80000000-0000-0000-0000-000000000f02',
     '20000000-0000-0000-0000-00000000000a', '30000000-0000-0000-0000-00000000000a',
     '10000000-0000-0000-0000-00000000000a', '40000000-0000-0000-0000-0000000000a1',
     '50000000-0000-0000-0000-0000000000b1', 0.99, 'GBP', 1299, 'inclusive', 2599,
     '60000000-0000-0000-0000-00000000000a', '70000000-0000-0000-0000-00000000000a',
     640, 4200, 2461, 70, 'high', 'medium', 'high', 'high',
     '{}'::jsonb, 'calc.v1', 'score.v1', '{}'::jsonb)$$,
  '23503',
  null,
  'a multi-row insert containing one cross-market row is rejected');

select is(
  (select count(*)::int from public.deals
    where id in ('80000000-0000-0000-0000-000000000f01',
                 '80000000-0000-0000-0000-000000000f02')),
  0,
  'and neither row from that statement landed — not even the valid one');

-- The lifecycle is per row, so a bulk write cannot smuggle a published deal in
-- behind a valid draft either.
select throws_ok(
  $$insert into public.deals (
      id, market_id, retailer_id, marketplace_id,
      retailer_product_id, marketplace_product_id, match_confidence, currency,
      buy_price_minor, buy_price_tax_treatment, sell_price_minor,
      fee_schedule_id, tax_schedule_id, net_profit_minor, roi_bps, margin_bps,
      deal_score, demand_band, competition_band, stability_band, confidence_band,
      score_breakdown, calc_version, score_version, inputs_snapshot, status
    ) values
    ('80000000-0000-0000-0000-000000000f03',
     '20000000-0000-0000-0000-00000000000a', '30000000-0000-0000-0000-00000000000a',
     '10000000-0000-0000-0000-00000000000a', '40000000-0000-0000-0000-0000000000a3',
     '50000000-0000-0000-0000-0000000000a3', 0.99, 'GBP', 1299, 'inclusive', 2599,
     '60000000-0000-0000-0000-00000000000a', '70000000-0000-0000-0000-00000000000a',
     640, 4200, 2461, 70, 'high', 'medium', 'high', 'high',
     '{}'::jsonb, 'calc.v1', 'score.v1', '{}'::jsonb, 'active')$$,
  '23514',
  'a deal must be created as draft, not active',
  'a bulk insert cannot publish a deal either — the lifecycle is enforced per row');

-- INSERT ... SELECT from a staging table: the shape a COPY-loaded batch takes
-- on its way into the real table, and the shape T19's bulk upsert uses.
create table public._deal_bulk_staging (like public.deals including defaults);

insert into public._deal_bulk_staging (
  id, market_id, retailer_id, marketplace_id,
  retailer_product_id, marketplace_product_id, match_confidence, currency,
  buy_price_minor, buy_price_tax_treatment, sell_price_minor,
  fee_schedule_id, tax_schedule_id, net_profit_minor, roi_bps, margin_bps,
  deal_score, demand_band, competition_band, stability_band, confidence_band,
  score_breakdown, calc_version, score_version, inputs_snapshot, status
) values
  ('80000000-0000-0000-0000-000000000f04',
   '20000000-0000-0000-0000-00000000000b', '30000000-0000-0000-0000-00000000000a',
   '10000000-0000-0000-0000-00000000000b', '40000000-0000-0000-0000-0000000000a3',
   '50000000-0000-0000-0000-0000000000b2', 0.99, 'USD', 1299, 'inclusive', 2599,
   '60000000-0000-0000-0000-00000000000b', '70000000-0000-0000-0000-00000000000b',
   640, 4200, 2461, 70, 'high', 'medium', 'high', 'high',
   '{}'::jsonb, 'calc.v1', 'score.v1', '{}'::jsonb, 'draft'),
  ('80000000-0000-0000-0000-000000000f05',
   '20000000-0000-0000-0000-00000000000a', '30000000-0000-0000-0000-00000000000a',
   '10000000-0000-0000-0000-00000000000a', '40000000-0000-0000-0000-0000000000a3',
   '50000000-0000-0000-0000-0000000000a3', 0.99, 'GBP', 1299, 'inclusive', 2599,
   '60000000-0000-0000-0000-00000000000a', '70000000-0000-0000-0000-00000000000a',
   640, 4200, 2461, 70, 'high', 'medium', 'high', 'high',
   '{}'::jsonb, 'calc.v1', 'score.v1', '{}'::jsonb, 'active');

select throws_ok(
  $$insert into public.deals select * from public._deal_bulk_staging
     where id = '80000000-0000-0000-0000-000000000f04'$$,
  '23503',
  null,
  'a set-based bulk load of a cross-market row is rejected');

select throws_ok(
  $$insert into public.deals select * from public._deal_bulk_staging
     where id = '80000000-0000-0000-0000-000000000f05'$$,
  '23514',
  'a deal must be created as draft, not active',
  'and a set-based bulk load cannot publish a deal either');

drop table public._deal_bulk_staging;

-- Upsert, insert path: cross-market.
select throws_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-000000000f06',
    '20000000-0000-0000-0000-00000000000a',
    '30000000-0000-0000-0000-00000000000a',
    '10000000-0000-0000-0000-00000000000a',
    '40000000-0000-0000-0000-0000000000a3',
    '50000000-0000-0000-0000-0000000000b1',
    'GBP', '60000000-0000-0000-0000-00000000000a', '70000000-0000-0000-0000-00000000000a',
    70, null,
    'on conflict (id) do update set deal_score = excluded.deal_score'),
  '23503',
  null,
  'an upsert whose inserted row is cross-market is rejected');

-- Upsert, insert path: a duplicate live pair. ON CONFLICT (id) does not catch a
-- violation of the partial index, which is the point — a pipeline that keys its
-- upsert on the wrong column does not get to create a second live deal.
select throws_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-000000000f07',
    '20000000-0000-0000-0000-00000000000a',
    '30000000-0000-0000-0000-00000000000a',
    '10000000-0000-0000-0000-00000000000a',
    '40000000-0000-0000-0000-0000000000a1',
    '50000000-0000-0000-0000-0000000000a1',
    'GBP', '60000000-0000-0000-0000-00000000000a', '70000000-0000-0000-0000-00000000000a',
    70, null,
    'on conflict (id) do update set deal_score = excluded.deal_score'),
  '23505',
  null,
  'an upsert cannot create a second live deal for a pair that already has one');

-- Upsert, update path: the row already exists and the DO UPDATE branch is what
-- would corrupt it. This is the path a re-run of T19's pipeline actually takes.
select throws_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-00000000000a',   -- existing market A deal
    '20000000-0000-0000-0000-00000000000b',
    '30000000-0000-0000-0000-00000000000b',
    '10000000-0000-0000-0000-00000000000b',
    '40000000-0000-0000-0000-0000000000b1',
    '50000000-0000-0000-0000-0000000000b1',
    'USD', '60000000-0000-0000-0000-00000000000b', '70000000-0000-0000-0000-00000000000b',
    70, null,
    $$on conflict (id) do update set
        market_id = excluded.market_id,
        marketplace_id = excluded.marketplace_id$$),
  '23503',
  null,
  'an upsert whose DO UPDATE branch would make an existing deal cross-market is rejected');

-- Upsert, update path: resurrecting a retired deal.
select throws_ok(
  public._deal_sql(
    '80000000-0000-0000-0000-000000000d01',   -- the retired deal from section G
    '20000000-0000-0000-0000-00000000000a',
    '30000000-0000-0000-0000-00000000000a',
    '10000000-0000-0000-0000-00000000000a',
    '40000000-0000-0000-0000-0000000000a2',
    '50000000-0000-0000-0000-0000000000a2',
    'GBP', '60000000-0000-0000-0000-00000000000a', '70000000-0000-0000-0000-00000000000a',
    70, null,
    $$on conflict (id) do update set status = 'active'$$),
  '23514',
  'deal status transition retired -> active is not permitted',
  'nor can an upsert resurrect a retired deal through its DO UPDATE branch');

select is(
  (select market_id from public.deals where id = '80000000-0000-0000-0000-00000000000a'),
  '20000000-0000-0000-0000-00000000000a'::uuid,
  'and the existing deals are untouched by the rejected upserts');

select is(
  (select status::text from public.deals where id = '80000000-0000-0000-0000-000000000d01'),
  'retired',
  'the retired deal in particular stays retired');

-- ---------------------------------------------------------------------------
-- J. The enforcement mechanisms are what they claim to be
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from pg_constraint
    where conrelid = 'public.deals'::regclass
      and contype = 'f'
      and conname in ('deals_retailer_product_fkey', 'deals_retailer_market_fkey',
                      'deals_marketplace_product_fkey', 'deals_market_marketplace_fkey')),
  4,
  'the two ADR-007 cross-market rules are four real foreign keys, not application convention');

-- Exactly two user triggers: updated_at, and the lifecycle. The cross-market
-- rules are deliberately NOT among them — a foreign key cannot be defeated by
-- DISABLE TRIGGER or by session_replication_role = replica, and a transition
-- rule has no declarative form in PostgreSQL, so it is the one thing that must
-- be a trigger (ADR-0009).
select is(
  (select string_agg(tgname, ',' order by tgname)
     from pg_trigger
    where tgrelid = 'public.deals'::regclass and not tgisinternal),
  'enforce_deal_lifecycle,set_updated_at',
  'deals carries exactly two user triggers: the lifecycle rule and updated_at');

select is(
  (select tgtype & 1 <> 0 and tgtype & 2 <> 0 and tgtype & 4 <> 0 and tgtype & 16 <> 0
     from pg_trigger
    where tgrelid = 'public.deals'::regclass and tgname = 'enforce_deal_lifecycle'),
  true,
  'and the lifecycle trigger is BEFORE INSERT OR UPDATE, FOR EACH ROW');

-- The load-bearing detail of the composite-FK approach: a NULL in a referencing
-- column makes a MATCH SIMPLE foreign key skip its check entirely, so these two
-- columns being NOT NULL is what closes the hole.
select col_not_null('public', 'deals', 'retailer_id',
  'deals.retailer_id is NOT NULL — a NULL would make its composite FK skip the check');
select col_not_null('public', 'deals', 'marketplace_id',
  'deals.marketplace_id is NOT NULL — same reason');
select col_not_null('public', 'deals', 'market_id',
  'deals.market_id is NOT NULL — every deal is scoped');
select col_not_null('public', 'deals', 'status',
  'deals.status is NOT NULL — a deal is always in exactly one lifecycle state');
select col_has_default('public', 'deals', 'status',
  'and it has a default, so a writer that forgets it still fails closed');

-- ---------------------------------------------------------------------------
-- K. Feed indexes lead with the market (§2.3)
-- ---------------------------------------------------------------------------

select has_index('public', 'deals', 'deals_market_status_score_idx',
  'feed index (market_id, status, deal_score desc) exists');
select has_index('public', 'deals', 'deals_market_status_roi_idx',
  'feed index (market_id, status, roi_bps desc) exists');
select has_index('public', 'deals', 'deals_market_status_computed_idx',
  'feed index (market_id, status, computed_at desc) exists');

select is(
  (select count(*)::int
     from pg_index i
     join pg_class c on c.oid = i.indexrelid
    where i.indrelid = 'public.deals'::regclass
      and c.relname in ('deals_market_status_score_idx', 'deals_market_status_roi_idx',
                        'deals_market_status_computed_idx')
      and (select attname from pg_attribute
            where attrelid = i.indrelid and attnum = i.indkey[0]) = 'market_id'),
  3,
  'and market_id leads all three — a feed query that forgets its market cannot use them');

-- ---------------------------------------------------------------------------
-- L. Score, rate and money constraints
-- ---------------------------------------------------------------------------

select lives_ok(
  $$update public.deals set deal_score = 0 where id = '80000000-0000-0000-0000-00000000000a'$$,
  'a deal score of 0 is accepted — the lower boundary is inside the domain');

select lives_ok(
  $$update public.deals set deal_score = 100 where id = '80000000-0000-0000-0000-00000000000a'$$,
  'a deal score of 100 is accepted — so is the upper boundary');

select throws_ok(
  $$update public.deals set deal_score = -1 where id = '80000000-0000-0000-0000-00000000000a'$$,
  '23514',
  null,
  'a deal score below 0 is rejected');

select throws_ok(
  $$update public.deals set deal_score = 101 where id = '80000000-0000-0000-0000-00000000000a'$$,
  '23514',
  null,
  'a deal score above 100 is rejected');

-- Rates are integer basis points, never floats or percentages (§2.4).
select col_type_is('public', 'deals', 'roi_bps',    'integer', 'roi_bps is an integer basis-point column');
select col_type_is('public', 'deals', 'margin_bps', 'integer', 'margin_bps is an integer basis-point column');
select col_type_is('public', 'deals', 'net_profit_minor', 'bigint', 'net_profit_minor is bigint minor units');
select col_type_is('public', 'deals', 'buy_price_minor',  'bigint', 'buy_price_minor is bigint minor units');

-- A loss is a real outcome and must be representable; §8.3 suppresses it from
-- publication, the storage layer does not pretend it cannot happen.
select lives_ok(
  $$update public.deals set net_profit_minor = -500, roi_bps = -1900, margin_bps = -1200
     where id = '80000000-0000-0000-0000-00000000000a'$$,
  'a negative profit, ROI and margin are representable — a loss is a real result');

select throws_ok(
  $$update public.deals set buy_price_minor = -1 where id = '80000000-0000-0000-0000-00000000000a'$$,
  '23514',
  null,
  'a negative buy price is rejected — a cost is not a credit');

select throws_ok(
  $$update public.deals set expires_at = computed_at - interval '1 hour'
     where id = '80000000-0000-0000-0000-00000000000a'$$,
  '23514',
  null,
  'a deal cannot expire before it was computed');

-- ---------------------------------------------------------------------------
-- M. Money never travels without its currency (§2.4, §11.2, §7.6)
-- ---------------------------------------------------------------------------

select col_not_null('public', 'deals', 'currency',
  'deals.currency is NOT NULL — no money-bearing deal row without a currency');

select throws_ok(
  $$update public.deals set currency = null where id = '80000000-0000-0000-0000-00000000000a'$$,
  '23502',
  null,
  'a deal cannot have its currency removed');

select throws_ok(
  $$update public.deals set currency = 'USD' where id = '80000000-0000-0000-0000-00000000000a'$$,
  '23503',
  null,
  'a deal cannot be denominated in a currency its market does not use — one deal, one currency, no FX');

-- ---------------------------------------------------------------------------
-- N. deal_unlocks
-- ---------------------------------------------------------------------------

insert into public.deal_unlocks (user_id, deal_id, credits_spent)
values ('90000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-00000000000a', 1);

select throws_ok(
  $$insert into public.deal_unlocks (user_id, deal_id, credits_spent)
    values ('90000000-0000-0000-0000-00000000000a',
            '80000000-0000-0000-0000-00000000000a', 1)$$,
  '23505',
  null,
  'a user cannot unlock — or be charged for — the same deal twice');

select lives_ok(
  $$insert into public.deal_unlocks (user_id, deal_id, credits_spent)
    values ('90000000-0000-0000-0000-00000000000b',
            '80000000-0000-0000-0000-00000000000a', 1)$$,
  'but two different users can each unlock the same deal');

select throws_ok(
  $$insert into public.deal_unlocks (user_id, deal_id, credits_spent)
    values ('90000000-0000-0000-0000-00000000000a',
            '80000000-0000-0000-0000-00000000000b', -1)$$,
  '23514',
  null,
  'an unlock cannot be recorded as having refunded credits');

-- AC10.7: unlocks are permanent, and survive the deal's retirement. Retirement
-- is a status change, never a delete — and a delete is refused anyway.
select lives_ok(
  $$update public.deals set status = 'retired' where id = '80000000-0000-0000-0000-00000000000a'$$,
  'an unlocked deal can be retired');

select is(
  (select count(*)::int from public.deal_unlocks
    where deal_id = '80000000-0000-0000-0000-00000000000a'),
  2,
  'and both unlocks survive it — unlocks are permanent (AC10.7)');

select throws_ok(
  $$delete from public.deals where id = '80000000-0000-0000-0000-00000000000a'$$,
  '23503',
  null,
  'a deal with unlocks cannot be deleted out from under the record of what was paid for');

-- ---------------------------------------------------------------------------
-- O. watchlist_items
-- ---------------------------------------------------------------------------

insert into public.watchlist_items
  (user_id, deal_id, marketplace_product_id, target_profit_minor, currency, note)
values
  ('90000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-00000000000a',
   '50000000-0000-0000-0000-0000000000a1', 800, 'GBP', 'watch this one');

select throws_ok(
  $$insert into public.watchlist_items (user_id, deal_id, marketplace_product_id)
    values ('90000000-0000-0000-0000-00000000000a',
            '80000000-0000-0000-0000-00000000000a',
            '50000000-0000-0000-0000-0000000000a1')$$,
  '23505',
  null,
  'the same deal cannot be watchlisted twice by one user');

select throws_ok(
  $$insert into public.watchlist_items
      (user_id, deal_id, marketplace_product_id, target_profit_minor)
    values ('90000000-0000-0000-0000-00000000000b',
            '80000000-0000-0000-0000-00000000000a',
            '50000000-0000-0000-0000-0000000000a1', 800)$$,
  '23514',
  null,
  'a target profit without a currency is rejected');

select throws_ok(
  $$insert into public.watchlist_items
      (user_id, deal_id, marketplace_product_id, target_profit_minor, currency)
    values ('90000000-0000-0000-0000-00000000000b',
            '80000000-0000-0000-0000-00000000000a',
            '50000000-0000-0000-0000-0000000000a1', 800, 'USD')$$,
  '23503',
  null,
  'a target denominated in a currency the deal is not priced in is rejected');

select throws_ok(
  $$insert into public.watchlist_items (user_id, deal_id, marketplace_product_id)
    values ('90000000-0000-0000-0000-00000000000b',
            '80000000-0000-0000-0000-00000000000a',
            '50000000-0000-0000-0000-0000000000b1')$$,
  '23503',
  null,
  'a watchlist item cannot point at a listing its deal is not about');

select lives_ok(
  $$insert into public.watchlist_items (user_id, deal_id, marketplace_product_id)
    values ('90000000-0000-0000-0000-00000000000b',
            '80000000-0000-0000-0000-00000000000a',
            '50000000-0000-0000-0000-0000000000a1')$$,
  'a watchlist item with no target and no currency is accepted');

-- ---------------------------------------------------------------------------
-- P. purchase_records — the measurement instrument
-- ---------------------------------------------------------------------------

insert into public.purchase_records
  (user_id, deal_id, market_id, units, currency, expected_profit_minor, inputs_snapshot)
values
  ('90000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-00000000000a',
   '20000000-0000-0000-0000-00000000000a', 6, 'GBP', 640, '{"marketId":"test"}'::jsonb);

select is(
  (select outcome::text from public.purchase_records
    where user_id = '90000000-0000-0000-0000-00000000000a'),
  'pending',
  'a new purchase record starts pending — the outcome is recorded later (AC14.4)');

select lives_ok(
  $$insert into public.purchase_records
      (user_id, deal_id, market_id, units, currency, expected_profit_minor, inputs_snapshot)
    values ('90000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-00000000000a',
            '20000000-0000-0000-0000-00000000000a', 3, 'GBP', 640, '{}'::jsonb)$$,
  'a user can record buying the same deal more than once');

select throws_ok(
  $$insert into public.purchase_records
      (user_id, deal_id, market_id, units, currency, expected_profit_minor, inputs_snapshot)
    values ('90000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-00000000000a',
            '20000000-0000-0000-0000-00000000000b', 1, 'GBP', 640, '{}'::jsonb)$$,
  '23503',
  null,
  'a purchase cannot be attributed to a market other than its deal''s — the metric is per market');

select throws_ok(
  $$insert into public.purchase_records
      (user_id, deal_id, market_id, units, currency, expected_profit_minor, inputs_snapshot)
    values ('90000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-00000000000a',
            '20000000-0000-0000-0000-00000000000a', 1, 'USD', 640, '{}'::jsonb)$$,
  '23503',
  null,
  'a purchase cannot be recorded in a currency its deal is not priced in');

select throws_ok(
  $$insert into public.purchase_records
      (user_id, deal_id, market_id, units, currency, expected_profit_minor, inputs_snapshot)
    values ('90000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-00000000000a',
            '20000000-0000-0000-0000-00000000000a', 0, 'GBP', 640, '{}'::jsonb)$$,
  '23514',
  null,
  'a purchase of zero units is not a purchase');

select throws_ok(
  $$insert into public.purchase_records
      (user_id, deal_id, market_id, units, currency, expected_profit_minor)
    values ('90000000-0000-0000-0000-00000000000a', '80000000-0000-0000-0000-00000000000a',
            '20000000-0000-0000-0000-00000000000a', 1, 'GBP', 640)$$,
  '23502',
  null,
  'a purchase record without its frozen inputs snapshot is rejected (AC14.3)');

-- ---------------------------------------------------------------------------
-- Q. barcode_lookups
-- ---------------------------------------------------------------------------

select lives_ok(
  $$insert into public.barcode_lookups (user_id, market_id, barcode_raw)
    values ('90000000-0000-0000-0000-00000000000a',
            '20000000-0000-0000-0000-00000000000a', '012345678905')$$,
  'a lookup that resolved nothing is still recorded, at zero credits');

select is(
  (select credits_spent from public.barcode_lookups
    where barcode_raw = '012345678905'),
  0,
  'and it is not charged — a failed lookup is free (§3)');

select throws_ok(
  $$insert into public.barcode_lookups (user_id, market_id, barcode_raw, gtin14)
    values ('90000000-0000-0000-0000-00000000000a',
            '20000000-0000-0000-0000-00000000000a', '012345678905', '0123456789012')$$,
  '23514',
  null,
  'a lookup cannot store a GTIN that is not canonicalised to 14 digits');

select lives_ok(
  $$insert into public.barcode_lookups
      (user_id, market_id, barcode_raw, gtin14, resolved_marketplace_product_id, credits_spent)
    values ('90000000-0000-0000-0000-00000000000a',
            '20000000-0000-0000-0000-00000000000a', '012345678905', '00012345678905',
            '50000000-0000-0000-0000-0000000000a1', 1)$$,
  'a resolved lookup records the listing it reached and the credit it cost');

-- ---------------------------------------------------------------------------
-- R. Account deletion cascades personal rows (AC1.5)
-- ---------------------------------------------------------------------------

delete from auth.users where id = '90000000-0000-0000-0000-00000000000a';

select is(
  (select (select count(*) from public.deal_unlocks     where user_id = '90000000-0000-0000-0000-00000000000a')
        + (select count(*) from public.watchlist_items  where user_id = '90000000-0000-0000-0000-00000000000a')
        + (select count(*) from public.purchase_records where user_id = '90000000-0000-0000-0000-00000000000a')
        + (select count(*) from public.barcode_lookups  where user_id = '90000000-0000-0000-0000-00000000000a'))::int,
  0,
  'deleting the auth user cascades away every Schema B row they owned (AC1.5)');

select is(
  (select count(*)::int from public.deals where id = '80000000-0000-0000-0000-00000000000a'),
  1,
  'and the deal itself survives — deals are derived data, not the user''s');

-- The audit trail keeps the fact without the person: deleting the admin who
-- published a deal must neither delete the deal nor block the deletion AC1.5
-- requires, so the actor reference is nulled and the timestamp stays.
select is(
  (select published_by is null and published_at is not null
     from public.deals where id = '80000000-0000-0000-0000-000000000d01'),
  true,
  'a deleted actor leaves published_at intact and published_by null');

-- ---------------------------------------------------------------------------
-- S. RLS: enabled everywhere, no policies yet (T04 acceptance criterion)
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and c.relrowsecurity
      and c.relname in ('deals', 'deal_unlocks', 'watchlist_items',
                        'purchase_records', 'barcode_lookups')),
  5,
  'RLS is enabled on all five Schema B tables');

select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0,
  'and no table in public has RLS disabled');

select is(
  (select count(*)::int from pg_policies where schemaname = 'public'),
  0,
  'no RLS policy exists yet — policies and their grants both land in T06');

-- ---------------------------------------------------------------------------
-- T. Privileges: the T03 baseline is not weakened (ADR-004, global rule 8)
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee in ('anon', 'authenticated')
      and table_name in ('deals', 'deal_unlocks', 'watchlist_items',
                         'purchase_records', 'barcode_lookups')),
  0,
  'anon and authenticated hold no privilege of any kind on any Schema B table');

select ok(
  not has_table_privilege('anon', 'public.deals', 'SELECT'),
  'anon cannot select from deals — the paid product is unreadable at the grant layer, before RLS is consulted');

select ok(
  not has_table_privilege('authenticated', 'public.deals', 'SELECT'),
  'authenticated cannot select from deals either — redaction is server-side (§6.3, risk #10)');

select ok(
  not has_table_privilege('authenticated', 'public.watchlist_items', 'SELECT'),
  'authenticated cannot yet read its own watchlist — the grant arrives in T06 with the policy that governs it');

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee = 'service_role'
      and privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
      and table_name in ('deals', 'deal_unlocks', 'watchlist_items',
                         'purchase_records', 'barcode_lookups')),
  20,
  'service_role holds all four DML privileges on all five Schema B tables (5 x 4)');

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee = 'service_role'
      and privilege_type not in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
      and table_name in ('deals', 'deal_unlocks', 'watchlist_items',
                         'purchase_records', 'barcode_lookups')),
  0,
  'and nothing beyond DML — no TRUNCATE, TRIGGER or REFERENCES');

-- No sequence was created, so there is no sequence default grant to have missed.
select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'S'),
  0,
  'Schema B created no sequences — every key is a uuid, so no sequence grant was missed');

-- The one function Schema B adds is owner-only, like every other function in
-- public (ADR-0007). `_deal_sql` is this test file's own helper.
select is(
  (select count(*)::int
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname not in ('set_updated_at', 'handle_new_user',
                            'enforce_deal_lifecycle', 'enforce_credit_ledger_append_only',
                            '_deal_sql')),
  0,
  'Schema B added exactly one function, the lifecycle trigger function');

select is(
  (select array_to_string(proacl, ',')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'enforce_deal_lifecycle'),
  'postgres=X/postgres',
  'and it is executable by its owner and nobody else');

select ok(
  not (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'enforce_deal_lifecycle'),
  'it is not SECURITY DEFINER — it needs no privilege its caller lacks');

-- Owner-only must not break the trigger for the role that actually writes
-- deals. EXECUTE on a trigger function is checked when the trigger is created,
-- not when it fires; this fires it as service_role, which holds no EXECUTE.
insert into public.deals (
  id, market_id, retailer_id, marketplace_id,
  retailer_product_id, marketplace_product_id, match_confidence, currency,
  buy_price_minor, buy_price_tax_treatment, sell_price_minor,
  fee_schedule_id, tax_schedule_id, net_profit_minor, roi_bps, margin_bps,
  deal_score, demand_band, competition_band, stability_band, confidence_band,
  score_breakdown, calc_version, score_version, inputs_snapshot
) values (
  '80000000-0000-0000-0000-0000000000a9',
  '20000000-0000-0000-0000-00000000000a', '30000000-0000-0000-0000-00000000000a',
  '10000000-0000-0000-0000-00000000000a', '40000000-0000-0000-0000-0000000000a1',
  '50000000-0000-0000-0000-0000000000a1', 0.99, 'GBP', 1299, 'inclusive', 2599,
  '60000000-0000-0000-0000-00000000000a', '70000000-0000-0000-0000-00000000000a',
  640, 4200, 2461, 70, 'high', 'medium', 'high', 'high',
  '{}'::jsonb, 'calc.v1', 'score.v1', '{}'::jsonb);

set local role service_role;
update public.deals set status = 'active' where id = '80000000-0000-0000-0000-0000000000a9';
reset role;

select ok(
  (select published_at is not null from public.deals
    where id = '80000000-0000-0000-0000-0000000000a9'),
  'the lifecycle trigger still fires for service_role, which holds no EXECUTE on it');

select throws_ok(
  $$update public.deals set status = 'draft' where id = '80000000-0000-0000-0000-0000000000a9'$$,
  '23514',
  null,
  'and it still rejects an illegal transition made by that same role');

-- ---------------------------------------------------------------------------
-- U. updated_at maintained on every new table
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from pg_trigger t
    where t.tgrelid in ('public.deals'::regclass, 'public.deal_unlocks'::regclass,
                        'public.watchlist_items'::regclass, 'public.purchase_records'::regclass,
                        'public.barcode_lookups'::regclass)
      and t.tgname = 'set_updated_at'
      and not t.tgisinternal),
  5,
  'every Schema B table maintains updated_at through the shared Schema A trigger');

-- now() is the transaction timestamp and is constant inside this transaction,
-- so a row inserted and updated here would show equal timestamps whether the
-- trigger fired or not. Backdating BOTH columns in the same statement removes
-- the ambiguity: the trigger fires BEFORE UPDATE and overwrites the explicit
-- stale updated_at with now(), so the two can only differ if it ran.
update public.deals
   set deal_score = 71,
       created_at = now() - interval '2 hours',
       updated_at = now() - interval '2 hours'
 where id = '80000000-0000-0000-0000-0000000000a9';

select ok(
  (select updated_at > created_at from public.deals
    where id = '80000000-0000-0000-0000-0000000000a9'),
  'and it overrides an explicitly-supplied updated_at, so the value cannot be back-written');

select * from finish();

rollback;
