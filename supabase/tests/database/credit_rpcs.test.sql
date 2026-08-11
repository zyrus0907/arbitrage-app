-- T07 — Atomic credit RPC tests (pgTAP), run by `npm run db:test`.
--
-- Real concurrency lives in credit_rpcs_concurrency.test.sql, which cannot run
-- inside a rolled-back transaction because separate sessions cannot see one.
-- Everything provable in a single session is proved here.
--
-- Three ideas shape the assertions:
--
-- 1. THE LEDGER IS THE SOURCE OF TRUTH. Every balance claim is checked against
--    credit_ledger as well as profiles.credit_balance, because a function that
--    updated only the cache would pass a test that only read the cache.
--
-- 2. NEGATIVE ASSERTIONS NAME THEIR MECHANISM. Following the T06 suite:
--      42501  insufficient_privilege — the grant layer refused, before the body
--             ran. This is what anon and authenticated must produce.
--      23514  check_violation        — INSUFFICIENT_CREDITS.
--      22023  invalid_parameter_value— argument validation.
--      23505  unique_violation       — IDEMPOTENCY_KEY_CONFLICT.
--      23503  foreign_key_violation  — USER_NOT_FOUND.
--      0A000  feature_not_supported  — the append-only trigger.
--    "It didn't work" is never the assertion.
--
-- 3. A CAUGHT EXCEPTION ROLLS BACK ITS OWN STATEMENT. So "a failed spend wrote
--    no ledger row" is partly a property of Postgres, not of this code. Where
--    the ORDER of operations inside the function is what actually matters, it
--    is proved by a consequence that survives the rollback — see section F's
--    "a key burned by a failure is still usable afterwards".
--
-- pgTAP is created inside this transaction and rolled back with it.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog, pg_temp;

select plan(132);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
--
-- Same shape as the T06 suite: the role switch lives inside one function so the
-- pgTAP assertion itself always runs as the owner, and the role is reset on
-- both the success and the failure path.

create function public._t7_sqlstate(p_role text, p_sql text)
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

-- The message, so the stable tokens §6.5 and AC10.3 name by hand can be
-- asserted rather than assumed. A SQLSTATE proves the class of failure; the
-- token is the contract the API layer will match on.
create function public._t7_message(p_sql text)
returns text
language plpgsql
as $fn$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end;
$fn$;

create function public._t7_balance(p_user uuid)
returns integer
language sql
stable
as $fn$ select credit_balance from public.profiles where id = p_user $fn$;

create function public._t7_ledger_count(p_user uuid)
returns integer
language sql
stable
as $fn$ select count(*)::int from public.credit_ledger where user_id = p_user $fn$;

-- AC10.8's invariant, expressed once: the cache equals the ledger.
create function public._t7_reconciles(p_user uuid)
returns boolean
language sql
stable
as $fn$
  select coalesce((select sum(delta)::int from public.credit_ledger where user_id = p_user), 0)
       = (select credit_balance from public.profiles where id = p_user)
$fn$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
--
-- profiles rows arrive via handle_new_user, the T03 signup trigger, so the
-- fixture is the same shape the application produces. Balances are then set
-- through grant_credits rather than by UPDATE, so every fixture user starts
-- reconciled and the reconciliation assertions at the end are meaningful rather
-- than circular.

insert into auth.users (id, email) values
  ('a7000000-0000-0000-0000-000000000001', 't7-spender@example.test'),
  ('a7000000-0000-0000-0000-000000000002', 't7-broke@example.test'),
  ('a7000000-0000-0000-0000-000000000003', 't7-reversals@example.test'),
  ('a7000000-0000-0000-0000-000000000004', 't7-validation@example.test');

select is(
  (select count(*)::int from public.profiles
    where id in ('a7000000-0000-0000-0000-000000000001',
                 'a7000000-0000-0000-0000-000000000002',
                 'a7000000-0000-0000-0000-000000000003',
                 'a7000000-0000-0000-0000-000000000004')),
  4, 'fixture: four profiles exist, created by the signup trigger');

select is(
  (select count(*)::int from public.profiles
    where id::text like 'a7000000%' and credit_balance <> 0),
  0, 'fixture: every profile starts at zero — a signup grant is a ledger event, not a column default');

-- ===========================================================================
-- A. Security posture of the three functions
-- ===========================================================================

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('spend_credits', 'grant_credits')),
  2, 'T07 created spend_credits and grant_credits, and neither is overloaded');

select is(
  (select pg_get_function_identity_arguments(p.oid)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'spend_credits'),
  'p_user uuid, p_amount integer, p_reason credit_reason, p_ref_type text, p_ref_id uuid, p_idem text',
  'spend_credits has T07''s exact parameter list, with reason typed as the enum the ledger column uses');

