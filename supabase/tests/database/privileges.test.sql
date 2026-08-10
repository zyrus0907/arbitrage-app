-- T03 — Privilege baseline tests (pgTAP), run by `npm run db:test`.
--
-- RLS is the authorisation boundary, but a role must hold the table privilege
-- before any policy is consulted. These tests assert the first gate directly,
-- so that T09's anon-access suite cannot pass for the wrong reason: if the
-- grants ever drift back to the hosted project's GRANT ALL, this fails here
-- rather than silently making a later RLS test meaningless.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog, pg_temp;

select plan(26);

-- ---------------------------------------------------------------------------
-- A. anon and authenticated hold no DML on any Schema A table
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee = 'anon'
      and privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')),
  0,
  'anon holds no SELECT, INSERT, UPDATE or DELETE on any public table');

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee = 'authenticated'
      and privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')),
  0,
  'authenticated holds no SELECT, INSERT, UPDATE or DELETE on any public table');

-- Not even the incidental ones. REFERENCES, TRIGGER, TRUNCATE and MAINTAIN are
-- the local stack's default and were never wanted.
select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee in ('anon', 'authenticated')),
  0,
  'anon and authenticated hold no table privilege of any kind in public');

-- Spot-checks through the privilege functions rather than the view, because
-- these are what PostgreSQL actually consults.
select ok(
  not has_table_privilege('anon', 'public.marketplace_products', 'SELECT'),
  'anon cannot select from marketplace_products — the paid product is not readable at the grant layer, let alone the policy layer');

select ok(
  not has_table_privilege('anon', 'public.profiles', 'SELECT'),
  'anon cannot select from profiles');

select ok(
  not has_table_privilege('authenticated', 'public.fee_schedules', 'SELECT'),
  'authenticated cannot select from fee_schedules');

select ok(
  not has_table_privilege('anon', 'public.currencies', 'INSERT'),
  'anon cannot insert reference data');

-- ---------------------------------------------------------------------------
-- B. The service role keeps exactly the four DML privileges
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee = 'service_role'
      and privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')),
  44,
  'service_role holds all four DML privileges on all eleven tables (11 x 4)');

select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public'
      and grantee = 'service_role'
      and privilege_type not in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')),
  0,
  'service_role holds nothing beyond DML — no TRUNCATE, TRIGGER or REFERENCES');

select ok(
  has_table_privilege('service_role', 'public.marketplace_products', 'SELECT'),
  'the service role can read the tables §6.3 designates service-role-only');

-- ---------------------------------------------------------------------------
-- C. Trigger functions are owner-only
-- ---------------------------------------------------------------------------

-- Owner-only: not anon, not authenticated, and not the service role either.
-- A function in public grants EXECUTE to nobody until a migration says so, so
-- T07's credit RPCs must carry their own explicit grant.

select ok(
  not has_function_privilege('anon', 'public.handle_new_user()', 'EXECUTE'),
  'anon cannot execute handle_new_user');

select ok(
  not has_function_privilege('authenticated', 'public.handle_new_user()', 'EXECUTE'),
  'authenticated cannot execute handle_new_user');

select ok(
  not has_function_privilege('service_role', 'public.handle_new_user()', 'EXECUTE'),
  'service_role cannot execute handle_new_user');

select ok(
  not has_function_privilege('anon', 'public.set_updated_at()', 'EXECUTE'),
  'anon cannot execute set_updated_at');

select ok(
  not has_function_privilege('authenticated', 'public.set_updated_at()', 'EXECUTE'),
  'authenticated cannot execute set_updated_at');

select ok(
  not has_function_privilege('service_role', 'public.set_updated_at()', 'EXECUTE'),
  'service_role cannot execute set_updated_at');

select is(
  (select array_to_string(proacl, ',')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'handle_new_user'),
  'postgres=X/postgres',
  'handle_new_user is executable by its owner and nobody else');

select is(
  (select array_to_string(proacl, ',')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'set_updated_at'),
  'postgres=X/postgres',
  'set_updated_at is executable by its owner and nobody else');

-- ---------------------------------------------------------------------------
-- C2. Owner-only does not break the triggers
-- ---------------------------------------------------------------------------
--
-- EXECUTE on a trigger function is checked when the trigger is created, not
-- when it fires. That is the load-bearing assumption behind revoking these, so
-- it is tested rather than trusted — both triggers are fired here by roles that
-- hold no EXECUTE on the function behind them.

