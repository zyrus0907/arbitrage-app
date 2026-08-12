-- ===========================================================================
-- T10 — account deletion by pseudonymisation (ADR-0017)
--
-- The three constraints T10 requires be satisfied SIMULTANEOUSLY are the spine
-- of this file, and each is asserted directly rather than inferred:
--
--   1. the user's personal data is gone,
--   2. the financial history still sums to the same totals per currency,
--   3. no retained row can be traced back to a person through this database.
--
-- Plus the two operational properties the mechanism lives or dies by: it is
-- idempotent, and it does not touch anybody else.
--
-- Every negative assertion names the mechanism it expects — a privilege error,
-- a check constraint, or the guard trigger — following the rule T09 established
-- (ADR-0016 decision 3): a test that merely asserts "it failed" keeps passing
-- when it starts failing for a different reason.
-- ===========================================================================

begin;
select plan(64);

create extension if not exists pgtap with schema extensions;

-- ---------------------------------------------------------------------------
-- Fixtures — two users, so "unrelated users are unaffected" has something real
-- to be unaffected. Ids are stable and namespaced so a failed run is traceable.
-- ---------------------------------------------------------------------------

\set subject '''d1000000-0000-0000-0000-000000000001'''
\set bystander '''d1000000-0000-0000-0000-000000000002'''

insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at)
values
  (:subject::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'subject@t10.test', 'x', now(), now(), now()),
  (:bystander::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'bystander@t10.test', 'x', now(), now(), now());

-- The profile rows are created by handle_new_user. Fill them the way onboarding
-- would, so the scrub has something real to remove.
update public.profiles set
  display_name                    = 'Subject Person',
  country_code                    = 'GB',
  default_market_id               = (select id from public.markets where slug = 'gb-amazon-uk'),
  locale                          = 'en-GB',
  timezone                        = 'Europe/London',
  tax_registered                  = true,
  tax_registration_country        = 'GB',
  tax_scheme                      = 'simplified',
  default_fulfilment              = 'seller_fulfilled',
  default_budget_minor            = 250000,
  prep_cost_per_unit_minor        = 45,
  inbound_shipping_per_unit_minor = 120,
  assumption_currency             = 'GBP',
  onboarded_at                    = now()
where id = :subject::uuid;

update public.profiles set
  display_name = 'Bystander', country_code = 'GB', locale = 'en-GB',
  assumption_currency = 'GBP', default_budget_minor = 100000, onboarded_at = now()
where id = :bystander::uuid;

-- Financial history for both. grant_credits is the only sanctioned writer.
select public.grant_credits(:subject::uuid,  5, 'signup_grant', null, null, 'del-sub-signup');
select public.grant_credits(:subject::uuid, 20, 'purchase',     null, null, 'del-sub-purchase');
select public.grant_credits(:subject::uuid, -3, 'chargeback',   null, null, 'del-sub-chargeback');
select public.grant_credits(:bystander::uuid, 5, 'signup_grant', null, null, 'del-bys-signup');

insert into public.credit_purchases (user_id, credit_pack_id, credits, amount_minor, currency, status)
values (:subject::uuid,   (select id from public.credit_packs order by credits limit 1), 20, 1999, 'GBP', 'paid'),
       (:bystander::uuid, (select id from public.credit_packs order by credits limit 1),  5,  499, 'GBP', 'paid');

-- Personal activity rows. Several reference a deal, so one is built from the
-- seeded launch market — including the denormalised parent keys ADR-0008's
-- composite foreign keys require, which is why this is more than three columns.
insert into public.retailer_products (id, retailer_id, retailer_sku, title, price_minor,
                                      currency, price_tax_treatment, gtin14, gtin_raw, gtin_format)
values ('d2000000-0000-0000-0000-000000000001',
        (select r.id from public.retailers r
           join public.markets m on m.id = r.market_id
          where m.slug = 'gb-amazon-uk' limit 1),
        'T10-SKU-1', 'Fixture product', 1000, 'GBP', 'inclusive',
        '00012345678905', '012345678905', 'upc_a');

insert into public.marketplace_products (id, marketplace_id, external_id, provider_key, title, gtins, currency)
values ('d3000000-0000-0000-0000-000000000001',
        (select marketplace_id from public.markets where slug = 'gb-amazon-uk'),
        'T10EXT0001', 'keepa', 'Fixture listing', array['00012345678905'], 'GBP');

