-- T07 — Credit RPC concurrency tests (pgTAP), run by `npm run db:test`.
--
-- AC10.1 is a release gate: "given a balance of 1 credit, when 10 unlock
-- requests arrive concurrently, then exactly one succeeds and the balance is 0
-- — verified by an automated concurrency test". T07 restates it and adds that
-- it "must be automated, not manual".
--
-- ---------------------------------------------------------------------------
-- WHY THIS FILE IS SHAPED DIFFERENTLY FROM EVERY OTHER TEST IN THE SUITE
-- ---------------------------------------------------------------------------
--
-- Concurrency cannot be simulated from one session. Two calls made one after
-- the other in the same transaction prove arithmetic and nothing else: the
-- second one sees the first one's uncommitted work, never waits for a lock, and
-- would pass identically against a spend_credits with no FOR UPDATE in it. The
-- property under test — that the row lock SERIALISES two sessions — is only
-- observable between real, separate backends.
--
-- So this file drives genuine concurrent sessions with `dblink`, and that has
-- two consequences it is worth being explicit about:
--
-- 1. THE FIXTURES MUST BE COMMITTED. A separate session cannot see rows created
--    inside this file's open transaction, so the fixtures are created THROUGH a
--    dblink connection (which autocommits) rather than locally. They are
--    therefore real rows in the local database until the cleanup section
--    removes them, and the cleanup is asserted rather than assumed.
--
-- 2. EVERY WRITE THIS FILE MAKES GOES THROUGH DBLINK. If dblink cannot connect,
--    the file creates nothing and fails at the first assertion. That is the
--    safety property that makes a committed-fixture test acceptable here: there
--    is no path on which it half-writes.
--
-- dblink is created inside this transaction and rolled back with it, exactly as
-- the suite does with pgtap, so no migration installs it.
--
-- ---------------------------------------------------------------------------
-- THE CONNECTION STRING
-- ---------------------------------------------------------------------------
--
-- dblink refuses a passwordless connection for a non-superuser, and `postgres`
-- is not a superuser on the Supabase local stack. It also refuses one where the
-- server did not actually demand the password — so `host=localhost` fails,
-- because loopback is trusted in the local pg_hba, and the target has to be the
-- container's own address, where the password rule applies. That is what
-- `inet_server_addr()` gives. The unrestricted variant that would sidestep the
-- whole question, `dblink_connect_u`, is owned by `supabase_admin` and grants
-- `postgres` no EXECUTE, so a password is genuinely required here.
--
-- IT IS NOT IN THIS FILE, AND THERE IS NO FALLBACK. The password is read from
-- the `t7.db_password` setting, which `scripts/db-test.mjs` resolves from
-- `supabase status` at run time, publishes for the length of the run, and
-- removes again in a `finally`. If the setting is absent this file RAISES
-- rather than guessing: a test that quietly substituted a default would pass on
-- the machine where the default happened to be right and fail confusingly
-- everywhere else, and a credential belongs in neither case.
--
-- `npm run db:test` is still one command and needs no manual setup.
--
-- ---------------------------------------------------------------------------
-- CLEANUP, AND THE ONE THING IT HAS TO WORK AROUND
-- ---------------------------------------------------------------------------
--
-- The ledger is append-only at two layers (T05, AC10.5), so the rows these
-- scenarios commit cannot simply be deleted — which is the correct behaviour
-- and is re-asserted at the end of this file. The cleanup therefore disables
-- the row-level trigger, deletes, and re-enables it, and does all three IN ONE
-- STATEMENT STRING, which dblink sends as a single transaction. Because
-- `ALTER TABLE ... DISABLE TRIGGER` takes an ACCESS EXCLUSIVE lock, no other
-- session can so much as read credit_ledger while the trigger is off; the
-- window in which the ledger is mutable is not observable from anywhere.
--
-- This is the table owner doing something only the table owner can do, in a
-- test, on an ephemeral local database. It changes no migration and no
-- privilege. The section that follows it proves the guard is back and still
-- refuses a delete.

begin;

create extension if not exists pgtap  with schema extensions;
create extension if not exists dblink with schema extensions;
set local search_path = extensions, public, pg_catalog, pg_temp;

