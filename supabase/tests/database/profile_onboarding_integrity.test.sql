-- ===========================================================================
-- T11 findings F3, F4, F7 — profile / onboarding integrity
--
-- The property under test is not "the application refuses these writes". It is
-- that the DATABASE refuses them, from the role a browser actually holds, with
-- no application in the picture at all — because the findings were exactly that
-- a direct PostgREST call, an alternate client or a future API implementation
-- could write what `src/services/profile/` would not.
--
-- So the adversarial cases below run under `set local role authenticated` with
-- `request.jwt.claims` set, which is what PostgREST does per request. A test
-- that ran as the owner would prove nothing about any of these findings.
--
-- Every negative assertion names its mechanism (ADR-0016 decision 3): 42501 for
-- a missing column privilege, 23514 for a coherence violation.
-- ===========================================================================

begin;
select plan(22);

create extension if not exists pgtap with schema extensions;

\set alice '''f1100000-0000-0000-0000-000000000001'''
\set bob '''f1100000-0000-0000-0000-000000000002'''

insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at)
values
  (:alice::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'alice@t11.test', 'x', now(), now(), now()),
  (:bob::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'bob@t11.test', 'x', now(), now(), now());

-- 'US' is a seeded country with no live market (T08), so it is a real country
-- that genuinely contradicts the GB market rather than a fixture invented to
-- make the assertion pass.

create or replace function pg_temp.as_alice() returns void language plpgsql as $$
begin
  -- Claims first, then the role: PostgREST sets both per request, and a role
  -- switch before the claim would be setting it from the wrong identity.
  perform set_config('request.jwt.claims',
    json_build_object('sub', 'f1100000-0000-0000-0000-000000000001',
                      'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- A. F4 — onboarded_at is not writable by the role a browser holds
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from information_schema.column_privileges
    where table_schema = 'public' and table_name = 'profiles'
      and column_name = 'onboarded_at' and grantee = 'authenticated'
      and privilege_type = 'UPDATE'),
  0,
  'authenticated holds no UPDATE privilege on profiles.onboarded_at (F4)');

savepoint before_forged_stamp;
select pg_temp.as_alice();

select throws_ok(
  format($$update public.profiles set onboarded_at = now() where id = %L$$, :alice),
  '42501',
  null,
  'a signed-in client cannot stamp its own onboarded_at — 42501 from the column grant (F4)');

rollback to before_forged_stamp;

-- The same attempt bundled with a legitimate edit, which is how it would
-- actually arrive: one PostgREST PATCH carrying both keys.
savepoint before_bundled_stamp;
select pg_temp.as_alice();

select throws_ok(
  format($$update public.profiles set display_name = 'Alice', onboarded_at = now() where id = %L$$, :alice),
  '42501',
  null,
  'and cannot smuggle it alongside a column it may write (F4)');

rollback to before_bundled_stamp;

-- ---------------------------------------------------------------------------
-- B. F3 — an empty profile cannot become "onboarded"
-- ---------------------------------------------------------------------------
--
-- The stage-bypass this closes: `profileStage()` reads `onboarded_at`, so a
-- non-null value on a row with no market, no currency and no cost assumptions
-- meant "ready" — a user routed into the deal feed with no basis for a single
-- number in it.

update public.profiles set onboarded_at = now() where id = :alice::uuid;

select is(
  (select onboarded_at from public.profiles where id = :alice::uuid),
  null,
  'even the OWNER cannot mark an empty profile onboarded — the value is derived (F3)');

-- Partial progress is still not onboarded, one field at a time.
update public.profiles set country_code = 'GB' where id = :alice::uuid;
select is(
  (select onboarded_at from public.profiles where id = :alice::uuid),
  null,
  'a country alone is the waitlist state, not onboarding (F3, AC2.2)');

update public.profiles set default_market_id = (select id from public.markets where slug = 'gb-amazon-uk')
 where id = :alice::uuid;
select is(
  (select onboarded_at from public.profiles where id = :alice::uuid),
  null,
  'a market without cost assumptions is not onboarded (F3)');

update public.profiles set assumption_currency = 'GBP', default_budget_minor = 250000
 where id = :alice::uuid;
select is(
  (select onboarded_at from public.profiles where id = :alice::uuid),
  null,
  'a budget with no prep or shipping assumption is not onboarded (F3)');

-- ---------------------------------------------------------------------------
-- C. The positive case — a genuinely complete profile IS onboarded, with no
--    client ever naming the column.
-- ---------------------------------------------------------------------------

update public.profiles set
  prep_cost_per_unit_minor        = 45,
  inbound_shipping_per_unit_minor = 120
where id = :alice::uuid;

select isnt(
  (select onboarded_at from public.profiles where id = :alice::uuid),
  null,
  'completing the last assumption stamps onboarded_at with no writer naming it (F3)');

-- And the stamp does not drift on a later, unrelated edit: recorded first,
-- compared afterwards, so this is a real before/after rather than a tautology.
create temporary table stamp_before as
  select onboarded_at from public.profiles where id = :alice::uuid;

update public.profiles set display_name = 'Alice Again' where id = :alice::uuid;

select is(
  (select onboarded_at from public.profiles where id = :alice::uuid),
  (select onboarded_at from stamp_before),
  'an unrelated edit does not move the recorded completion time');

