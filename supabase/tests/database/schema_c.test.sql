-- T05 — Schema C database tests (pgTAP), run by `npm run db:test`.
--
-- These assert the properties T05's acceptance criteria name, in the database
-- rather than through the application: the credit ledger's append-only
-- guarantee at BOTH of its layers, the retention foreign keys, the money and
-- idempotency constraints, the per-currency pack pricing split, the webhook
-- replay guard, the operational logs, the eight required indexes, and the
-- privilege posture including the two ADR-0010 narrowings.
--
-- The load-bearing test in this file is section E. T05 requires the two
-- immutability layers to be told apart:
--
--   * a PRIVILEGE failure (42501) proves `REVOKE UPDATE, DELETE … FROM
--     service_role` is in place;
--   * a TRIGGER failure (0A000) proves the append-only trigger fires.
--
-- A suite that only ever ran as `service_role` could not distinguish them and
-- would pass unchanged if the trigger were dropped. So the trigger is exercised
-- as the migration owner — a role that genuinely HOLDS UPDATE and DELETE, which
-- section E asserts before relying on it.
--
-- pgTAP is created inside this transaction and rolled back with it, so the test
-- extension never appears in a migration and never reaches the hosted project.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog, pg_temp;

select plan(158);

-- ---------------------------------------------------------------------------
-- Helpers: run a statement AS another role and report the mechanism
-- ---------------------------------------------------------------------------
--
-- pgTAP's own functions live in `extensions` and are called as the test's
-- session role, so switching role around a `throws_ok` would change who runs
-- the assertion as well as who runs the statement. These two helpers keep the
-- role switch inside one statement instead: the SQL under test runs as the
-- named role, the assertion always runs as the owner.
--
-- `_sqlstate_as` returns the SQLSTATE of the failure, or NULL when the
-- statement succeeded — which is what makes "denied by privilege" (42501) and
-- "denied by trigger" (0A000) separable assertions rather than one vague
-- "it failed". Both are created inside this transaction and rolled back with it.

create function public._sqlstate_as(p_role text, p_sql text)
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

create function public._scalar_as(p_role text, p_sql text)
returns text
language plpgsql
as $fn$
declare
  result text;
begin
  execute format('set local role %I', p_role);
  execute p_sql into result;
  execute 'reset role';
  return result;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
--
-- One market, because nothing in T05 is cross-market — the credit ledger is
-- currency-neutral by design (§9.1) and the logs are market-tagged rather than
-- market-constrained. Four users, each with a different financial footprint, so
-- the retention rules in section F are tested against the exact difference they
-- are supposed to make:
--
--   u1  a ledger row      → cannot be deleted (ON DELETE RESTRICT)
--   u2  a purchase row    → cannot be deleted (ON DELETE RESTRICT)
--   u3  nothing financial → CAN be deleted (the control: proves it is the FK
--                           doing the work and not something global)
--   u4  an app_event      → CAN be deleted, and the event is de-identified
--
-- GBP and USD come from supabase/seed/0001_currencies.sql.

insert into public.countries
  (code, name, default_currency, default_locale, tax_regime, retail_price_display, timezone_default, active)
values
  ('CC', 'Creditland', 'GBP', 'en-CC', 'vat', 'inclusive', 'UTC', true);

insert into public.marketplaces
  (id, provider, code, country_code, currency, domain, adapter_key, active)
values
  ('11000000-0000-0000-0000-00000000000c', 'testprovider', 'test_cc', 'CC', 'GBP',
   'example.test', 'testadapter', true);

insert into public.markets
  (id, slug, source_country_code, marketplace_id, currency, active, launch_status)
values
  ('21000000-0000-0000-0000-00000000000c', 'cc', 'CC',
   '11000000-0000-0000-0000-00000000000c', 'GBP', true, 'beta');

insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'schema-c-1@example.test'),
  ('a1000000-0000-0000-0000-000000000002', 'schema-c-2@example.test'),
  ('a1000000-0000-0000-0000-000000000003', 'schema-c-3@example.test'),
  ('a1000000-0000-0000-0000-000000000004', 'schema-c-4@example.test');

-- One pack, two currencies. This is the §9.1 split in fixture form: the pack
-- carries the credits, the prices carry the money.
insert into public.credit_packs (id, name, credits, active, sort_order) values
  ('b1000000-0000-0000-0000-000000000001', 'Starter', 100, true, 1);

-- stripe_price_id is NULL on both, which is exactly what T08 will seed
-- (ADR-0010 decision 4) and must therefore be a valid state today.
insert into public.credit_pack_prices
  (id, credit_pack_id, currency, amount_minor, stripe_price_id, active)
values
  ('c1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001',
   'GBP', 999, null, true),
  ('c1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001',
   'USD', 1299, null, true);

insert into public.credit_ledger
  (id, user_id, delta, reason, ref_type, ref_id, balance_after, idempotency_key)
values
  ('d1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001',
   5, 'signup_grant', null, null, 5, 'fixture:signup:u1');

insert into public.credit_purchases
  (id, user_id, credit_pack_id, credit_pack_price_id,
   stripe_checkout_session_id, stripe_payment_intent_id, stripe_customer_id,
   credits, amount_minor, currency, status)
values
  ('e1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000002',
   'b1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001',
   'cs_fixture_1', 'pi_fixture_1', 'cus_fixture_1',
   100, 999, 'GBP', 'paid');

insert into public.stripe_webhook_events (stripe_event_id, type, payload) values
  ('evt_fixture_1', 'checkout.session.completed', '{"id":"evt_fixture_1"}'::jsonb);

insert into public.app_events (user_id, market_id, event, properties) values
  ('a1000000-0000-0000-0000-000000000004', '21000000-0000-0000-0000-00000000000c',
   'pack_purchased', '{"pack":"starter"}'::jsonb);

-- ---------------------------------------------------------------------------
-- A. The eight tables exist, and nothing marketplace-specific arrived with them
-- ---------------------------------------------------------------------------

select has_table('public', 'credit_packs',          'credit_packs exists');
select has_table('public', 'credit_pack_prices',    'credit_pack_prices exists');
select has_table('public', 'credit_ledger',         'credit_ledger exists');
select has_table('public', 'credit_purchases',      'credit_purchases exists');
select has_table('public', 'stripe_webhook_events', 'stripe_webhook_events exists');
select has_table('public', 'api_usage_log',         'api_usage_log exists');
select has_table('public', 'ingestion_runs',        'ingestion_runs exists');
select has_table('public', 'app_events',            'app_events exists');