select plan(40);

-- First, so that a missing setting reports itself rather than surfacing later as
-- dblink's generic "password required". The assertion is on a boolean; the value
-- itself is never rendered into a test description or a diagnostic.
select ok(
  nullif(btrim(coalesce(current_setting('t7.db_password', true), '')), '') is not null,
  'the t7.db_password setting is present — `npm run db:test` publishes it for the length of the run and removes it again');

-- ---------------------------------------------------------------------------
-- Machinery
-- ---------------------------------------------------------------------------

create function public._t7c_conn()
returns text
language plpgsql
stable
as $fn$
declare
  v_password text := nullif(btrim(coalesce(current_setting('t7.db_password', true), '')), '');
begin
  if v_password is null then
    raise exception
      using errcode = '42501',
            message = 'T07 concurrency tests: the t7.db_password setting is absent',
            detail  = 'dblink refuses a passwordless connection for a non-superuser, so these tests need the local stack''s database password supplied at run time. It is deliberately not stored in this repository, and there is no default to fall back to.',
            hint    = 'run the suite with `npm run db:test`, which resolves the password from `supabase status`, publishes it for the length of the run and removes it afterwards';
  end if;

  return format('host=%s port=%s dbname=%s user=%s password=%s',
                host(inet_server_addr()),
                current_setting('port'),
                current_database(),
                current_user,
                v_password);
end;
$fn$;

-- One long-lived connection used for fixtures, state reads and cleanup. Every
-- statement on it autocommits, which is the whole point.
create function public._t7c_admin(p_sql text)
returns void
language plpgsql
as $fn$
begin
  perform extensions.dblink_exec('t7c_admin', p_sql);
end;
$fn$;

-- The SQLSTATE a statement produces in the OTHER session. dblink propagates the
-- remote error's code, which is what lets a negative assertion here name its
-- mechanism the same way the rest of the suite does.
create function public._t7c_sqlstate(p_sql text)
returns text
language plpgsql
as $fn$
begin
  perform extensions.dblink_exec('t7c_admin', p_sql);
  return null;
exception when others then
  return sqlstate;
end;
$fn$;

create function public._t7c_int(p_sql text)
returns integer
language plpgsql
stable
as $fn$
declare
  v integer;
begin
  select n into v from extensions.dblink('t7c_admin', p_sql) as t(n integer);
  return v;
end;
$fn$;

-- Runs one statement per connection, ALL SENT BEFORE ANY RESULT IS COLLECTED.
-- That ordering is what makes them concurrent: dblink_send_query returns as
-- soon as the query is on the wire, so by the time the first dblink_get_result
-- is called, every backend is already contending for the same profile row.
--
-- Each statement must produce a single integer column. Returns how many
-- succeeded, how many were refused with INSUFFICIENT_CREDITS (23514), how many
-- failed some other way, the values the successful ones returned, and every
-- SQLSTATE seen — so a surprise failure is legible in the diagnostics rather
-- than just moving a count.
create function public._t7c_race(p_sqls text[])
returns table (ok integer, insufficient integer, other integer, results text, codes text)
language plpgsql
as $fn$
declare
  i        integer;
  cn       text;
  n        integer := array_length(p_sqls, 1);
  v_ok     integer := 0;
  v_insuff integer := 0;
  v_other  integer := 0;
  v_vals   integer[] := '{}';
  v_codes  text[] := '{}';
  v_res    integer;
  v_code   text;
  v_failed boolean;
begin
  for i in 1..n loop
    perform extensions.dblink_connect(format('t7c_%s', i), public._t7c_conn());
  end loop;

  for i in 1..n loop
    perform extensions.dblink_send_query(format('t7c_%s', i), p_sqls[i]);
  end loop;

  for i in 1..n loop
    cn := format('t7c_%s', i);
    v_failed := true;
    v_code := null;
    begin
      select t.n into v_res from extensions.dblink_get_result(cn) as t(n integer);
      -- A second call returns zero rows and marks the connection idle again.
      perform * from extensions.dblink_get_result(cn) as t(n integer);
      v_failed := false;
    exception when others then
      v_code := sqlstate;
    end;

    -- Counters are updated outside the exception block so a sub-transaction
    -- rollback can never take an increment with it.
    if v_failed then
      v_codes := v_codes || v_code;
      if v_code = '23514' then
        v_insuff := v_insuff + 1;
      else
        v_other := v_other + 1;
      end if;
    else
      v_ok := v_ok + 1;
      v_vals := v_vals || v_res;
    end if;
  end loop;

  for i in 1..n loop
    perform extensions.dblink_disconnect(format('t7c_%s', i));
  end loop;

  return query select v_ok, v_insuff, v_other,
                      array_to_string(v_vals, ','), array_to_string(v_codes, ',');
