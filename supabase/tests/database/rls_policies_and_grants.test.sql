-- T06 — RLS policy and grant tests (pgTAP), run by `npm run db:test`.
--
-- T09 owns the formal, exhaustive privilege suite. This file ships T06's own
-- proof that the surface it opened behaves as designed, and it is written
-- around one idea that ADR-004 makes non-negotiable:
--
--   A table is usable only when BOTH layers permit it — the SQL privilege AND
--   the RLS policy. So every assertion here names WHICH layer it is testing.
--
-- Concretely, "the anon role sees nothing" has three different causes and only
-- one of them is the one we want in any given case:
--
--   42501  insufficient_privilege — the grant layer refused. The query never
--          reached RLS. This is what a closed table must produce.
--   0 rows — the grant exists, the query ran, and the policy predicate filtered
--          everything out. This is what a public table's hidden rows produce.
--   0A000  feature_not_supported — a trigger refused (the repo's convention,
--          shared with enforce_credit_ledger_append_only). This is what the
--          ledger and the webhook restricted-update rules produce.
--
-- A test that asserts "zero rows" without naming the mechanism passes for the
-- wrong reason and stops protecting anything the day a grant is added. Every
-- negative assertion below therefore asserts a SQLSTATE or a row count, never
-- "it didn't work".
--
-- pgTAP is created inside this transaction and rolled back with it.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog, pg_temp;

select plan(162);

-- ---------------------------------------------------------------------------
-- Helpers: run a statement as a role, optionally as a specific auth.uid()
-- ---------------------------------------------------------------------------
--
-- Same construction as schema_c.test.sql: the role switch lives inside one
-- statement so the pgTAP assertion itself always runs as the owner. The
-- addition here is the JWT claim, because RLS on the user-owned tables is a
-- function of auth.uid(), which reads `request.jwt.claims` (see auth.uid()'s
-- body). Passing p_uid => null leaves the claim empty, which is exactly what an
-- anonymous request looks like: auth.uid() returns NULL and `user_id = NULL`
-- is NULL, never true. That is the property that makes the user-owned policies
-- safe against an unauthenticated caller, and it is asserted directly in F.

create function public._t6_sqlstate(p_role text, p_uid uuid, p_sql text)
returns text
language plpgsql
as $fn$
declare
  code text;
begin
  begin
    perform set_config('request.jwt.claims',
                       case when p_uid is null then '' else json_build_object('sub', p_uid)::text end,
                       true);
    execute format('set local role %I', p_role);
    execute p_sql;
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    return null;
  exception when others then
    code := sqlstate;
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    return code;
  end;
end;
$fn$;

-- Returns the row count a role actually sees. NULL means the statement failed
-- outright, which the caller should be asserting with _t6_sqlstate instead —
-- a count assertion that quietly turned into an error would be the exact
-- pass-for-the-wrong-reason this file exists to prevent, so it returns NULL
-- rather than 0 and the `is(..., N)` fails loudly.
create function public._t6_count(p_role text, p_uid uuid, p_sql text)
returns integer
language plpgsql
as $fn$
declare
  n integer;
begin
  begin
    perform set_config('request.jwt.claims',
                       case when p_uid is null then '' else json_build_object('sub', p_uid)::text end,
                       true);
    execute format('set local role %I', p_role);
    execute p_sql into n;
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    return n;
  exception when others then
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    return null;
  end;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
--
-- Shaped around the predicates rather than around the tables: every public-read
-- policy gets at least one row it must show and at least one row it must hide,
-- so a policy that degenerated to `true` fails here rather than in production.
--
-- Two users, u1 and u2, each with a full set of user-owned rows. u2 exists for
-- exactly one purpose: to be the other user whose rows u1 must never see.

insert into public.countries
  (code, name, default_currency, default_locale, tax_regime, retail_price_display, timezone_default, active)
values
  ('PA', 'Publicland', 'GBP', 'en-PA', 'vat', 'inclusive', 'UTC', true),
  ('PZ', 'Hiddenland', 'GBP', 'en-PZ', 'vat', 'inclusive', 'UTC', false);

-- Four marketplaces rather than one, only because markets is UNIQUE on
-- (source_country_code, marketplace_id) — the four markets below have to differ
-- on something, and the marketplace is the axis that costs nothing here.
insert into public.marketplaces
  (id, provider, code, country_code, currency, domain, adapter_key, active)
values
  ('16000000-0000-0000-0000-000000000001', 'testprovider', 'test_pa1', 'PA', 'GBP',
   'example.test', 'testadapter', true),
  ('16000000-0000-0000-0000-000000000002', 'testprovider', 'test_pa2', 'PA', 'GBP',
   'example.test', 'testadapter', true),
  ('16000000-0000-0000-0000-000000000003', 'testprovider', 'test_pa3', 'PA', 'GBP',
   'example.test', 'testadapter', true),
  ('16000000-0000-0000-0000-000000000004', 'testprovider', 'test_pa4', 'PA', 'GBP',
   'example.test', 'testadapter', true);

-- Four markets covering the two-flag predicate. Only the first is visible.
insert into public.markets
  (id, slug, source_country_code, marketplace_id, currency, active, launch_status)
values
  ('26000000-0000-0000-0000-000000000001', 'pa-live',     'PA',
   '16000000-0000-0000-0000-000000000001', 'GBP', true,  'live'),
  ('26000000-0000-0000-0000-000000000002', 'pa-beta',     'PA',
   '16000000-0000-0000-0000-000000000002', 'GBP', true,  'beta'),
  ('26000000-0000-0000-0000-000000000003', 'pa-planned',  'PA',
   '16000000-0000-0000-0000-000000000003', 'GBP', true,  'planned'),
  ('26000000-0000-0000-0000-000000000004', 'pa-inactive', 'PA',
   '16000000-0000-0000-0000-000000000004', 'GBP', false, 'live');

insert into public.retailers
  (id, name, slug, market_id, country_code, currency, source_type, price_display, active)
values
  ('36000000-0000-0000-0000-000000000001', 'Retailer P', 'retailer-p',
   '26000000-0000-0000-0000-000000000001', 'PA', 'GBP', 'curated', 'inclusive', true);

insert into public.retailer_products
  (id, retailer_id, retailer_sku, gtin14, price_minor, currency, price_tax_treatment)
values
  ('46000000-0000-0000-0000-000000000001', '36000000-0000-0000-0000-000000000001',
   'SKU-P1', '00012345670001', 1299, 'GBP', 'inclusive'),
  ('46000000-0000-0000-0000-000000000002', '36000000-0000-0000-0000-000000000001',
   'SKU-P2', '00012345670002', 1399, 'GBP', 'inclusive');

insert into public.marketplace_products
  (id, marketplace_id, external_id, currency, gtins, provider_key)
values
  ('56000000-0000-0000-0000-000000000001', '16000000-0000-0000-0000-000000000001',
   'EXT-P1', 'GBP', array['00012345670001'], 'testadapter'),
  ('56000000-0000-0000-0000-000000000002', '16000000-0000-0000-0000-000000000001',
   'EXT-P2', 'GBP', array['00012345670002'], 'testadapter');

insert into public.fee_schedules (id, marketplace_id, version, effective_from, currency)
values ('66000000-0000-0000-0000-000000000001', '16000000-0000-0000-0000-000000000001',
        'test.v1', date '2026-01-01', 'GBP');