insert into public.deals (
  id, market_id, retailer_id, marketplace_id, retailer_product_id, marketplace_product_id,
  match_confidence, currency, buy_price_minor, buy_price_tax_treatment, sell_price_minor,
  fee_schedule_id, tax_schedule_id, net_profit_minor, roi_bps, margin_bps, deal_score,
  demand_band, competition_band, stability_band, confidence_band,
  score_breakdown, calc_version, score_version, inputs_snapshot, computed_at)
select 'd4000000-0000-0000-0000-000000000001',
       m.id,
       (select r.id from public.retailers r where r.market_id = m.id limit 1),
       m.marketplace_id,
       'd2000000-0000-0000-0000-000000000001',
       'd3000000-0000-0000-0000-000000000001',
       1.0, 'GBP', 1000, 'inclusive', 2000,
       (select f.id from public.fee_schedules f
         where f.marketplace_id = m.id_marketplace order by f.effective_from desc limit 1),
       (select t.id from public.tax_schedules t
         where t.country_code = m.source_country_code order by t.effective_from desc limit 1),
       500, 5000, 2500, 70,
       'medium', 'medium', 'medium', 'medium',
       '{}'::jsonb, 't10', 't10', '{}'::jsonb, now()
from (select mk.id, mk.marketplace_id as id_marketplace, mk.marketplace_id, mk.source_country_code
        from public.markets mk where mk.slug = 'gb-amazon-uk') m;

insert into public.deal_unlocks (user_id, deal_id, credits_spent)
values (:subject::uuid, 'd4000000-0000-0000-0000-000000000001', 1),
       (:bystander::uuid, 'd4000000-0000-0000-0000-000000000001', 1);

insert into public.watchlist_items (user_id, deal_id, marketplace_product_id, target_profit_minor, currency, note)
values (:subject::uuid, 'd4000000-0000-0000-0000-000000000001',
        'd3000000-0000-0000-0000-000000000001', 800, 'GBP', 'a note the user typed'),
       (:bystander::uuid, 'd4000000-0000-0000-0000-000000000001',
        'd3000000-0000-0000-0000-000000000001', 900, 'GBP', 'bystander note');

insert into public.purchase_records (user_id, deal_id, market_id, units, actual_buy_price_minor,
                                     currency, expected_profit_minor, inputs_snapshot)
values (:subject::uuid, 'd4000000-0000-0000-0000-000000000001',
        (select id from public.markets where slug = 'gb-amazon-uk'), 3, 1000, 'GBP', 500, '{}'::jsonb),
       (:bystander::uuid, 'd4000000-0000-0000-0000-000000000001',
        (select id from public.markets where slug = 'gb-amazon-uk'), 1, 1000, 'GBP', 500, '{}'::jsonb);

insert into public.barcode_lookups (user_id, market_id, barcode_raw, gtin14, credits_spent)
values (:subject::uuid, (select id from public.markets where slug = 'gb-amazon-uk'),
        '012345678905', '00012345678905', 1);

insert into public.app_events (user_id, event, market_id)
values (:subject::uuid, 'deal_unlocked', (select id from public.markets where slug = 'gb-amazon-uk')),
       (:bystander::uuid, 'deal_unlocked', (select id from public.markets where slug = 'gb-amazon-uk'));

-- ---------------------------------------------------------------------------
-- A. Privilege posture — the same rules T07's RPCs are held to
-- ---------------------------------------------------------------------------

select is(
  (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'pseudonymise_account'),
  true,
  'pseudonymise_account is SECURITY DEFINER — it must write rows the caller cannot');

select is(
  (select array_to_string(p.proconfig, ';') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'pseudonymise_account'),
  'search_path=public, pg_temp',
  'and it pins its search_path (§11.2)');

select ok(
  not has_function_privilege('anon', 'public.pseudonymise_account(uuid)', 'execute'),
  'anon cannot execute it');

select ok(
  not has_function_privilege('authenticated', 'public.pseudonymise_account(uuid)', 'execute'),
  'authenticated cannot execute it — a user may not scrub another account');

