-- T08 — seed / reference data tests (pgTAP), run by `npm run db:test`.
--
-- These assert the CONTENT of supabase/seed/, which no earlier suite touches:
-- schema_a/b/c assert structure, T05A asserts the temporal constraints, and T06
-- asserts the policy surface against fixtures it creates itself. This file
-- asserts that a clean `npm run db:reset` produced the exact reference rows the
-- launch market depends on.
--
-- WHY EXACT VALUES AND NOT COUNTS
--
-- A count assertion passes for the wrong reason the moment someone edits a rate
-- and leaves the row count unchanged — which is precisely the risk #2 failure
-- this data exists to prevent. Rates, exponents, flags and boundary dates are
-- therefore asserted by value. Counts appear only where the claim genuinely is
-- about cardinality ("exactly one live market", "no overlapping periods").
--
-- pgTAP is created inside this transaction and rolled back with it, so the test
-- extension never appears in a migration and never reaches the hosted project.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog, pg_temp;

select plan(103);

-- ---------------------------------------------------------------------------
-- Helpers — same construction as rls_policies_and_grants.test.sql
-- ---------------------------------------------------------------------------
-- The role switch lives inside one statement so the pgTAP assertion itself
-- always runs as the owner. _t8_count returns NULL when the statement failed
-- outright, so a count assertion that quietly became a privilege error fails
-- loudly instead of passing as a zero.

create function public._t8_count(p_role text, p_sql text)
returns integer
language plpgsql
as $fn$
declare
  n integer;
begin
  begin
    execute format('set local role %I', p_role);
    execute p_sql into n;
    execute 'reset role';
    return n;
  exception when others then
    execute 'reset role';
    return null;
  end;
end;
$fn$;

create function public._t8_sqlstate(p_role text, p_sql text)
returns text
language plpgsql
as $fn$
declare
  code text;
begin
  begin
    execute format('set local role %I', p_role);
    execute p_sql;
    execute 'reset role';
    return null;
  exception when others then
    code := sqlstate;
    execute 'reset role';
    return code;
  end;
end;
$fn$;

-- ===========================================================================
-- A. Currencies — the minor-unit exponent is data (§2.2, §2.4)
-- ===========================================================================

select is((select count(*)::int from public.currencies), 5,
  'five currencies are seeded');

select is((select minor_unit_exponent from public.currencies where code = 'GBP'), 2::smallint,
  'GBP has exponent 2');
select is((select minor_unit_exponent from public.currencies where code = 'USD'), 2::smallint,
  'USD has exponent 2');
select is((select minor_unit_exponent from public.currencies where code = 'EUR'), 2::smallint,
  'EUR has exponent 2');

-- The two that make the exponent load-bearing. If either of these ever became 2
-- because someone "tidied" the seed, code assuming x100 would start passing.
select is((select minor_unit_exponent from public.currencies where code = 'JPY'), 0::smallint,
  'JPY has exponent 0 — a zero-decimal currency stays representable');
select is((select minor_unit_exponent from public.currencies where code = 'KWD'), 3::smallint,
  'KWD has exponent 3 — a three-decimal currency stays representable');

select is(
  (select count(distinct minor_unit_exponent)::int from public.currencies),
  3,
  'the seed spans three distinct exponents, so x100 cannot be assumed anywhere');

select ok(
  (select bool_and(name is not null and name <> '') from public.currencies),
  'every currency carries a name');

-- ===========================================================================
-- B. Countries — and the tax/price-display facts that move money
-- ===========================================================================

select is((select count(*)::int from public.countries), 4,
  'four countries are seeded — more than one, so the abstraction is exercised');

select is(
  (select array_agg(code order by code) from public.countries),
  array['DE', 'GB', 'JP', 'US'],
  'the seeded countries are exactly DE, GB, JP and US');

select is((select default_currency from public.countries where code = 'GB'), 'GBP',
  'GB defaults to GBP');
select is((select tax_regime from public.countries where code = 'GB'), 'vat'::public.tax_regime,
  'GB operates a VAT regime');
select is((select retail_price_display from public.countries where code = 'GB'),
  'inclusive'::public.price_tax_treatment,
  'GB shelf prices include tax');