-- The core schema stays global-first and marketplace-agnostic (§0.3). No column
-- here names a country, a currency, a tax regime or a marketplace. `stripe_*`
-- columns are the deliberate exception and are matched out: Stripe is the
-- payment processor §10.5 names, and these columns store its object ids.
select is(
  (select count(*)::int
     from information_schema.columns
    where table_schema = 'public'
      and table_name in ('credit_packs', 'credit_pack_prices', 'credit_ledger',
                         'credit_purchases', 'stripe_webhook_events',
                         'api_usage_log', 'ingestion_runs', 'app_events')
      and column_name !~ '^stripe_'
      and (column_name ~* '(amazon|asin|keepa|fba|fbm|ebay|vat|gbp|usd|eur|uk_)')),
  0,
  'no Schema C column names a marketplace, a provider, a tax regime or a currency');

-- fx_rates is deferred to Phase 3 (ADR-005) and must not be created "for later".
select hasnt_table('public', 'fx_rates',
  'fx_rates does not exist — deferred to Phase 3 (ADR-005), not created speculatively');

-- ---------------------------------------------------------------------------
-- B. Full column sets
-- ---------------------------------------------------------------------------
--
-- columns_are is exact in both directions: a missing column fails, and so does
-- an unannounced extra one.

-- Exactly §2.3's nine. There is deliberately NO updated_at: an append-only
-- table cannot have a "when was this last changed" column, and the trigger
-- would raise on the update that maintained it.
select columns_are('public', 'credit_ledger', array[
  'id', 'user_id', 'delta', 'reason', 'ref_type', 'ref_id',
  'balance_after', 'idempotency_key', 'created_at'
], 'credit_ledger has exactly §2.3''s nine columns, and no updated_at');

select columns_are('public', 'credit_purchases', array[
  'id', 'user_id', 'credit_pack_id', 'credit_pack_price_id',
  'stripe_checkout_session_id', 'stripe_payment_intent_id', 'stripe_customer_id',
  'credits', 'amount_minor', 'currency', 'status',
  'created_at', 'completed_at', 'updated_at'
], 'credit_purchases has the full §2.3 column set');

select columns_are('public', 'credit_packs', array[
  'id', 'name', 'credits', 'active', 'sort_order', 'created_at', 'updated_at'
], 'credit_packs carries the pack value, not its price');

select columns_are('public', 'credit_pack_prices', array[
  'id', 'credit_pack_id', 'currency', 'amount_minor', 'stripe_price_id',
  'active', 'created_at', 'updated_at'
], 'credit_pack_prices carries the per-currency price');

-- Exactly §2.3's six. No created_at (received_at is the arrival time) and no
-- updated_at, which would become a fourth column T06's restricted-UPDATE
-- trigger had to carve an exception for.
select columns_are('public', 'stripe_webhook_events', array[
  'stripe_event_id', 'type', 'payload', 'received_at', 'processed_at', 'error'
], 'stripe_webhook_events has exactly §2.3''s six columns');

select columns_are('public', 'api_usage_log', array[
  'id', 'provider', 'marketplace_id', 'endpoint', 'units_used',
  'cost_minor_est', 'currency', 'status', 'latency_ms', 'created_at'
], 'api_usage_log records provider, marketplace, units, cost, status and latency');

select columns_are('public', 'ingestion_runs', array[
  'id', 'market_id', 'source', 'started_at', 'finished_at', 'status',
  'rows_in', 'rows_upserted', 'rows_failed', 'error'
], 'ingestion_runs includes market_id and the AC3.4 counters');

select columns_are('public', 'app_events', array[
  'id', 'user_id', 'market_id', 'event', 'properties', 'created_at'
], 'app_events includes market_id');

-- ---------------------------------------------------------------------------
-- C. Enum discipline (inventory before creating, no near-duplicates)
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typtype = 'e'),
  14,
  'fourteen enum types exist: T03''s nine, T04''s three and exactly two new ones');

-- The headline of ADR-0010: refund and chargeback are BOTH present and are not
-- interchangeable. One value would make a payment dispute count as product
-- goodwill in the §9.4 trust metric.
select is(
  (select string_agg(e.enumlabel, '|' order by e.enumsortorder)
     from pg_type t join pg_enum e on e.enumtypid = t.oid
     join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'credit_reason'),
  'signup_grant|purchase|unlock_deal|barcode_lookup|refund|chargeback|admin_adjust|promo',
  'credit_reason carries all eight §2.3 reasons, with refund and chargeback distinct');

select is(
  (select string_agg(e.enumlabel, '|' order by e.enumsortorder)
     from pg_type t join pg_enum e on e.enumtypid = t.oid
     join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public' and t.typname = 'credit_purchase_status'),
  'pending|paid|failed|refunded',
  'credit_purchase_status is exactly §2.3''s four values, in lifecycle order');

-- The general form of the rule, re-asserted with the two new types present.
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
  'no two enum types share an identical label set — Schema C added no near-duplicate');

select is(
  (select udt_name from information_schema.columns
    where table_schema = 'public' and table_name = 'credit_ledger' and column_name = 'reason'),
  'credit_reason',
  'credit_ledger.reason uses the credit_reason enum');

select is(
  (select udt_name from information_schema.columns
    where table_schema = 'public' and table_name = 'credit_purchases' and column_name = 'status'),
  'credit_purchase_status',
  'credit_purchases.status uses the credit_purchase_status enum');

-- Three columns that are deliberately text (ADR-0005 decision 3): no document
-- closes these domains, and an enum would mean a migration every time a
-- provider surfaces a new failure mode.
select col_type_is('public', 'api_usage_log', 'status', 'text',
  'api_usage_log.status is text, not an enum — the domain is not closed by any document');
select col_type_is('public', 'ingestion_runs', 'status', 'text',
  'ingestion_runs.status is text, not an enum — owned by T19');
select col_type_is('public', 'credit_ledger', 'ref_type', 'text',
  'credit_ledger.ref_type is text — the set of referable things grows with every feature');

