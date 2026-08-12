-- T09 — the exhaustive security baseline (pgTAP), run by `npm run db:test`.
--
-- rls_policies_and_grants.test.sql says in its own header that "T09 owns the
-- formal, exhaustive privilege suite". This is that file, and it is deliberately
-- a different KIND of test from every suite before it.
--
-- ===========================================================================
-- WHY ALLOWLISTS, AND WHY THEY ARE NOT DUPLICATES
-- ===========================================================================
--
-- T03–T08 assert that the things they built behave correctly: this table is
-- closed, that policy filters, this trigger refuses. Every one of those
-- assertions is scoped to an object the author already knew about.
--
-- That leaves one hole, and it is the hole a security baseline exists to close:
-- **nothing fails when something NEW appears.** A migration in T20 that adds a
-- grant, a policy, a function or a table passes every existing suite, because no
-- existing suite is looking for it. The assertions below compare the WHOLE
-- catalogue against a literal, so an addition anywhere turns this file red and
-- has to be justified by whoever made it.
--
-- The failure message is a diff of the entire matrix, which is the point: the
-- reviewer sees exactly what changed. When the change is intended, the literal
-- is updated in the same commit, and the diff of THIS file is the audit record
-- of a privilege change.
--
-- These are therefore not duplicate assertions. They restate nothing; they
-- assert the complement — that the surface contains nothing else.
--
-- ===========================================================================
-- WHAT IS DELIBERATELY NOT HERE
-- ===========================================================================
--
--   * Behaviour of individual policies (T06's file, sections A–G).
--   * Credit RPC semantics and concurrency (T07's two files).
--   * Temporal exclusion behaviour (T05A's file).
--   * Seed row values (T08's file).
--   * What a real browser holding the anon key receives — that cannot be
--     asserted here at all, because `SET LOCAL ROLE` is not a JWT. It lives in
--     tests/integration/rls.test.ts.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog, pg_temp;

select plan(27);

-- ===========================================================================
-- A. The complete table-privilege matrix
-- ===========================================================================
--
-- Forty rows. Any new grant to any client role, on any table, anywhere in
-- `public`, fails this.

select is(
  (select string_agg(line, E'\n' order by line) from (
     select format('%s %s %s', grantee, table_name,
                   string_agg(privilege_type, ',' order by privilege_type)) line
       from information_schema.role_table_grants
      where table_schema = 'public'
        and grantee in ('anon', 'authenticated', 'service_role')
      group by grantee, table_name) g),
  'anon countries SELECT
anon credit_pack_prices SELECT
anon credit_packs SELECT
anon currencies SELECT
anon markets SELECT
authenticated barcode_lookups DELETE,INSERT,SELECT
authenticated countries SELECT
authenticated credit_ledger SELECT
authenticated credit_pack_prices SELECT
authenticated credit_packs SELECT
authenticated currencies SELECT
authenticated deal_unlocks INSERT,SELECT
authenticated markets SELECT
authenticated profiles SELECT
authenticated purchase_records DELETE,INSERT,SELECT
authenticated watchlist_items DELETE,INSERT,SELECT
service_role api_usage_log DELETE,INSERT,SELECT,UPDATE
service_role app_events DELETE,INSERT,SELECT,UPDATE
service_role barcode_lookups DELETE,INSERT,SELECT,UPDATE
service_role countries DELETE,INSERT,SELECT,UPDATE
service_role credit_ledger INSERT,SELECT
service_role credit_pack_prices DELETE,INSERT,SELECT,UPDATE
service_role credit_packs DELETE,INSERT,SELECT,UPDATE
service_role credit_purchases DELETE,INSERT,SELECT,UPDATE
service_role currencies DELETE,INSERT,SELECT,UPDATE
service_role deal_unlocks DELETE,INSERT,SELECT,UPDATE
service_role deals DELETE,INSERT,SELECT,UPDATE
service_role fee_schedules DELETE,INSERT,SELECT,UPDATE
service_role ingestion_runs DELETE,INSERT,SELECT,UPDATE
service_role marketplace_products DELETE,INSERT,SELECT,UPDATE
service_role marketplaces DELETE,INSERT,SELECT,UPDATE
service_role markets DELETE,INSERT,SELECT,UPDATE
service_role product_matches DELETE,INSERT,SELECT,UPDATE
service_role profiles DELETE,INSERT,SELECT,UPDATE
service_role purchase_records DELETE,INSERT,SELECT,UPDATE
service_role retailer_products DELETE,INSERT,SELECT,UPDATE
service_role retailers DELETE,INSERT,SELECT,UPDATE
service_role stripe_webhook_events INSERT,SELECT,UPDATE
service_role tax_schedules DELETE,INSERT,SELECT,UPDATE
service_role watchlist_items DELETE,INSERT,SELECT,UPDATE',
  'the complete table-privilege matrix is exactly the designed forty rows');

-- The two deliberate narrowings, called out separately so that if the matrix
-- above is ever updated carelessly these still fail on their own terms.
select is(
  (select string_agg(privilege_type, ',' order by privilege_type)
     from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'credit_ledger' and grantee = 'service_role'),
  'INSERT,SELECT',
  'service_role still cannot UPDATE or DELETE credit_ledger (ADR-0011 decision 5)');

select is(
  (select string_agg(privilege_type, ',' order by privilege_type)
     from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'stripe_webhook_events' and grantee = 'service_role'),
  'INSERT,SELECT,UPDATE',
  'service_role still cannot DELETE stripe_webhook_events (ADR-0010 decision 5)');

select is(
  (select count(*)::int from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'PUBLIC'),
  0,
  'no table in public is granted to PUBLIC');

-- ===========================================================================
-- B. The complete column-privilege matrix
-- ===========================================================================
--
-- The only column-level grants in the schema are the fourteen that make
-- `profiles` updatable without making `credit_balance` updatable. A future
-- column added to `profiles` is NOT granted by default, which is the safe
-- direction; a future column added to this list has to appear here first.

select is(
  (select string_agg(line, E'\n' order by line) from (
     select format('%s %s %s %s', grantee, table_name, column_name, privilege_type) line
       from information_schema.column_privileges cp
      where table_schema = 'public'
        and grantee in ('anon', 'authenticated', 'service_role')
        and not exists (
          select 1 from information_schema.role_table_grants g
           where g.table_schema = 'public' and g.table_name = cp.table_name
             and g.grantee = cp.grantee and g.privilege_type = cp.privilege_type)) c),
  'authenticated profiles assumption_currency UPDATE
authenticated profiles country_code UPDATE
authenticated profiles default_budget_minor UPDATE
authenticated profiles default_fulfilment UPDATE
authenticated profiles default_market_id UPDATE
authenticated profiles display_name UPDATE
authenticated profiles inbound_shipping_per_unit_minor UPDATE
authenticated profiles locale UPDATE
authenticated profiles onboarded_at UPDATE
authenticated profiles prep_cost_per_unit_minor UPDATE
authenticated profiles tax_registered UPDATE
authenticated profiles tax_registration_country UPDATE
authenticated profiles tax_scheme UPDATE
authenticated profiles timezone UPDATE',
  'the only column-level grants are the fourteen writable profile columns');

-- Named directly, because this is the one that matters most: the cached balance
-- is moved only by the T07 RPCs, and a write privilege here would be a way
-- around them that no policy would catch.
--
-- The assertion is about WRITE, not about all access. `authenticated` does hold
-- SELECT on this column, inherited from the table-level SELECT grant on
-- `profiles`, and that is intended — a user reads their own balance to see it.
-- Asserting "no privilege at all" would be asserting the wrong invariant and
-- would fail against a correct system; both halves are pinned separately.
select is(
  (select coalesce(string_agg(privilege_type, ',' order by privilege_type), '<none>')
     from information_schema.column_privileges
    where table_schema = 'public' and table_name = 'profiles'
      and column_name = 'credit_balance'
      and grantee in ('anon', 'authenticated')),
  'SELECT',
  'the only client privilege on profiles.credit_balance is SELECT — it is readable, never writable');

select ok(
  not exists (
    select 1 from information_schema.column_privileges
     where table_schema = 'public' and table_name = 'profiles'
       and column_name = 'credit_balance'
       and grantee in ('anon', 'authenticated')
       and privilege_type in ('INSERT', 'UPDATE', 'REFERENCES')),
  'no client role can write profiles.credit_balance — only the T07 RPCs move it');

select ok(
  not exists (
    select 1 from information_schema.column_privileges
     where table_schema = 'public' and table_name = 'profiles'
       and column_name in ('id', 'created_at', 'updated_at')
       and grantee = 'authenticated' and privilege_type = 'UPDATE'),
  'authenticated cannot update a profile''s identity or timestamps either');

-- ===========================================================================
-- C. The complete RLS policy allowlist
-- ===========================================================================
--
-- polcmd: r = SELECT, a = INSERT, w = UPDATE, d = DELETE, * = ALL.
-- A policy for ALL would appear as '*' and fail this immediately, which is
-- intended — every policy in this schema is deliberately single-command.

select is(
  (select string_agg(line, E'\n' order by line) from (
     select format('%s %s %s %s', c.relname, p.polname, p.polcmd,
                   coalesce((select string_agg(r.rolname, '+' order by r.rolname)
                               from pg_roles r where r.oid = any (p.polroles)), 'PUBLIC')) line
       from pg_policy p
       join pg_class c on c.oid = p.polrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public') pol),
  'barcode_lookups barcode_lookups_delete_own d authenticated
barcode_lookups barcode_lookups_insert_own a authenticated
barcode_lookups barcode_lookups_select_own r authenticated
countries countries_select_public r anon+authenticated
credit_ledger credit_ledger_select_own r authenticated
credit_pack_prices credit_pack_prices_select_public r anon+authenticated
credit_packs credit_packs_select_public r anon+authenticated
currencies currencies_select_public r anon+authenticated
deal_unlocks deal_unlocks_insert_own a authenticated
deal_unlocks deal_unlocks_select_own r authenticated
markets markets_select_public r anon+authenticated
profiles profiles_select_own r authenticated
profiles profiles_update_own w authenticated
purchase_records purchase_records_delete_own d authenticated
purchase_records purchase_records_insert_own a authenticated
purchase_records purchase_records_select_own r authenticated
watchlist_items watchlist_items_delete_own d authenticated
watchlist_items watchlist_items_insert_own a authenticated
watchlist_items watchlist_items_select_own r authenticated',
  'the complete RLS policy set is exactly the designed nineteen');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0,
  'RLS is enabled on every table in public');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'),
  24,
  'public holds exactly 24 tables — a new one must be classified by T09''s suites');

-- The correspondence rule, as a set operation rather than table by table: a
-- grant with no policy is an inert grant, a policy with no grant is an inert
-- policy, and both are defects even though neither leaks on its own.
select is(
  (select string_agg(t, ',' order by t) from (
     select c.relname t
       from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r'
        and exists (select 1 from pg_policy p where p.polrelid = c.oid)
     except
     select distinct table_name
       from information_schema.role_table_grants
      where table_schema = 'public' and grantee in ('anon', 'authenticated')) x),
  null,
  'no table carries a policy without a matching client grant (an inert policy)');

select is(
  (select string_agg(t, ',' order by t) from (
     select distinct table_name t
       from information_schema.role_table_grants
      where table_schema = 'public' and grantee in ('anon', 'authenticated')
     except
     select c.relname
       from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r'
        and exists (select 1 from pg_policy p where p.polrelid = c.oid)) x),
  null,
  'no table carries a client grant without a policy (an unguarded grant)');

-- ===========================================================================
-- D. The complete function inventory and ACL allowlist
-- ===========================================================================
--
-- A NULL proacl is the trap this catches: Postgres grants EXECUTE to PUBLIC on
-- creation, so a function whose migration forgot to REVOKE shows NULL here and
-- is callable by anon. On a SECURITY DEFINER function that mints credits, that
-- is the whole game.

select is(
  (select string_agg(line, E'\n' order by line) from (
     select format('%s secdef=%s cfg=%s acl=%s', p.proname, p.prosecdef,
                   coalesce(array_to_string(p.proconfig, ';'), 'NONE'),
                   coalesce(p.proacl::text, 'NULL')) line
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public') f),
  'credit_ledger_idempotent_match secdef=f cfg=search_path=public, pg_temp acl={postgres=X/postgres}
enforce_credit_ledger_append_only secdef=f cfg=search_path=pg_catalog, pg_temp acl={postgres=X/postgres}
enforce_deal_lifecycle secdef=f cfg=search_path=pg_catalog, pg_temp acl={postgres=X/postgres}
enforce_profile_tombstoned_before_auth_delete secdef=t cfg=search_path=public, pg_temp acl={postgres=X/postgres}
enforce_webhook_event_restricted_update secdef=f cfg=search_path=pg_catalog, pg_temp acl={postgres=X/postgres}
enforce_webhook_events_no_truncate secdef=f cfg=search_path=pg_catalog, pg_temp acl={postgres=X/postgres}
grant_credits secdef=t cfg=search_path=public, pg_temp acl={postgres=X/postgres,service_role=X/postgres}
handle_new_user secdef=t cfg=search_path=public, pg_temp acl={postgres=X/postgres}
pseudonymise_account secdef=t cfg=search_path=public, pg_temp acl={postgres=X/postgres,service_role=X/postgres}
set_updated_at secdef=f cfg=search_path=pg_catalog, pg_temp acl={postgres=X/postgres}
spend_credits secdef=t cfg=search_path=public, pg_temp acl={postgres=X/postgres,service_role=X/postgres}',
  'the complete function inventory, security posture and ACL set is exactly as designed');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proacl is null),
  0,
  'no function in public has a NULL ACL — a NULL ACL IS a PUBLIC execute grant');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proconfig is null),
  0,
  'every function in public pins a search_path');

-- ===========================================================================
-- E. SECURITY DEFINER hardening
-- ===========================================================================

select is(
  (select string_agg(p.proname, ',' order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef),
  'enforce_profile_tombstoned_before_auth_delete,grant_credits,handle_new_user,pseudonymise_account,spend_credits',
  -- T10/ADR-0017 adds two. `pseudonymise_account` must run as owner to write the
  -- tombstone and delete the personal rows, and is granted EXECUTE to
  -- service_role alone — the same posture as the two credit RPCs. The delete
  -- guard must run as owner for the same reason `handle_new_user` does: the
  -- calling role is `supabase_auth_admin`, which holds no privilege on
  -- `public.profiles`. It is executable by nobody, reads one column, writes
  -- nothing, and either returns OLD or raises.
  'exactly five SECURITY DEFINER functions exist, and they are the known five');

-- pg_temp must be LAST. A definer function whose search_path resolved pg_temp
-- first could be pointed at a temporary table created by the caller.
select ok(
  (select bool_and(array_to_string(p.proconfig, ';') like '%, pg_temp')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef),
  'every SECURITY DEFINER function resolves pg_temp last, never first');

-- The reason `search_path = public, pg_temp` is safe on a definer function at
-- all: no client role may create an object in `public` to shadow one. If this
-- ever changes, the three definer functions above become hijackable.
select ok(
  not (has_schema_privilege('anon', 'public', 'CREATE')
       or has_schema_privilege('authenticated', 'public', 'CREATE')
       or has_schema_privilege('service_role', 'public', 'CREATE')),
  'no client role may CREATE in public — which is what makes a definer search_path of `public` safe');

-- No dynamic SQL in a definer function. `format(... %I ...)` + EXECUTE is a
-- legitimate pattern but it is also the injection surface, and none of these
-- three needs it, so its absence is asserted rather than reviewed by eye.
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
      and p.prosrc ~* '(^|[^[:alnum:]_])execute[[:space:]]'),
  0,
  'no SECURITY DEFINER function builds or executes dynamic SQL');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
      and has_function_privilege('anon', p.oid, 'EXECUTE')),
  0,
  'anon can execute no SECURITY DEFINER function');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  0,
  'authenticated can execute no SECURITY DEFINER function');

