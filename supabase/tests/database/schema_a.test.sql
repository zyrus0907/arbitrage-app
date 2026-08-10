-- T03 — Schema A database tests (pgTAP), run by `npm run db:test`.
--
-- These assert the properties the acceptance criteria name, in the database
-- itself rather than through the application: constraints, cascades, indexes,
-- the signup trigger, and RLS default-deny.
--
-- pgTAP is created inside this transaction and rolled back with it, so the
-- test extension never appears in a migration and never reaches the hosted
-- project.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog, pg_temp;

select plan(49);

-- ---------------------------------------------------------------------------
-- A. The tables that must exist, and the one that must not
-- ---------------------------------------------------------------------------

select has_table('public', 'currencies',           'currencies exists');
select has_table('public', 'countries',            'countries exists');
select has_table('public', 'marketplaces',         'marketplaces exists');
select has_table('public', 'markets',              'markets exists');
select has_table('public', 'tax_schedules',        'tax_schedules exists');
select has_table('public', 'fee_schedules',        'fee_schedules exists');
select has_table('public', 'profiles',             'profiles exists');
select has_table('public', 'retailers',            'retailers exists');
select has_table('public', 'retailer_products',    'retailer_products exists');
select has_table('public', 'marketplace_products', 'marketplace_products exists');
select has_table('public', 'product_matches',      'product_matches exists');

-- The core catalogue is marketplace-generic. No Amazon-specific core table may
-- exist: ASIN is an external_id on marketplace_products, nothing more.
select hasnt_table('public', 'amazon_products',
  'no Amazon-specific core table exists');

select has_function('public', 'handle_new_user',
  'the signup profile trigger function exists');

-- ---------------------------------------------------------------------------
-- B. RLS default deny (§6.3) — enabled everywhere, no policies at T03
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity),
  11,
  'RLS is enabled on all eleven Schema A tables');

select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0,
  'no public table has RLS disabled');

select is(
  (select count(*)::int from pg_policies where schemaname = 'public'),
  0,
  'no RLS policy exists yet — every table is unreachable by anon and authenticated (T06 adds policies)');

-- ---------------------------------------------------------------------------
-- C. Currency exponents are data, not an assumed x100 (§2.2)
-- ---------------------------------------------------------------------------

select is(
  (select minor_unit_exponent from public.currencies where code = 'JPY'),
  0::smallint,
  'a 0-decimal currency is stored with exponent 0');

select is(
  (select minor_unit_exponent from public.currencies where code = 'GBP'),
  2::smallint,
  'a 2-decimal currency is stored with exponent 2');

select lives_ok(
  $$insert into public.currencies (code, minor_unit_exponent, name)
    values ('BHD', 3, 'Bahraini Dinar')$$,
  'a 3-decimal currency is accepted');

select throws_ok(
  $$insert into public.currencies (code, minor_unit_exponent, name)
    values ('ZZZ', 9, 'Nonsense')$$,
  '23514',
  null,
  'an out-of-range minor unit exponent is rejected');

select throws_ok(
  $$insert into public.currencies (code, minor_unit_exponent, name)
    values ('gbp2', 2, 'Malformed')$$,
  '23514',
  null,
  'a non-ISO-4217 currency code is rejected');

-- ---------------------------------------------------------------------------
-- Fixtures for the remaining sections
-- ---------------------------------------------------------------------------

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

insert into public.markets
  (id, slug, source_country_code, marketplace_id, currency, active, launch_status)
values
  ('33333333-3333-3333-3333-333333333333', 'aa', 'AA',
   '11111111-1111-1111-1111-111111111111', 'GBP', true, 'beta');

insert into public.retailers
  (id, name, slug, market_id, country_code, currency, source_type, price_display, active)
values
  ('44444444-4444-4444-4444-444444444444', 'Test Retailer', 'test-retailer',
   '33333333-3333-3333-3333-333333333333', 'AA', 'GBP', 'curated', 'inclusive', true);

insert into public.marketplace_products
  (id, marketplace_id, external_id, currency, gtins, provider_key)
values
  ('55555555-5555-5555-5555-555555555555', '11111111-1111-1111-1111-111111111111',
   'EXT0000001', 'GBP', array['00012345678905'], 'testadapter');

-- ---------------------------------------------------------------------------
-- D. Signup creates a profile; deleting the user cascades it away (§2.3)
-- ---------------------------------------------------------------------------

insert into auth.users (id, email)
values ('66666666-6666-6666-6666-666666666666', 'schema-a-test@example.test');

select is(
  (select count(*)::int from public.profiles
    where id = '66666666-6666-6666-6666-666666666666'),
  1,
  'a profile is created by trigger when an auth user signs up');