-- ---------------------------------------------------------------------------
-- D. credit_ledger constraints
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a1000000-0000-0000-0000-000000000001', 0, 'admin_adjust', 5, 'zero-delta')$$,
  '23514', null,
  'delta = 0 is rejected — a zero-delta row is a bug or a no-op that consumes an idempotency key');

select throws_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a1000000-0000-0000-0000-000000000001', 1, 'promo', 6, null)$$,
  '23502', null,
  'a NULL idempotency_key is rejected — nullable would defeat the guard entirely, since NULLs do not conflict');

select throws_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a1000000-0000-0000-0000-000000000001', 1, 'promo', 6, 'fixture:signup:u1')$$,
  '23505', null,
  'a duplicate idempotency_key is rejected — the guard T07 and T35 both rest on');

select throws_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a1000000-0000-0000-0000-000000000001', 1, 'promo', null, 'null-balance')$$,
  '23502', null,
  'balance_after is NOT NULL');

-- No non-negative check, on purpose (AC17.5).
select lives_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a1000000-0000-0000-0000-000000000001', -8, 'chargeback', -3, 'negative-balance')$$,
  'balance_after may be negative — a chargeback takes the balance below zero rather than erasing history');

select is(
  (select balance_after from public.credit_ledger where idempotency_key = 'negative-balance'),
  -3,
  'and the negative balance is stored as written, not clamped');

-- ADR-0010 decision 1 at the storage layer: the two reversal reasons move in
-- opposite directions and a reversed sign cannot be written.
select throws_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a1000000-0000-0000-0000-000000000001', -1, 'refund', 4, 'bad-refund-sign')$$,
  '23514', null,
  'a NEGATIVE refund is rejected — refund restores a credit after our own error (AC15.4)');

select throws_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a1000000-0000-0000-0000-000000000001', 1, 'chargeback', 6, 'bad-chargeback-sign')$$,
  '23514', null,
  'a POSITIVE chargeback is rejected — chargeback claws credits back after Stripe reversed a payment (AC17.5)');

select lives_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a1000000-0000-0000-0000-000000000001', 1, 'refund', 6, 'good-refund')$$,
  'a POSITIVE refund is accepted');

select lives_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a1000000-0000-0000-0000-000000000001', -1, 'chargeback', 5, 'good-chargeback')$$,
  'a NEGATIVE chargeback is accepted');

-- admin_adjust is signed by definition, which is exactly why the sign alone
-- cannot tell a refund from a chargeback after the fact (ADR-0010).
select lives_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a1000000-0000-0000-0000-000000000001', -2, 'admin_adjust', 3, 'negative-admin-adjust')$$,
  'admin_adjust may be negative — which is why the sign is not a substitute for the reason');

select throws_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values (null, 1, 'promo', 1, 'null-user')$$,
  '23502', null,
  'user_id is NOT NULL — a ledger row always belongs to someone');

select throws_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a1000000-0000-0000-0000-00000000ffff', 1, 'promo', 1, 'unknown-user')$$,
  '23503', null,
  'user_id is FK-validated against profiles');

-- The §11.4 reconciliation invariant is `sum(credit_ledger.delta) ==
-- profiles.credit_balance`. That comparison is only meaningful if the two
-- columns are the same type — a bigint ledger against an integer cached balance
-- would silently disagree at the edges.
select col_type_is('public', 'credit_ledger', 'delta', 'integer',
  'delta is integer, matching profiles.credit_balance');
select col_type_is('public', 'credit_ledger', 'balance_after', 'integer',
  'balance_after is integer, matching profiles.credit_balance');
select col_type_is('public', 'profiles', 'credit_balance', 'integer',
  'and profiles.credit_balance is unchanged, so the reconciliation compares like with like');

-- Credits are currency-neutral (§9.1): the ledger holds no money and no
-- currency, and adding one would be the first step towards per-country pricing
-- of every feature.
select hasnt_column('public', 'credit_ledger', 'currency',
  'credit_ledger has no currency column — credits are the unit of value, currency only the unit of payment (§9.1)');

-- ---------------------------------------------------------------------------
-- E. Append-only, enforced at two INDEPENDENT layers (ADR-0010 decision 3)
-- ---------------------------------------------------------------------------
--
-- The mechanism, not just the outcome. Read this section as two columns:
--
--            role holds privilege?   what stops the write?   SQLSTATE
--   owner            yes                   the trigger         0A000
--   service_role     no                    the revoke          42501

-- Layer (a): the trigger, exercised as a role that GENUINELY HOLDS the
-- privilege. Without this assertion the three that follow would prove nothing —
-- a privilege error and a trigger error are both "it failed".
select ok(
  has_table_privilege('postgres', 'public.credit_ledger', 'UPDATE'),
  'the migration owner DOES hold UPDATE on credit_ledger — so the next assertion tests the trigger, not a missing grant');

select ok(
  has_table_privilege('postgres', 'public.credit_ledger', 'DELETE'),
  'and DELETE');

select throws_ok(
  $$update public.credit_ledger set balance_after = 999 where idempotency_key = 'fixture:signup:u1'$$,
  '0A000', null,
  'the append-only trigger rejects UPDATE for a role that holds the privilege');

select throws_ok(
  $$delete from public.credit_ledger where idempotency_key = 'fixture:signup:u1'$$,
  '0A000', null,
  'the append-only trigger rejects DELETE for a role that holds the privilege');

-- TRUNCATE is neither UPDATE nor DELETE, and a row-level trigger never sees it.
select throws_ok(
  $$truncate public.credit_ledger$$,
  '0A000', null,
  'and TRUNCATE, which a row-level trigger would not have caught');

-- T07's implementation constraint, proved rather than asserted in prose: an
-- upsert's DO UPDATE branch is an UPDATE, so the idempotency check must be
-- ON CONFLICT DO NOTHING plus a read (ADR-0010 consequence for T07).
select throws_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a1000000-0000-0000-0000-000000000001', 1, 'promo', 6, 'fixture:signup:u1')
    on conflict (idempotency_key) do update set delta = excluded.delta$$,
  '0A000', null,
  'ON CONFLICT DO UPDATE is rejected too — T07''s idempotency check must be DO NOTHING plus a read');

-- Layer (b): the revoke. Asserted as a PRIVILEGE failure, so it cannot pass by
-- accident of the trigger.
select ok(
  not has_table_privilege('service_role', 'public.credit_ledger', 'UPDATE'),
  'service_role does not hold UPDATE on credit_ledger');

