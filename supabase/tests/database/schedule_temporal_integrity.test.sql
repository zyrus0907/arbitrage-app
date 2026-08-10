-- T05A — Temporal integrity database tests (pgTAP), run by `npm run db:test`.
--
-- These assert, in the database rather than through the application, that a
-- versioned schedule cannot overlap another version of itself — the property
-- MarketContext (T13) depends on when it resolves "the schedule effective for
-- this key on this date" and expects exactly one row back.
--
-- The half-open [effective_from, effective_to) semantics are what most of this
-- file is about, because the two easy mistakes point in opposite directions:
--
--   * a constraint that rejects ADJACENT versions makes an ordinary version
--     bump impossible, so someone eventually drops it;
--   * a constraint that lets NULL effective_to drop out of overlap detection
--     protects everything except the current row, which is the row most likely
--     to be NULL-terminated and the row every resolution query reads.
--
-- Both are tested in both directions on both tables. Sections E to G assert
-- that nothing else moved: T03's keys, indexes and triggers, RLS default-deny,
-- and the ADR-004 privilege baseline.
--
-- pgTAP is created inside this transaction and rolled back with it, so the test
-- extension never appears in a migration and never reaches the hosted project.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog, pg_temp;

select plan(76);

-- ---------------------------------------------------------------------------
-- A. The constraints exist, by exact name and exact definition
-- ---------------------------------------------------------------------------
--
-- Named assertions, not counted ones: the names are what a later migration
-- would have to say out loud in order to drop one.

select ok(
  exists (select 1 from pg_extension where extname = 'btree_gist'),
  'btree_gist is installed — the equality half of each EXCLUDE needs gist_text_ops and gist_uuid_ops');

select is(
  (select n.nspname
     from pg_extension e join pg_namespace n on n.oid = e.extnamespace
    where e.extname = 'btree_gist'),
  'extensions',
  'btree_gist lives in the extensions schema, like every other extension here — public stays for application objects');

select is(
  (select contype::text from pg_constraint
    where conrelid = 'public.tax_schedules'::regclass
      and conname = 'tax_schedules_no_overlapping_periods'),
  'x',
  'tax_schedules_no_overlapping_periods exists and is an EXCLUSION constraint');

select is(
  (select contype::text from pg_constraint
    where conrelid = 'public.fee_schedules'::regclass
      and conname = 'fee_schedules_no_overlapping_periods'),
  'x',
  'fee_schedules_no_overlapping_periods exists and is an EXCLUSION constraint');

-- The definition is asserted verbatim rather than by behaviour alone. A
-- constraint that was quietly rewritten to '[]' or to tstzrange would still
-- reject a plain overlap and would still pass every behavioural test in
-- section B except the adjacency ones — so the text is worth pinning.
select is(
  (select pg_get_constraintdef(oid) from pg_constraint
    where conrelid = 'public.tax_schedules'::regclass
      and conname = 'tax_schedules_no_overlapping_periods'),
  'EXCLUDE USING gist (country_code WITH =, daterange(effective_from, effective_to, ''[)''::text) WITH &&)',
  'tax_schedules is scoped by country_code and uses a half-open daterange');

select is(
  (select pg_get_constraintdef(oid) from pg_constraint
    where conrelid = 'public.fee_schedules'::regclass
      and conname = 'fee_schedules_no_overlapping_periods'),
  'EXCLUDE USING gist (marketplace_id WITH =, daterange(effective_from, effective_to, ''[)''::text) WITH &&)',
  'fee_schedules is scoped by marketplace_id and uses a half-open daterange');

-- The T03 check constraints are the reason the exclusion constraints are
-- total: daterange(d, d, '[)') is the EMPTY range, which overlaps nothing and
-- would sit outside the exclusion index entirely.
select is(
  (select pg_get_constraintdef(oid) from pg_constraint
    where conrelid = 'public.tax_schedules'::regclass
      and conname = 'tax_schedules_effective_range'),
  'CHECK (((effective_to IS NULL) OR (effective_to > effective_from)))',
  'T03''s tax_schedules_effective_range is intact — it is what keeps an empty range unrepresentable');