insert into public.tax_schedules (id, country_code, regime, standard_rate_bps, effective_from)
values ('76000000-0000-0000-0000-000000000001', 'PA', 'vat', 2000, date '2026-01-01');

-- Two deals. Inserted `draft` because ADR-0009's trigger requires it, then one
-- published to `active`. Section E uses the pair to prove that deal status is
-- irrelevant to a client — neither is reachable, because `deals` is closed at
-- the grant layer, which is a stronger guarantee than "only active deals are
-- visible" and is what §6.3 chose over column-level RLS.
insert into public.deals (
  id, market_id, retailer_id, marketplace_id,
  retailer_product_id, marketplace_product_id, match_confidence, currency,
  buy_price_minor, buy_price_tax_treatment, sell_price_minor,
  fee_schedule_id, tax_schedule_id, net_profit_minor, roi_bps, margin_bps,
  deal_score, demand_band, competition_band, stability_band, confidence_band,
  score_breakdown, calc_version, score_version, inputs_snapshot
) values
  ('86000000-0000-0000-0000-000000000001',
   '26000000-0000-0000-0000-000000000001', '36000000-0000-0000-0000-000000000001',
   '16000000-0000-0000-0000-000000000001', '46000000-0000-0000-0000-000000000001',
   '56000000-0000-0000-0000-000000000001', 0.99, 'GBP', 1299, 'inclusive', 2599,
   '66000000-0000-0000-0000-000000000001', '76000000-0000-0000-0000-000000000001',
   640, 4200, 2461, 72, 'high', 'medium', 'high', 'high',
   '{}'::jsonb, 'calc.v1', 'score.v1', '{}'::jsonb),
  ('86000000-0000-0000-0000-000000000002',
   '26000000-0000-0000-0000-000000000001', '36000000-0000-0000-0000-000000000001',
   '16000000-0000-0000-0000-000000000001', '46000000-0000-0000-0000-000000000002',
   '56000000-0000-0000-0000-000000000002', 0.99, 'GBP', 1399, 'inclusive', 2699,
   '66000000-0000-0000-0000-000000000001', '76000000-0000-0000-0000-000000000001',
   680, 4300, 2500, 74, 'high', 'medium', 'high', 'high',
   '{}'::jsonb, 'calc.v1', 'score.v1', '{}'::jsonb);

update public.deals
   set status = 'active', published_at = now()
 where id = '86000000-0000-0000-0000-000000000001';

-- profiles rows arrive via the handle_new_user trigger on auth.users (T03).
insert into auth.users (id, email) values
  ('a6000000-0000-0000-0000-000000000001', 't06-u1@example.test'),
  ('a6000000-0000-0000-0000-000000000002', 't06-u2@example.test');

update public.profiles set credit_balance = 5, display_name = 'U1'
 where id = 'a6000000-0000-0000-0000-000000000001';
update public.profiles set credit_balance = 9, display_name = 'U2'
 where id = 'a6000000-0000-0000-0000-000000000002';

-- Two packs: one shown, one hidden by `active`.
insert into public.credit_packs (id, name, credits, active, sort_order) values
  ('b6000000-0000-0000-0000-000000000001', 'Visible pack', 100, true,  1),
  ('b6000000-0000-0000-0000-000000000002', 'Retired pack', 50,  false, 2);

-- The full 2x2 of the credit_pack_prices predicate. Exactly one row is visible.
-- The unique key is (credit_pack_id, currency) and the seed carries three
-- currencies (GBP, USD, JPY), so the four combinations are spread across the
-- two packs. Which pack a price hangs off is irrelevant to this predicate —
-- credit_pack_prices.active is its own flag — and section B2 checks the two
-- packs separately for exactly that reason.
insert into public.credit_pack_prices
  (id, credit_pack_id, currency, amount_minor, stripe_price_id, active)
values
  ('c6000000-0000-0000-0000-000000000001', 'b6000000-0000-0000-0000-000000000001',
   'GBP', 999,  'price_t06_visible', true),   -- active + id      => VISIBLE
  ('c6000000-0000-0000-0000-000000000002', 'b6000000-0000-0000-0000-000000000001',
   'USD', 1299, null,                 true),  -- active + no id   => hidden (T08 state)
  ('c6000000-0000-0000-0000-000000000003', 'b6000000-0000-0000-0000-000000000002',
   'GBP', 1199, 'price_t06_retired',  false), -- inactive + id    => hidden
  ('c6000000-0000-0000-0000-000000000004', 'b6000000-0000-0000-0000-000000000002',
   'USD', 1500, null,                 false); -- inactive + no id => hidden

insert into public.credit_ledger
  (id, user_id, delta, reason, balance_after, idempotency_key)
values
  ('d6000000-0000-0000-0000-000000000001', 'a6000000-0000-0000-0000-000000000001',
   5, 'signup_grant', 5, 't06-u1-signup'),
  ('d6000000-0000-0000-0000-000000000002', 'a6000000-0000-0000-0000-000000000002',
   9, 'signup_grant', 9, 't06-u2-signup');

insert into public.deal_unlocks (id, user_id, deal_id, credits_spent) values
  ('e6000000-0000-0000-0000-000000000001', 'a6000000-0000-0000-0000-000000000001',
   '86000000-0000-0000-0000-000000000001', 1),
  ('e6000000-0000-0000-0000-000000000002', 'a6000000-0000-0000-0000-000000000002',
   '86000000-0000-0000-0000-000000000002', 1);

insert into public.watchlist_items (id, user_id, deal_id, marketplace_product_id) values
  ('f6000000-0000-0000-0000-000000000001', 'a6000000-0000-0000-0000-000000000001',
   '86000000-0000-0000-0000-000000000001', '56000000-0000-0000-0000-000000000001'),
  ('f6000000-0000-0000-0000-000000000002', 'a6000000-0000-0000-0000-000000000002',
   '86000000-0000-0000-0000-000000000002', '56000000-0000-0000-0000-000000000002');

insert into public.purchase_records
  (id, user_id, deal_id, market_id, units, currency, expected_profit_minor, inputs_snapshot)
values
  ('a6000000-0000-0000-0000-0000000000f1', 'a6000000-0000-0000-0000-000000000001',
   '86000000-0000-0000-0000-000000000001', '26000000-0000-0000-0000-000000000001',
   2, 'GBP', 640, '{}'::jsonb),
  ('a6000000-0000-0000-0000-0000000000f2', 'a6000000-0000-0000-0000-000000000002',
   '86000000-0000-0000-0000-000000000002', '26000000-0000-0000-0000-000000000001',
   3, 'GBP', 680, '{}'::jsonb);

insert into public.barcode_lookups (id, user_id, market_id, barcode_raw, credits_spent) values
  ('a6000000-0000-0000-0000-0000000000b1', 'a6000000-0000-0000-0000-000000000001',
   '26000000-0000-0000-0000-000000000001', '012345670001', 1),
  ('a6000000-0000-0000-0000-0000000000b2', 'a6000000-0000-0000-0000-000000000002',
   '26000000-0000-0000-0000-000000000001', '012345670002', 1);

insert into public.stripe_webhook_events (stripe_event_id, type, payload) values
  ('evt_t06_0001', 'checkout.session.completed', '{"id":"evt_t06_0001","v":1}'::jsonb),
  ('evt_t06_0002', 'charge.refunded',            '{"id":"evt_t06_0002","v":1}'::jsonb);

