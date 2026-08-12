-- ===========================================================================
-- T10 — Account deletion by pseudonymisation (ADR-0017)
--
-- Resolves the mechanism ADR-0010 decision 2 deliberately left open: financial
-- records are ON DELETE RESTRICT and survive account deletion, which makes a
-- plain `delete from auth.users` fail with 23503 for every user who ever held
-- a credit (i.e. every user, since signup grants five).
--
-- THE MODEL: a tombstone profile retained under the SAME subject UUID, with the
-- auth.users row genuinely deleted.
--
-- Why not a surrogate financial subject, and why not a nullable actor column:
-- both require UPDATE on credit_ledger.user_id, and credit_ledger is
-- append-only at two independent layers (T05 / ADR-0010 decision 3) — a
-- BEFORE UPDATE OR DELETE trigger that raises unconditionally, plus
-- REVOKE UPDATE, DELETE FROM service_role. Neither option is implementable
-- without dismantling the strongest guarantee in the schema, so neither was
-- chosen. The ledger's user_id is immutable for the life of the row.
--
-- That leaves exactly one lever: make the UUID those rows point at stop
-- resolving to a person. The email, the identities and the login all live in
-- auth.users, so auth.users must actually go — which is what this migration
-- makes possible.
--
-- PRIVILEGE POSTURE (global rule 8 / ADR-004):
--   * Creates one function, `public.pseudonymise_account`. It is SECURITY
--     DEFINER with a pinned search_path, REVOKEd from PUBLIC, `anon` and
--     `authenticated`, and GRANTed EXECUTE to `service_role` only — the same
--     posture as the T07 credit RPCs, and for the same reason: it is a
--     privileged operation reached exclusively through a server route that has
--     already authenticated the caller as the subject.
--   * Adds one column, `profiles.deleted_at`. It is deliberately NOT added to
--     T06's `grant update (...)` column allowlist on `profiles`, so it is
--     server-owned exactly like `credit_balance`, `id`, `created_at` and
--     `updated_at`. An authenticated client cannot set it, clear it, or
--     resurrect a tombstone.
--   * Grants nothing to `anon` or `authenticated`. Adds no policy. Alters no
--     existing policy, grant or trigger. The T06 surface is untouched: 19
--     policies, 16 table grants, 14 profiles column grants.
--   * Drops one constraint, `profiles_id_fkey`, and explains why below.
--   * Writes no row.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Detach `profiles` from `auth.users`
-- ---------------------------------------------------------------------------
--
-- T03 created `profiles.id references auth.users (id) on delete cascade`. That
-- cascade is precisely what makes deletion impossible today: deleting the auth
-- user tries to delete the profile, and credit_ledger / credit_purchases hold
-- it back with ON DELETE RESTRICT (23503).
--
-- Dropping the constraint does NOT weaken any authorisation boundary:
--
--   * The profile row is still created only by `handle_new_user()`, a trigger
--     on auth.users. There is no INSERT policy and no INSERT grant on
--     `profiles` for any client role (T06), so a client cannot manufacture a
--     profile for an id that has no auth user.
--   * T06's policies are `id = auth.uid()`. A tombstoned profile has no
--     auth.users row, so no JWT can ever carry its subject and `auth.uid()`
--     can never equal its id. The row becomes permanently unreadable and
--     unwritable by every client role — a stronger property than the FK
--     provided, achieved without editing one character of T06.
--   * `deals.published_by` / `retired_by` still reference auth.users directly
--     with ON DELETE SET NULL (T04), so an admin's deletion still nulls the
--     actor and keeps the timestamp, exactly as T04 intended.
--
-- What is genuinely given up is the database-enforced guarantee that every
-- profile has a live auth user. That guarantee is incompatible with retaining
-- financial history, and it is replaced by the tombstone invariant in section 3
-- plus the deletion routine in section 4, both of which are tested.

alter table public.profiles
  drop constraint profiles_id_fkey;


-- ---------------------------------------------------------------------------
-- 2. The tombstone marker
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column if not exists deleted_at timestamptz;