select is(
  (select pg_get_function_identity_arguments(p.oid)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'grant_credits'),
  'p_user uuid, p_amount integer, p_reason credit_reason, p_ref_type text, p_ref_id uuid, p_idem text',
  'grant_credits mirrors it exactly');

select is(
  (select pg_get_function_result(p.oid)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'spend_credits'),
  'TABLE(new_balance integer, ledger_id uuid)',
  'spend_credits returns (new_balance, ledger_id) and nothing else');

select is(
  (select pg_get_function_result(p.oid)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'grant_credits'),
  'TABLE(new_balance integer, ledger_id uuid)',
  'grant_credits likewise');

select ok(
  (select bool_and(p.prosecdef) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('spend_credits', 'grant_credits')),
  'both RPCs are SECURITY DEFINER, as T07 requires');

select is(
  (select array_to_string(p.proconfig, ',') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'spend_credits'),
  'search_path=public, pg_temp',
  'spend_credits pins search_path to public, pg_temp — pg_temp last, so no caller can shadow a name');

select is(
  (select array_to_string(p.proconfig, ',') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'grant_credits'),
  'search_path=public, pg_temp',
  'grant_credits likewise');

select is(
  (select array_to_string(p.proconfig, ',') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'credit_ledger_idempotent_match'),
  'search_path=public, pg_temp',
  'and so does the private helper, even though it is SECURITY INVOKER');

select ok(
  not (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'credit_ledger_idempotent_match'),
  'the helper is SECURITY INVOKER — it needs no authority its callers lack, so it gets none');

select is(
  (select array_agg(p.provolatile::text order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('spend_credits', 'grant_credits')),
  array['v', 'v'],
  'both RPCs are VOLATILE — a STABLE credit function could be folded or skipped by the planner');

-- ===========================================================================
-- B. The privilege matrix (ADR-004, T07)
-- ===========================================================================

select is(
  (select array_to_string(p.proacl, ',') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'spend_credits'),
  'postgres=X/postgres,service_role=X/postgres',
  'spend_credits: the complete ACL is owner + service_role. Not "at least" — exactly.');

select is(
  (select array_to_string(p.proacl, ',') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'grant_credits'),
  'postgres=X/postgres,service_role=X/postgres',
  'grant_credits: the same');

select is(
  (select array_to_string(p.proacl, ',') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'credit_ledger_idempotent_match'),
  'postgres=X/postgres',
  'the helper is owner-only — not even service_role, which would otherwise be able to probe which idempotency keys exist');

-- An explicit ACL is what proves PUBLIC was revoked. A function whose proacl is
-- NULL has the default, and the default INCLUDES `PUBLIC=X`: null here would
-- mean anyone can mint credits. This is the single most important assertion in
-- the file.
select ok(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('spend_credits', 'grant_credits', 'credit_ledger_idempotent_match')
      and p.proacl is null) = 0,
  'no T07 function has a NULL proacl — a null ACL is the Postgres default, and the default grants EXECUTE to PUBLIC');

select ok(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('spend_credits', 'grant_credits', 'credit_ledger_idempotent_match')
      and array_to_string(p.proacl, ',') ~ '(^|,)=') = 0,
  'and no T07 function grants anything to PUBLIC (the empty grantee in an ACL entry)');

select ok(not has_function_privilege('anon',
  'public.spend_credits(uuid, integer, public.credit_reason, text, uuid, text)', 'EXECUTE'),
  'anon cannot execute spend_credits');

select ok(not has_function_privilege('anon',
  'public.grant_credits(uuid, integer, public.credit_reason, text, uuid, text)', 'EXECUTE'),
  'anon cannot execute grant_credits');

select ok(not has_function_privilege('authenticated',
  'public.spend_credits(uuid, integer, public.credit_reason, text, uuid, text)', 'EXECUTE'),
  'authenticated cannot execute spend_credits — the amount and the reason are server decisions');

select ok(not has_function_privilege('authenticated',
  'public.grant_credits(uuid, integer, public.credit_reason, text, uuid, text)', 'EXECUTE'),
  'authenticated cannot execute grant_credits — this one mints credits');

select ok(has_function_privilege('service_role',
  'public.spend_credits(uuid, integer, public.credit_reason, text, uuid, text)', 'EXECUTE'),
  'service_role CAN execute spend_credits — the intended caller');

select ok(has_function_privilege('service_role',
  'public.grant_credits(uuid, integer, public.credit_reason, text, uuid, text)', 'EXECUTE'),
  'service_role CAN execute grant_credits');

select ok(not has_function_privilege('service_role',
  'public.credit_ledger_idempotent_match(text, uuid, integer, public.credit_reason, text, uuid)', 'EXECUTE'),
  'service_role cannot execute the helper directly');