insert into public.credit_purchases
  (id, user_id, stripe_checkout_session_id, credit_pack_id, credits, amount_minor, currency, status)
values
  ('a6000000-0000-0000-0000-0000000000c1', 'a6000000-0000-0000-0000-000000000001',
   'cs_t06_0001', 'b6000000-0000-0000-0000-000000000001', 100, 999, 'GBP', 'paid');

insert into public.api_usage_log (provider, endpoint, units_used, status)
values ('testprovider', '/probe', 1, 'ok');

insert into public.ingestion_runs (market_id, source, status)
values ('26000000-0000-0000-0000-000000000001', 'curated', 'running');

insert into public.app_events (user_id, market_id, event)
values ('a6000000-0000-0000-0000-000000000001',
        '26000000-0000-0000-0000-000000000001', 't06_probe');


-- ===========================================================================
-- A. The two layers still hold everywhere they were not deliberately opened
-- ===========================================================================
--
-- T03's baseline was "anon and authenticated hold nothing at all". T06 breaks
-- that by design, so the baseline assertion is replaced by an exact allowlist
-- rather than dropped. Anything outside the eleven tables below is a leak.

select bag_eq(
  $$select distinct table_name::text
      from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'anon'$$,
  $$values ('countries'), ('currencies'), ('markets'),
           ('credit_packs'), ('credit_pack_prices')$$,
  'anon holds table privileges on exactly the five public reference tables');

select is(
  (select string_agg(distinct privilege_type, ',' order by privilege_type)
     from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'anon'),
  'SELECT',
  'and every one of them is SELECT — anon holds no write privilege anywhere');

select bag_eq(
  $$select distinct table_name::text
      from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'authenticated'$$,
  $$values ('countries'), ('currencies'), ('markets'),
           ('credit_packs'), ('credit_pack_prices'),
           ('profiles'), ('credit_ledger'), ('deal_unlocks'),
           ('watchlist_items'), ('purchase_records'), ('barcode_lookups')$$,
  'authenticated holds table privileges on exactly eleven tables — five public, six user-owned');

-- UPDATE is the privilege that would matter most if it leaked, so it is
-- enumerated on its own. profiles is absent because its UPDATE is column-level
-- (section C) and therefore does not appear in role_table_grants at all — which
-- is itself the point: no table on this schema grants authenticated a
-- whole-table UPDATE.
select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee in ('anon', 'authenticated')
      and privilege_type = 'UPDATE'),
  0,
  'no whole-table UPDATE is granted to anon or authenticated anywhere');

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee in ('anon', 'authenticated')
      and privilege_type not in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')),
  0,
  'and no incidental TRUNCATE, REFERENCES, TRIGGER or MAINTAIN crept back in');

-- The thirteen closed tables, named. This is the assertion that turns red when
-- a future task grants something without deciding to.
select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee in ('anon', 'authenticated')
      and table_name in (
        'deals', 'retailers', 'retailer_products', 'marketplace_products',
        'product_matches', 'marketplaces', 'tax_schedules', 'fee_schedules',
        'credit_purchases', 'stripe_webhook_events', 'api_usage_log',
        'ingestion_runs', 'app_events')),
  0,
  'the thirteen service-role-only tables grant anon and authenticated nothing');

select is(
  (select count(*)::int
     from information_schema.column_privileges
    where table_schema = 'public'
      and grantee in ('anon', 'authenticated')
      and table_name in (
        'deals', 'retailers', 'retailer_products', 'marketplace_products',
        'product_matches', 'marketplaces', 'tax_schedules', 'fee_schedules',
        'credit_purchases', 'stripe_webhook_events', 'api_usage_log',
        'ingestion_runs', 'app_events')),
  0,
  'not even a column-level grant on any of them — the column layer is checked separately because a table-level query would miss it');

-- No policy on the closed tables either. Belt and braces in the other
-- direction: a policy here would be inert today and a leak the moment someone
-- "fixed" the missing grant.
select is(
  (select count(*)::int
     from pg_policies
    where schemaname = 'public'
      and tablename in (
        'deals', 'retailers', 'retailer_products', 'marketplace_products',
        'product_matches', 'marketplaces', 'tax_schedules', 'fee_schedules',
        'credit_purchases', 'stripe_webhook_events', 'api_usage_log',
        'ingestion_runs', 'app_events')),
  0,
  'and no RLS policy exists on any of them');

-- RLS is still on for all 24, including the ones that just gained grants.
select is(
  (select count(*)::int
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity),
  24,
  'RLS is enabled on all 24 public tables — the grants added by T06 sit on top of it, not instead of it');

-- ---------------------------------------------------------------------------
-- A2. The closed tables refused at the GRANT layer, not the RLS layer
-- ---------------------------------------------------------------------------
--
-- 42501 and not "zero rows". If these ever start returning 0 rows instead, a
-- grant has appeared and the policy layer is doing work that the privilege
-- layer was supposed to have already refused.

select is(public._t6_sqlstate('anon', null, 'select 1 from public.deals limit 1'),
  '42501', 'anon reading deals fails with a PRIVILEGE error — the paid product is closed at the first gate');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  'select 1 from public.deals limit 1'),
  '42501', 'an authenticated user reading deals fails with a privilege error too — unlocking is a server-side entitlement, not a row filter');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  'select 1 from public.marketplaces limit 1'),
  '42501', 'marketplaces is closed (ADR-008) — adapter_key and capabilities are integration internals');

select is(public._t6_sqlstate('anon', null, 'select 1 from public.marketplaces limit 1'),
  '42501', 'and closed to anon as well');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  'select 1 from public.retailer_products limit 1'),
  '42501', 'retailer_products is closed — this is the "where to buy it" half of the paid answer');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  'select 1 from public.marketplace_products limit 1'),
  '42501', 'marketplace_products is closed');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  'select 1 from public.product_matches limit 1'),
  '42501', 'product_matches is closed');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  'select 1 from public.retailers limit 1'),
  '42501', 'retailers is closed');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  'select 1 from public.fee_schedules limit 1'),
  '42501', 'fee_schedules is closed');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  'select 1 from public.tax_schedules limit 1'),
  '42501', 'tax_schedules is closed');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  'select 1 from public.credit_purchases limit 1'),
  '42501', 'credit_purchases is closed — a user cannot read even their own payment rows directly');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  'select 1 from public.stripe_webhook_events limit 1'),
  '42501', 'stripe_webhook_events is closed — raw Stripe payloads are never client-readable');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  'select 1 from public.api_usage_log limit 1'),
  '42501', 'api_usage_log is closed — provider quota and cost are operational data');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  'select 1 from public.ingestion_runs limit 1'),
  '42501', 'ingestion_runs is closed — ingestion state is operational data');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  'select 1 from public.app_events limit 1'),
  '42501', 'app_events is closed — it may carry other users'' behaviour');


-- ===========================================================================
-- B. Public reference data — both layers, and the predicate boundaries
-- ===========================================================================
--
-- Each table is checked three ways: the grant exists, a matching policy exists,
-- and the role can actually read the rows it should. The third is the one T06
-- calls out specifically — a policy that is inert for want of a grant must fail
-- here, not at T09.