select is(
  (select pg_get_constraintdef(oid) from pg_constraint
    where conrelid = 'public.fee_schedules'::regclass
      and conname = 'fee_schedules_effective_range'),
  'CHECK (((effective_to IS NULL) OR (effective_to > effective_from)))',
  'T03''s fee_schedules_effective_range is intact');

-- The representation choice, asserted as a negative: no stored range column
-- was introduced on either table, so the generated TypeScript types are
-- untouched and the range cannot drift from the two columns it derives from.
select hasnt_column('public', 'tax_schedules', 'effective_period',
  'no redundant stored range column on tax_schedules — the range is derived in the index');

select hasnt_column('public', 'fee_schedules', 'effective_period',
  'no redundant stored range column on fee_schedules');

select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'public' and table_name = 'tax_schedules'),
  15,
  'tax_schedules still has exactly the 15 columns T03 created');

select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'public' and table_name = 'fee_schedules'),
  14,
  'fee_schedules still has exactly the 14 columns T03 created');

select is(
  (select am.amname from pg_constraint c
     join pg_class i on i.oid = c.conindid
     join pg_am am on am.oid = i.relam
    where c.conname = 'tax_schedules_no_overlapping_periods'),
  'gist',
  'the tax exclusion constraint is backed by a GiST index — which is also the index the resolution query wants');

select is(
  (select am.amname from pg_constraint c
     join pg_class i on i.oid = c.conindid
     join pg_am am on am.oid = i.relam
    where c.conname = 'fee_schedules_no_overlapping_periods'),
  'gist',
  'the fee exclusion constraint is backed by a GiST index');

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
--
-- Two synthetic countries and two synthetic marketplaces. No real country,
-- currency-market pairing or marketplace appears: §0.3 requires that nothing
-- in this schema knows which country or marketplace it is in, and a test that
-- hard-coded GB or Amazon would quietly re-import the assumption v2.0 removed.
-- GBP/USD come from the T03 seed.

insert into public.countries
  (code, name, default_currency, default_locale, tax_regime, retail_price_display, timezone_default, active)
values
  ('AA', 'Testland',  'GBP', 'en-AA', 'vat',       'inclusive', 'UTC', true),
  ('BB', 'Otherland', 'USD', 'en-BB', 'sales_tax', 'exclusive', 'UTC', true);

insert into public.marketplaces
  (id, provider, code, country_code, currency, domain, adapter_key, active)
values
  ('11111111-1111-1111-1111-111111111111', 'testprovider', 'test_aa',
   'AA', 'GBP', 'example.test', 'testadapter', true),
  ('22222222-2222-2222-2222-222222222222', 'testprovider', 'test_bb',
   'BB', 'USD', 'example.test', 'testadapter', true);

-- ---------------------------------------------------------------------------
-- B. tax_schedules — overlap is impossible per country
-- ---------------------------------------------------------------------------

-- B1. A bounded period.
select lives_ok(
  $$insert into public.tax_schedules
      (id, country_code, regime, standard_rate_bps, effective_from, effective_to)
    values ('aaaa0001-0000-0000-0000-000000000000', 'AA', 'vat', 2000, '2024-01-01', '2025-01-01')$$,
  'a bounded tax period inserts');

-- B2. The successor starts on the day the predecessor ends. Under [) these are
-- adjacent, not overlapping — the normal shape of a rate change, and the case a
-- naive [] constraint would wrongly reject.
select lives_ok(
  $$insert into public.tax_schedules
      (id, country_code, regime, standard_rate_bps, effective_from, effective_to)
    values ('aaaa0002-0000-0000-0000-000000000000', 'AA', 'vat', 2100, '2025-01-01', '2026-01-01')$$,
  'an adjacent tax period inserts — effective_to is EXCLUSIVE, so a version ending on T and one starting on T do not overlap');

-- B3. A period landing inside an existing one.
select throws_ok(
  $$insert into public.tax_schedules
      (country_code, regime, standard_rate_bps, effective_from, effective_to)
    values ('AA', 'vat', 2200, '2024-06-01', '2024-09-01')$$,
  '23P01',
  null,
  'an overlapping tax period for the same country is rejected by the exclusion constraint');