-- The sweep. Named functions can be checked one at a time; this catches the
-- function nobody remembered to check.
select is(
  (select count(*)::int
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname not like '\_t7\_%'
      and (p.proacl is null or array_to_string(p.proacl, ',') ~ '(^|,)(anon|authenticated)=')),
  0,
  'across all of public: no function is executable by anon or authenticated, and none has been left on the PUBLIC-granting default');

-- ===========================================================================
-- C. anon and authenticated are refused at the PRIVILEGE layer (T07 (d), (e))
-- ===========================================================================
--
-- T07: "Tests (d) and (e) must assert a privilege failure, not merely an absent
-- result." A SECURITY DEFINER function that returned nothing would look
-- identical from the client; 42501 means the body never ran.

select is(
  public._t7_sqlstate('authenticated',
    $$select * from public.spend_credits('a7000000-0000-0000-0000-000000000001', 1,
        'unlock_deal', 'deal', 'd7000000-0000-0000-0000-000000000001', 'k-auth-spend')$$),
  '42501',
  'authenticated calling spend_credits is refused with insufficient_privilege, not an empty result');

select is(
  public._t7_sqlstate('authenticated',
    $$select * from public.grant_credits('a7000000-0000-0000-0000-000000000001', 100,
        'promo', null, null, 'k-auth-grant')$$),
  '42501',
  'authenticated calling grant_credits likewise');

select is(
  public._t7_sqlstate('anon',
    $$select * from public.spend_credits('a7000000-0000-0000-0000-000000000001', 1,
        'unlock_deal', 'deal', 'd7000000-0000-0000-0000-000000000001', 'k-anon-spend')$$),
  '42501',
  'anon calling spend_credits likewise');

select is(
  public._t7_sqlstate('anon',
    $$select * from public.grant_credits('a7000000-0000-0000-0000-000000000001', 100,
        'promo', null, null, 'k-anon-grant')$$),
  '42501',
  'anon calling grant_credits likewise');

select is(
  public._t7_sqlstate('authenticated',
    $$select public.credit_ledger_idempotent_match('k-auth-grant',
        'a7000000-0000-0000-0000-000000000001', 1, 'promo', null, null)$$),
  '42501',
  'and the helper is unreachable from authenticated too');

select is(
  public._t7_ledger_count('a7000000-0000-0000-0000-000000000001'), 0,
  'four refused client calls wrote no ledger row between them');

select is(
  (select count(*)::int from public.credit_ledger where idempotency_key like 'k-auth-%' or idempotency_key like 'k-anon-%'),
  0, 'and consumed none of the idempotency keys they carried');

-- ===========================================================================
-- D. A successful spend
-- ===========================================================================

select is(
  (select new_balance from public.grant_credits(
     'a7000000-0000-0000-0000-000000000001', 5, 'signup_grant', null, null, 'k1-signup')),
  5, 'AC10.6: a signup grant of 5 credits returns the new balance');

select is(public._t7_balance('a7000000-0000-0000-0000-000000000001'), 5,
  'and profiles.credit_balance now reads 5');

-- The spend under test. Captured into a temp table so the same single call can
-- be interrogated from several angles — calling the function again would be a
-- different operation.
create temporary table _t7_spend1 on commit drop as
select * from public.spend_credits(
  'a7000000-0000-0000-0000-000000000001', 2, 'unlock_deal',
  'deal', 'd7000000-0000-0000-0000-000000000001', 'k1-spend-2');

select is((select new_balance from _t7_spend1), 3,
  'spending 2 of 5 returns a new balance of 3');

select is(public._t7_balance('a7000000-0000-0000-0000-000000000001'), 3,
  'and profiles.credit_balance was reduced by exactly the amount spent');

select is(
  (select count(*)::int from public.credit_ledger
    where user_id = 'a7000000-0000-0000-0000-000000000001' and idempotency_key = 'k1-spend-2'),
  1, 'exactly one ledger row was written for the spend');

select is(
  (select l.delta from public.credit_ledger l join _t7_spend1 s on s.ledger_id = l.id),
  -2, 'the delta is negative: p_amount is positive and the direction is the function''s decision, not the caller''s');

select is(
  (select l.balance_after from public.credit_ledger l join _t7_spend1 s on s.ledger_id = l.id),
  3, 'balance_after on the ledger row equals the balance the call returned');

select is(
  (select l.balance_after from public.credit_ledger l join _t7_spend1 s on s.ledger_id = l.id),
  public._t7_balance('a7000000-0000-0000-0000-000000000001'),
  'and equals the cached balance on the profile — the two are written from one computed value');