select ok(has_table_privilege('anon', 'public.countries', 'SELECT'),
  'countries: anon holds SELECT (grant layer)');
select ok(has_table_privilege('authenticated', 'public.countries', 'SELECT'),
  'countries: authenticated holds SELECT (grant layer)');
select is(
  (select count(*)::int from pg_policies
    where schemaname='public' and tablename='countries' and cmd='SELECT'),
  1, 'countries: exactly one SELECT policy governs it (policy layer)');

select is(public._t6_count('anon', null,
  $$select count(*)::int from public.countries where code in ('PA','PZ')$$),
  1, 'countries: anon sees the active country and not the inactive one');

select is(public._t6_count('anon', null,
  $$select count(*)::int from public.countries where code = 'PZ'$$),
  0, 'countries: the inactive row is hidden by the policy, not by an error — the query ran');

select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$select count(*)::int from public.countries where code = 'PA'$$),
  1, 'countries: an authenticated user reads it too');

select is(public._t6_sqlstate('anon', null,
  $$update public.countries set name = 'Hacked' where code = 'PA'$$),
  '42501', 'countries: anon cannot write to it — SELECT only');

select ok(has_table_privilege('anon', 'public.currencies', 'SELECT'),
  'currencies: anon holds SELECT (grant layer)');
select is(
  (select count(*)::int from pg_policies
    where schemaname='public' and tablename='currencies' and cmd='SELECT'),
  1, 'currencies: exactly one SELECT policy governs it (policy layer)');

-- The one unqualified predicate in T06, and the documented deviation: the table
-- has no `active` column to filter on.
select is(
  (select qual from pg_policies
    where schemaname='public' and tablename='currencies'),
  'true',
  'currencies: the predicate is deliberately unqualified — ARCHITECTURE §2.2 gives the table no `active` column to filter on');

select ok(
  not exists (select 1 from information_schema.columns
               where table_schema='public' and table_name='currencies' and column_name='active'),
  'currencies: and there is genuinely no active column, so this is a schema fact rather than a forgotten predicate');

select cmp_ok(public._t6_count('anon', null,
  $$select count(*)::int from public.currencies$$),
  '>', 0, 'currencies: anon can actually read the exponent it needs to format money (§2.4)');

select is(public._t6_sqlstate('anon', null,
  $$insert into public.currencies (code, minor_unit_exponent, name) values ('ZZZ', 2, 'Fake')$$),
  '42501', 'currencies: anon cannot insert reference data');

select ok(has_table_privilege('anon', 'public.markets', 'SELECT'),
  'markets: anon holds SELECT (grant layer)');
select is(
  (select count(*)::int from pg_policies
    where schemaname='public' and tablename='markets' and cmd='SELECT'),
  1, 'markets: exactly one SELECT policy governs it (policy layer)');

-- The four-row fixture is the whole point: three of the four must be hidden.
select is(public._t6_count('anon', null,
  $$select count(*)::int from public.markets where slug like 'pa-%'$$),
  1, 'markets: anon sees exactly one of the four fixture markets');

select is(public._t6_count('anon', null,
  $$select count(*)::int from public.markets where slug = 'pa-live'$$),
  1, 'markets: the active + live market is visible');

select is(public._t6_count('anon', null,
  $$select count(*)::int from public.markets where slug = 'pa-beta'$$),
  0, 'markets: an active but beta market is hidden — a user there is waitlisted, not shown a half-ready market (AC2.2)');

select is(public._t6_count('anon', null,
  $$select count(*)::int from public.markets where slug = 'pa-planned'$$),
  0, 'markets: an active but planned market is hidden (risk #7)');

select is(public._t6_count('anon', null,
  $$select count(*)::int from public.markets where slug = 'pa-inactive'$$),
  0, 'markets: a live but inactive market is hidden — both flags are load-bearing');

select ok(has_table_privilege('anon', 'public.credit_packs', 'SELECT'),
  'credit_packs: anon holds SELECT (grant layer)');
select is(
  (select count(*)::int from pg_policies
    where schemaname='public' and tablename='credit_packs' and cmd='SELECT'),
  1, 'credit_packs: exactly one SELECT policy governs it (policy layer)');

select is(public._t6_count('anon', null,
  $$select count(*)::int from public.credit_packs
     where id in ('b6000000-0000-0000-0000-000000000001','b6000000-0000-0000-0000-000000000002')$$),
  1, 'credit_packs: anon sees the active pack and not the retired one');

select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$select count(*)::int from public.credit_packs
     where id = 'b6000000-0000-0000-0000-000000000001'$$),
  1, 'credit_packs: an authenticated user reads it too');

-- ---------------------------------------------------------------------------
-- B2. credit_pack_prices — the full 2x2 of ADR-0010 decision 4
-- ---------------------------------------------------------------------------

select ok(has_table_privilege('anon', 'public.credit_pack_prices', 'SELECT'),
  'credit_pack_prices: anon holds SELECT (grant layer)');
select is(
  (select count(*)::int from pg_policies
    where schemaname='public' and tablename='credit_pack_prices' and cmd='SELECT'),
  1, 'credit_pack_prices: exactly one SELECT policy governs it (policy layer)');

select is(
  (select qual from pg_policies
    where schemaname='public' and tablename='credit_pack_prices'),
  '(active AND (stripe_price_id IS NOT NULL))',
  'credit_pack_prices: the predicate is exactly active AND stripe_price_id IS NOT NULL');

select is(public._t6_count('anon', null,
  $$select count(*)::int from public.credit_pack_prices
     where id = 'c6000000-0000-0000-0000-000000000001'$$),
  1, 'credit_pack_prices: active + stripe_price_id present => VISIBLE');

select is(public._t6_count('anon', null,
  $$select count(*)::int from public.credit_pack_prices
     where id = 'c6000000-0000-0000-0000-000000000002'$$),
  0, 'credit_pack_prices: active + stripe_price_id NULL => hidden — this is exactly what T08 seeds and it must not be buyable before T34');

select is(public._t6_count('anon', null,
  $$select count(*)::int from public.credit_pack_prices
     where id = 'c6000000-0000-0000-0000-000000000003'$$),
  0, 'credit_pack_prices: inactive + stripe_price_id present => hidden');

select is(public._t6_count('anon', null,
  $$select count(*)::int from public.credit_pack_prices
     where id = 'c6000000-0000-0000-0000-000000000004'$$),
  0, 'credit_pack_prices: inactive + stripe_price_id NULL => hidden');

select is(public._t6_count('anon', null,
  $$select count(*)::int from public.credit_pack_prices
     where credit_pack_id in ('b6000000-0000-0000-0000-000000000001',
                              'b6000000-0000-0000-0000-000000000002')$$),
  1, 'credit_pack_prices: exactly one of the four fixture rows is visible in total');

select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$select count(*)::int from public.credit_pack_prices
     where credit_pack_id in ('b6000000-0000-0000-0000-000000000001',
                              'b6000000-0000-0000-0000-000000000002')$$),
  1, 'credit_pack_prices: an authenticated user sees the same one row — the predicate is not a function of who is asking');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$update public.credit_pack_prices set amount_minor = 1
     where id = 'c6000000-0000-0000-0000-000000000001'$$),
  '42501', 'credit_pack_prices: a user cannot rewrite a price — SELECT only');