-- ===========================================================================
-- F. The TRUNCATE guards — T09's own decision
-- ===========================================================================
--
-- T06 deferred this table's guard to T09 (TASKS.md T06 completion note). The
-- decision was to add it: before the T09 migration, `TRUNCATE
-- stripe_webhook_events` SUCCEEDED for the table owner, while the same
-- statement against credit_ledger was refused — an asymmetry between two tables
-- whose rows are both evidence. See ADR-0016.
--
-- A row trigger never fires for TRUNCATE, so the presence of the restricted-
-- update trigger says nothing about this. Both guards are asserted by
-- BEHAVIOUR below, not merely by catalogue presence.

select is(
  (select count(*)::int from pg_trigger t
    where t.tgrelid = 'public.stripe_webhook_events'::regclass
      and not t.tgisinternal
      and (t.tgtype::int & 32) > 0),
  1,
  'stripe_webhook_events carries a TRUNCATE trigger');

select throws_ok(
  'truncate public.stripe_webhook_events',
  '0A000',
  'stripe_webhook_events may not be truncated',
  'TRUNCATE on stripe_webhook_events is refused by the trigger, as the OWNER');

select throws_ok(
  'truncate public.credit_ledger',
  '0A000',
  null,
  'TRUNCATE on credit_ledger is still refused, as the OWNER');

-- The guard must not have narrowed the UPDATE path the table exists to allow.
select lives_ok(
  $$insert into public.stripe_webhook_events (stripe_event_id, type, payload)
    values ('evt_t09_baseline', 'test.event', '{}'::jsonb)$$,
  'a webhook event can still be recorded');

select lives_ok(
  $$update public.stripe_webhook_events set processed_at = now()
     where stripe_event_id = 'evt_t09_baseline'$$,
  'and can still be marked processed — the TRUNCATE guard narrowed nothing');

select * from finish();

rollback;