end;
$fn$;

create function public._t7c_spend_sql(p_user uuid, p_amount integer, p_key text)
returns text
language sql
immutable
as $fn$
  select format('select new_balance from public.spend_credits(%L, %s, %L, null, null, %L)',
                p_user, p_amount, 'unlock_deal', p_key)
$fn$;

-- ---------------------------------------------------------------------------
-- Connect, and fail loudly rather than skip if we cannot
-- ---------------------------------------------------------------------------

select lives_ok(
  $$select extensions.dblink_connect('t7c_admin', public._t7c_conn())$$,
  'dblink can open a second session against this database — without it there is no concurrency test, and AC10.1 has no release gate');

-- ---------------------------------------------------------------------------
-- Committed fixtures
-- ---------------------------------------------------------------------------
--
-- Balances are set through grant_credits, so the fixtures start reconciled and
-- every later balance claim is a claim about the ledger too.

select public._t7c_admin($$
  insert into auth.users (id, email) values
    ('a7c00000-0000-0000-0000-000000000001', 't7c-lastcredit@example.test'),
    ('a7c00000-0000-0000-0000-000000000002', 't7c-partial@example.test'),
    ('a7c00000-0000-0000-0000-000000000003', 't7c-samekey@example.test'),
    ('a7c00000-0000-0000-0000-000000000004', 't7c-blocking@example.test')
$$);

select public._t7c_admin($$
  do $do$
  begin
    perform public.grant_credits('a7c00000-0000-0000-0000-000000000001', 1, 'signup_grant', null, null, 'kc1-signup');
    perform public.grant_credits('a7c00000-0000-0000-0000-000000000002', 3, 'signup_grant', null, null, 'kc2-signup');
    perform public.grant_credits('a7c00000-0000-0000-0000-000000000003', 5, 'signup_grant', null, null, 'kc3-signup');
    perform public.grant_credits('a7c00000-0000-0000-0000-000000000004', 1, 'signup_grant', null, null, 'kc4-signup');
  end
  $do$
$$);

select is(
  public._t7c_int($$select count(*)::int from public.profiles where id::text like 'a7c00000%'$$),
  4, 'fixture: four committed profiles, visible from a second session');

select is(
  public._t7c_int($$select credit_balance from public.profiles where id = 'a7c00000-0000-0000-0000-000000000001'$$),
  1, 'fixture: the AC10.1 user holds exactly 1 credit');

-- ===========================================================================
-- A. The lock actually blocks (the property, not the arithmetic)
-- ===========================================================================
--
-- Session A opens a transaction, spends, and HOLDS IT OPEN. Session B's spend
-- is then observed to be still running while A is uncommitted, which is only
-- possible if B is waiting on a lock A holds.
--
-- What that assertion does and does not prove, checked by deleting the
-- FOR UPDATE from spend_credits and re-running this file:
--
--   B still blocks. The `update profiles set credit_balance` at the END of the
--   function takes the same row lock, so "B is busy" stays true — it is a proof
--   that the two sessions serialise SOMEWHERE, not that they serialise before
--   the balance is read.
--
--   The next three assertions are the ones that go red, and they are the point:
--   B wakes up having ALREADY read a balance of 1 and ALREADY passed the
--   sufficiency check, so it commits a second debit and the balance lands at
--   -1. Blocking late is worth nothing. The lock has to be taken before the
--   read, and that is what the outcome proves.
--
-- Under that mutation the whole file fails: fourteen assertions across all four
-- scenarios, including AC10.1 landing six successful unlocks and a balance of
-- -5 against a starting balance of 1.