select ok(
  not has_table_privilege('service_role', 'public.credit_ledger', 'DELETE'),
  'service_role does not hold DELETE on credit_ledger');

select is(
  public._sqlstate_as('service_role',
    $$update public.credit_ledger set balance_after = 999 where idempotency_key = 'fixture:signup:u1'$$),
  '42501',
  'service_role UPDATE on credit_ledger fails with a PRIVILEGE error (42501), not a trigger error');

select is(
  public._sqlstate_as('service_role',
    $$delete from public.credit_ledger where idempotency_key = 'fixture:signup:u1'$$),
  '42501',
  'service_role DELETE on credit_ledger fails with a PRIVILEGE error (42501), not a trigger error');

select is(
  public._sqlstate_as('service_role', $$truncate public.credit_ledger$$),
  '42501',
  'and service_role cannot TRUNCATE it either — no TRUNCATE was ever granted');

-- The privileges the ledger's write path actually needs are intact: narrowing
-- must not have broken the sanctioned path.
select ok(
  has_table_privilege('service_role', 'public.credit_ledger', 'SELECT'),
  'service_role retains SELECT — reading a balance is part of the design');

select ok(
  has_table_privilege('service_role', 'public.credit_ledger', 'INSERT'),
  'service_role retains INSERT — appending a row is the only write the design performs');

select ok(
  public._sqlstate_as('service_role',
    $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
      values ('a1000000-0000-0000-0000-000000000001', 3, 'purchase', 6, 'service-role-append')$$) is null,
  'and service_role can genuinely append — the narrowing removed only what the design never uses');

-- Nothing above destroyed anything: every rejected mutation left the ledger as
-- it was.
select is(
  (select count(*)::int from public.credit_ledger where idempotency_key = 'fixture:signup:u1'),
  1,
  'the row every rejected UPDATE, DELETE and TRUNCATE targeted is still there, unchanged');

select is(
  (select balance_after from public.credit_ledger where idempotency_key = 'fixture:signup:u1'),
  5,
  'with its original balance_after');

-- Both triggers exist, and the function behind them is owner-only.
select is(
  (select count(*)::int from pg_trigger
    where tgrelid = 'public.credit_ledger'::regclass and not tgisinternal),
  2,
  'credit_ledger carries exactly two triggers: the row-level append-only guard and the TRUNCATE guard');

select is(
  (select array_to_string(proacl, ',')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'enforce_credit_ledger_append_only'),
  'postgres=X/postgres',
  'the append-only trigger function is executable by its owner and nobody else (ADR-0007)');

select ok(
  not (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'enforce_credit_ledger_append_only'),
  'and it is not SECURITY DEFINER — it needs no privilege its caller lacks');

-- Owner-only must not break the trigger for the role that actually writes the
-- ledger. EXECUTE is checked when a trigger is created, not when it fires.
select ok(
  not has_function_privilege('service_role', 'public.enforce_credit_ledger_append_only()', 'EXECUTE'),
  'service_role holds no EXECUTE on the trigger function');

select is(
  public._sqlstate_as('service_role',
    $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
      values ('a1000000-0000-0000-0000-000000000001', 0, 'promo', 6, 'service-role-zero-delta')$$),
  '23514',
  'and the table''s constraints still fire for it — the zero-delta check rejects a service_role insert');

-- ---------------------------------------------------------------------------
-- F. Financial records survive account deletion (ADR-0010 decision 2, AC1.6)
-- ---------------------------------------------------------------------------
--
-- The cascade chain traced end to end, which is the part a one-hop reading
-- misses: profiles cascades FROM auth.users, so a RESTRICT two levels down
-- blocks the auth-user delete as well.

select throws_ok(
  $$delete from public.profiles where id = 'a1000000-0000-0000-0000-000000000001'$$,
  '23503', null,
  'deleting a profile with ledger rows is rejected by ON DELETE RESTRICT');

select throws_ok(
  $$delete from auth.users where id = 'a1000000-0000-0000-0000-000000000001'$$,
  '23503', null,
  'and deleting the auth user is rejected too — the cascade to profiles hits the same RESTRICT');

select throws_ok(
  $$delete from public.profiles where id = 'a1000000-0000-0000-0000-000000000002'$$,
  '23503', null,
  'deleting a profile with purchase rows is rejected — purchase history is reconciliation evidence');

select throws_ok(
  $$delete from auth.users where id = 'a1000000-0000-0000-0000-000000000002'$$,
  '23503', null,
  'and via auth.users likewise');

select is(
  (select count(*)::int from public.credit_ledger
    where user_id = 'a1000000-0000-0000-0000-000000000001'),
  6,
  'every ledger row survived the attempted deletions');

select is(
  (select count(*)::int from public.credit_purchases
    where user_id = 'a1000000-0000-0000-0000-000000000002'),
  1,
  'and the purchase row did too');

-- The control. Without it, the four assertions above could pass because
-- something unrelated blocks every delete.
select lives_ok(
  $$delete from auth.users where id = 'a1000000-0000-0000-0000-000000000003'$$,
  'a user with no financial rows CAN still be deleted — it is the FK doing the work, not a global block');

select is(
  (select count(*)::int from public.profiles where id = 'a1000000-0000-0000-0000-000000000003'),
  0,
  'and their profile cascaded away as AC1.5 requires');

-- ---------------------------------------------------------------------------
-- G. credit_purchases
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.credit_purchases
      (user_id, credit_pack_id, credits, amount_minor, currency, stripe_payment_intent_id)
    values ('a1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001',
            100, 999, 'GBP', 'pi_fixture_1')$$,
  '23505', null,
  'a duplicate stripe_payment_intent_id is rejected — one payment, one purchase');

select throws_ok(
  $$insert into public.credit_purchases
      (user_id, credit_pack_id, credits, amount_minor, currency, stripe_checkout_session_id)
    values ('a1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001',
            100, 999, 'GBP', 'cs_fixture_1')$$,
  '23505', null,
  'a duplicate stripe_checkout_session_id is rejected');

-- Nullable on purpose: §9.2 inserts the purchase row BEFORE the Checkout
-- Session and the PaymentIntent exist. Several NULLs must coexist.
select lives_ok(
  $$insert into public.credit_purchases
      (id, user_id, credit_pack_id, credits, amount_minor, currency)
    values ('e1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000002',
            'b1000000-0000-0000-0000-000000000001', 100, 999, 'GBP')$$,
  'a purchase with no Stripe ids yet is valid — §9.2 creates the row before the Checkout Session');