select is(
  (select l.reason::text from public.credit_ledger l join _t7_spend1 s on s.ledger_id = l.id),
  'unlock_deal', 'the reason is recorded as passed');

select is(
  (select l.ref_type || '/' || l.ref_id::text from public.credit_ledger l join _t7_spend1 s on s.ledger_id = l.id),
  'deal/d7000000-0000-0000-0000-000000000001', 'and so is the reference');

select ok(public._t7_reconciles('a7000000-0000-0000-0000-000000000001'),
  'AC10.8 holds after the first spend: sum(delta) equals credit_balance');

-- ===========================================================================
-- E. Argument validation — every rejection before a lock or a write
-- ===========================================================================
--
-- Each one asserts the SQLSTATE, and the section closes by asserting that the
-- whole batch moved neither the balance nor the ledger.

select is(public._t7_balance('a7000000-0000-0000-0000-000000000004'), 0,
  'the validation fixture starts at zero credits');

select is(
  (select new_balance from public.grant_credits(
     'a7000000-0000-0000-0000-000000000004', 10, 'signup_grant', null, null, 'k4-signup')),
  10, 'and is granted 10 so that every rejection below fails for its stated reason, not for want of funds');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000004', 0, 'unlock_deal', null, null, 'k4-zero')$$),
  '22023', 'a zero spend is rejected: it is a no-op that would burn an idempotency key');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000004', -3, 'unlock_deal', null, null, 'k4-negative')$$),
  '22023', 'a negative spend is rejected: that is a grant, and grants are the function that may go below zero');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000004', null, 'unlock_deal', null, null, 'k4-null-amount')$$),
  '22023', 'a null amount is rejected explicitly rather than falling through a null comparison');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000004', 1, 'unlock_deal', null, null, null)$$),
  '22023', 'a null idempotency key is rejected');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000004', 1, 'unlock_deal', null, null, '   ')$$),
  '22023', 'a blank idempotency key is rejected — the column is unique, so every blank key would collide with every other');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    null, 1, 'unlock_deal', null, null, 'k4-null-user')$$),
  '22023', 'a null user is rejected');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000004', 1, 'purchase', null, null, 'k4-wrong-reason')$$),
  '22023', 'spend_credits refuses a grant reason: purchase is not consumption');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000004', 1, 'chargeback', null, null, 'k4-chargeback')$$),
  '22023',
  'and refuses chargeback in particular — there it would meet the balance guard, which is the opposite of AC17.5');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000004', 1, 'unlock_deal', '', 'd7000000-0000-0000-0000-000000000001', 'k4-blank-ref')$$),
  '22023', 'a blank ref_type is rejected rather than silently normalised to null');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000004', 1, 'unlock_deal', 'deal', null, 'k4-half-ref-a')$$),
  '22023', 'a ref_type with no ref_id is rejected — it points at nothing');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000004', 1, 'unlock_deal', null, 'd7000000-0000-0000-0000-000000000001', 'k4-half-ref-b')$$),
  '22023', 'a ref_id with no ref_type is rejected — it points at an unknown table');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7999999-9999-9999-9999-999999999999', 1, 'unlock_deal', null, null, 'k4-no-user')$$),
  '23503', 'an unknown user is refused with the foreign-key code the ledger insert would have raised');

select is(
  public._t7_sqlstate('postgres', $$select * from public.grant_credits(
    'a7000000-0000-0000-0000-000000000004', 0, 'promo', null, null, 'k4-grant-zero')$$),
  '22023', 'a zero grant is rejected too — credit_ledger_delta_non_zero would reject it anyway');

select is(
  public._t7_sqlstate('postgres', $$select * from public.grant_credits(
    'a7000000-0000-0000-0000-000000000004', 1, 'unlock_deal', null, null, 'k4-grant-consumption')$$),
  '22023',
  'grant_credits refuses a consumption reason — routing a spend through it would bypass the balance check entirely');

select is(public._t7_balance('a7000000-0000-0000-0000-000000000004'), 10,
  'after every rejected call above, the balance is untouched');

select is(public._t7_ledger_count('a7000000-0000-0000-0000-000000000004'), 1,
  'and the only ledger row is the signup grant that set the balance up');

select ok(public._t7_reconciles('a7000000-0000-0000-0000-000000000004'),
  'and the user still reconciles');

-- ===========================================================================
-- F. Insufficient credits, and no partial state (AC10.3)
-- ===========================================================================

select is(
  (select new_balance from public.grant_credits(
     'a7000000-0000-0000-0000-000000000002', 1, 'signup_grant', null, null, 'k2-signup')),
  1, 'the broke fixture is given exactly 1 credit');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000002', 2, 'unlock_deal', null, null, 'k2-too-much')$$),
  '23514', 'spending 2 with a balance of 1 raises check_violation');