-- The US row is the one that proves the column is not decoration: getting it
-- wrong inflates or deflates every US profit figure by the sales-tax rate.
select is((select tax_regime from public.countries where code = 'US'), 'sales_tax'::public.tax_regime,
  'US operates a sales-tax regime, not VAT');
select is((select retail_price_display from public.countries where code = 'US'),
  'exclusive'::public.price_tax_treatment,
  'US shelf prices exclude tax');

select is((select count(*)::int from public.countries where active), 1,
  'exactly one country is active');
select ok((select active from public.countries where code = 'GB'),
  'GB is the active country');

-- ===========================================================================
-- C. Marketplaces — generic rows, no Amazon-specific structure
-- ===========================================================================

select is((select count(*)::int from public.marketplaces), 4,
  'four Amazon locales are seeded');

select is(
  (select array_agg(code order by code) from public.marketplaces),
  array['amazon_de', 'amazon_jp', 'amazon_uk', 'amazon_us'],
  'the seeded marketplaces are exactly the four Amazon locales');

select is((select country_code from public.marketplaces where code = 'amazon_uk'), 'GB',
  'amazon_uk belongs to GB');
select is((select currency from public.marketplaces where code = 'amazon_uk'), 'GBP',
  'amazon_uk prices in GBP');
select is((select domain from public.marketplaces where code = 'amazon_uk'), 'www.amazon.co.uk',
  'amazon_uk carries its real domain');
select is((select adapter_key from public.marketplaces where code = 'amazon_uk'), 'keepa',
  'amazon_uk resolves to the Keepa adapter');

select is((select count(*)::int from public.marketplaces where active), 1,
  'exactly one marketplace is active');

-- §8.7: a component whose inputs are unavailable is dropped and the weights are
-- renormalised. That only works if capabilities are stated per marketplace.
select ok(
  (select bool_and(capabilities ? 'priceHistory'
               and capabilities ? 'rankOrDemandProxy'
               and capabilities ? 'offerCounts'
               and capabilities ? 'feePreview'
               and capabilities ? 'categoryTaxonomy')
     from public.marketplaces),
  'every marketplace declares all five MarketplaceCapabilities keys');

-- feePreview = false is why fee_schedules exists and is hand-verified.
select is(
  (select capabilities ->> 'feePreview' from public.marketplaces where code = 'amazon_uk'),
  'false',
  'the Keepa adapter does not claim a fee-preview capability');

select is(
  (select fulfilment_programs ->> 'marketplace_fulfilled' from public.marketplaces where code = 'amazon_uk'),
  'FBA',
  'the generic fulfilment role maps to this marketplace''s own programme code');

-- ===========================================================================
-- D. Markets — relationship, currency invariant, and exactly one live
-- ===========================================================================

select is((select count(*)::int from public.markets), 2,
  'two markets are seeded — the launch market and the synthetic second one');

select is(
  (select mp.code
     from public.markets m
     join public.marketplaces mp on mp.id = m.marketplace_id
    where m.slug = 'gb-amazon-uk'),
  'amazon_uk',
  'gb-amazon-uk resolves to the amazon_uk marketplace');

select is((select source_country_code from public.markets where slug = 'gb-amazon-uk'), 'GB',
  'gb-amazon-uk sources from GB');
select is((select currency from public.markets where slug = 'gb-amazon-uk'), 'GBP',
  'gb-amazon-uk is denominated in GBP');

-- §1.3 stored invariant: a market's currency IS its marketplace's currency.
-- The composite FK enforces it; this asserts the seed actually satisfies it
-- rather than trusting that it must.
select ok(
  (select bool_and(m.currency = mp.currency)
     from public.markets m
     join public.marketplaces mp on mp.id = m.marketplace_id),
  'every market''s currency matches its marketplace''s currency');

-- T08 AC: exactly one operating market is live. This is seeding and release
-- discipline, not a database constraint, so it is asserted here and in the T40
-- checklist rather than enforced with a unique index.
select is(
  (select count(*)::int from public.markets where active and launch_status = 'live'),
  1,
  'exactly one market is active AND live');

select is((select launch_status from public.markets where slug = 'gb-amazon-uk'),
  'live'::public.market_launch_status,
  'gb-amazon-uk is the live market');
select ok((select active from public.markets where slug = 'gb-amazon-uk'),
  'gb-amazon-uk is active');