select ok(
  has_function_privilege('service_role', 'public.pseudonymise_account(uuid)', 'execute'),
  'service_role can, because the API route calls it after verifying the session');

select isnt(
  (select p.proacl::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'pseudonymise_account'),
  null,
  'its ACL is not NULL — a NULL proacl IS a PUBLIC execute grant (ADR-0016)');

-- The guard must be SECURITY DEFINER, and this assertion is here because the
-- first implementation was not. The role that deletes an auth user is
-- `supabase_auth_admin`, which holds no privilege on `public.profiles`, so an
-- INVOKER guard fails with 42501 on EVERY deletion — caught by the T10
-- integration suite as a 500 from the delete route, not by inspection.
select is(
  (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'enforce_profile_tombstoned_before_auth_delete'),
  true,
  'the delete guard is SECURITY DEFINER — supabase_auth_admin cannot read public.profiles');

select ok(
  not has_table_privilege('supabase_auth_admin', 'public.profiles', 'select'),
  'and that is measured, not assumed: supabase_auth_admin genuinely cannot read profiles');

-- ---------------------------------------------------------------------------
-- B. `deleted_at` is server-owned, exactly like credit_balance
-- ---------------------------------------------------------------------------

select ok(
  not has_column_privilege('authenticated', 'public.profiles', 'deleted_at', 'update'),
  'authenticated cannot write profiles.deleted_at — a user cannot tombstone or un-tombstone a row');

select ok(
  has_column_privilege('authenticated', 'public.profiles', 'tax_registered', 'update'),
  'while the T06 settings allowlist is untouched — the control is meaningful');

select ok(
  not has_column_privilege('authenticated', 'public.profiles', 'credit_balance', 'update'),
  'and credit_balance is still refused (T06 unchanged by T10)');

-- ---------------------------------------------------------------------------
-- C. Requirement 16 — plain deletion is refused BEFORE the T10 mechanism runs
-- ---------------------------------------------------------------------------

select throws_ok(
  format($$delete from public.profiles where id = %L$$, :subject),
  '23503', null,
  'deleting the profile directly is refused by credit_ledger''s ON DELETE RESTRICT (ADR-0010)');

select throws_ok(
  format($$delete from auth.users where id = %L$$, :subject),
  '23503', null,
  'and deleting the auth user is refused by the T10 guard, which names the sanctioned path');

select ok(
  (select count(*) from public.credit_ledger where user_id = :subject::uuid) = 3,
  'nothing was destroyed by the refused attempts');

-- ---------------------------------------------------------------------------
-- D. Totals recorded BEFORE the deletion, so "unchanged" means something
-- ---------------------------------------------------------------------------

create temporary table t10_before as
select
  (select sum(delta) from public.credit_ledger where user_id = :subject::uuid)      as subject_delta_sum,
  (select count(*)   from public.credit_ledger where user_id = :subject::uuid)      as subject_ledger_rows,
  (select credit_balance from public.profiles where id = :subject::uuid)            as subject_balance,
  (select sum(amount_minor) from public.credit_purchases where user_id = :subject::uuid) as subject_purchase_minor,
  (select sum(delta) from public.credit_ledger where user_id = :bystander::uuid)    as bystander_delta_sum,
  (select credit_balance from public.profiles where id = :bystander::uuid)          as bystander_balance;

-- ---------------------------------------------------------------------------
-- E. The mechanism runs
-- ---------------------------------------------------------------------------

select lives_ok(
  format($$select public.pseudonymise_account(%L)$$, :subject),
  'pseudonymise_account succeeds (requirement 17)');

select is(
  (select already_deleted from public.pseudonymise_account(:subject::uuid)),
  true,
  'a second call reports the account was already deleted — it is idempotent (requirement 23)');

select lives_ok(
  format($$select public.pseudonymise_account(%L)$$, :subject),
  'and a third call still succeeds rather than raising — convergent, not merely tolerant');

select throws_ok(
  $$select public.pseudonymise_account('00000000-0000-0000-0000-0000000000ff')$$,
  '23503', null,
  'an unknown subject raises rather than silently succeeding');

select throws_ok(
  $$select public.pseudonymise_account(null)$$,
  '22023', null,
  'and a null subject is a validation error, not a mass scrub');