-- ===========================================================================
-- C. profiles — own row only, and never the balance
-- ===========================================================================

select ok(has_table_privilege('authenticated', 'public.profiles', 'SELECT'),
  'profiles: authenticated holds SELECT (grant layer)');

select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$select count(*)::int from public.profiles$$),
  1, 'profiles: a user sees exactly one row — their own — with no WHERE clause at all');

select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$select count(*)::int from public.profiles where id = 'a6000000-0000-0000-0000-000000000002'$$),
  0, 'profiles: another user''s row is invisible even when asked for by id');

select is(public._t6_sqlstate('anon', null,
  $$select 1 from public.profiles limit 1$$),
  '42501', 'profiles: anon is refused at the GRANT layer — the policy is scoped to authenticated only, so anon never reaches it');

-- The ownership predicate against a NULL auth.uid(). Belt and braces: even if
-- anon somehow held the grant, `id = NULL` is NULL and never true.
select is(public._t6_count('authenticated', null,
  $$select count(*)::int from public.profiles$$),
  0, 'profiles: an authenticated role with no JWT subject sees nothing — `id = NULL` is NULL, never true');

select ok(has_column_privilege('authenticated', 'public.profiles', 'display_name', 'UPDATE'),
  'profiles: authenticated may update display_name (column grant)');

select ok(
  not has_column_privilege('authenticated', 'public.profiles', 'credit_balance', 'UPDATE'),
  'profiles: authenticated may NOT update credit_balance — the money column is excluded at the column-grant layer');

select ok(
  not has_column_privilege('authenticated', 'public.profiles', 'id', 'UPDATE'),
  'profiles: nor `id` — ownership cannot be reassigned even before WITH CHECK is consulted');

select ok(
  not has_table_privilege('authenticated', 'public.profiles', 'UPDATE'),
  'profiles: and there is no whole-table UPDATE grant, so the column list is the entire writable surface');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$update public.profiles set display_name = 'Renamed' where id = 'a6000000-0000-0000-0000-000000000001'$$),
  null, 'profiles: a user CAN update their own display_name — the policy is not inert');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$update public.profiles set credit_balance = 1000000 where id = 'a6000000-0000-0000-0000-000000000001'$$),
  '42501', 'profiles: updating credit_balance fails with a PRIVILEGE error — credits are not mintable from the client');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$update public.profiles set id = 'a6000000-0000-0000-0000-000000000002'
     where id = 'a6000000-0000-0000-0000-000000000001'$$),
  '42501', 'profiles: reassigning ownership fails at the column layer before RLS is even reached');

-- Updating another user's row is not a privilege failure — the grant is held.
-- It is an RLS no-op: zero rows match USING. Asserted as a row count so the two
-- mechanisms stay distinguishable.
select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$with u as (update public.profiles set display_name = 'Hijacked'
                where id = 'a6000000-0000-0000-0000-000000000002' returning 1)
    select count(*)::int from u$$),
  0, 'profiles: updating another user''s row changes zero rows — RLS filtered it, no error');

select is(
  (select display_name from public.profiles where id = 'a6000000-0000-0000-0000-000000000002'),
  'U2', 'profiles: and that other row is genuinely untouched');

select is(
  (select credit_balance from public.profiles where id = 'a6000000-0000-0000-0000-000000000001'),
  5, 'profiles: the balance is still what the ledger says, after every attempt above');

select is(
  (select count(*)::int from pg_policies
    where schemaname='public' and tablename='profiles' and cmd='INSERT'),
  0, 'profiles: no INSERT policy — the row is created by the handle_new_user trigger, which is the only sanctioned path');

select is(
  (select count(*)::int from pg_policies
    where schemaname='public' and tablename='profiles' and cmd='DELETE'),
  0, 'profiles: no DELETE policy — account deletion cascades from auth.users and belongs to T10');


-- ===========================================================================
-- D. credit_ledger — read own, write nothing, at every layer
-- ===========================================================================

select ok(has_table_privilege('authenticated', 'public.credit_ledger', 'SELECT'),
  'credit_ledger: authenticated holds SELECT (grant layer)');

select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$select count(*)::int from public.credit_ledger$$),
  1, 'credit_ledger: a user sees exactly their own row');

select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$select count(*)::int from public.credit_ledger
     where user_id = 'a6000000-0000-0000-0000-000000000002'$$),
  0, 'credit_ledger: another user''s financial history is invisible');

select is(public._t6_sqlstate('anon', null, 'select 1 from public.credit_ledger limit 1'),
  '42501', 'credit_ledger: anon is refused at the grant layer');

select ok(
  not has_table_privilege('authenticated', 'public.credit_ledger', 'INSERT')
  and not has_table_privilege('authenticated', 'public.credit_ledger', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.credit_ledger', 'DELETE'),
  'credit_ledger: authenticated holds no INSERT, UPDATE or DELETE — SELECT is the whole surface');

select is(
  (select count(*)::int from pg_policies
    where schemaname='public' and tablename='credit_ledger' and cmd <> 'SELECT'),
  0, 'credit_ledger: there is no write policy of any kind — belt and braces on the source of truth for money');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a6000000-0000-0000-0000-000000000001', 1000, 'promo', 1005, 't06-minted')$$),
  '42501', 'credit_ledger: a user cannot mint credits — refused at the grant layer, before any policy');

-- ---------------------------------------------------------------------------
-- D2. The T05 protections are still intact — verified, never re-created
-- ---------------------------------------------------------------------------
--
-- ADR-0010 decision 3 puts both layers in T05 and makes T06's job verification.
-- Two triggers with one purpose would mean either could be dropped without a
-- test going red, so the assertion is that there is exactly ONE row-level
-- append-only trigger, not "at least one".

select is(
  (select count(*)::int from pg_trigger
    where tgrelid = 'public.credit_ledger'::regclass and not tgisinternal),
  2, 'credit_ledger: exactly two triggers — the row-level append-only guard and the TRUNCATE guard. T06 added none.');

select ok(
  exists (select 1 from pg_trigger
           where tgrelid = 'public.credit_ledger'::regclass
             and tgname = 'credit_ledger_append_only' and not tgisinternal),
  'credit_ledger: the T05 append-only trigger still exists');

select ok(
  exists (select 1 from pg_trigger
           where tgrelid = 'public.credit_ledger'::regclass
             and tgname = 'credit_ledger_no_truncate' and not tgisinternal),
  'credit_ledger: the T05 TRUNCATE guard still exists');

select ok(
  not has_table_privilege('service_role', 'public.credit_ledger', 'UPDATE'),
  'credit_ledger: service_role still has no UPDATE (the T05 revoke, ADR-0010 decision 3)');

select ok(
  not has_table_privilege('service_role', 'public.credit_ledger', 'DELETE'),
  'credit_ledger: service_role still has no DELETE');

select ok(
  has_table_privilege('service_role', 'public.credit_ledger', 'SELECT')
  and has_table_privilege('service_role', 'public.credit_ledger', 'INSERT'),
  'credit_ledger: and service_role still holds SELECT and INSERT, so the sanctioned write path is open');

select is(public._t6_sqlstate('service_role', null,
  $$update public.credit_ledger set delta = 99 where id = 'd6000000-0000-0000-0000-000000000001'$$),
  '42501', 'credit_ledger: service_role UPDATE fails with a PRIVILEGE error — the revoke layer');