-- The synthetic second market: seeded, resolvable, and deliberately not public.
select is((select launch_status from public.markets where slug = 'de-amazon-de'),
  'planned'::public.market_launch_status,
  'de-amazon-de is planned, not live');
select ok((select not active from public.markets where slug = 'de-amazon-de'),
  'de-amazon-de is inactive');

-- ===========================================================================
-- E. Tax schedules — exactly one current row, no overlaps, verified
-- ===========================================================================

select is((select count(*)::int from public.tax_schedules), 4,
  'four tax schedule versions are seeded');

-- The resolution MarketContext (T13) will perform: one country, one date.
select is(
  (select count(*)::int
     from public.tax_schedules
    where country_code = 'GB'
      and effective_from <= current_date
      and (effective_to is null or effective_to > current_date)),
  1,
  'GB resolves to exactly one tax schedule today');

select is(
  (select count(*)::int
     from public.tax_schedules
    where country_code = 'DE'
      and effective_from <= current_date
      and (effective_to is null or effective_to > current_date)),
  1,
  'the synthetic second market''s country resolves to exactly one tax schedule today');

select is(
  (select standard_rate_bps
     from public.tax_schedules
    where country_code = 'GB' and effective_to is null),
  2000,
  'the current GB standard rate is 2000 bps (20%)');

-- The 2024-08-01 boundary is a fee-VAT change, not a rate change, and it is the
-- one that costs a non-registered seller real money.
select ok(
  (select marketplace_fees_taxed
     from public.tax_schedules
    where country_code = 'GB' and effective_to is null),
  'the current GB schedule taxes marketplace fees');

select is(
  (select effective_from from public.tax_schedules where country_code = 'GB' and effective_to is null),
  date '2024-08-01',
  'the current GB schedule starts on the date Amazon fees became VAT-bearing');

select is(
  (select standard_rate_bps from public.tax_schedules
    where country_code = 'GB' and effective_from = date '2010-01-01'),
  1750,
  'the superseded GB schedule carries the historical 17.5% rate');

-- Half-open [from, to): a version ending on T and its successor starting on T
-- are adjacent, and there is no uncovered day between them.
select is(
  (select count(*)::int
     from public.tax_schedules a
     join public.tax_schedules b
       on b.country_code = a.country_code
      and b.effective_from = a.effective_to),
  2,
  'the GB versions are adjacent — each bounded row is closed by its successor');

-- Overlap, asserted over the data rather than trusted to the constraint. If the
-- exclusion constraint were ever dropped, this still fails.
select is(
  (select count(*)::int
     from public.tax_schedules a
     join public.tax_schedules b
       on b.country_code = a.country_code
      and b.id <> a.id
      and daterange(a.effective_from, a.effective_to, '[)')
       && daterange(b.effective_from, b.effective_to, '[)')),
  0,
  'no two tax schedules for one country overlap');

select is(
  (select count(*)::int from public.tax_schedules where effective_to is null),
  2,
  'exactly one open-ended tax schedule exists per seeded country');

-- verified_at is a claim. The live market must carry one; the planned market
-- deliberately does not, and MARKET_PLAYBOOK.md gates the live flip on it.
select ok(
  (select bool_and(verified_at is not null and source_url is not null)
     from public.tax_schedules where country_code = 'GB'),
  'every GB tax schedule records a source URL and a verification date');

select ok(
  (select verified_at is null from public.tax_schedules where country_code = 'DE'),
  'the unverified DE schedule says so with a NULL verified_at rather than a fabricated one');

-- ===========================================================================
-- F. Fee schedules — one current row per marketplace, no overlaps, no band gaps
-- ===========================================================================

select is((select count(*)::int from public.fee_schedules), 3,
  'three fee schedule versions are seeded');

select is(
  (select count(*)::int
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id
    where mp.code = 'amazon_uk'
      and f.effective_from <= current_date
      and (f.effective_to is null or f.effective_to > current_date)),
  1,
  'amazon_uk resolves to exactly one fee schedule today');

select is(
  (select count(*)::int
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id
    where mp.code = 'amazon_de'
      and f.effective_from <= current_date
      and (f.effective_to is null or f.effective_to > current_date)),
  1,
  'the synthetic second market''s marketplace resolves to exactly one fee schedule today');