comment on column public.profiles.deleted_at is
  'Non-null when the account has been deleted and this row is a tombstone retained solely to satisfy the ON DELETE RESTRICT foreign keys from credit_ledger and credit_purchases (ADR-0010, ADR-0017). A tombstone carries no personal data — enforced by profiles_tombstone_carries_no_personal_data. It has no auth.users row, so no session can ever resolve to it. Server-owned: absent from T06''s authenticated column-UPDATE allowlist. Retention DURATION is an unresolved legal-policy question, deliberately not encoded here.';

-- Partial: tombstones are the rare case and the index exists for the retention
-- and reconciliation queries that ask "which subjects are deleted", never for a
-- per-user lookup, which goes through the primary key.
create index if not exists profiles_deleted_at_idx
  on public.profiles (deleted_at)
  where deleted_at is not null;


-- ---------------------------------------------------------------------------
-- 3. What a tombstone may contain — asserted by the database, not by the caller
-- ---------------------------------------------------------------------------
--
-- The privacy claim in AC1.6 is "the retained rows must not identify the
-- deleted user". A routine that scrubs the columns is a promise; a constraint
-- is a guarantee, and it also catches the column added in some future task
-- whose author did not read this file — because that column will not be in the
-- scrub list, and if it is personal the check below is where the omission is
-- meant to be noticed.
--
-- `credit_balance` is deliberately NOT constrained to zero. Zeroing it would
-- break AC10.8's invariant `sum(credit_ledger.delta) = profiles.credit_balance`
-- for the retained rows, and §11.4's reconciliation is explicitly required to
-- keep covering deleted accounts. The balance is not personal data: it is a
-- number that reconciles against a ledger nobody can trace to a person.
--
-- `created_at` / `updated_at` are retained. A signup timestamp alone does not
-- identify anyone, and the retention question ("how long has this evidence
-- existed") cannot be answered without it.

alter table public.profiles
  add constraint profiles_tombstone_carries_no_personal_data check (
    deleted_at is null
    or (
      display_name                    is null
      and country_code                is null
      and default_market_id           is null
      and locale                      is null
      and timezone                    is null
      and tax_registration_country    is null
      and default_budget_minor        is null
      and prep_cost_per_unit_minor    is null
      and inbound_shipping_per_unit_minor is null
      and assumption_currency         is null
      and onboarded_at                is null
      -- The three NOT NULL preference columns cannot be nulled, so the
      -- tombstone must carry their schema defaults rather than the user's
      -- choice. `tax_registered = false` is also T03's conservative default.
      and tax_registered              = false
      and tax_scheme                  = 'standard'
      and default_fulfilment          = 'marketplace_fulfilled'
    )
  );


-- ---------------------------------------------------------------------------
-- 4. The deletion routine
-- ---------------------------------------------------------------------------
--
-- Deletes every personal row, scrubs the profile, stamps the tombstone, and
-- touches neither credit_ledger nor credit_purchases.
--
-- IDEMPOTENT AND CONVERGENT. Every statement is a DELETE or an UPDATE to a
-- fixed value, so a second call is a no-op that returns the same summary with
-- `already_deleted = true`. This matters operationally: the caller in
-- `src/services/account/` must delete the auth.users row AFTER this function
-- succeeds, and if that second step fails the whole operation is retried from
-- the top.
--
-- WHY THE PERSONAL ROWS ARE DELETED EXPLICITLY. ARCHITECTURE.md §11.5 says
-- they "cascade from auth.users". They do not: deal_unlocks, watchlist_items,
-- purchase_records and barcode_lookups all reference public.profiles, and the
-- profile row survives here by design, so no cascade fires. Relying on the
-- documented-but-untrue cascade would leave every one of them in place.
--
-- app_events.user_id is ON DELETE SET NULL from profiles and is nulled here for
-- the same reason — the cascade that would have done it never runs. Its
-- `properties` column is documented as carrying no PII (T05), so nulling the
-- actor is sufficient and the behavioural rows themselves are retained for the
-- funnel analysis they exist to serve.

create or replace function public.pseudonymise_account(p_user uuid)
returns table (
  already_deleted   boolean,
  deleted_at        timestamptz,
  unlocks_deleted   integer,
  watchlist_deleted integer,
  purchases_deleted integer,
  lookups_deleted   integer,
  events_detached   integer,
  ledger_retained   integer,
  credit_purchases_retained integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_existing  timestamptz;
  v_unlocks   integer;
  v_watchlist integer;
  v_purchases integer;
  v_lookups   integer;
  v_events    integer;
  v_ledger    integer;
  v_credit_purchases integer;
begin
  if p_user is null then
    raise exception 'INVALID_ARGUMENT: p_user is required'
      using errcode = '22023';
  end if;

  -- Lock the subject for the duration, so two concurrent delete requests
  -- serialise rather than interleave their scrubs.
  select p.deleted_at into v_existing
  from public.profiles p
  where p.id = p_user
  for update;

  if not found then
    raise exception 'UNKNOWN_SUBJECT: no profile exists for %', p_user
      using errcode = '23503';
  end if;

  delete from public.deal_unlocks    where user_id = p_user;
  get diagnostics v_unlocks = row_count;

  delete from public.watchlist_items where user_id = p_user;
  get diagnostics v_watchlist = row_count;

  delete from public.purchase_records where user_id = p_user;
  get diagnostics v_purchases = row_count;

  delete from public.barcode_lookups where user_id = p_user;
  get diagnostics v_lookups = row_count;

  update public.app_events set user_id = null where user_id = p_user;
  get diagnostics v_events = row_count;

  -- The scrub. Every personal column to NULL or to its schema default; the
  -- balance, the timestamps and the id untouched.
  update public.profiles
  set display_name                    = null,
      country_code                    = null,
      default_market_id               = null,
      locale                          = null,
      timezone                        = null,
      tax_registered                  = false,
      tax_registration_country        = null,
      tax_scheme                      = 'standard',
      default_fulfilment              = 'marketplace_fulfilled',
      default_budget_minor            = null,
      prep_cost_per_unit_minor        = null,
      inbound_shipping_per_unit_minor = null,
      assumption_currency             = null,
      onboarded_at                    = null,
      deleted_at                      = coalesce(v_existing, now())
  where id = p_user;

  -- Counted, not touched. Returning these makes the retention guarantee
  -- observable to the caller and to the test suite in the same breath as the
  -- deletion, rather than requiring a separate query that could be run against
  -- a different snapshot.
  select count(*)::integer into v_ledger
  from public.credit_ledger where user_id = p_user;

  select count(*)::integer into v_credit_purchases
  from public.credit_purchases where user_id = p_user;

  return query
  select v_existing is not null,
         coalesce(v_existing, (select p.deleted_at from public.profiles p where p.id = p_user)),
         v_unlocks, v_watchlist, v_purchases, v_lookups, v_events,
         v_ledger, v_credit_purchases;
end;
$$;

comment on function public.pseudonymise_account(uuid) is
  'T10 / ADR-0017. Deletes every personal row for a subject, scrubs the profile to a tombstone and stamps deleted_at. Retains credit_ledger and credit_purchases untouched (ADR-0010, AC1.6) and does not alter credit_balance, so AC10.8 reconciliation still holds. Idempotent and convergent: safe to retry. The caller deletes the auth.users row afterwards.';

-- Same posture as the T07 credit RPCs. The REVOKE is not optional even under
-- ADR-004's owner-only default: PostgreSQL grants EXECUTE to PUBLIC on function
-- creation, and a later CREATE OR REPLACE that omitted the revoke would
-- silently reopen it. Both statements live in the same file as the body so they
-- cannot drift apart.
revoke all on function public.pseudonymise_account(uuid) from public, anon, authenticated;
grant execute on function public.pseudonymise_account(uuid) to service_role;


-- ---------------------------------------------------------------------------
-- 5. The restriction that section 1 would otherwise have removed
-- ---------------------------------------------------------------------------
--
-- THIS IS THE MOST IMPORTANT OBJECT IN THE MIGRATION, and it exists because of
-- a consequence that is easy to miss.
--
-- Before this migration, `delete from auth.users` failed with 23503 for any
-- user holding a ledger row: the delete cascaded to `profiles`, and
-- credit_ledger's ON DELETE RESTRICT held the profile back. T09 asserts exactly
-- that, and ADR-0010 relied on it.
--
-- Dropping `profiles_id_fkey` in section 1 makes that delete SUCCEED — and the
-- result is strictly worse than the failure it replaces: the auth user is gone,
-- nothing cascades, and a profile row full of the person's country, locale,
-- timezone, budget and cost assumptions is left behind with no owner and no
-- route by which anyone would notice. A migration that traded a loud 23503 for
-- silent orphaned personal data would have defeated its own purpose.
--
-- So the restriction is re-established deliberately, one layer up and stated in
-- its own terms: **an auth user may not be deleted while their profile still
-- holds personal data.** Not "while financial rows exist" — that was always a
-- proxy for the real rule, and it is the wrong test now, because the whole
-- point of the tombstone is that financial rows exist *afterwards* too.
--
-- The consequences:
--   * `auth.admin.deleteUser` on a live account still fails, loudly, with a
--     message naming the sanctioned path.
--   * `pseudonymise_account` then makes the same call succeed, because the
--     profile is a tombstone and there is nothing left to orphan.
--   * There is exactly one way to delete an account, and it is the one that
--     scrubs first. A support script, a dashboard session or a future task that
--     reaches for `deleteUser` directly gets told, rather than quietly
--     producing an orphan.
--
-- SECURITY DEFINER, for exactly the reason T03's `handle_new_user` is: the role
-- that deletes an auth user is `supabase_auth_admin`, which holds no privilege
-- on `public.profiles` at all. A SECURITY INVOKER guard here fails with
-- `42501 permission denied for table profiles` on every deletion — measured,
-- not assumed: the first implementation was INVOKER and the T10 integration
-- suite caught it as a 500 from `DELETE /api/v1/account`.
--
-- Definer is safe here in the way that matters: the function reads one column
-- of one row and either returns OLD or raises. It writes nothing, takes no
-- input but the row being deleted, builds no dynamic SQL, and is executable by
-- nobody — it is reached only as a trigger. `search_path` is pinned and
-- `public` is not CREATE-able by any client role, which is what makes a
-- definer's schema resolution trustworthy in the first place (T09).

create or replace function public.enforce_profile_tombstoned_before_auth_delete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_deleted_at timestamptz;
begin
  select p.deleted_at
    into v_deleted_at
    from public.profiles p
   where p.id = old.id;

  -- No profile: nothing to orphan, nothing to protect. Deleting is fine.
  if not found then
    return old;
  end if;

  if v_deleted_at is null then
    raise exception
      using errcode = '23503',
            message = format('ACCOUNT_NOT_PSEUDONYMISED: profile %s still holds personal data', old.id),
            detail  = 'credit_ledger and credit_purchases are ON DELETE RESTRICT (ADR-0010), so the profile row is retained as a tombstone rather than deleted. Deleting the auth user first would leave that row orphaned with the personal data still in it.',
            hint    = 'call public.pseudonymise_account(<user id>) first — it is idempotent';
  end if;

  return old;
end;
$$;

comment on function public.enforce_profile_tombstoned_before_auth_delete() is
  'T10 / ADR-0017. Refuses to delete an auth.users row whose profile has not been pseudonymised, replacing the restriction that profiles_id_fkey provided before it was dropped. Raises 23503 with a message naming pseudonymise_account. SECURITY DEFINER because the deleting role is supabase_auth_admin, which holds no privilege on public.profiles; it reads one column and either returns OLD or raises.';

revoke all on function public.enforce_profile_tombstoned_before_auth_delete() from public, anon, authenticated;

drop trigger if exists on_auth_user_deleted on auth.users;
create trigger on_auth_user_deleted
  before delete on auth.users
  for each row execute function public.enforce_profile_tombstoned_before_auth_delete();