select is(public._t6_sqlstate('service_role', null,
  $$delete from public.credit_ledger where id = 'd6000000-0000-0000-0000-000000000001'$$),
  '42501', 'credit_ledger: service_role DELETE fails with a PRIVILEGE error — the revoke layer');

-- Run as the owner, which genuinely holds UPDATE and DELETE, so the failure can
-- only be the trigger. Without this pair the suite would pass unchanged if the
-- trigger were dropped.
select ok(
  has_table_privilege('postgres', 'public.credit_ledger', 'UPDATE')
  and has_table_privilege('postgres', 'public.credit_ledger', 'DELETE'),
  'credit_ledger: the owner DOES hold UPDATE and DELETE — which is what makes the next two assertions about the trigger and not about privileges');

select is(public._t6_sqlstate('postgres', null,
  $$update public.credit_ledger set delta = 99 where id = 'd6000000-0000-0000-0000-000000000001'$$),
  '0A000', 'credit_ledger: a privileged UPDATE fails with a TRIGGER error — a different mechanism, distinguishable from 42501');

select is(public._t6_sqlstate('postgres', null,
  $$delete from public.credit_ledger where id = 'd6000000-0000-0000-0000-000000000001'$$),
  '0A000', 'credit_ledger: a privileged DELETE fails with a TRIGGER error');

select is(
  (select count(*)::int from public.credit_ledger
    where id = 'd6000000-0000-0000-0000-000000000001'),
  1, 'credit_ledger: the row survived every attempt above unchanged');


-- ===========================================================================
-- E. User-owned activity tables — own rows, insert as self, delete per T06
-- ===========================================================================

-- deal_unlocks: SELECT + INSERT, and deliberately no DELETE (AC10.7).
select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$select count(*)::int from public.deal_unlocks$$),
  1, 'deal_unlocks: a user sees only their own unlock');

select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000002',
  $$select count(*)::int from public.deal_unlocks
     where user_id = 'a6000000-0000-0000-0000-000000000001'$$),
  0, 'deal_unlocks: the other user''s unlock is invisible');

select is(public._t6_sqlstate('anon', null, 'select 1 from public.deal_unlocks limit 1'),
  '42501', 'deal_unlocks: anon is refused at the grant layer');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$insert into public.deal_unlocks (user_id, deal_id, credits_spent)
    values ('a6000000-0000-0000-0000-000000000001','86000000-0000-0000-0000-000000000002',1)$$),
  null, 'deal_unlocks: a user can insert a row owned by themselves — the policy is not inert');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$insert into public.deal_unlocks (user_id, deal_id, credits_spent)
    values ('a6000000-0000-0000-0000-000000000002','86000000-0000-0000-0000-000000000001',1)$$),
  '42501', 'deal_unlocks: inserting a row owned by ANOTHER user is rejected by WITH CHECK (SQLSTATE 42501, "new row violates row-level security policy")');

select ok(
  not has_table_privilege('authenticated', 'public.deal_unlocks', 'DELETE'),
  'deal_unlocks: no DELETE grant — unlocks are permanent (AC10.7), so a user cannot be charged twice');

select is(
  (select count(*)::int from pg_policies
    where schemaname='public' and tablename='deal_unlocks' and cmd='DELETE'),
  0, 'deal_unlocks: and no DELETE policy either — the grant and the policy are absent together, not one or the other');

select ok(
  not has_table_privilege('authenticated', 'public.deal_unlocks', 'UPDATE'),
  'deal_unlocks: no UPDATE grant — an unlock is a fact, not a process');

-- watchlist_items: the full SELECT/INSERT/DELETE shape.
select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$select count(*)::int from public.watchlist_items$$),
  1, 'watchlist_items: a user sees only their own item');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$insert into public.watchlist_items (user_id, deal_id, marketplace_product_id)
    values ('a6000000-0000-0000-0000-000000000001','86000000-0000-0000-0000-000000000002',
            '56000000-0000-0000-0000-000000000002')$$),
  null, 'watchlist_items: a user can add their own item');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$insert into public.watchlist_items (user_id, deal_id, marketplace_product_id)
    values ('a6000000-0000-0000-0000-000000000002','86000000-0000-0000-0000-000000000001',
            '56000000-0000-0000-0000-000000000001')$$),
  '42501', 'watchlist_items: a user cannot add an item owned by someone else');

select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$with d as (delete from public.watchlist_items
                where id = 'f6000000-0000-0000-0000-000000000002' returning 1)
    select count(*)::int from d$$),
  0, 'watchlist_items: deleting another user''s item removes zero rows — RLS filtered it, no error raised');

select is(
  (select count(*)::int from public.watchlist_items
    where id = 'f6000000-0000-0000-0000-000000000002'),
  1, 'watchlist_items: and that item is still there');

select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$with d as (delete from public.watchlist_items
                where id = 'f6000000-0000-0000-0000-000000000001' returning 1)
    select count(*)::int from d$$),
  1, 'watchlist_items: a user CAN delete their own item — the DELETE policy and grant are both live');

select ok(
  not has_table_privilege('authenticated', 'public.watchlist_items', 'UPDATE'),
  'watchlist_items: no UPDATE grant — T06 defines SELECT/INSERT/DELETE only');

-- purchase_records: the MVP validation instrument.
select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$select count(*)::int from public.purchase_records$$),
  1, 'purchase_records: a user sees only their own record');

select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000002',
  $$select count(*)::int from public.purchase_records
     where id = 'a6000000-0000-0000-0000-0000000000f1'$$),
  0, 'purchase_records: another user''s record is invisible');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$insert into public.purchase_records
      (user_id, deal_id, market_id, units, currency, expected_profit_minor, inputs_snapshot)
    values ('a6000000-0000-0000-0000-000000000001','86000000-0000-0000-0000-000000000002',
            '26000000-0000-0000-0000-000000000001', 1, 'GBP', 100, '{}'::jsonb)$$),
  null, 'purchase_records: a user can log their own purchase');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$insert into public.purchase_records
      (user_id, deal_id, market_id, units, currency, expected_profit_minor, inputs_snapshot)
    values ('a6000000-0000-0000-0000-000000000002','86000000-0000-0000-0000-000000000002',
            '26000000-0000-0000-0000-000000000001', 1, 'GBP', 100, '{}'::jsonb)$$),
  '42501', 'purchase_records: a user cannot log a purchase against another account');

select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$with d as (delete from public.purchase_records
                where id = 'a6000000-0000-0000-0000-0000000000f2' returning 1)
    select count(*)::int from d$$),
  0, 'purchase_records: deleting another user''s record removes zero rows');

select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$with d as (delete from public.purchase_records
                where id = 'a6000000-0000-0000-0000-0000000000f1' returning 1)
    select count(*)::int from d$$),
  1, 'purchase_records: a user can delete their own record');

select ok(
  not has_table_privilege('authenticated', 'public.purchase_records', 'UPDATE'),
  'purchase_records: no UPDATE grant — the outcome transition runs server-side until a task opens it deliberately');

-- barcode_lookups.
select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$select count(*)::int from public.barcode_lookups$$),
  1, 'barcode_lookups: a user sees only their own lookup');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$insert into public.barcode_lookups (user_id, market_id, barcode_raw, credits_spent)
    values ('a6000000-0000-0000-0000-000000000001','26000000-0000-0000-0000-000000000001','012345670003',1)$$),
  null, 'barcode_lookups: a user can record their own lookup');