select matches(
  public._t7_message($$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000002', 2, 'unlock_deal', null, null, 'k2-too-much-msg')$$),
  '^INSUFFICIENT_CREDITS: balance 1, requested 2$',
  'and the message leads with the token §6.5 and AC10.3 name, followed by both numbers');

select is(public._t7_balance('a7000000-0000-0000-0000-000000000002'), 1,
  'the balance is unchanged by the refusal');

select is(public._t7_ledger_count('a7000000-0000-0000-0000-000000000002'), 1,
  'and no ledger row was written — only the signup grant is there');

-- The ordering proof. If the ledger insert had happened before the balance
-- check, the key would still be free after the statement rolled back — so this
-- is not proof on its own. What it does prove is the property that matters to a
-- caller: a refused spend leaves the key usable, so a retry after a top-up is a
-- normal first attempt rather than a conflict.
select is(
  (select new_balance from public.spend_credits(
     'a7000000-0000-0000-0000-000000000002', 1, 'unlock_deal', null, null, 'k2-too-much')),
  0, 'the key from the refused spend is not burned: reusing it for a spend that fits succeeds');

select is(public._t7_balance('a7000000-0000-0000-0000-000000000002'), 0,
  'spending the last credit takes the balance to exactly zero');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000002', 1, 'unlock_deal', null, null, 'k2-from-zero')$$),
  '23514', 'and a further spend from zero is refused — ordinary spend can never make a balance negative');

select ok(public._t7_reconciles('a7000000-0000-0000-0000-000000000002'),
  'the broke user reconciles at zero');

-- ===========================================================================
-- G. Idempotency
-- ===========================================================================

create temporary table _t7_replay on commit drop as
select * from public.spend_credits(
  'a7000000-0000-0000-0000-000000000001', 2, 'unlock_deal',
  'deal', 'd7000000-0000-0000-0000-000000000001', 'k1-spend-2');

select is((select new_balance from _t7_replay), 3,
  'replaying the same key with the same arguments returns the PRIOR balance, not the current one');

select is(
  (select r.ledger_id from _t7_replay r), (select s.ledger_id from _t7_spend1 s),
  'and the prior ledger id — the replay is byte-identical to the original result');

select is(
  (select count(*)::int from public.credit_ledger where idempotency_key = 'k1-spend-2'),
  1, 'still exactly one ledger row: the same key did not charge twice');

select is(public._t7_balance('a7000000-0000-0000-0000-000000000001'), 3,
  'and the balance did not move on the replay');

-- Determinism over time: the replay's answer must not drift as the account
-- carries on being used. A later unrelated spend changes the balance; the
-- replay of the earlier operation must still describe the earlier operation.
select is(
  (select new_balance from public.spend_credits(
     'a7000000-0000-0000-0000-000000000001', 1, 'barcode_lookup',
     'barcode_lookup', 'b7000000-0000-0000-0000-000000000001', 'k1-barcode')),
  2, 'a second, independent key spends independently — 3 becomes 2');

select is(
  (select new_balance from public.spend_credits(
     'a7000000-0000-0000-0000-000000000001', 2, 'unlock_deal',
     'deal', 'd7000000-0000-0000-0000-000000000001', 'k1-spend-2')),
  3, 'and replaying the FIRST key still returns 3 — the recorded result, not the live balance');

select is(public._t7_balance('a7000000-0000-0000-0000-000000000001'), 2,
  'while the live balance remains 2, untouched by the replay');

select is(
  (select count(*)::int from public.credit_ledger where user_id = 'a7000000-0000-0000-0000-000000000001'),
  3, 'three ledger rows for three real operations, across five calls');

-- Conflicting reuse. Each dimension of identity is tried separately, because a
-- comparison that omitted one of them would still pass a test that only varied
-- another.
select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000001', 3, 'unlock_deal',
    'deal', 'd7000000-0000-0000-0000-000000000001', 'k1-spend-2')$$),
  '23505', 'reusing a key with a different AMOUNT is a conflict, not a replay');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000001', 2, 'barcode_lookup',
    'deal', 'd7000000-0000-0000-0000-000000000001', 'k1-spend-2')$$),
  '23505', 'a different REASON is a conflict');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000001', 2, 'unlock_deal',
    'deal', 'd7000000-0000-0000-0000-000000000002', 'k1-spend-2')$$),
  '23505', 'a different REF_ID is a conflict');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000001', 2, 'unlock_deal',
    'deal_unlock', 'd7000000-0000-0000-0000-000000000001', 'k1-spend-2')$$),
  '23505', 'a different REF_TYPE is a conflict');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000003', 2, 'unlock_deal',
    'deal', 'd7000000-0000-0000-0000-000000000001', 'k1-spend-2')$$),
  '23505', 'a different USER is a conflict — an idempotency key is not a global "already done" flag');