-- B4. And a period swallowing existing ones, which is the direction an admin
-- "correcting" a historic schedule actually goes.
select throws_ok(
  $$insert into public.tax_schedules
      (country_code, regime, standard_rate_bps, effective_from, effective_to)
    values ('AA', 'vat', 2200, '2023-01-01', '2027-01-01')$$,
  '23P01',
  null,
  'a tax period that contains existing periods for the same country is rejected');

-- B5. An identical range. Note the SQLSTATE: T03's unique on (country_code,
-- effective_from) is an older index and is checked first, so this specific
-- mistake surfaces as 23505 rather than 23P01. Both mean "this period is
-- already covered" and T33's editor must say so for either.
select throws_ok(
  $$insert into public.tax_schedules
      (country_code, regime, standard_rate_bps, effective_from, effective_to)
    values ('AA', 'vat', 2200, '2024-01-01', '2025-01-01')$$,
  '23505',
  null,
  'an identical tax period for the same country is rejected — by T03''s unique on (country_code, effective_from), which is checked before the exclusion constraint');

-- B6. Different country, same calendar. This is the case a global-first schema
-- exists for: every country's schedule covers the same dates.
select lives_ok(
  $$insert into public.tax_schedules
      (id, country_code, regime, standard_rate_bps, effective_from, effective_to)
    values ('bbbb0001-0000-0000-0000-000000000000', 'BB', 'sales_tax', 700, '2024-01-01', '2025-01-01')$$,
  'the same dates for a DIFFERENT country are accepted');

-- B7. The current row: open-ended, beginning exactly where the last bounded
-- version ended.
select lives_ok(
  $$insert into public.tax_schedules
      (id, country_code, regime, standard_rate_bps, effective_from, effective_to)
    values ('aaaa0003-0000-0000-0000-000000000000', 'AA', 'vat', 2300, '2026-01-01', null)$$,
  'an open-ended tax period beginning exactly at the prior effective_to is accepted');

-- B8. The one that matters most. A NULL upper bound is UNBOUNDED, not
-- "excluded from the constraint": two current rows for one country conflict.
select throws_ok(
  $$insert into public.tax_schedules
      (country_code, regime, standard_rate_bps, effective_from, effective_to)
    values ('AA', 'vat', 2400, '2027-01-01', null)$$,
  '23P01',
  null,
  'a SECOND open-ended tax period for the same country is rejected — NULL effective_to is an unbounded upper edge, not an exemption');

-- B9. And the reverse direction: a bounded row cannot be slipped underneath an
-- open-ended one.
select throws_ok(
  $$insert into public.tax_schedules
      (country_code, regime, standard_rate_bps, effective_from, effective_to)
    values ('AA', 'vat', 2400, '2026-06-01', '2026-09-01')$$,
  '23P01',
  null,
  'a bounded tax period overlapping an open-ended one is rejected');

-- B10. Adjacency on both edges at once: a bounded row that exactly fills the
-- gap between a bounded predecessor and an open-ended successor.
select lives_ok(
  $$insert into public.tax_schedules
      (id, country_code, regime, standard_rate_bps, effective_from, effective_to)
    values ('bbbb0002-0000-0000-0000-000000000000', 'BB', 'sales_tax', 750, '2026-01-01', null)$$,
  'an open-ended tax period for the second country is accepted');

select lives_ok(
  $$insert into public.tax_schedules
      (id, country_code, regime, standard_rate_bps, effective_from, effective_to)
    values ('bbbb0003-0000-0000-0000-000000000000', 'BB', 'sales_tax', 725, '2025-01-01', '2026-01-01')$$,
  'a bounded tax period that exactly fills the gap — adjacent to a bounded predecessor AND to an open-ended successor — is accepted');

-- B11/B12. Degenerate ranges, caught by T03's check before the range is ever
-- constructed.
select throws_ok(
  $$insert into public.tax_schedules
      (country_code, regime, standard_rate_bps, effective_from, effective_to)
    values ('AA', 'vat', 2000, '2030-01-01', '2030-01-01')$$,
  '23514',
  null,
  'a tax period with effective_to = effective_from is rejected — an empty range would be invisible to the exclusion constraint');