-- The signup path in miniature. auth.users is owned by supabase_auth_admin and
-- cannot be granted from here, so this probe reproduces its shape: a table
-- whose insert fires a SECURITY DEFINER trigger function that writes elsewhere
-- — exactly handle_new_user's structure — with EXECUTE revoked from the role
-- doing the inserting. All three objects are created and dropped inside this
-- transaction.
create table public._trigger_probe_users (id uuid primary key);
create table public._trigger_probe_profiles (id uuid primary key);

create function public._trigger_probe_fn() returns trigger
  language plpgsql security definer set search_path = public, pg_temp as $probe$
begin
  insert into public._trigger_probe_profiles (id) values (new.id) on conflict (id) do nothing;
  return new;
end;
$probe$;

create trigger on_probe_user_created
  after insert on public._trigger_probe_users
  for each row execute function public._trigger_probe_fn();

-- Revoked AFTER the trigger exists, which is the situation the migration creates.
revoke all on function public._trigger_probe_fn() from public, anon, authenticated, service_role;
grant insert on table public._trigger_probe_users to anon;

set local role anon;
insert into public._trigger_probe_users (id) values ('cccccccc-cccc-cccc-cccc-cccccccccccc');
reset role;

select is(
  (select count(*)::int from public._trigger_probe_profiles
    where id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'),
  1,
  'a SECURITY DEFINER signup-shaped trigger still fires for a role holding no EXECUTE on it');

select ok(
  not has_function_privilege('anon', 'public._trigger_probe_fn()', 'EXECUTE'),
  'and that role genuinely held no EXECUTE while it fired');

-- The updated_at trigger, fired by the service role — which holds UPDATE on the
-- table, BYPASSRLS, and no EXECUTE on set_updated_at.
set local role service_role;
update public.currencies set name = 'Yen (trigger probe)' where code = 'JPY';
reset role;

select ok(
  (select updated_at > created_at from public.currencies where code = 'JPY'),
  'the updated_at trigger still fires for a role with no EXECUTE on set_updated_at');

-- ---------------------------------------------------------------------------
-- D. Future objects inherit the same posture
-- ---------------------------------------------------------------------------
--
-- This is the assertion that stops the divergence coming back with T04's deals
-- table or T07's credit RPCs.

select is(
  (select count(*)::int
     from pg_default_acl d
     join pg_namespace n on n.oid = d.defaclnamespace
    where n.nspname = 'public'
      and pg_get_userbyid(d.defaclrole) = 'postgres'
      and array_to_string(d.defaclacl, ',') ~ '(^|,)(anon|authenticated)='),
  0,
  'no default privilege grants anything to anon or authenticated on objects postgres creates in public');

-- A future table should hand the service role the same four privileges the
-- eleven current ones do — not TRUNCATE, TRIGGER and REFERENCES as well.
select is(
  (select array_to_string(d.defaclacl, ',')
     from pg_default_acl d
     join pg_namespace n on n.oid = d.defaclnamespace
    where n.nspname = 'public'
      and pg_get_userbyid(d.defaclrole) = 'postgres'
      and d.defaclobjtype = 'r'),
  'postgres=arwdDxtm/postgres,service_role=arwd/postgres',
  'a future table grants the service role exactly SELECT, INSERT, UPDATE and DELETE');

-- Future functions are owner-only: no PUBLIC, no anon, no authenticated, and
-- no service_role. T07 grants EXECUTE explicitly on the RPCs it creates.
select is(
  (select array_to_string(d.defaclacl, ',')
     from pg_default_acl d
     join pg_namespace n on n.oid = d.defaclnamespace
    where n.nspname = 'public'
      and pg_get_userbyid(d.defaclrole) = 'postgres'
      and d.defaclobjtype = 'f'),
  'postgres=X/postgres',
  'a future function in public is executable by its owner alone');

select is(
  (select count(*)::int
     from pg_default_acl d
     join pg_namespace n on n.oid = d.defaclnamespace
    where n.nspname = 'public'
      and pg_get_userbyid(d.defaclrole) = 'postgres'
      and d.defaclobjtype = 'f'
      and array_to_string(d.defaclacl, ',') ~ '(^|,)(anon|authenticated|service_role)='),
  0,
  'no role inherits EXECUTE on future functions automatically');

-- RLS is untouched by this migration and must stay untouched.
select is(
  (select count(*)::int from pg_policies where schemaname = 'public'),
  0,
  'normalising privileges added no RLS policy — those belong to T06');

select * from finish();

rollback;