create function public._t7c_blocking()
returns table (busy_while_a_open integer, b_sqlstate text, final_balance integer)
language plpgsql
as $fn$
declare
  v_busy integer;
  v_code text := null;
  v_bal  integer;
begin
  perform extensions.dblink_connect('t7c_a', public._t7c_conn());
  perform extensions.dblink_connect('t7c_b', public._t7c_conn());

  -- A: begin, spend the single credit, do not commit.
  perform extensions.dblink_exec('t7c_a', 'begin');
  perform * from extensions.dblink('t7c_a',
    public._t7c_spend_sql('a7c00000-0000-0000-0000-000000000004', 1, 'kc4-a')) as t(n integer);

  -- B: the same user, a different key, sent asynchronously.
  perform extensions.dblink_send_query('t7c_b',
    public._t7c_spend_sql('a7c00000-0000-0000-0000-000000000004', 1, 'kc4-b'));

  -- Give B every chance to finish if it is not going to block.
  perform pg_sleep(0.5);
  v_busy := extensions.dblink_is_busy('t7c_b');

  -- Release A. B can now proceed, and will find a balance of 0.
  perform extensions.dblink_exec('t7c_a', 'commit');

  begin
    perform * from extensions.dblink_get_result('t7c_b') as t(n integer);
    perform * from extensions.dblink_get_result('t7c_b') as t(n integer);
  exception when others then
    v_code := sqlstate;
  end;

  perform extensions.dblink_disconnect('t7c_a');
  perform extensions.dblink_disconnect('t7c_b');

  select n into v_bal from extensions.dblink('t7c_admin',
    $q$select credit_balance from public.profiles where id = 'a7c00000-0000-0000-0000-000000000004'$q$) as t(n integer);

  return query select v_busy, v_code, v_bal;
end;
$fn$;

create temporary table _t7c_block on commit drop as select * from public._t7c_blocking();

select is(
  (select busy_while_a_open from _t7c_block), 1,
  'B is STILL RUNNING half a second after A spent the last credit and left its transaction open — it is waiting on the profile row lock');

select is(
  (select b_sqlstate from _t7c_block), '23514',
  'and once A commits, B wakes up, re-reads a balance of 0 and is refused with INSUFFICIENT_CREDITS');

select is(
  (select final_balance from _t7c_block), 0,
  'the balance is 0, not -1: the second spend was refused rather than applied to a stale read');

select is(
  public._t7c_int($$select count(*)::int from public.credit_ledger
                     where user_id = 'a7c00000-0000-0000-0000-000000000004' and delta < 0$$),
  1, 'exactly one debit reached the ledger');

select is(
  public._t7c_int($$select count(*)::int from public.credit_ledger where idempotency_key = 'kc4-b'$$),
  0, 'and the loser''s idempotency key was never consumed');

-- ===========================================================================
-- B. AC10.1 — ten concurrent unlocks against a balance of 1
-- ===========================================================================

create temporary table _t7c_ac101 on commit drop as
select * from public._t7c_race(
  (select array_agg(public._t7c_spend_sql('a7c00000-0000-0000-0000-000000000001', 1,
                                          format('kc1-race-%s', g)))
     from generate_series(1, 10) g));

select is((select ok from _t7c_ac101), 1,
  'AC10.1: of ten concurrent unlock attempts against a balance of 1, exactly ONE succeeds');

select is((select insufficient from _t7c_ac101), 9,
  'and the other nine are refused with INSUFFICIENT_CREDITS');

select is((select other from _t7c_ac101), 0,
  'with no deadlock, no serialisation failure and no unexpected error among them');

select is((select results from _t7c_ac101), '0',
  'the winner returned a new balance of 0');

select is(
  public._t7c_int($$select credit_balance from public.profiles where id = 'a7c00000-0000-0000-0000-000000000001'$$),
  0, 'AC10.1: and the balance is 0 — not -8, which is what ten unserialised reads of "1" would have produced');

select is(
  public._t7c_int($$select count(*)::int from public.credit_ledger
                     where user_id = 'a7c00000-0000-0000-0000-000000000001' and delta < 0$$),
  1, 'exactly one debit row exists');