select is(
  (select count(*)::int
     from public.fee_schedules a
     join public.fee_schedules b
       on b.marketplace_id = a.marketplace_id
      and b.id <> a.id
      and daterange(a.effective_from, a.effective_to, '[)')
       && daterange(b.effective_from, b.effective_to, '[)')),
  0,
  'no two fee schedules for one marketplace overlap');

select is(
  (select count(*)::int
     from public.fee_schedules a
     join public.fee_schedules b
       on b.marketplace_id = a.marketplace_id
      and b.effective_from = a.effective_to),
  1,
  'the amazon_uk versions are adjacent — the bounded row is closed by its successor');

select ok(
  (select bool_and(f.currency = mp.currency)
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id),
  'every fee schedule is denominated in its marketplace''s currency');

select ok(
  (select verified_at is not null and source_url is not null
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id
    where mp.code = 'amazon_uk' and f.effective_to is null),
  'the launch market''s current fee schedule records a source URL and a verification date');

-- Referral coverage is total by construction: the last rule is the catch-all.
select ok(
  (select (f.referral_rules -> (jsonb_array_length(f.referral_rules) - 1)) ->> 'default' = 'true'
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id
    where mp.code = 'amazon_uk' and f.effective_to is null),
  'the launch market''s referral rules end in a default catch-all, so no category is uncovered');

select is(
  (select count(*)::int
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id
    cross join lateral jsonb_array_elements(f.referral_rules) r
    where mp.code = 'amazon_uk' and f.effective_to is null
      and r ->> 'mode' not in ('flat', 'threshold', 'marginal')),
  0,
  'every referral rule declares a known mode — the marginal/threshold distinction is never implicit');

-- Only the final tier of a rule may be unbounded, or an earlier tier would
-- swallow every price above it.
select is(
  (select count(*)::int
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id
    cross join lateral jsonb_array_elements(f.referral_rules) r
    cross join lateral jsonb_array_elements(r -> 'tiers') with ordinality as t(tier, ord)
    where mp.code = 'amazon_uk' and f.effective_to is null
      and t.tier ->> 'up_to_minor' is null
      and t.ord <> jsonb_array_length(r -> 'tiers')),
  0,
  'no referral tier is unbounded except the last one in its rule');

-- T08 testing requirement: fee-band coverage in the launch market has no gaps
-- and no overlaps. Bands are (from, to], so within a tier each band must begin
-- exactly where the previous one ended.
select is(
  (with bands as (
     select b ->> 'tier' as tier,
            (b ->> 'from_weight_g')::numeric as from_g,
            (b ->> 'to_weight_g')::numeric   as to_g
       from public.fee_schedules f
       join public.marketplaces mp on mp.id = f.marketplace_id
      cross join lateral jsonb_array_elements(f.fulfilment_bands) b
      where mp.code = 'amazon_uk' and f.effective_to is null
   )
   select count(*)::int
     from (select *, lag(to_g) over (partition by tier order by from_g) as prev_to from bands) x
    where prev_to is not null and prev_to <> from_g),
  0,
  'within every fulfilment tier the weight bands are contiguous — no gaps, no overlaps');

select is(
  (select count(*)::int
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id
    cross join lateral jsonb_array_elements(f.fulfilment_bands) b
    where mp.code = 'amazon_uk' and f.effective_to is null
      and (b ->> 'to_weight_g') is not null
      and (b ->> 'to_weight_g')::numeric <= (b ->> 'from_weight_g')::numeric),
  0,
  'every fulfilment band ends above where it starts');

select is(
  (select count(distinct b ->> 'tier')::int
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id
    cross join lateral jsonb_array_elements(f.fulfilment_bands) b
    where mp.code = 'amazon_uk' and f.effective_to is null),
  13,
  'all thirteen UK size tiers from the rate card are seeded');

select ok(
  (select bool_and((b ->> 'amount_minor')::bigint > 0)
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id
    cross join lateral jsonb_array_elements(f.fulfilment_bands) b
    where mp.code = 'amazon_uk' and f.effective_to is null),
  'every fulfilment band carries a positive amount in minor units');