select throws_ok(
  $$insert into public.tax_schedules
      (country_code, regime, standard_rate_bps, effective_from, effective_to)
    values ('AA', 'vat', 2000, '2030-01-01', '2029-01-01')$$,
  '23514',
  null,
  'a tax period with effective_to < effective_from is rejected');

-- B13. UPDATE is the path T33's editor actually takes, and an exclusion
-- constraint that only guarded INSERT would be useless there.
select throws_ok(
  $$update public.tax_schedules
       set effective_to = '2025-06-01'
     where id = 'aaaa0001-0000-0000-0000-000000000000'$$,
  '23P01',
  null,
  'an UPDATE that extends a tax period into its successor is rejected');

select lives_ok(
  $$update public.tax_schedules
       set effective_from = '2023-06-01'
     where id = 'aaaa0001-0000-0000-0000-000000000000'$$,
  'an UPDATE that moves a tax period into free space is accepted — the constraint blocks overlap, not editing');

-- ---------------------------------------------------------------------------
-- C. fee_schedules — the same guarantees, scoped by marketplace
-- ---------------------------------------------------------------------------
--
-- Fee schedules are per MARKETPLACE, not per country (§2.2). Two Amazon
-- locales are two marketplaces and their schedules cover the same calendar.

-- C1.
select lives_ok(
  $$insert into public.fee_schedules
      (id, marketplace_id, version, effective_from, effective_to, currency)
    values ('cccc0001-0000-0000-0000-000000000000',
            '11111111-1111-1111-1111-111111111111', 'v2024', '2024-01-01', '2025-01-01', 'GBP')$$,
  'a bounded fee period inserts');

-- C2.
select lives_ok(
  $$insert into public.fee_schedules
      (id, marketplace_id, version, effective_from, effective_to, currency)
    values ('cccc0002-0000-0000-0000-000000000000',
            '11111111-1111-1111-1111-111111111111', 'v2025', '2025-01-01', '2026-01-01', 'GBP')$$,
  'an adjacent fee period inserts');

-- C3.
select throws_ok(
  $$insert into public.fee_schedules
      (marketplace_id, version, effective_from, effective_to, currency)
    values ('11111111-1111-1111-1111-111111111111', 'v2024-mid', '2024-06-01', '2024-09-01', 'GBP')$$,
  '23P01',
  null,
  'an overlapping fee period for the same marketplace is rejected');

-- C4.
select throws_ok(
  $$insert into public.fee_schedules
      (marketplace_id, version, effective_from, effective_to, currency)
    values ('11111111-1111-1111-1111-111111111111', 'v-all', '2023-01-01', '2027-01-01', 'GBP')$$,
  '23P01',
  null,
  'a fee period that contains existing periods for the same marketplace is rejected');

-- C5. The gap this task actually closes on this table. The T03 unique is on
-- (marketplace_id, VERSION) — a label, not a period — so two differently
-- labelled versions could previously cover identical dates. Here that is 23P01,
-- from the exclusion constraint itself, which is the asymmetry with
-- tax_schedules that T33 has to expect.
select throws_ok(
  $$insert into public.fee_schedules
      (marketplace_id, version, effective_from, effective_to, currency)
    values ('11111111-1111-1111-1111-111111111111', 'v2024-revised', '2024-01-01', '2025-01-01', 'GBP')$$,
  '23P01',
  null,
  'an identical fee period under a DIFFERENT version label is rejected — the exclusion constraint governs the period, the T03 unique only ever governed the label');

select throws_ok(
  $$insert into public.fee_schedules
      (marketplace_id, version, effective_from, effective_to, currency)
    values ('11111111-1111-1111-1111-111111111111', 'v2024', '2028-01-01', '2029-01-01', 'GBP')$$,
  '23505',
  null,
  'T03''s unique on (marketplace_id, version) still rejects a duplicate version label, even in free calendar space');