-- A tax-registered seller with no registration country has not answered AC2.1
-- step 2, and the tax treatment of every downstream profit figure depends on it.
savepoint before_tax_gap;
update public.profiles set tax_registered = true, tax_registration_country = null
 where id = :alice::uuid;
select is(
  (select onboarded_at from public.profiles where id = :alice::uuid),
  null,
  'declaring tax registration without a country un-onboards the profile (F3)');
rollback to before_tax_gap;

-- Dropping the currency while amounts remain is refused outright — it would
-- leave stored amounts denominated in nothing (§11.2).
savepoint before_orphan_currency;
select throws_ok(
  format($$update public.profiles set assumption_currency = null where id = %L$$, :alice),
  '23514',
  null,
  'the currency cannot be cleared out from under stored amounts (F7, §11.2)');
rollback to before_orphan_currency;

-- Clearing the cost basis properly takes "onboarded" away with it, in the same
-- write — the invariant holds in both directions, not just on the way in.
savepoint before_clear;
update public.profiles set default_budget_minor = null, prep_cost_per_unit_minor = null,
  inbound_shipping_per_unit_minor = null, assumption_currency = null
 where id = :alice::uuid;
select is(
  (select onboarded_at from public.profiles where id = :alice::uuid),
  null,
  'removing the cost basis removes the onboarded claim with it (F3)');
rollback to before_clear;

-- ---------------------------------------------------------------------------
-- D. F7 — country, market and currency may not contradict one another
-- ---------------------------------------------------------------------------

savepoint before_country_mismatch;
select pg_temp.as_alice();

select throws_ok(
  format($$update public.profiles set country_code = 'US' where id = %L$$, :alice),
  '23514',
  null,
  'a signed-in client cannot point country_code at a country its market does not operate in (F7)');

rollback to before_country_mismatch;

savepoint before_currency_mismatch;
select pg_temp.as_alice();

select throws_ok(
  format($$update public.profiles set assumption_currency = 'USD' where id = %L$$, :alice),
  '23514',
  null,
  'nor state a currency the selected market does not trade in (F7, §11.3)');

rollback to before_currency_mismatch;

-- The owner is refused for exactly the same reason: this is a storage-layer
-- invariant, not a client-role restriction.
select throws_ok(
  format($$update public.profiles set country_code = 'US' where id = %L$$, :alice),
  '23514',
  null,
  'and neither can the table owner — the invariant is in the database (F7)');

-- Setting a market without a country is the contradictory combination stated
-- the other way round.
savepoint before_marketless_country;
update public.profiles set country_code = null, default_market_id = null,
  assumption_currency = null, default_budget_minor = null,
  prep_cost_per_unit_minor = null, inbound_shipping_per_unit_minor = null
 where id = :bob::uuid;

select throws_ok(
  format($$update public.profiles
             set default_market_id = (select id from public.markets where slug = 'gb-amazon-uk')
           where id = %L$$, :bob),
  '23514',
  null,
  'a market with no country is refused rather than stored half-resolved (F7)');
rollback to before_marketless_country;

-- Money against a market with no currency named is refused, and the message
-- names the market's currency rather than leaving the caller to guess.
savepoint before_money_without_currency;
update public.profiles set
  country_code = 'GB',
  default_market_id = (select id from public.markets where slug = 'gb-amazon-uk')
 where id = :bob::uuid;

select throws_ok(
  format($$update public.profiles set default_budget_minor = 1000 where id = %L$$, :bob),
  '23514',
  null,
  'a cost assumption with no currency is refused at the storage layer (F7, §11.2)');
rollback to before_money_without_currency;

-- ---------------------------------------------------------------------------
-- E. The waitlist and fresh-signup states remain writable
-- ---------------------------------------------------------------------------
--
-- An invariant that also rejected valid states would be a different defect, so
-- both legitimate market-less states are asserted to still work.

savepoint before_waitlist;
select pg_temp.as_alice();

select lives_ok(
  format($$update public.profiles set country_code = null, default_market_id = null,
             assumption_currency = null, default_budget_minor = null,
             prep_cost_per_unit_minor = null, inbound_shipping_per_unit_minor = null
           where id = %L$$, :alice),
  'a profile may still be emptied back to the pre-onboarding state');

rollback to before_waitlist;

select lives_ok(
  format($$update public.profiles set country_code = 'US', default_market_id = null
           where id = %L$$, :bob),
  'a country with no live market is still storable — that is the waitlist (AC2.2)');

select is(
  (select onboarded_at from public.profiles where id = :bob::uuid),
  null,
  'and a waitlisted profile is not onboarded');

-- ---------------------------------------------------------------------------
-- F. The triggers exist, in the order the design depends on
-- ---------------------------------------------------------------------------

select is(
  (select string_agg(tgname, ',' order by tgname)
     from pg_trigger
    where tgrelid = 'public.profiles'::regclass and not tgisinternal),
  'profiles_coherence_before_write,profiles_onboarded_at_before_write,set_updated_at',
  'both integrity triggers exist, and coherence sorts before derivation so a refused row is never stamped');

select ok(
  (select bool_and(t.tgtype & 2 = 2)  -- BEFORE
     from pg_trigger t
    where t.tgrelid = 'public.profiles'::regclass
      and t.tgname in ('profiles_coherence_before_write', 'profiles_onboarded_at_before_write')),
  'both fire BEFORE the write, so nothing incoherent is ever stored even briefly');

select * from finish();
rollback;