select is(
  public._t7_sqlstate('postgres', $$select * from public.grant_credits(
    'a7000000-0000-0000-0000-000000000001', 2, 'refund',
    'deal', 'd7000000-0000-0000-0000-000000000001', 'k1-spend-2')$$),
  '23505',
  'and a spend key reused for a grant is a conflict — the sign differs, so the two can never be the same operation');

select matches(
  public._t7_message($$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000001', 9, 'unlock_deal',
    'deal', 'd7000000-0000-0000-0000-000000000001', 'k1-spend-2')$$),
  '^IDEMPOTENCY_KEY_CONFLICT: ',
  'the conflict message leads with its own stable token, distinct from a plain unique violation');

select is(
  (select count(*)::int from public.credit_ledger where user_id = 'a7000000-0000-0000-0000-000000000001'),
  3, 'seven conflicting calls later, there are still three ledger rows');

select is(public._t7_balance('a7000000-0000-0000-0000-000000000001'), 2,
  'and the balance is still 2');

select ok(public._t7_reconciles('a7000000-0000-0000-0000-000000000001'),
  'the spender reconciles');

-- ===========================================================================
-- H. grant_credits: direction per reason, and the negative balance it must allow
-- ===========================================================================

select is(
  (select new_balance from public.grant_credits(
     'a7000000-0000-0000-0000-000000000003', 5, 'purchase',
     'credit_purchase', 'c7000000-0000-0000-0000-000000000001', 'k3-purchase')),
  5, 'a purchase grants credits');

select is(
  (select new_balance from public.grant_credits(
     'a7000000-0000-0000-0000-000000000003', 1, 'refund',
     'deal', 'd7000000-0000-0000-0000-000000000001', 'k3-refund')),
  6, 'AC15.4: a refund is a POSITIVE restoration after our own error');

select is(
  public._t7_sqlstate('postgres', $$select * from public.grant_credits(
    'a7000000-0000-0000-0000-000000000003', -1, 'refund', null, null, 'k3-bad-refund')$$),
  '22023', 'a negative refund is refused at the function');

-- ...and would be refused by the table too, so the function is not the only
-- thing standing between a reversed sign and the ledger. Inserted as owner,
-- which is the most privileged writer there is.
select throws_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a7000000-0000-0000-0000-000000000003', -1, 'refund', 5, 'k3-direct-bad-refund')$$,
  '23514',
  null,
  'and credit_ledger_reversal_direction refuses it independently — T07 did not become the only guard');

select throws_ok(
  $$insert into public.credit_ledger (user_id, delta, reason, balance_after, idempotency_key)
    values ('a7000000-0000-0000-0000-000000000003', 1, 'chargeback', 7, 'k3-direct-bad-cb')$$,
  '23514',
  null,
  'nor is a positive chargeback accepted by the table');

select is(
  public._t7_sqlstate('postgres', $$select * from public.grant_credits(
    'a7000000-0000-0000-0000-000000000003', 1, 'chargeback', null, null, 'k3-bad-chargeback')$$),
  '22023', 'a positive chargeback is refused at the function: AC17.5 fixes it as a clawback');

select is(
  public._t7_sqlstate('postgres', $$select * from public.grant_credits(
    'a7000000-0000-0000-0000-000000000003', -1, 'signup_grant', null, null, 'k3-bad-signup')$$),
  '22023', 'a negative signup_grant is refused — T05 left this reason unconstrained at the table, so the writer constrains it');

select is(
  public._t7_sqlstate('postgres', $$select * from public.grant_credits(
    'a7000000-0000-0000-0000-000000000003', -1, 'promo', null, null, 'k3-bad-promo')$$),
  '22023', 'and so is a negative promo');

-- AC17.5, the case the whole two-function split exists for.
select is(
  (select new_balance from public.grant_credits(
     'a7000000-0000-0000-0000-000000000003', -10, 'chargeback',
     'credit_purchase', 'c7000000-0000-0000-0000-000000000001', 'k3-chargeback')),
  -4, 'AC17.5: a chargeback of 10 against a balance of 6 leaves MINUS 4 — history is not erased to make the number tidy');

select is(public._t7_balance('a7000000-0000-0000-0000-000000000003'), -4,
  'and the cached balance is negative too, in step with the ledger');

select is(
  (select balance_after from public.credit_ledger where idempotency_key = 'k3-chargeback'),
  -4, 'the ledger row records the negative balance_after');