select is(
  (select credit_balance from public.profiles
    where id = '66666666-6666-6666-6666-666666666666'),
  0,
  'a new profile starts at zero credits — the signup grant is a ledger entry (T07), not a default');

select is(
  (select tax_registered from public.profiles
    where id = '66666666-6666-6666-6666-666666666666'),
  false,
  'a new profile defaults to not tax-registered, the conservative case (§7.4)');

delete from auth.users where id = '66666666-6666-6666-6666-666666666666';

select is(
  (select count(*)::int from public.profiles
    where id = '66666666-6666-6666-6666-666666666666'),
  0,
  'deleting the auth user cascades the profile away');

-- ---------------------------------------------------------------------------
-- E. Uniqueness (§2.3)
-- ---------------------------------------------------------------------------

insert into public.retailer_products
  (id, retailer_id, retailer_sku, gtin14, gtin_raw, gtin_format,
   price_minor, currency, price_tax_treatment)
values
  ('77777777-7777-7777-7777-777777777777', '44444444-4444-4444-4444-444444444444',
   'SKU-1', '00012345678905', '012345678905', 'upc_a', 1299, 'GBP', 'inclusive');

select throws_ok(
  $$insert into public.retailer_products
      (retailer_id, retailer_sku, price_minor, currency, price_tax_treatment)
    values ('44444444-4444-4444-4444-444444444444', 'SKU-1', 500, 'GBP', 'inclusive')$$,
  '23505',
  null,
  'a retailer cannot hold the same SKU twice');

select throws_ok(
  $$insert into public.marketplace_products
      (marketplace_id, external_id, currency, provider_key)
    values ('11111111-1111-1111-1111-111111111111', 'EXT0000001', 'GBP', 'testadapter')$$,
  '23505',
  null,
  'a marketplace cannot hold the same external id twice');

insert into public.product_matches
  (retailer_product_id, marketplace_product_id, method, confidence)
values
  ('77777777-7777-7777-7777-777777777777', '55555555-5555-5555-5555-555555555555',
   'gtin_exact', 0.99);

select throws_ok(
  $$insert into public.product_matches
      (retailer_product_id, marketplace_product_id, method, confidence)
    values ('77777777-7777-7777-7777-777777777777',
            '55555555-5555-5555-5555-555555555555', 'manual', 0.80)$$,
  '23505',
  null,
  'the same retailer product and marketplace product cannot be matched twice');

select throws_ok(
  $$insert into public.product_matches
      (retailer_product_id, marketplace_product_id, method, confidence)
    values ('77777777-7777-7777-7777-777777777777',
            '55555555-5555-5555-5555-555555555555', 'manual', 1.50)$$,
  '23514',
  null,
  'match confidence outside 0..1 is rejected');

-- ---------------------------------------------------------------------------
-- F. The MVP single-currency invariant is enforced in storage (§1.3, §7.6)
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.markets (slug, source_country_code, marketplace_id, currency)
    values ('mismatch', 'BB', '11111111-1111-1111-1111-111111111111', 'USD')$$,
  '23503',
  null,
  'a market cannot use a currency its marketplace does not trade in');

select throws_ok(
  $$insert into public.retailers
      (name, slug, market_id, country_code, currency, source_type, price_display)
    values ('Wrong Currency', 'wrong-currency',
            '33333333-3333-3333-3333-333333333333', 'AA', 'USD', 'curated', 'inclusive')$$,
  '23503',
  null,
  'a retailer cannot price in a currency its market does not use');

select throws_ok(
  $$insert into public.marketplace_products
      (marketplace_id, external_id, currency, provider_key)
    values ('11111111-1111-1111-1111-111111111111', 'EXT0000002', 'USD', 'testadapter')$$,
  '23503',
  null,
  'a marketplace product cannot be priced in a foreign currency');

-- ---------------------------------------------------------------------------
-- G. No money without a currency (§11.2)
-- ---------------------------------------------------------------------------

insert into auth.users (id, email)
values ('88888888-8888-8888-8888-888888888888', 'schema-a-money@example.test');

select throws_ok(
  $$update public.profiles set default_budget_minor = 50000
     where id = '88888888-8888-8888-8888-888888888888'$$,
  '23514',
  null,
  'a cost assumption cannot be stored without the currency it is denominated in');

select lives_ok(
  $$update public.profiles
       set default_budget_minor = 50000, assumption_currency = 'GBP'
     where id = '88888888-8888-8888-8888-888888888888'$$,
  'a cost assumption with an explicit currency is accepted');