select is(
  public._t7c_int($$select count(*)::int from public.credit_ledger where idempotency_key like 'kc1-race-%'$$),
  1, 'and nine of the ten idempotency keys are still unused — a refusal consumes nothing');

select is(
  public._t7c_int($$select coalesce(sum(delta), 0)::int from public.credit_ledger
                     where user_id = 'a7c00000-0000-0000-0000-000000000001'$$),
  0, 'AC10.8 survives the race: sum(delta) equals the cached balance');

-- ===========================================================================
-- C. Two concurrent spends that together exceed the balance
-- ===========================================================================
--
-- Balance 3, two simultaneous spends of 2. Each is individually affordable and
-- together they are not, so this is the case a naive "check, then deduct" gets
-- wrong in the most expensive way: both checks pass, both deduct, the balance
-- lands at -1 and two unlocks were sold for the price of one and a half.

create temporary table _t7c_partial on commit drop as
select * from public._t7c_race(array[
  public._t7c_spend_sql('a7c00000-0000-0000-0000-000000000002', 2, 'kc2-race-a'),
  public._t7c_spend_sql('a7c00000-0000-0000-0000-000000000002', 2, 'kc2-race-b')
]);

select is((select ok from _t7c_partial), 1,
  'two concurrent spends of 2 against a balance of 3: exactly one succeeds');

select is((select insufficient from _t7c_partial), 1,
  'and the other is refused — the second one re-reads 1, not the 3 it would have read without the lock');

select is((select results from _t7c_partial), '1',
  'the winner returned 1');

select is(
  public._t7c_int($$select credit_balance from public.profiles where id = 'a7c00000-0000-0000-0000-000000000002'$$),
  1, 'the balance is 1, never -1');

select is(
  public._t7c_int($$select count(*)::int from public.credit_ledger
                     where user_id = 'a7c00000-0000-0000-0000-000000000002' and delta < 0$$),
  1, 'with a single debit row behind it');

-- ===========================================================================
-- D. Concurrent retries of the SAME idempotency key
-- ===========================================================================
--
-- Five sessions send the identical operation at the same instant — the shape of
-- a client retrying a request whose response it never saw, or a webhook
-- delivered five times. None of them can see the others' uncommitted ledger
-- row, so the pre-lock idempotency check catches nobody: this is the path that
-- exercises the unique-index collision and the replay handler behind it.
--
-- All five must succeed, all five must return the same answer, and the ledger
-- must contain one row.

create temporary table _t7c_samekey on commit drop as
select * from public._t7c_race(
  (select array_agg(public._t7c_spend_sql('a7c00000-0000-0000-0000-000000000003', 1, 'kc3-retry'))
     from generate_series(1, 5) g));

select is((select ok from _t7c_samekey), 5,
  'all five concurrent retries of one idempotency key return successfully — a retry is not an error');

select is((select other from _t7c_samekey), 0,
  'none of them leaked a unique-violation to the caller: the collision is resolved into a replay inside the function');

select is((select results from _t7c_samekey), '4,4,4,4,4',
  'and all five return the SAME balance — the one the operation actually produced');

select is(
  public._t7c_int($$select count(*)::int from public.credit_ledger where idempotency_key = 'kc3-retry'$$),
  1, 'exactly one ledger row exists for the key');

select is(
  public._t7c_int($$select credit_balance from public.profiles where id = 'a7c00000-0000-0000-0000-000000000003'$$),
  4, 'and the user was charged once: 5 became 4, not 0');

-- Independence, under the same concurrency: five DIFFERENT keys against the
-- remaining 4 credits. Four must land and one must be refused.
create temporary table _t7c_distinct on commit drop as
select * from public._t7c_race(
  (select array_agg(public._t7c_spend_sql('a7c00000-0000-0000-0000-000000000003', 1,
                                          format('kc3-distinct-%s', g)))
     from generate_series(1, 5) g));

select is((select ok from _t7c_distinct), 4,
  'five concurrent spends under five DIFFERENT keys against 4 credits: four succeed, so distinct keys are genuinely independent');

select is((select insufficient from _t7c_distinct), 1,
  'and the fifth is refused for want of credits, not for want of a distinct key');