select lives_ok(
  $$insert into public.credit_purchases
      (id, user_id, credit_pack_id, credits, amount_minor, currency)
    values ('e1000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000002',
            'b1000000-0000-0000-0000-000000000001', 100, 999, 'GBP')$$,
  'and a second one — several NULL Stripe ids coexist under the unique constraints');

select is(
  (select status::text from public.credit_purchases where id = 'e1000000-0000-0000-0000-000000000002'),
  'pending',
  'a new purchase defaults to pending');

select throws_ok(
  $$insert into public.credit_purchases (user_id, credit_pack_id, credits, amount_minor, currency)
    values ('a1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001', 100, 0, 'GBP')$$,
  '23514', null,
  'amount_minor = 0 is rejected');

select throws_ok(
  $$insert into public.credit_purchases (user_id, credit_pack_id, credits, amount_minor, currency)
    values ('a1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001', 100, -1, 'GBP')$$,
  '23514', null,
  'a negative amount_minor is rejected');

select throws_ok(
  $$insert into public.credit_purchases (user_id, credit_pack_id, credits, amount_minor, currency)
    values ('a1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001', 0, 999, 'GBP')$$,
  '23514', null,
  'a purchase of zero credits is rejected');

select throws_ok(
  $$insert into public.credit_purchases (user_id, credit_pack_id, credits, amount_minor, currency)
    values ('a1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001', 100, 999, 'ZZZ')$$,
  '23503', null,
  'an amount in an unknown currency is rejected — currency is a real reference (§11.2)');

select throws_ok(
  $$insert into public.credit_purchases (user_id, credit_pack_id, credits, amount_minor, currency)
    values ('a1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001', 100, 999, null)$$,
  '23502', null,
  'a currency-free amount is impossible at the storage layer, not merely discouraged');

-- The composite FK: a purchase cannot record a currency its price row does not
-- carry. Price c1…0001 is the GBP row.
select throws_ok(
  $$insert into public.credit_purchases
      (user_id, credit_pack_id, credit_pack_price_id, credits, amount_minor, currency)
    values ('a1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001',
            'c1000000-0000-0000-0000-000000000001', 100, 1299, 'USD')$$,
  '23503', null,
  'a USD purchase against a GBP price row is rejected — a per-currency reconciliation cannot be fooled by it');

select lives_ok(
  $$insert into public.credit_purchases
      (user_id, credit_pack_id, credit_pack_price_id, credits, amount_minor, currency)
    values ('a1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001',
            null, 100, 999, 'GBP')$$,
  'and a purchase with NO price row is valid — a retired price or an admin grant has none');

-- The snapshot rule is enforced by documentation at this layer (RUNBOOK
-- financial checklist §4: "immutable in intent and documented as such"), so the
-- documentation is the thing to assert.
select is(
  (select count(*)::int
     from information_schema.columns c
     join pg_class rel on rel.relname = c.table_name
     join pg_namespace n on n.oid = rel.relnamespace and n.nspname = c.table_schema
    where c.table_schema = 'public' and c.table_name = 'credit_purchases'
      and c.column_name in ('credits', 'amount_minor', 'currency')
      and col_description(rel.oid, c.ordinal_position::int) ~ 'Immutable snapshot'),
  3,
  'credits, amount_minor and currency are each documented as immutable purchase snapshots');

-- ---------------------------------------------------------------------------
-- H. credit_packs and credit_pack_prices
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.credit_packs (name, credits) values ('Free', 0)$$,
  '23514', null,
  'a pack of zero credits is rejected — a free pack is not a product');

select throws_ok(
  $$insert into public.credit_packs (name, credits) values ('Negative', -1)$$,
  '23514', null,
  'and a negative one');

select throws_ok(
  $$insert into public.credit_pack_prices (credit_pack_id, currency, amount_minor)
    values ('b1000000-0000-0000-0000-000000000001', 'JPY', 0)$$,
  '23514', null,
  'a price of zero is rejected');

select throws_ok(
  $$insert into public.credit_pack_prices (credit_pack_id, currency, amount_minor)
    values ('b1000000-0000-0000-0000-000000000001', 'JPY', -1)$$,
  '23514', null,
  'and a negative price');

select throws_ok(
  $$insert into public.credit_pack_prices (credit_pack_id, currency, amount_minor)
    values ('b1000000-0000-0000-0000-000000000001', 'ZZZ', 500)$$,
  '23503', null,
  'a price in an unknown currency is rejected — credit_pack_prices.currency is an FK to currencies');

select throws_ok(
  $$insert into public.credit_pack_prices (credit_pack_id, currency, amount_minor)
    values ('b1000000-0000-0000-0000-000000000001', null, 500)$$,
  '23502', null,
  'and a price with no currency at all');

select throws_ok(
  $$insert into public.credit_pack_prices (credit_pack_id, currency, amount_minor)
    values ('b1000000-0000-0000-0000-000000000001', 'GBP', 1999)$$,
  '23505', null,
  'one price per pack per currency');

-- ADR-0010 decision 4: T08 seeds NULL, weeks before T34 creates any Stripe
-- object. That state must be valid, readable, and must not collide.
select is(
  (select count(*)::int from public.credit_pack_prices
    where credit_pack_id = 'b1000000-0000-0000-0000-000000000001' and stripe_price_id is null),
  2,
  'a credit_pack_prices row with stripe_price_id NULL is valid — and two of them coexist, as T08 will seed');

-- Scoped to this file's own fixture pack, exactly as the assertion above is.
-- It was an unscoped whole-table count while the table was empty; T08's seed
-- added six more NULL-priced rows, which is the behaviour that assertion
-- predicted rather than a regression. The claim is that service_role can read
-- NULL-priced rows, not that only two exist in the database.
select is(
  public._scalar_as('service_role',
    $$select count(*) from public.credit_pack_prices
       where credit_pack_id = 'b1000000-0000-0000-0000-000000000001'
         and stripe_price_id is null$$),
  '2',
  'and service_role can read those rows');