-- ---------------------------------------------------------------------------
-- F. Constraint 1 — the personal data is gone (requirement 20)
-- ---------------------------------------------------------------------------

select is((select display_name                    from public.profiles where id = :subject::uuid), null, 'display_name is gone');
select is((select country_code                    from public.profiles where id = :subject::uuid), null, 'country_code is gone');
select is((select default_market_id               from public.profiles where id = :subject::uuid), null, 'default_market_id is gone');
select is((select locale                          from public.profiles where id = :subject::uuid), null, 'locale is gone');
select is((select timezone                        from public.profiles where id = :subject::uuid), null, 'timezone is gone');
select is((select tax_registration_country        from public.profiles where id = :subject::uuid), null, 'tax_registration_country is gone');
select is((select default_budget_minor            from public.profiles where id = :subject::uuid), null, 'default_budget_minor is gone');
select is((select prep_cost_per_unit_minor        from public.profiles where id = :subject::uuid), null, 'prep_cost_per_unit_minor is gone');
select is((select inbound_shipping_per_unit_minor from public.profiles where id = :subject::uuid), null, 'inbound_shipping_per_unit_minor is gone');
select is((select assumption_currency             from public.profiles where id = :subject::uuid), null, 'assumption_currency is gone');
select is((select onboarded_at                    from public.profiles where id = :subject::uuid), null, 'onboarded_at is gone');

select is((select tax_registered     from public.profiles where id = :subject::uuid), false,
  'tax_registered is reset to the conservative default rather than left as the user set it');
select is((select tax_scheme::text   from public.profiles where id = :subject::uuid), 'standard',
  'tax_scheme is reset to its default');
select is((select default_fulfilment::text from public.profiles where id = :subject::uuid), 'marketplace_fulfilled',
  'default_fulfilment is reset to its default');

select isnt((select deleted_at from public.profiles where id = :subject::uuid), null,
  'and the row is marked as a tombstone');

select is((select count(*)::int from public.deal_unlocks     where user_id = :subject::uuid), 0, 'deal_unlocks are deleted');
select is((select count(*)::int from public.watchlist_items  where user_id = :subject::uuid), 0, 'watchlist_items are deleted — including the free text the user typed');
select is((select count(*)::int from public.purchase_records where user_id = :subject::uuid), 0, 'purchase_records are deleted');
select is((select count(*)::int from public.barcode_lookups  where user_id = :subject::uuid), 0, 'barcode_lookups are deleted — a scanned barcode is a location trace');
select is((select count(*)::int from public.app_events       where user_id = :subject::uuid), 0, 'no app_event still names the subject');

-- ---------------------------------------------------------------------------
-- G. Constraint 2 — the financial history is untouched (requirements 18, 19)
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from public.credit_ledger where user_id = :subject::uuid),
  (select subject_ledger_rows::int from t10_before),
  'every ledger row survives (requirement 18)');

select is(
  (select sum(delta) from public.credit_ledger where user_id = :subject::uuid),
  (select subject_delta_sum from t10_before),
  'and the deltas sum to exactly what they summed to before');

select is(
  (select sum(amount_minor) from public.credit_purchases where user_id = :subject::uuid),
  (select subject_purchase_minor from t10_before),
  'the credit purchase rows survive with the same amounts (requirement 19)');

select is(
  (select count(distinct currency)::int from public.credit_purchases where user_id = :subject::uuid),
  1,
  'and they still carry their currency — a currency-blind total hides a per-currency bug (§11.4)');

select is(
  (select credit_balance from public.profiles where id = :subject::uuid),
  (select subject_balance from t10_before),
  'credit_balance is NOT zeroed: zeroing it would falsify the balance and break AC10.8');

select is(
  (select credit_balance from public.profiles where id = :subject::uuid),
  (select sum(delta)::int from public.credit_ledger where user_id = :subject::uuid),
  'so AC10.8''s invariant sum(delta) = credit_balance still holds for the deleted subject');

select is(
  (select count(*)::int from public.app_events where user_id is null and event = 'deal_unlocked'),
  1,
  'the analytics row itself survives with a nulled actor — the funnel keeps the count, not the person');