-- ---------------------------------------------------------------------------
-- H. Canonical GTIN-14 identifiers (§2.3)
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.retailer_products
      (retailer_id, retailer_sku, gtin14, price_minor, currency, price_tax_treatment)
    values ('44444444-4444-4444-4444-444444444444', 'SKU-BADGTIN',
            '0123456789012', 100, 'GBP', 'inclusive')$$,
  '23514',
  null,
  'a GTIN that is not zero-padded to 14 digits is rejected');

select throws_ok(
  $$insert into public.retailer_products
      (retailer_id, retailer_sku, gtin_raw, price_minor, currency, price_tax_treatment)
    values ('44444444-4444-4444-4444-444444444444', 'SKU-NOFORMAT',
            '012345678905', 100, 'GBP', 'inclusive')$$,
  '23514',
  null,
  'a raw code without its declared format is rejected');

select throws_ok(
  $$insert into public.marketplace_products
      (marketplace_id, external_id, currency, gtins, provider_key)
    values ('11111111-1111-1111-1111-111111111111', 'EXT-BADGTIN', 'GBP',
            array['0012345678905'], 'testadapter')$$,
  '23514',
  null,
  'a marketplace product cannot carry a non-canonical GTIN');

-- The point of the canonical form: a UPC-12 from one country and an EAN-13
-- from another are the same product, and both must reach the same listing.
insert into public.retailer_products
  (id, retailer_id, retailer_sku, gtin14, gtin_raw, gtin_format,
   price_minor, currency, price_tax_treatment)
values
  ('99999999-9999-9999-9999-999999999999', '44444444-4444-4444-4444-444444444444',
   'SKU-EAN13', '00012345678905', '0012345678905', 'ean_13', 1350, 'GBP', 'inclusive');

select is(
  (select count(distinct mp.id)::int
     from public.retailer_products rp
     join public.marketplace_products mp on rp.gtin14 = any (mp.gtins)
    where rp.id in ('77777777-7777-7777-7777-777777777777',
                    '99999999-9999-9999-9999-999999999999')),
  1,
  'a UPC-12 and an EAN-13 for the same product resolve to one marketplace listing');

select is(
  (select count(distinct gtin_format)::int
     from public.retailer_products
    where id in ('77777777-7777-7777-7777-777777777777',
                 '99999999-9999-9999-9999-999999999999')),
  2,
  'the two rows genuinely arrived in different original formats');

-- ---------------------------------------------------------------------------
-- I. Cascade and restrict behaviour
-- ---------------------------------------------------------------------------

select throws_ok(
  $$delete from public.currencies where code = 'GBP'$$,
  '23503',
  null,
  'a currency in use cannot be deleted out from under the rows that reference it');

select throws_ok(
  $$delete from public.marketplaces where id = '11111111-1111-1111-1111-111111111111'$$,
  '23503',
  null,
  'a marketplace in use cannot be deleted');

delete from public.retailers where id = '44444444-4444-4444-4444-444444444444';

select is(
  (select count(*)::int from public.retailer_products
    where retailer_id = '44444444-4444-4444-4444-444444444444'),
  0,
  'deleting a retailer cascades its products away');

select is(
  (select count(*)::int from public.product_matches
    where retailer_product_id = '77777777-7777-7777-7777-777777777777'),
  0,
  'deleting a retailer product cascades its matches away');

-- ---------------------------------------------------------------------------
-- J. Indexes the expected access patterns require (§2.3)
-- ---------------------------------------------------------------------------

select has_index('public', 'retailer_products', 'retailer_products_gtin14_idx',
  'retailer_products.gtin14 is indexed — it is the matching key');

select has_index('public', 'retailer_products', 'retailer_products_last_seen_at_idx',
  'retailer_products.last_seen_at is indexed');

select has_index('public', 'marketplace_products', 'marketplace_products_gtins_idx',
  'marketplace_products.gtins has a GIN index');

select is(
  (select amname from pg_class i
     join pg_am am on am.oid = i.relam
    where i.relname = 'marketplace_products_gtins_idx'),
  'gin',
  'the GTIN array index is a GIN index, not a btree');

select has_index('public', 'marketplace_products', 'marketplace_products_refreshed_at_idx',
  'marketplace_products.refreshed_at is indexed — the refresh policy selects on staleness');

-- ---------------------------------------------------------------------------
-- K. Timestamps
-- ---------------------------------------------------------------------------

update public.currencies set name = 'Pound Sterling (touched)' where code = 'GBP';

select ok(
  (select updated_at > created_at from public.currencies where code = 'GBP'),
  'updated_at advances on update while created_at stays put');

select * from finish();

rollback;