select is(
  public._t7c_int($$select credit_balance from public.profiles where id = 'a7c00000-0000-0000-0000-000000000003'$$),
  0, 'the balance is exactly 0');

select is(
  public._t7c_int($$select count(*)::int from public.credit_ledger
                     where user_id = 'a7c00000-0000-0000-0000-000000000003' and delta < 0$$),
  5, 'five debits in total: one from the retry storm and four from the distinct keys');

-- ===========================================================================
-- E. Cleanup, and the proof that the append-only guard came back
-- ===========================================================================

-- Before anything is disabled: the guard is doing its job right now, with rows
-- present for it to refuse.
select is(
  public._t7c_sqlstate($$delete from public.credit_ledger where user_id::text like 'a7c00000%'$$),
  '0A000',
  'AC10.5 before the cleanup: the append-only trigger refuses to let these rows be deleted, which is why the cleanup has to disable it');

-- One statement, so one transaction, so the ACCESS EXCLUSIVE lock the ALTER
-- takes covers the whole window in which the ledger is mutable.
select public._t7c_admin($$
  do $do$
  begin
    alter table public.credit_ledger disable trigger credit_ledger_append_only;
    delete from public.credit_ledger where user_id::text like 'a7c00000%';
    alter table public.credit_ledger enable trigger credit_ledger_append_only;
    delete from auth.users where id::text like 'a7c00000%';
  end
  $do$
$$);

select is(
  public._t7c_int($$select count(*)::int from public.credit_ledger where user_id::text like 'a7c00000%'$$),
  0, 'cleanup: this file committed rows and it removed every one of them — the local database is as it found it');

select is(
  public._t7c_int($$select count(*)::int from public.profiles where id::text like 'a7c00000%'$$),
  0, 'cleanup: and the profiles with them, which the ledger''s ON DELETE RESTRICT would have blocked had any row survived');

select is(
  public._t7c_int($$select count(*)::int from pg_trigger
                     where tgrelid = 'public.credit_ledger'::regclass
                       and not tgisinternal and tgenabled = 'O'$$),
  2, 'the two append-only triggers are enabled again');

-- The catalogue says the trigger is enabled. That is not the same as it firing,
-- and an empty table cannot tell the difference — a DELETE matching no rows
-- succeeds whether the guard is there or not. So one more row is created purely
-- to be refused, and then removed the same way.
select public._t7c_admin($$
  insert into auth.users (id, email)
    values ('a7c00000-0000-0000-0000-0000000000ff', 't7c-probe@example.test')
$$);

select public._t7c_admin($$
  do $do$
  begin
    perform public.grant_credits('a7c00000-0000-0000-0000-0000000000ff', 1,
                                 'signup_grant', null, null, 'kcff-probe');
  end
  $do$
$$);

select is(
  public._t7c_sqlstate($$delete from public.credit_ledger where idempotency_key = 'kcff-probe'$$),
  '0A000',
  'AC10.5 after the cleanup: a freshly written ledger row still cannot be deleted — the guard is not merely re-enabled in the catalogue, it fires');

select is(
  public._t7c_sqlstate($$update public.credit_ledger set delta = 99 where idempotency_key = 'kcff-probe'$$),
  '0A000',
  'and still cannot be updated');

select public._t7c_admin($$
  do $do$
  begin
    alter table public.credit_ledger disable trigger credit_ledger_append_only;
    delete from public.credit_ledger where user_id::text like 'a7c00000%';
    alter table public.credit_ledger enable trigger credit_ledger_append_only;
    delete from auth.users where id::text like 'a7c00000%';
  end
  $do$
$$);

select is(
  public._t7c_int($$select count(*)::int from public.credit_ledger$$),
  0, 'the probe row is gone too, and credit_ledger is empty — which is how db:reset left it');

select is(
  public._t7c_int($$select count(*)::int from pg_trigger
                     where tgrelid = 'public.credit_ledger'::regclass
                       and not tgisinternal and tgenabled = 'O'$$),
  2, 'with both guards enabled, as they were before this file ran');

select lives_ok(
  $$select extensions.dblink_disconnect('t7c_admin')$$,
  'the admin connection closes cleanly');

select * from finish();

rollback;