-- ---------------------------------------------------------------------------
-- H. Constraint 3 — nothing retained identifies a person
-- ---------------------------------------------------------------------------
--
-- Asserted as an allowlist over the tombstone's own columns rather than as a
-- list of fields someone remembered to check. A column added to `profiles` by a
-- later task lands in this assertion automatically, which is the only way this
-- stays true between here and T44.

select is(
  (select string_agg(c.column_name, ',' order by c.column_name)
     from information_schema.columns c
    where c.table_schema = 'public' and c.table_name = 'profiles'
      and c.column_name not in ('id', 'credit_balance', 'created_at', 'updated_at', 'deleted_at')),
  'assumption_currency,country_code,default_budget_minor,default_fulfilment,default_market_id,'
  || 'display_name,inbound_shipping_per_unit_minor,locale,onboarded_at,prep_cost_per_unit_minor,'
  || 'tax_registered,tax_registration_country,tax_scheme,timezone',
  'the set of personal columns on profiles is exactly what the scrub covers — a new column fails here');

select lives_ok(
  format($$delete from auth.users where id = %L$$, :subject),
  'the auth user can now be deleted — the guard is satisfied by the tombstone (requirement 21)');

select is(
  (select count(*)::int from auth.users where id = :subject::uuid),
  0,
  'and the email, identities and login are genuinely gone rather than scrambled in place');

select is(
  (select count(*)::int from public.profiles where id = :subject::uuid),
  1,
  'while the tombstone remains, because the financial FKs point at it');

select is(
  (select count(*)::int from public.credit_ledger where user_id = :subject::uuid),
  (select subject_ledger_rows::int from t10_before),
  'and the ledger is still intact after the auth user is gone');

-- ---------------------------------------------------------------------------
-- I. The tombstone invariant is enforced by the database, not by the routine
-- ---------------------------------------------------------------------------

select throws_ok(
  format($$update public.profiles set display_name = 'Re-identified' where id = %L$$, :subject),
  '23514', null,
  'writing personal data back onto a tombstone is refused by a check constraint, not merely discouraged');

select throws_ok(
  format($$update public.profiles set country_code = 'GB' where id = %L$$, :subject),
  '23514', null,
  'and the same for any other personal column');

select lives_ok(
  format($$update public.profiles set credit_balance = credit_balance where id = %L$$, :subject),
  'while the balance stays writable by the RPCs — a late chargeback must still be recordable (§11.4)');

-- ---------------------------------------------------------------------------
-- J. Requirement 24 — unrelated users are unaffected
-- ---------------------------------------------------------------------------

select is((select display_name from public.profiles where id = :bystander::uuid), 'Bystander',
  'the other user''s profile is untouched');
select is((select deleted_at from public.profiles where id = :bystander::uuid), null,
  'and is not tombstoned');
select is((select count(*)::int from public.deal_unlocks     where user_id = :bystander::uuid), 1, 'their unlock survives');
select is((select count(*)::int from public.watchlist_items  where user_id = :bystander::uuid), 1, 'their watchlist item survives');
select is((select count(*)::int from public.purchase_records where user_id = :bystander::uuid), 1, 'their purchase record survives');
select is(
  (select sum(delta) from public.credit_ledger where user_id = :bystander::uuid),
  (select bystander_delta_sum from t10_before),
  'and their ledger total is unchanged');
select is(
  (select credit_balance from public.profiles where id = :bystander::uuid),
  (select bystander_balance from t10_before),
  'as is their balance');

-- ---------------------------------------------------------------------------
-- K. The guard cannot be sidestepped by deleting in the other order
-- ---------------------------------------------------------------------------

select throws_ok(
  format($$delete from auth.users where id = %L$$, :bystander),
  '23503', null,
  'the bystander is still protected — the guard applies to every account, not just one');

select is(
  (select count(*)::int from pg_trigger
    where tgrelid = 'auth.users'::regclass and tgname = 'on_auth_user_deleted' and not tgisinternal),
  1,
  'the guard is a real trigger on auth.users, asserted by name so it cannot be dropped silently');

select is(
  (select tgtype::int & 2 from pg_trigger
    where tgrelid = 'auth.users'::regclass and tgname = 'on_auth_user_deleted'),
  2,
  'and it is a BEFORE trigger — an AFTER trigger would fire once the row was already gone');

select * from finish();
rollback;