-- C6.
select lives_ok(
  $$insert into public.fee_schedules
      (id, marketplace_id, version, effective_from, effective_to, currency)
    values ('dddd0001-0000-0000-0000-000000000000',
            '22222222-2222-2222-2222-222222222222', 'v2024', '2024-01-01', '2025-01-01', 'USD')$$,
  'the same dates for a DIFFERENT marketplace are accepted');

-- C7.
select lives_ok(
  $$insert into public.fee_schedules
      (id, marketplace_id, version, effective_from, effective_to, currency)
    values ('cccc0003-0000-0000-0000-000000000000',
            '11111111-1111-1111-1111-111111111111', 'v2026', '2026-01-01', null, 'GBP')$$,
  'an open-ended fee period beginning exactly at the prior effective_to is accepted');

-- C8.
select throws_ok(
  $$insert into public.fee_schedules
      (marketplace_id, version, effective_from, effective_to, currency)
    values ('11111111-1111-1111-1111-111111111111', 'v2027', '2027-01-01', null, 'GBP')$$,
  '23P01',
  null,
  'a SECOND open-ended fee period for the same marketplace is rejected');

-- C9.
select throws_ok(
  $$insert into public.fee_schedules
      (marketplace_id, version, effective_from, effective_to, currency)
    values ('11111111-1111-1111-1111-111111111111', 'v2026-mid', '2026-06-01', '2026-09-01', 'GBP')$$,
  '23P01',
  null,
  'a bounded fee period overlapping an open-ended one is rejected');

-- C10.
select lives_ok(
  $$insert into public.fee_schedules
      (id, marketplace_id, version, effective_from, effective_to, currency)
    values ('dddd0002-0000-0000-0000-000000000000',
            '22222222-2222-2222-2222-222222222222', 'v2026', '2026-01-01', null, 'USD')$$,
  'an open-ended fee period for the second marketplace is accepted');

select lives_ok(
  $$insert into public.fee_schedules
      (id, marketplace_id, version, effective_from, effective_to, currency)
    values ('dddd0003-0000-0000-0000-000000000000',
            '22222222-2222-2222-2222-222222222222', 'v2025', '2025-01-01', '2026-01-01', 'USD')$$,
  'a bounded fee period that exactly fills the gap between a bounded predecessor and an open-ended successor is accepted');

-- C11/C12.
select throws_ok(
  $$insert into public.fee_schedules
      (marketplace_id, version, effective_from, effective_to, currency)
    values ('11111111-1111-1111-1111-111111111111', 'v-degenerate', '2030-01-01', '2030-01-01', 'GBP')$$,
  '23514',
  null,
  'a fee period with effective_to = effective_from is rejected');

select throws_ok(
  $$insert into public.fee_schedules
      (marketplace_id, version, effective_from, effective_to, currency)
    values ('11111111-1111-1111-1111-111111111111', 'v-backwards', '2030-01-01', '2029-01-01', 'GBP')$$,
  '23514',
  null,
  'a fee period with effective_to < effective_from is rejected');

-- C13.
select throws_ok(
  $$update public.fee_schedules
       set effective_to = '2025-06-01'
     where id = 'cccc0001-0000-0000-0000-000000000000'$$,
  '23P01',
  null,
  'an UPDATE that extends a fee period into its successor is rejected');

select lives_ok(
  $$update public.fee_schedules
       set effective_from = '2023-06-01'
     where id = 'cccc0001-0000-0000-0000-000000000000'$$,
  'an UPDATE that moves a fee period into free space is accepted');

-- ---------------------------------------------------------------------------
-- D. The point of all of it: resolution returns exactly one row
-- ---------------------------------------------------------------------------
--
-- This is the shape of the query MarketContext (T13) will run. Asserted over
-- the accepted fixtures above, at a date inside a bounded version, on a
-- boundary day, and inside the open-ended current version — the three places
-- an off-by-one in the interval semantics would show up.

select is(
  (select count(*)::int from public.tax_schedules
    where country_code = 'AA'
      and effective_from <= date '2024-06-01'
      and (effective_to is null or effective_to > date '2024-06-01')),
  1,
  'tax resolution mid-period returns exactly one row');