-- The one pack carries both currencies. This is the §9.1 split working: selling
-- into a second country is a row, not a refactor.
select is(
  (select count(*)::int from public.credit_packs
    where id = 'b1000000-0000-0000-0000-000000000001'),
  1,
  'one pack…');

select is(
  (select string_agg(currency, ',' order by currency) from public.credit_pack_prices
    where credit_pack_id = 'b1000000-0000-0000-0000-000000000001'),
  'GBP,USD',
  '…priced in GBP and USD, without duplicating the pack itself');

-- Two price rows must not point at the same Stripe Price: one Stripe object
-- selling two credit quantities is a reconciliation defect.
update public.credit_pack_prices set stripe_price_id = 'price_test_a'
 where id = 'c1000000-0000-0000-0000-000000000001';

select throws_ok(
  $$update public.credit_pack_prices set stripe_price_id = 'price_test_a'
     where id = 'c1000000-0000-0000-0000-000000000002'$$,
  '23505', null,
  'two price rows cannot share one Stripe Price id');

-- Restore the fixture state for the privilege assertions below.
update public.credit_pack_prices set stripe_price_id = null
 where id = 'c1000000-0000-0000-0000-000000000001';

select throws_ok(
  $$delete from public.credit_packs where id = 'b1000000-0000-0000-0000-000000000001'$$,
  '23503', null,
  'a pack with prices cannot be deleted out from under them');

-- ---------------------------------------------------------------------------
-- I. stripe_webhook_events — the replay guard, restricted but NOT immutable
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.stripe_webhook_events (stripe_event_id, type, payload)
    values ('evt_fixture_1', 'checkout.session.completed', '{}'::jsonb)$$,
  '23505', null,
  'a duplicate stripe_event_id is rejected — the first of §9.2''s two idempotency layers (AC17.3)');

select throws_ok(
  $$insert into public.stripe_webhook_events (stripe_event_id, type, payload)
    values ('evt_not_object', 'charge.refunded', '"a string"'::jsonb)$$,
  '23514', null,
  'the payload must be a JSON object, not a scalar');

select ok(
  (select received_at is not null and processed_at is null
     from public.stripe_webhook_events where stripe_event_id = 'evt_fixture_1'),
  'a new event has received_at stamped and processed_at NULL — received, not yet fulfilled');

-- The property T05 must NOT break: T35 writes the outcome after the fact.
select ok(
  public._sqlstate_as('service_role',
    $$update public.stripe_webhook_events
         set processed_at = now(), error = null
       where stripe_event_id = 'evt_fixture_1'$$) is null,
  'service_role CAN write processed_at — this table records a process and is deliberately not immutable');

select ok(
  (select processed_at is not null from public.stripe_webhook_events
    where stripe_event_id = 'evt_fixture_1'),
  'and the outcome actually landed');

-- T05 adds no trigger here. T06 owns the restricted-UPDATE trigger, and two
-- triggers with one purpose means either can be dropped with no test going red.
-- Updated by T06, which added exactly the one trigger this comment predicted.
-- Asserting ONE and naming it is the assertion that keeps the "two triggers
-- with one purpose" trap closed: a second guard here would let either be
-- dropped with no test going red.
-- Updated by T09, which added the TRUNCATE guard T06 deferred to it (ADR-0016).
-- The count moved from one to two and the assertion was made MORE specific
-- rather than looser: it now names both triggers and, below, their levels. The
-- trap this guards against is two triggers with ONE purpose, either of which
-- could be dropped with nothing going red. These two have different purposes —
-- a row trigger cannot see TRUNCATE and a statement trigger cannot compare OLD
-- with NEW — so neither is redundant, and asserting the level of each is what
-- keeps that true.
select is(
  (select count(*)::int from pg_trigger
    where tgrelid = 'public.stripe_webhook_events'::regclass and not tgisinternal),
  2,
  'stripe_webhook_events carries exactly two triggers — T06''s restricted UPDATE and T09''s TRUNCATE guard');

select is(
  (select string_agg(tgname::text, ',' order by tgname) from pg_trigger
    where tgrelid = 'public.stripe_webhook_events'::regclass and not tgisinternal),
  'stripe_webhook_events_no_truncate,stripe_webhook_events_restricted_update',
  'and they are exactly those two by name — no blanket immutability guard, which would break T35''s fulfilment path');

-- Levels asserted explicitly: swapping either would silently disable it.
select is(
  (select (tgtype::int & 1) from pg_trigger
    where tgrelid = 'public.stripe_webhook_events'::regclass
      and tgname = 'stripe_webhook_events_restricted_update'),
  1,
  'the restricted-UPDATE guard is a ROW trigger — it must see OLD and NEW');

select is(
  (select (tgtype::int & 1) from pg_trigger
    where tgrelid = 'public.stripe_webhook_events'::regclass
      and tgname = 'stripe_webhook_events_no_truncate'),
  0,
  'the TRUNCATE guard is a STATEMENT trigger — a row trigger never fires for TRUNCATE');

select ok(
  not has_table_privilege('service_role', 'public.stripe_webhook_events', 'DELETE'),
  'service_role does not hold DELETE — the row IS the replay guard');

select is(
  public._sqlstate_as('service_role',
    $$delete from public.stripe_webhook_events where stripe_event_id = 'evt_fixture_1'$$),
  '42501',
  'and a service_role DELETE fails with a PRIVILEGE error');

select ok(
  has_table_privilege('service_role', 'public.stripe_webhook_events', 'UPDATE'),
  'UPDATE is retained on purpose — T35 needs it, and T06 will restrict which columns it may touch');

-- ---------------------------------------------------------------------------
-- J. Operational logs
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.api_usage_log (provider, endpoint, status, cost_minor_est)
    values ('testprovider', '/product', 'ok', 250)$$,
  '23514', null,
  'an estimated cost with no currency is rejected (§11.2)');

select throws_ok(
  $$insert into public.api_usage_log (provider, endpoint, status, currency)
    values ('testprovider', '/product', 'ok', 'GBP')$$,
  '23514', null,
  'and a currency with no amount — the pairing runs both ways');

select lives_ok(
  $$insert into public.api_usage_log (provider, endpoint, status, cost_minor_est, currency)
    values ('testprovider', '/product', 'ok', 250, 'GBP')$$,
  'a cost with its currency is accepted');