-- The surcharges list is what replaced v1.0's hardcoded digital_services_fee
-- column. The DSF must be present and must NOT be modelled as referral-only,
-- which would understate the fee.
select ok(
  (select bool_or(s ->> 'code' = 'digital_services_fee' and s ->> 'basis' = 'selling_fees')
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id
    cross join lateral jsonb_array_elements(f.surcharges) s
    where mp.code = 'amazon_uk' and f.effective_to is null),
  'the Digital Services Fee is an itemised surcharge applied to selling fees, not a hardcoded column');

select ok(
  (select bool_or(s ->> 'code' = 'fuel_and_logistics_surcharge')
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id
    cross join lateral jsonb_array_elements(f.surcharges) s
    where mp.code = 'amazon_uk' and f.effective_to is null),
  'the fuel and logistics surcharge is present on the current schedule');

select ok(
  (select not bool_or(s ->> 'code' = 'fuel_and_logistics_surcharge')
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id
    cross join lateral jsonb_array_elements(f.surcharges) s
    where mp.code = 'amazon_uk' and f.effective_to = date '2026-04-17'),
  'the fuel surcharge is absent from the version that predates it — versions are not copies');

-- UK storage is billed per cubic FOOT; the rest of Europe per cubic metre. A
-- pricing engine that assumed m3 would be out by a factor of ~35.
select is(
  (select f.storage_rules ->> 'unit'
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id
    where mp.code = 'amazon_uk' and f.effective_to is null),
  'cubic_foot',
  'the launch market''s storage unit is data, and it is cubic feet');

select is(
  (select f.storage_rules ->> 'unit'
     from public.fee_schedules f
     join public.marketplaces mp on mp.id = f.marketplace_id
    where mp.code = 'amazon_de'),
  'cubic_metre',
  'the second market''s storage unit differs — which is why the unit is a column and not a constant');

-- ===========================================================================
-- G. Retailers — 3-5 curated, in the launch market, with no credentials
-- ===========================================================================

select ok((select count(*) between 3 and 5 from public.retailers),
  'between three and five retailers are seeded');

select ok(
  (select bool_and(source_type = 'curated') from public.retailers),
  'every seeded retailer is source_type = curated');

select ok(
  (select bool_and(m.slug = 'gb-amazon-uk')
     from public.retailers r join public.markets m on m.id = r.market_id),
  'every seeded retailer belongs to the launch market');

select ok(
  (select bool_and(r.currency = m.currency)
     from public.retailers r join public.markets m on m.id = r.market_id),
  'every retailer prices in its market''s currency');

-- No affiliate identifier is invented. A plausible-looking tracking template is
-- worse than an empty column, for the same reason a fake Stripe id is.
select ok(
  (select bool_and(affiliate_network is null and affiliate_tracking_template is null)
     from public.retailers),
  'no retailer carries a fabricated affiliate network or tracking template');

-- ===========================================================================
-- H. Credit packs and prices — and the NULL stripe_price_id rule
-- ===========================================================================

select ok((select count(*) >= 3 from public.credit_packs),
  'at least three credit packs are seeded');

select ok(
  (select bool_and(credits > 0) from public.credit_packs),
  'every pack carries a positive credit quantity');

select ok(
  (select bool_and(active) from public.credit_packs),
  'every seeded pack is active, so the public pricing page can render it');

select is(
  (select count(*)::int from public.credit_pack_prices where currency = 'GBP' and active),
  3,
  'the launch currency has an active price for every pack');

select ok(
  (select bool_and(amount_minor > 0) from public.credit_pack_prices),
  'every pack price is a positive amount in minor units');

-- amount_minor is bigint, so "integer minor units" is a storage guarantee
-- rather than a convention; assert it holds rather than assuming the type.
select is(
  (select count(*)::int from public.credit_pack_prices
    where amount_minor <> trunc(amount_minor)),
  0,
  'every pack price is a whole number of minor units');

select ok(
  (select bool_and(c.code is not null)
     from public.credit_pack_prices p
     left join public.currencies c on c.code = p.currency),
  'every pack price references a seeded currency');

-- THE T08 ACCEPTANCE CRITERION (ADR-0010 decision 4).
select is(
  (select count(*)::int from public.credit_pack_prices where stripe_price_id is not null),
  0,
  'every seeded stripe_price_id is NULL — no placeholder Stripe Price ID exists');