select is(
  (select count(*)::int from public.tax_schedules
    where country_code = 'AA'
      and effective_from <= date '2025-01-01'
      and (effective_to is null or effective_to > date '2025-01-01')),
  1,
  'tax resolution ON a boundary date returns exactly one row — the successor, because effective_from is INCLUSIVE and effective_to is EXCLUSIVE');

select is(
  (select standard_rate_bps from public.tax_schedules
    where country_code = 'AA'
      and effective_from <= date '2025-01-01'
      and (effective_to is null or effective_to > date '2025-01-01')),
  2100,
  'and the row it returns on the boundary is the SUCCESSOR, not the version that ended that day');

select is(
  (select count(*)::int from public.tax_schedules
    where country_code = 'AA'
      and effective_from <= date '2099-01-01'
      and (effective_to is null or effective_to > date '2099-01-01')),
  1,
  'tax resolution far in the future returns exactly one row — the open-ended current version');

select is(
  (select count(*)::int from public.tax_schedules
    where country_code = 'AA'
      and effective_from <= date '2022-01-01'
      and (effective_to is null or effective_to > date '2022-01-01')),
  0,
  'tax resolution before any version returns NO row — a gap is a legitimate answer, and the caller must handle it rather than receive an arbitrary schedule');

select is(
  (select count(*)::int from public.fee_schedules
    where marketplace_id = '11111111-1111-1111-1111-111111111111'
      and effective_from <= date '2024-06-01'
      and (effective_to is null or effective_to > date '2024-06-01')),
  1,
  'fee resolution mid-period returns exactly one row');

select is(
  (select version from public.fee_schedules
    where marketplace_id = '11111111-1111-1111-1111-111111111111'
      and effective_from <= date '2026-01-01'
      and (effective_to is null or effective_to > date '2026-01-01')),
  'v2026',
  'fee resolution on the boundary date returns the successor version');

select is(
  (select count(*)::int from public.fee_schedules
    where marketplace_id = '11111111-1111-1111-1111-111111111111'
      and effective_from <= date '2099-01-01'
      and (effective_to is null or effective_to > date '2099-01-01')),
  1,
  'fee resolution far in the future returns exactly one row');

-- Both keys resolve independently on the same date — the global-first claim,
-- reduced to two counts.
select is(
  (select count(distinct country_code)::int from public.tax_schedules
    where effective_from <= date '2024-06-01'
      and (effective_to is null or effective_to > date '2024-06-01')),
  2,
  'on one date, two countries each resolve their own tax schedule');

select is(
  (select count(distinct marketplace_id)::int from public.fee_schedules
    where effective_from <= date '2024-06-01'
      and (effective_to is null or effective_to > date '2024-06-01')),
  2,
  'on one date, two marketplaces each resolve their own fee schedule');

-- ---------------------------------------------------------------------------
-- E. Nothing T03 built was disturbed
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from pg_constraint
    where conrelid = 'public.tax_schedules'::regclass
      and conname in ('tax_schedules_pkey',
                      'tax_schedules_country_effective_from_key',
                      'tax_schedules_country_code_fkey',
                      'tax_schedules_standard_rate_bps_range')),
  4,
  'tax_schedules keeps its primary key, its unique, its country foreign key and its rate check');

select is(
  (select count(*)::int from pg_constraint
    where conrelid = 'public.fee_schedules'::regclass
      and conname in ('fee_schedules_pkey',
                      'fee_schedules_marketplace_version_key',
                      'fee_schedules_marketplace_id_fkey',
                      'fee_schedules_currency_fkey')),
  4,
  'fee_schedules keeps its primary key, its unique and both foreign keys');

-- The deals FKs are the reason a schedule row can never be deleted out from
-- under a computed deal (§2.3). An ALTER TABLE on the parent must not touch
-- them.
select is(
  (select count(*)::int from pg_constraint
    where conrelid = 'public.deals'::regclass
      and conname in ('deals_tax_schedule_id_fkey', 'deals_fee_schedule_id_fkey')
      and confdeltype = 'r'),
  2,
  'deals still references both schedule tables with ON DELETE RESTRICT');