select is(public._t6_sqlstate('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$insert into public.barcode_lookups (user_id, market_id, barcode_raw, credits_spent)
    values ('a6000000-0000-0000-0000-000000000002','26000000-0000-0000-0000-000000000001','012345670004',1)$$),
  '42501', 'barcode_lookups: a user cannot record a lookup against another account');

select is(public._t6_count('authenticated', 'a6000000-0000-0000-0000-000000000001',
  $$with d as (delete from public.barcode_lookups
                where id = 'a6000000-0000-0000-0000-0000000000b2' returning 1)
    select count(*)::int from d$$),
  0, 'barcode_lookups: deleting another user''s lookup removes zero rows');

select ok(
  not has_table_privilege('authenticated', 'public.barcode_lookups', 'UPDATE'),
  'barcode_lookups: no UPDATE grant — a lookup is a historical fact');

-- ---------------------------------------------------------------------------
-- E2. An anonymous caller reaches none of the user-owned tables
-- ---------------------------------------------------------------------------
--
-- All six refuse at the grant layer, because every user-owned policy is scoped
-- `TO authenticated` and anon holds no grant on any of them.

select is(public._t6_sqlstate('anon', null, 'select 1 from public.watchlist_items limit 1'),
  '42501', 'anon cannot read watchlist_items');
select is(public._t6_sqlstate('anon', null, 'select 1 from public.purchase_records limit 1'),
  '42501', 'anon cannot read purchase_records');
select is(public._t6_sqlstate('anon', null, 'select 1 from public.barcode_lookups limit 1'),
  '42501', 'anon cannot read barcode_lookups');
select is(public._t6_sqlstate('anon', null,
  $$insert into public.watchlist_items (user_id, deal_id, marketplace_product_id)
    values ('a6000000-0000-0000-0000-000000000001','86000000-0000-0000-0000-000000000001',
            '56000000-0000-0000-0000-000000000001')$$),
  '42501', 'anon cannot insert into watchlist_items');

-- And an authenticated role carrying no subject claim sees nothing anywhere.
-- This is the nullable-ownership question asked from the other direction: the
-- columns are NOT NULL, so the only way `user_id = auth.uid()` can be satisfied
-- loosely would be a NULL uid matching something. It cannot.
select is(public._t6_count('authenticated', null,
  $$select (select count(*) from public.deal_unlocks)
         + (select count(*) from public.watchlist_items)
         + (select count(*) from public.purchase_records)
         + (select count(*) from public.barcode_lookups)
         + (select count(*) from public.credit_ledger)$$),
  0, 'an authenticated role with no JWT subject sees zero rows across all five user-owned tables');


-- ===========================================================================
-- F. stripe_webhook_events — restricted UPDATE, not immutability
-- ===========================================================================
--
-- The rule is asymmetric on purpose (ADR-0010 decision 5): the outcome columns
-- must be writable for T35's fulfilment path, the identity columns must never
-- move. A blanket immutability trigger here would break webhook fulfilment,
-- which is why this is not the credit_ledger treatment.
--
-- Every rejection below is asserted as 0A000, and section D's service_role
-- assertions are asserted as 42501, so a trigger failure and a privilege
-- failure can never be mistaken for one another.

select ok(
  exists (select 1 from pg_trigger
           where tgrelid = 'public.stripe_webhook_events'::regclass
             and tgname = 'stripe_webhook_events_restricted_update'
             and not tgisinternal),
  'stripe_webhook_events: the restricted-update trigger exists');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public' and p.proname='enforce_webhook_event_restricted_update'
      and not p.prosecdef),
  1, 'the trigger function is SECURITY INVOKER — nothing here needs privileges the caller lacks');

select is(
  (select array_to_string(proconfig, ',') from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='enforce_webhook_event_restricted_update'),
  'search_path=pg_catalog, pg_temp',
  'and its search_path is pinned, matching the repo''s other trigger functions');

select ok(
  not has_function_privilege('anon', 'public.enforce_webhook_event_restricted_update()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.enforce_webhook_event_restricted_update()', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.enforce_webhook_event_restricted_update()', 'EXECUTE'),
  'and it is owner-only — no role holds EXECUTE, which does not affect the trigger firing');

-- The writable half.
select is(public._t6_sqlstate('service_role', null,
  $$update public.stripe_webhook_events set processed_at = now()
     where stripe_event_id = 'evt_t06_0001'$$),
  null, 'stripe_webhook_events: service_role CAN set processed_at — T35''s fulfilment path works');

select is(public._t6_sqlstate('service_role', null,
  $$update public.stripe_webhook_events set error = 'boom'
     where stripe_event_id = 'evt_t06_0001'$$),
  null, 'stripe_webhook_events: service_role CAN set error');

select is(public._t6_sqlstate('service_role', null,
  $$update public.stripe_webhook_events set processed_at = now(), error = 'retryable'
     where stripe_event_id = 'evt_t06_0002'$$),
  null, 'stripe_webhook_events: service_role CAN set both in one statement');

select is(
  (select error from public.stripe_webhook_events where stripe_event_id = 'evt_t06_0002'),
  'retryable', 'stripe_webhook_events: and the write actually landed');

-- Clearing an outcome column back to NULL is still an outcome write.
select is(public._t6_sqlstate('service_role', null,
  $$update public.stripe_webhook_events set error = null
     where stripe_event_id = 'evt_t06_0001'$$),
  null, 'stripe_webhook_events: clearing error back to NULL is permitted — it is an outcome, not an identity');

-- The frozen half. Four columns, four assertions, each 0A000.
select is(public._t6_sqlstate('service_role', null,
  $$update public.stripe_webhook_events set stripe_event_id = 'evt_rewritten'
     where stripe_event_id = 'evt_t06_0001'$$),
  '0A000', 'stripe_webhook_events: changing stripe_event_id is rejected by the TRIGGER (0A000), not by a privilege');

select is(public._t6_sqlstate('service_role', null,
  $$update public.stripe_webhook_events set type = 'invoice.paid'
     where stripe_event_id = 'evt_t06_0001'$$),
  '0A000', 'stripe_webhook_events: changing type is rejected by the trigger');

select is(public._t6_sqlstate('service_role', null,
  $$update public.stripe_webhook_events set payload = '{"tampered":true}'::jsonb
     where stripe_event_id = 'evt_t06_0001'$$),
  '0A000', 'stripe_webhook_events: changing payload is rejected by the trigger — the payload is the evidence');

select is(public._t6_sqlstate('service_role', null,
  $$update public.stripe_webhook_events set received_at = now() - interval '1 day'
     where stripe_event_id = 'evt_t06_0001'$$),
  '0A000', 'stripe_webhook_events: changing received_at is rejected by the trigger');

-- A mixed statement must fail as a whole rather than applying the legal half.
select is(public._t6_sqlstate('service_role', null,
  $$update public.stripe_webhook_events set processed_at = now(), payload = '{"tampered":true}'::jsonb
     where stripe_event_id = 'evt_t06_0001'$$),
  '0A000', 'stripe_webhook_events: a statement mixing a legal and an illegal column is rejected entirely');

select is(
  (select payload->>'v' from public.stripe_webhook_events where stripe_event_id = 'evt_t06_0001'),
  '1', 'stripe_webhook_events: and the payload is unchanged after every attempt above');

select is(
  (select type from public.stripe_webhook_events where stripe_event_id = 'evt_t06_0001'),
  'checkout.session.completed', 'stripe_webhook_events: as is type');

-- DELETE, at both layers, and the two mechanisms told apart.
select ok(
  not has_table_privilege('service_role', 'public.stripe_webhook_events', 'DELETE'),
  'stripe_webhook_events: service_role still holds no DELETE (the T05 revoke)');

select is(public._t6_sqlstate('service_role', null,
  $$delete from public.stripe_webhook_events where stripe_event_id = 'evt_t06_0001'$$),
  '42501', 'stripe_webhook_events: service_role DELETE fails with a PRIVILEGE error');

select ok(
  has_table_privilege('postgres', 'public.stripe_webhook_events', 'DELETE'),
  'stripe_webhook_events: the owner DOES hold DELETE — which makes the next assertion about the trigger');

select is(public._t6_sqlstate('postgres', null,
  $$delete from public.stripe_webhook_events where stripe_event_id = 'evt_t06_0001'$$),
  '0A000', 'stripe_webhook_events: a privileged DELETE fails with a TRIGGER error — deleting an event re-opens the replay window');

select is(
  (select count(*)::int from public.stripe_webhook_events
    where stripe_event_id in ('evt_t06_0001','evt_t06_0002')),
  2, 'stripe_webhook_events: both events survived');

select ok(
  has_table_privilege('service_role', 'public.stripe_webhook_events', 'SELECT')
  and has_table_privilege('service_role', 'public.stripe_webhook_events', 'INSERT')
  and has_table_privilege('service_role', 'public.stripe_webhook_events', 'UPDATE'),
  'stripe_webhook_events: service_role keeps exactly SELECT, INSERT and UPDATE — the T05 narrowing is unchanged by T06');


-- ===========================================================================
-- G. Grant/policy correspondence, in both directions, over the whole schema
-- ===========================================================================
--
-- ADR-004 decision 4 as an executable check rather than a review question.
-- These are the two assertions that would catch a future task adding one half
-- of the pair, which is the failure mode the whole posture exists to prevent.

select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and exists (select 1 from information_schema.column_privileges cp
                   where cp.table_schema='public' and cp.table_name = c.relname
                     and cp.grantee in ('anon','authenticated'))
      and not exists (select 1 from pg_policy p where p.polrelid = c.oid)),
  0, 'no public table holds an anon/authenticated grant without a policy — no ungoverned privilege exists');