select is(
  public._t7_sqlstate('postgres', $$select * from public.spend_credits(
    'a7000000-0000-0000-0000-000000000003', 1, 'unlock_deal', null, null, 'k3-spend-negative')$$),
  '23514', '§9.2: spending is BLOCKED at a negative balance rather than the history being rewritten');

select is(
  (select new_balance from public.grant_credits(
     'a7000000-0000-0000-0000-000000000003', -10, 'chargeback',
     'credit_purchase', 'c7000000-0000-0000-0000-000000000001', 'k3-chargeback')),
  -4, 'the chargeback is idempotent: replaying the webhook key returns the prior result');

select is(public._t7_balance('a7000000-0000-0000-0000-000000000003'), -4,
  'and does not deduct twice');

select is(
  (select new_balance from public.grant_credits(
     'a7000000-0000-0000-0000-000000000003', 1, 'refund',
     'deal', 'd7000000-0000-0000-0000-000000000001', 'k3-refund')),
  6, 'the refund replays its own prior result too, unaffected by the chargeback that came after it');

select is(
  (select new_balance from public.grant_credits(
     'a7000000-0000-0000-0000-000000000003', 4, 'admin_adjust', null, null, 'k3-admin-up')),
  0, 'admin_adjust is signed by definition: +4 brings the balance back to zero');

select is(
  (select new_balance from public.grant_credits(
     'a7000000-0000-0000-0000-000000000003', -2, 'admin_adjust', null, null, 'k3-admin-down')),
  -2, 'and -2 takes it below zero again, which only grant_credits may do');

select ok(public._t7_reconciles('a7000000-0000-0000-0000-000000000003'),
  'the reversals user reconciles at a negative balance');

select is(
  (select count(*)::int from public.credit_ledger where user_id = 'a7000000-0000-0000-0000-000000000003'),
  5, 'five real movements for that user — purchase, refund, chargeback and two admin_adjusts — and nothing from the rejected calls or the replays');

-- ===========================================================================
-- I. T05 and T06 are unchanged by T07
-- ===========================================================================

select is(
  (select count(*)::int from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'credit_ledger' and grantee = 'service_role'
      and privilege_type in ('UPDATE', 'DELETE')),
  0, 'T05''s narrowing survives: service_role still holds no UPDATE or DELETE on credit_ledger');

select is(
  (select string_agg(privilege_type, ',' order by privilege_type)
     from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'credit_ledger' and grantee = 'service_role'),
  'INSERT,SELECT', 'and holds exactly INSERT and SELECT, as T05 left it');

select is(
  public._t7_sqlstate('service_role',
    $$update public.credit_ledger set delta = 0 where idempotency_key = 'k1-spend-2'$$),
  '42501', 'service_role updating the ledger is refused at the grant layer');

select is(
  public._t7_sqlstate('service_role',
    $$delete from public.credit_ledger where idempotency_key = 'k1-spend-2'$$),
  '42501', 'and deleting likewise');

select throws_ok(
  $$update public.credit_ledger set delta = 0 where idempotency_key = 'k1-spend-2'$$,
  '0A000', null,
  'AC10.5: even the owner cannot update a ledger row — the append-only trigger is layer two and T07 did not touch it');

select throws_ok(
  $$delete from public.credit_ledger where idempotency_key = 'k1-spend-2'$$,
  '0A000', null,
  'nor delete one');

select is(
  (select count(*)::int from pg_trigger
    where tgrelid = 'public.credit_ledger'::regclass and not tgisinternal),
  2, 'credit_ledger still carries exactly its two guards — the row-level one and the TRUNCATE one. T07 added none.');

select is(
  (select count(*)::int from pg_trigger
    where tgrelid = 'public.credit_ledger'::regclass and not tgisinternal and tgenabled <> 'O'),
  0, 'and both are enabled');

select is(
  public._t7_sqlstate('authenticated',
    $$update public.profiles set credit_balance = 1000 where id = 'a7000000-0000-0000-0000-000000000001'$$),
  '42501',
  'T06''s column grant holds: authenticated cannot write credit_balance, so the RPC is not competing with a client path');

-- SELECT is expected and wanted: a user reads their own balance through the
-- whole-table select grant. What must not exist is any WRITE privilege on this
-- one column, which is the distinction T06's enumerated column grant draws.
select is(
  (select count(*)::int from information_schema.column_privileges
    where table_schema = 'public' and table_name = 'profiles'
      and column_name = 'credit_balance'
      and grantee in ('anon', 'authenticated')
      and privilege_type <> 'SELECT'),
  0, 'neither client role holds any write privilege on the profiles.credit_balance column');

select is(
  (select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'credit_ledger'),
  1, 'credit_ledger still has exactly one policy — the T06 select-own. T07 added no write policy.');

select is(
  (select count(*)::int from pg_policies where schemaname = 'public'),
  19, 'the total policy count across public is unchanged from T06');