select lives_ok(
  $$insert into public.api_usage_log (provider, marketplace_id, endpoint, units_used, status, latency_ms)
    values ('testprovider', '11000000-0000-0000-0000-00000000000c', '/product', 12, 'ok', 340)$$,
  'a marketplace-scoped call with token usage and latency is accepted');

select lives_ok(
  $$insert into public.api_usage_log (provider, endpoint, status)
    values ('testprovider', '/feed', 'rate_limited')$$,
  'and a call with no marketplace at all — not every provider call is marketplace-scoped');

select throws_ok(
  $$insert into public.api_usage_log (provider, endpoint, status, units_used)
    values ('testprovider', '/product', 'ok', -1)$$,
  '23514', null,
  'negative unit usage is rejected');

select throws_ok(
  $$insert into public.ingestion_runs (source, status) values ('curated_csv', 'running')$$,
  '23502', null,
  'an ingestion run without a market is rejected — every run happens in exactly one market');

select lives_ok(
  $$insert into public.ingestion_runs (market_id, source, status, rows_in, rows_upserted, rows_failed)
    values ('21000000-0000-0000-0000-00000000000c', 'curated_csv', 'success', 100, 98, 2)$$,
  'a run records rows in, upserted and failed (AC3.4)');

select throws_ok(
  $$insert into public.ingestion_runs (market_id, source, status, started_at, finished_at)
    values ('21000000-0000-0000-0000-00000000000c', 'curated_csv', 'success',
            now(), now() - interval '1 hour')$$,
  '23514', null,
  'a run cannot finish before it started');

select throws_ok(
  $$insert into public.ingestion_runs (market_id, source, status, rows_failed)
    values ('21000000-0000-0000-0000-00000000000c', 'curated_csv', 'success', -1)$$,
  '23514', null,
  'and cannot report a negative row count');

select throws_ok(
  $$insert into public.app_events (event, properties) values ('signup', '[]'::jsonb)$$,
  '23514', null,
  'app_events.properties must be a JSON object, not an array');

select lives_ok(
  $$insert into public.app_events (event) values ('signup')$$,
  'an event with no user and no market is valid — signup happens before either exists');

select is(
  (select properties::text from public.app_events where event = 'signup'),
  '{}',
  'and properties defaults to an empty object rather than NULL');

-- The rule has to be written where the next author will see it, because nothing
-- validates the contents of this column.
select ok(
  (select col_description('public.app_events'::regclass, c.ordinal_position::int) ~ 'NO PII'
     from information_schema.columns c
    where c.table_schema = 'public' and c.table_name = 'app_events'
      and c.column_name = 'properties'),
  'app_events.properties carries a column comment documenting the no-PII rule (§11.5)');

-- An analytics row must not block account deletion, and must not identify a
-- deleted user afterwards.
select lives_ok(
  $$delete from auth.users where id = 'a1000000-0000-0000-0000-000000000004'$$,
  'a user whose only footprint is an app_event can be deleted');

select is(
  (select count(*)::int from public.app_events
    where event = 'pack_purchased' and user_id is null),
  1,
  'and their event survives de-identified — the funnel keeps the count, not the person');

-- ---------------------------------------------------------------------------
-- K. The eight required indexes exist, exactly as T05 enumerates them
-- ---------------------------------------------------------------------------
--
-- Asserted against indexdef rather than by name, so a renamed-but-equivalent
-- index passes and a same-named but differently-ordered one fails. The DESC
-- matters: these are all "newest first" reads.

select ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'credit_ledger'
           and indexdef ~ 'btree \(user_id, created_at DESC\)'),
  'credit_ledger (user_id, created_at desc)');

select ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'credit_purchases'
           and indexdef ~ 'btree \(user_id, created_at DESC\)'),
  'credit_purchases (user_id, created_at desc)');

select ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'credit_purchases'
           and indexdef ~ 'btree \(status\)'),
  'credit_purchases (status)');

select ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'api_usage_log'
           and indexdef ~ 'btree \(provider, created_at DESC\)'),
  'api_usage_log (provider, created_at desc)');

select ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'api_usage_log'
           and indexdef ~ 'btree \(marketplace_id, created_at DESC\)'),
  'api_usage_log (marketplace_id, created_at desc)');

select ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'ingestion_runs'
           and indexdef ~ 'btree \(market_id, started_at DESC\)'),
  'ingestion_runs (market_id, started_at desc)');

select ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'app_events'
           and indexdef ~ 'btree \(event, created_at DESC\)'),
  'app_events (event, created_at desc)');

select ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'app_events'
           and indexdef ~ 'btree \(user_id, created_at DESC\)'),
  'app_events (user_id, created_at desc)');

-- The idempotency guard is an index too, and the one most costly to lose.
select ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'credit_ledger'
           and indexdef ~ 'CREATE UNIQUE INDEX .* btree \(idempotency_key\)'),
  'and credit_ledger.idempotency_key is backed by a UNIQUE index');

-- ---------------------------------------------------------------------------
-- L. RLS: enabled everywhere, no policies yet (T05 acceptance criterion)
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
      and c.relname in ('credit_packs', 'credit_pack_prices', 'credit_ledger',
                        'credit_purchases', 'stripe_webhook_events',
                        'api_usage_log', 'ingestion_runs', 'app_events')),
  8,
  'RLS is enabled on all eight Schema C tables');