select is(
  (select count(*)::int
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and exists (select 1 from pg_policy p where p.polrelid = c.oid)
      and not exists (select 1 from information_schema.column_privileges cp
                       where cp.table_schema='public' and cp.table_name = c.relname
                         and cp.grantee in ('anon','authenticated'))),
  0, 'and no public table carries a policy without a grant — no inert policy exists');

-- Per-command, not just per-table: a SELECT grant paired with an INSERT policy
-- would satisfy the two assertions above and still be wrong in both directions.
-- polcmd: r=SELECT a=INSERT w=UPDATE d=DELETE '*'=ALL.
--
-- SELECT, INSERT and UPDATE are checked with has_any_column_privilege because
-- profiles' UPDATE is granted per column and has_table_privilege reports false
-- for it. DELETE has no column form in PostgreSQL at all, so it is checked at
-- the table level — the two branches are a property of the privilege system,
-- not a loophole.
select is(
  (select count(*)::int
     from pg_policy p
     join pg_class c on c.oid = p.polrelid
     join pg_namespace n on n.oid = c.relnamespace
     cross join lateral unnest(p.polroles) as r(oid)
    where n.nspname = 'public'
      and pg_get_userbyid(r.oid) in ('anon','authenticated')
      and not case p.polcmd
                when 'd' then has_table_privilege(pg_get_userbyid(r.oid), c.oid, 'DELETE')
                else has_any_column_privilege(
                       pg_get_userbyid(r.oid), c.oid,
                       case p.polcmd when 'r' then 'SELECT'
                                     when 'a' then 'INSERT'
                                     when 'w' then 'UPDATE' end)
              end),
  0, 'every policy''s command is backed by a matching privilege for the role it names — no policy grants broader access than its paired object privilege');

select is(
  (select count(*)::int from pg_policy p
     join pg_class c on c.oid = p.polrelid
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and p.polcmd = '*'),
  0, 'no policy is written FOR ALL — every one names a single command, so its scope is reviewable');

select is(
  (select count(*)::int from pg_policy p
     join pg_class c on c.oid = p.polrelid
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and p.polroles = '{0}'),
  0, 'no policy targets PUBLIC — every one names anon, authenticated or both explicitly');

-- One policy per table per command. Permissive policies are ORed, so a second
-- policy on the same command silently widens the first.
select is(
  (select count(*)::int from (
     select polrelid, polcmd from pg_policy p
       join pg_class c on c.oid = p.polrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
      group by 1, 2 having count(*) > 1) s),
  0, 'no table has two policies for the same command — overlapping permissive policies would OR together and widen the narrower one');

select is(
  (select count(*)::int from pg_policies where schemaname='public'),
  19, 'exactly nineteen policies exist across the schema: 5 public-read, 2 profiles, 1 ledger, 2 deal_unlocks, 9 across the three read/create/delete tables');

-- The one deliberate `true` predicate, and nowhere else. `qual` is null for
-- INSERT policies (they carry with_check instead), which is why both columns
-- are inspected.
select is(
  (select string_agg(tablename, ',' order by tablename) from pg_policies
    where schemaname='public' and (qual = 'true' or with_check = 'true')),
  'currencies',
  'currencies is the ONLY table with an unqualified predicate anywhere in the schema');

select is(
  (select count(*)::int from pg_policies
    where schemaname='public' and cmd = 'INSERT' and with_check !~ 'auth\.uid'),
  0, 'every INSERT policy constrains ownership against auth.uid() — none accepts an arbitrary user_id');

select is(
  (select count(*)::int from pg_policies
    where schemaname='public' and cmd = 'DELETE' and qual !~ 'auth\.uid'),
  0, 'every DELETE policy is scoped to the caller''s own rows');

select is(
  (select count(*)::int from pg_policies
    where schemaname='public' and cmd = 'UPDATE'
      and (qual !~ 'auth\.uid' or with_check !~ 'auth\.uid')),
  0, 'every UPDATE policy constrains BOTH the rows it may touch (USING) and the rows it may produce (WITH CHECK)');

-- Ownership columns cannot be null, so no policy predicate can be satisfied by
-- a null owner. Asserted over the catalogue rather than per table so a future
-- user-owned table cannot be added with a nullable owner.
select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'public'
      and table_name in ('credit_ledger','deal_unlocks','watchlist_items',
                         'purchase_records','barcode_lookups')
      and column_name = 'user_id'
      and is_nullable = 'YES'),
  0, 'every user-owned table''s user_id is NOT NULL — no ownership predicate can be bypassed through a nullable column');

select is(
  (select is_nullable from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='id'),
  'NO', 'and profiles.id is NOT NULL for the same reason');

select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r' and not c.relrowsecurity),
  0, 'no public table has RLS disabled — restated after every grant in this file has been exercised');

select * from finish();

rollback;