-- ===========================================================================
-- J. The ledger is the source of truth, not the activity tables (ADR-0013)
-- ===========================================================================
--
-- The scenario decision 3 warns about, run for real: a user inserts an unlock
-- row claiming a credit was spent. Nothing about the ledger or the balance
-- moves, because the RPC never consults that table.

-- The smallest chain that reaches an activity table: one country, one
-- marketplace, one market. barcode_lookups is used rather than deal_unlocks
-- because a deal row needs the whole Schema B chain and the point being made is
-- identical for both tables.
insert into public.countries (code, name, default_currency, default_locale,
                              tax_regime, retail_price_display, timezone_default)
  values ('ZZ', 'Testland', 'GBP', 'en-ZZ', 'vat', 'inclusive', 'Europe/London');

insert into public.marketplaces (id, provider, code, country_code, currency, domain, adapter_key)
  values ('e7000000-0000-0000-0000-000000000001', 'test', 'T7_TEST', 'ZZ', 'GBP',
          'example.test', 'test.v1');

insert into public.markets (id, slug, source_country_code, marketplace_id, currency)
  values ('f7000000-0000-0000-0000-000000000001', 't7-market', 'ZZ',
          'e7000000-0000-0000-0000-000000000001', 'GBP');

select is(
  (select count(*)::int from public.credit_ledger
    where user_id = 'a7000000-0000-0000-0000-000000000001'),
  3, 'the spender has three ledger rows before the forged activity row');

select lives_ok(
  $$insert into public.barcode_lookups (user_id, market_id, barcode_raw, credits_spent)
    values ('a7000000-0000-0000-0000-000000000001', 'f7000000-0000-0000-0000-000000000001',
            '5000000000000', 1)$$,
  'an activity row claiming a credit was spent can be written with no ledger row behind it — the owner can, and per ADR-0013 so can authenticated');

select is(
  (select count(*)::int from public.credit_ledger
    where user_id = 'a7000000-0000-0000-0000-000000000001'),
  3, 'and it created no ledger row: an activity row is not a financial record');

select is(public._t7_balance('a7000000-0000-0000-0000-000000000001'), 2,
  'nor did it move the balance');

select ok(public._t7_reconciles('a7000000-0000-0000-0000-000000000001'),
  'and the user still reconciles — the forged row is invisible to the accounting');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('spend_credits', 'grant_credits', 'credit_ledger_idempotent_match')
      and (p.prosrc ~ 'deal_unlocks' or p.prosrc ~ 'barcode_lookups')),
  0, 'and no T07 function so much as mentions deal_unlocks or barcode_lookups');

-- ===========================================================================
-- K. Reconciliation across every fixture, after everything above
-- ===========================================================================
--
-- Note on "the latest balance_after": created_at defaults to now(), which is
-- the TRANSACTION timestamp, so every row written in this test file shares one
-- value and `order by created_at desc limit 1` picks an arbitrary row. The
-- durable invariant is AC10.8's — sum(delta) equals the cached balance — and
-- the per-operation form is checked against the ledger id the call returned
-- (section D). A nightly reconciliation must use the sum, not the ordering.

select is(
  (select count(*)::int
     from public.profiles p
    where p.id::text like 'a7000000%'
      and p.credit_balance is distinct from coalesce(
        (select sum(l.delta)::int from public.credit_ledger l where l.user_id = p.id), 0)),
  0, 'AC10.8: for every fixture user, sum(ledger delta) equals profiles.credit_balance');

-- The per-operation form of the same invariant, pinned to the last successful
-- movement for each fixture user by its idempotency key rather than by an
-- ordering the transaction timestamp cannot provide.
select is(
  (select count(*)::int from public.credit_ledger l
     join public.profiles p on p.id = l.user_id
    where l.idempotency_key in ('k1-barcode', 'k2-too-much', 'k3-admin-down', 'k4-signup')
      and l.balance_after = p.credit_balance),
  4, 'and for each of the four, the balance_after of its last movement equals the profile balance today');

select is(
  (select count(*)::int from public.credit_ledger where user_id::text like 'a7000000%' and delta = 0),
  0, 'no zero-delta row reached the ledger');

select is(
  (select count(*)::int from public.credit_ledger
    where user_id::text like 'a7000000%' and (btrim(idempotency_key) = '' or idempotency_key is null)),
  0, 'and no blank idempotency key did either');

select is(
  (select count(distinct idempotency_key)::int from public.credit_ledger where user_id::text like 'a7000000%'),
  (select count(*)::int from public.credit_ledger where user_id::text like 'a7000000%'),
  'every ledger row this file created carries a distinct key — no key was consumed twice');

select * from finish();

rollback;