-- The failure this guards is not a NULL, it is a plausible fake. Assert the
-- shape too, so 'price_TODO' would fail even if someone argued it was not NULL.
select is(
  (select count(*)::int from public.credit_pack_prices
    where stripe_price_id is not null and stripe_price_id !~ '^price_[A-Za-z0-9]{14,}$'),
  0,
  'no pack price carries a value that merely looks like a Stripe Price ID');

-- The inactive fixture T09 needs, and coverage for the unique index: several
-- NULLs coexist, which is exactly why the constraint must not be read as a
-- reason to invent a placeholder.
select ok(
  (select count(*) >= 1 from public.credit_pack_prices where not active),
  'at least one inactive pack price is seeded as a fixture for the T09 visibility assertions');

-- ===========================================================================
-- I. T06 public surface, exercised against the real seed
-- ===========================================================================
--
-- T06's own suite asserts the policies against fixtures it builds. This asserts
-- what the SEED makes visible, which is the thing a browser will actually get.

select is(public._t8_count('anon', 'select count(*) from public.countries'), 1,
  'anon sees exactly the one active country');
select is(public._t8_count('anon', 'select count(*) from public.markets'), 1,
  'anon sees exactly the one active, live market');
select is(public._t8_count('anon', 'select count(*) from public.markets where slug = ''de-amazon-de'''), 0,
  'anon cannot see the planned market — a beta/planned market is not accidentally public');
select is(public._t8_count('anon', 'select count(*) from public.currencies'), 5,
  'anon sees every currency, which the render boundary needs to format money');
select is(public._t8_count('anon', 'select count(*) from public.credit_packs'), 3,
  'anon sees the active credit packs');

-- The expected, correct consequence of seeding stripe_price_id as NULL: no pack
-- price is publicly readable until T34 backfills real Stripe Price IDs. This is
-- asserted so that "the credits page is empty" is a recorded decision rather
-- than a bug someone later "fixes" with a placeholder.
select is(public._t8_count('anon', 'select count(*) from public.credit_pack_prices'), 0,
  'anon sees NO pack price — every seeded row has a NULL stripe_price_id (correct until T34)');
select is(public._t8_count('authenticated', 'select count(*) from public.credit_pack_prices'), 0,
  'authenticated sees no pack price either');

-- service_role must still reach them, or T34 could not backfill and T35 could
-- not reconcile.
select is(public._t8_count('service_role', 'select count(*) from public.credit_pack_prices'), 6,
  'service_role reads all six pack prices');
select is(public._t8_count('service_role', 'select count(*) from public.markets'), 2,
  'service_role reads both markets, including the planned one');

-- Service-role-only reference tables must fail with a PRIVILEGE error, not an
-- empty result. An empty result would mean a grant exists that should not.
select is(public._t8_sqlstate('anon', 'select 1 from public.marketplaces'), '42501',
  'anon is refused marketplaces by privilege — adapter keys and capabilities stay internal');
select is(public._t8_sqlstate('anon', 'select 1 from public.tax_schedules'), '42501',
  'anon is refused tax_schedules by privilege');
select is(public._t8_sqlstate('anon', 'select 1 from public.fee_schedules'), '42501',
  'anon is refused fee_schedules by privilege');
select is(public._t8_sqlstate('anon', 'select 1 from public.retailers'), '42501',
  'anon is refused retailers by privilege');

-- ===========================================================================
-- J. What the seed must NOT contain
-- ===========================================================================
--
-- T08 seeds reference data. It seeds no user, no deal and no financial record —
-- a dashboard populated with invented deals would be a lie told to the person
-- deciding whether the pipeline works.

select is((select count(*)::int from auth.users), 0,
  'the seed creates no users');
select is((select count(*)::int from public.profiles), 0,
  'the seed creates no profiles');
select is((select count(*)::int from public.deals), 0,
  'the seed creates no deals — the deal pipeline is T19, not fixture data');
select is((select count(*)::int from public.credit_ledger), 0,
  'the seed creates no ledger entries');
select is((select count(*)::int from public.credit_purchases), 0,
  'the seed creates no purchases');
select is((select count(*)::int from public.retailer_products), 0,
  'the seed creates no retailer products');
select is((select count(*)::int from public.marketplace_products), 0,
  'the seed creates no marketplace products');

select * from finish();

rollback;