select is(
  (select count(*)::int
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0,
  'and no table in public has RLS disabled');

-- Updated by T06. Rescoped to Schema C's own tables: two of the eight are
-- opened for public read, one for own-row read, and the remaining five carry no
-- policy at all — including stripe_webhook_events, which gained a trigger in
-- T06 but never a policy or a grant.
select bag_eq(
  $$select tablename::text || ':' || cmd::text from pg_policies
     where schemaname = 'public'
       and tablename in ('credit_packs', 'credit_pack_prices', 'credit_ledger',
                         'credit_purchases', 'stripe_webhook_events',
                         'api_usage_log', 'ingestion_runs', 'app_events')$$,
  $$values ('credit_packs:SELECT'), ('credit_pack_prices:SELECT'),
           ('credit_ledger:SELECT')$$,
  'exactly three Schema C policies exist after T06, all SELECT — and credit_ledger has no write policy of any kind');

select is(
  (select count(*)::int from pg_policies
    where schemaname = 'public'
      and tablename in ('credit_purchases', 'stripe_webhook_events',
                        'api_usage_log', 'ingestion_runs', 'app_events')),
  0,
  'and the five service-role-only Schema C tables carry none');

-- ---------------------------------------------------------------------------
-- M. Privileges: the T03 baseline, plus the two ADR-0010 narrowings
-- ---------------------------------------------------------------------------

-- Updated by T06. The Schema C grant surface is now an exact allowlist rather
-- than "nothing": three tables, SELECT only, and five tables still holding
-- nothing at all. Every entry below is paired with a policy asserted above.
select bag_eq(
  $$select grantee::text || ':' || table_name::text || ':' || privilege_type::text
      from information_schema.role_table_grants
     where table_schema = 'public'
       and grantee in ('anon', 'authenticated')
       and table_name in ('credit_packs', 'credit_pack_prices', 'credit_ledger',
                          'credit_purchases', 'stripe_webhook_events',
                          'api_usage_log', 'ingestion_runs', 'app_events')$$,
  $$values ('anon:credit_packs:SELECT'), ('authenticated:credit_packs:SELECT'),
           ('anon:credit_pack_prices:SELECT'), ('authenticated:credit_pack_prices:SELECT'),
           ('authenticated:credit_ledger:SELECT')$$,
  'the Schema C grant surface is exactly five SELECT grants — and credit_ledger is authenticated-only, with no INSERT, UPDATE or DELETE to anyone');

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee in ('anon', 'authenticated')
      and table_name in ('credit_purchases', 'stripe_webhook_events',
                         'api_usage_log', 'ingestion_runs', 'app_events')),
  0,
  'payment history, raw webhook payloads and the operational logs grant anon and authenticated nothing');

-- The two tables T06 opened, and the predicate that governs the second one. A
-- grant without its predicate would be an ungoverned privilege, so the grant
-- and the policy predicate are asserted together.
select ok(
  has_table_privilege('anon', 'public.credit_packs', 'SELECT'),
  'anon can now read credit_packs — T06 added the grant with credit_packs_select_public');

select ok(
  has_table_privilege('anon', 'public.credit_pack_prices', 'SELECT'),
  'anon can now read credit_pack_prices — and the policy, not the grant, is what hides a NULL stripe_price_id row');

select is(
  (select qual from pg_policies
    where schemaname = 'public' and tablename = 'credit_pack_prices'),
  '(active AND (stripe_price_id IS NOT NULL))',
  'and that predicate is exactly ADR-0010 decision 4 — the fixture rows above, seeded NULL as T08 will seed them, are therefore invisible');

select ok(
  has_table_privilege('authenticated', 'public.credit_ledger', 'SELECT'),
  'authenticated can now read its own ledger — T06 added the SELECT grant with credit_ledger_select_own');

select ok(
  not has_table_privilege('authenticated', 'public.credit_ledger', 'INSERT')
  and not has_table_privilege('authenticated', 'public.credit_ledger', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.credit_ledger', 'DELETE'),
  'and SELECT is all it gained — the ledger is unwritable from the client at the grant layer, not merely unpolicied');

select ok(
  not has_table_privilege('anon', 'public.credit_purchases', 'SELECT'),
  'anon cannot read credit_purchases');

select ok(
  not has_table_privilege('authenticated', 'public.stripe_webhook_events', 'SELECT'),
  'authenticated cannot read stripe_webhook_events — service-role-only, permanently');

-- The narrowed posture, per table. A blanket assertion across all tables would
-- pass on the day someone re-grants the ledger.
select is(
  (select string_agg(privilege_type, ',' order by privilege_type)
     from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'service_role'
      and table_name = 'credit_ledger'),
  'INSERT,SELECT',
  'service_role holds exactly INSERT and SELECT on credit_ledger — narrowing 1 (ADR-0010)');

select is(
  (select string_agg(privilege_type, ',' order by privilege_type)
     from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'service_role'
      and table_name = 'stripe_webhook_events'),
  'INSERT,SELECT,UPDATE',
  'service_role holds exactly INSERT, SELECT and UPDATE on stripe_webhook_events — narrowing 2 (ADR-0010)');

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'service_role'
      and privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
      and table_name in ('credit_packs', 'credit_pack_prices', 'credit_purchases',
                         'api_usage_log', 'ingestion_runs', 'app_events')),
  24,
  'the six unnarrowed Schema C tables keep all four DML privileges (6 x 4)');

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'service_role'
      and privilege_type not in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
      and table_name in ('credit_packs', 'credit_pack_prices', 'credit_ledger',
                         'credit_purchases', 'stripe_webhook_events',
                         'api_usage_log', 'ingestion_runs', 'app_events')),
  0,
  'and nothing beyond DML on any of them — no TRUNCATE, TRIGGER or REFERENCES');

select is(
  (select count(*)::int
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'S'),
  0,
  'Schema C created no sequences — every key is a uuid or an external id, so no sequence grant was missed');

-- Exactly one function was added, and it is the trigger function.
select is(
  (select count(*)::int
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname not in ('set_updated_at', 'handle_new_user',
                            'enforce_deal_lifecycle', 'enforce_credit_ledger_append_only',
                            'enforce_webhook_event_restricted_update',
                            -- T09/ADR-0016: the TRUNCATE guard T06 deferred.
                            'enforce_webhook_events_no_truncate',
                            'spend_credits', 'grant_credits',
                            'credit_ledger_idempotent_match',
                            '_sqlstate_as', '_scalar_as')),
  0,
  'Schema C added exactly one function, the append-only trigger function');

select ok(
  not has_function_privilege('anon', 'public.enforce_credit_ledger_append_only()', 'EXECUTE'),
  'anon cannot execute it');

select ok(
  not has_function_privilege('authenticated', 'public.enforce_credit_ledger_append_only()', 'EXECUTE'),
  'authenticated cannot execute it');

-- The default privileges T03 established still hold, so the NEXT table inherits
-- the same posture rather than re-importing the hosted project's GRANT ALL.
select is(
  (select count(*)::int
     from pg_default_acl d join pg_namespace n on n.oid = d.defaclnamespace
    where n.nspname = 'public'
      and pg_get_userbyid(d.defaclrole) = 'postgres'
      and array_to_string(d.defaclacl, ',') ~ '(^|,)(anon|authenticated)='),
  0,
  'no default privilege grants anything to anon or authenticated on future objects (ADR-004 intact)');

select * from finish();

rollback;