select is(
  (select count(*)::int from pg_index i
     join pg_class c on c.oid = i.indrelid
    where c.relname = 'tax_schedules'),
  3,
  'tax_schedules has exactly three indexes: the primary key, the T03 unique, and the new exclusion constraint');

select is(
  (select count(*)::int from pg_index i
     join pg_class c on c.oid = i.indrelid
    where c.relname = 'fee_schedules'),
  3,
  'fee_schedules has exactly three indexes: the primary key, the T03 unique, and the new exclusion constraint');

select has_trigger('public', 'tax_schedules', 'set_updated_at',
  'the tax_schedules updated_at trigger survives');

select has_trigger('public', 'fee_schedules', 'set_updated_at',
  'the fee_schedules updated_at trigger survives');

select is(
  (select count(*)::int from pg_trigger t
     join pg_class c on c.oid = t.tgrelid
    where c.relname in ('tax_schedules', 'fee_schedules') and not t.tgisinternal),
  2,
  'and no trigger was added — T05A is declarative, with no procedural enforcement to keep in step');

-- ---------------------------------------------------------------------------
-- F. RLS default-deny is unchanged
-- ---------------------------------------------------------------------------

select ok(
  (select relrowsecurity from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'tax_schedules'),
  'RLS is still enabled on tax_schedules');

select ok(
  (select relrowsecurity from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'fee_schedules'),
  'RLS is still enabled on fee_schedules');

select is(
  (select count(*)::int from pg_policies where schemaname = 'public'),
  0,
  'no RLS policy exists anywhere in public — T05A adds none, and both schedule tables are service-role-only per §6.3');

select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0,
  'no public table has RLS disabled');

-- ---------------------------------------------------------------------------
-- G. The ADR-004 privilege baseline is unchanged
-- ---------------------------------------------------------------------------
--
-- T05A grants nothing and revokes nothing. Asserted rather than assumed,
-- because "the migration only adds constraints" is exactly the claim a stray
-- GRANT would hide behind.

select is(
  (select count(*)::int from information_schema.role_table_grants
    where table_schema = 'public' and grantee in ('anon', 'authenticated')),
  0,
  'anon and authenticated still hold no table privilege of any kind in public');

select ok(
  not has_table_privilege('anon', 'public.tax_schedules', 'SELECT'),
  'anon cannot select from tax_schedules');

select ok(
  not has_table_privilege('anon', 'public.fee_schedules', 'SELECT'),
  'anon cannot select from fee_schedules');

select ok(
  not has_table_privilege('authenticated', 'public.tax_schedules', 'SELECT'),
  'authenticated cannot select from tax_schedules');

select ok(
  not has_table_privilege('authenticated', 'public.fee_schedules', 'SELECT'),
  'authenticated cannot select from fee_schedules');

select is(
  (select count(*)::int from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee = 'service_role'
      and privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
      and table_name in ('tax_schedules', 'fee_schedules')),
  8,
  'service_role keeps exactly the four DML privileges on both schedule tables (2 x 4) — unchanged by this migration');

select is(
  (select count(*)::int from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee = 'service_role'
      and privilege_type not in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')),
  0,
  'service_role still holds nothing beyond DML anywhere in public');

-- btree_gist adds no reachable surface: no table, no view, no sequence, and
-- nothing in `public`. Its support functions carry PostgreSQL's own default
-- EXECUTE to PUBLIC, exactly as pgcrypto and uuid-ossp already do in the same
-- schema — that is asserted here as the known, accepted state rather than left
-- for a reviewer to wonder about.
select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     join pg_depend d on d.objid = c.oid and d.deptype = 'e'
     join pg_extension e on e.oid = d.refobjid
    where e.extname = 'btree_gist'
      and c.relkind in ('r', 'v', 'm', 'S', 'p')),
  0,
  'btree_gist creates no table, view or sequence — it contributes operator classes and their support functions, nothing a role can read from');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     join pg_depend d on d.objid = c.oid and d.deptype = 'e'
     join pg_extension e on e.oid = d.refobjid
    where e.extname = 'btree_gist' and n.nspname = 'public'),
  0,
  'btree_gist installed nothing into the public schema');

select * from finish();

rollback;
