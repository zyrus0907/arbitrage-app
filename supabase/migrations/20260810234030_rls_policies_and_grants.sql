-- T06 — RLS policies, matching SQL grants, and restricted-UPDATE protection
--       for stripe_webhook_events.
--
-- Privilege posture of this migration (ADR-004, RUNBOOK "Migration checklist —
-- privilege posture"). This is the first migration in the project that grants
-- anything to `anon` or `authenticated`, so it states the whole surface rather
-- than only its delta:
--
--   * anon, authenticated  → SELECT on five reference tables; SELECT/INSERT/
--                            DELETE (per table, per operation) on six
--                            user-owned tables; a column-level UPDATE on
--                            profiles. Nothing else, anywhere.
--   * service_role         → unchanged. This migration grants it nothing and
--                            revokes nothing from it. The T03 baseline and the
--                            two T05 narrowings (credit_ledger SELECT/INSERT,
--                            stripe_webhook_events SELECT/INSERT/UPDATE) stand.
--   * functions            → owner-only. The one function created here is
--                            revoked from PUBLIC, anon and authenticated in
--                            this same file, immediately after its body.
--
-- The rule this task turns on (ADR-004 decision 4): access requires BOTH a SQL
-- privilege and an RLS policy, and neither works alone. RLS filters rows within
-- privileges already held, so a policy without a grant is inert and a grant
-- without a policy is ungoverned. Every GRANT below is written adjacent to the
-- policy that governs it, in the same section, for exactly that reason.
--
-- RLS is already enabled on all 24 public tables (T03, T04, T05). This
-- migration enables it on nothing, because there is nothing left to enable —
-- section G asserts that rather than assuming it.
--
-- Naming convention: <table>_<command>_<scope>. `_public` means the policy is
-- granted to anon and authenticated; `_own` means the row belongs to
-- auth.uid(). One policy per table per command. There are deliberately no
-- overlapping policies: PostgreSQL ORs permissive policies together, so two
-- policies on one command means the effective predicate is the union, and the
-- narrower one stops being load-bearing without any test going red.
--
-- `(select auth.uid())` rather than a bare `auth.uid()` throughout: the
-- subselect is evaluated once per statement instead of once per row.


-- ===========================================================================
-- A. Public reference data — SELECT to anon and authenticated
-- ===========================================================================
--
-- The exposure surface is exactly ADR-008's table and nothing more. Each entry
-- below records why the table is open, because "it is reference data" is not a
-- reason — `marketplaces` is reference data too and stays closed (section F).
--
-- Every predicate here is a *visibility* predicate, not a convenience filter.
-- The database refuses to show a row that the client could not act on, rather
-- than trusting every present and future caller to filter it out.

-- countries — signup asks the user which country they are in (§6.1, AC2.2), and
-- that list must be renderable before a session exists. `active` is the flag
-- that says a country is one we operate in; an inactive country in the picker
-- produces a signup that resolves to no market.
create policy countries_select_public
  on public.countries
  for select
  to anon, authenticated
  using (active);

grant select on table public.countries to anon, authenticated;

-- currencies — money is rendered from {amountMinor, currency} at the render
-- boundary (§4.2) and the minor-unit exponent is data, never an assumed x100
-- (§2.4). The client cannot format a price without this row.
--
-- DOCUMENTED DEVIATION. ADR-008's table and TASKS.md T06 both say "active rows
-- only" for this table, but `currencies` has no `active` column: ARCHITECTURE
-- §2.2 defines it as (code, minor_unit_exponent, symbol, name) and T03 built it
-- that way. The predicate is therefore `true` — the only unqualified USING in
-- this migration. It is defensible here and nowhere else: the table is the ISO
-- 4217 list, every column is public knowledge, and the grant is SELECT only. If
-- an `active` column is ever added, this policy must be narrowed in the same
-- migration that adds it.
create policy currencies_select_public
  on public.currencies
  for select
  to anon, authenticated
  using (true);

grant select on table public.currencies to anon, authenticated;

-- markets — signup resolves country -> market (§6.1) and MarketSwitcher renders
-- market names (§4.4). Both need the row before or without a session.
--
-- DOCUMENTED INTERPRETATION. Three documents describe this predicate slightly
-- differently: ARCHITECTURE §6.3 says `active = true`, ADR-008 and TASKS.md T06
-- say "active/live rows only", and §5.3 documents the public endpoint as "Live
-- markets (public — drives signup)". The narrowest reading is taken, because
-- this is a security boundary and the narrow reading cannot over-expose:
-- `active` AND `launch_status = 'live'`.
--
-- The consequence is intended, not incidental. A `beta` or `planned` market is
-- invisible to anon and authenticated, so a user in that country is waitlisted
-- rather than shown a market that is not ready — which is exactly AC2.2 and
-- AC8.6, and exactly risk #7's "all boxes ticked or the market stays planned".
-- Server-side reads run as service_role and are unaffected.
create policy markets_select_public
  on public.markets
  for select
  to anon, authenticated
  using (active and launch_status = 'live');

grant select on table public.markets to anon, authenticated;

-- credit_packs — the pricing page is public marketing (§4.3 /(marketing)/pricing)
-- and must render before signup. A pack carries credits, not money (§9.1).
create policy credit_packs_select_public
  on public.credit_packs
  for select
  to anon, authenticated
  using (active);

grant select on table public.credit_packs to anon, authenticated;

-- credit_pack_prices — the per-currency money half of the same page.
--
-- The predicate is `active = true AND stripe_price_id IS NOT NULL` (ADR-0010
-- decision 4). Both halves are load-bearing:
--
--   * `active` is the ordinary retirement flag.
--   * `stripe_price_id IS NOT NULL` is the buyability guarantee. T08 seeds this
--     column NULL and T34 backfills the real Stripe Price IDs (T05, ADR-0010),
--     so between those two tasks every price row exists and none can be bought.
--     A price with no Stripe Price ID renders a button whose Checkout session
--     cannot be created — the worst place to discover the problem. The database
--     refuses to show an unbuyable price rather than trusting every caller to
--     filter for it, which is why this is a read predicate and not a NOT NULL
--     column constraint: a placeholder id would satisfy the constraint and then
--     fail at the Checkout call.
--
-- Consequence, and it is correct: until T34 runs, this policy makes the credits
-- page show no purchasable pack. That must not be "fixed" with a placeholder.
create policy credit_pack_prices_select_public
  on public.credit_pack_prices
  for select
  to anon, authenticated
  using (active and stripe_price_id is not null);

grant select on table public.credit_pack_prices to anon, authenticated;


-- ===========================================================================
-- B. profiles — the user's own row, minus the balance
-- ===========================================================================
--
-- `profiles.id` is the auth.users id (§2.3) and is NOT NULL, so there is no
-- nullable-ownership hole: a row always has an owner and `id = auth.uid()`
-- always evaluates against a real value.
--
-- Two policies, one per command. No INSERT policy and no INSERT grant: the row
-- is created by the `handle_new_user` SECURITY DEFINER trigger on auth.users
-- (T03), which is the only sanctioned creation path. No DELETE policy and no
-- DELETE grant: account deletion cascades from auth.users and belongs to T10.

create policy profiles_select_own
  on public.profiles
  for select
  to authenticated
  using (id = (select auth.uid()));

create policy profiles_update_own
  on public.profiles
  for update
  to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- The WITH CHECK above is what stops a user rewriting `id` to point their row
-- at another account; the column grant below is what stops them touching
-- `credit_balance` at all. Both are wanted — see the next comment.

grant select on table public.profiles to authenticated;

-- T06 requires that `credit_balance` is not directly updatable by the user, and
-- offers a column-level grant or an update trigger. The column-level grant is
-- taken. It is declarative, it is visible in information_schema.column_privileges
-- next to every other grant in this file, and it fails at privilege-check time
-- (42501) before the row is ever read — a trigger would have to re-derive the
-- same decision per row and could be dropped without anything noticing.
--
-- The grant enumerates what the settings page (§4.3) actually edits, rather
-- than "everything except credit_balance". Minimum-necessary means the list is
-- the allowlist: a column added later is not updatable by the user until a
-- migration says it is, which is the safe default in this direction.
--
-- Deliberately absent: `id` (identity — also blocked by WITH CHECK above),
-- `credit_balance` (money — the authoritative source is credit_ledger and the
-- only sanctioned writer is T07's SECURITY DEFINER spend/grant RPC),
-- `created_at` and `updated_at` (the latter is maintained by the set_updated_at
-- trigger, which fires regardless of the caller's column privileges).
grant update (
  display_name,
  country_code,
  default_market_id,
  locale,
  timezone,
  tax_registered,
  tax_registration_country,
  tax_scheme,
  default_fulfilment,
  default_budget_minor,
  prep_cost_per_unit_minor,
  inbound_shipping_per_unit_minor,
  assumption_currency,
  onboarded_at
) on table public.profiles to authenticated;


-- ===========================================================================
-- C. credit_ledger — read own history, and nothing else, at every layer
-- ===========================================================================
--
-- SELECT policy, SELECT grant. That is the entire client surface.
--
-- There is deliberately no INSERT, UPDATE or DELETE policy and no such grant —
-- belt and braces, because this table is the source of truth for money (§2.3,
-- AC10.5). Writes arrive only through T07's SECURITY DEFINER RPCs, which run as
-- the function owner and are therefore unaffected by the absence of a grant
-- here. That is the intended shape, not a loophole: the one sanctioned write
-- path stays open and every unsanctioned one is closed at both layers.
--
-- `user_id` is NOT NULL and ON DELETE RESTRICT (T05, ADR-0010 decision 2), so
-- the predicate cannot be defeated by a null owner and the row cannot outlive
-- its owner as an orphan.

create policy credit_ledger_select_own
  on public.credit_ledger
  for select
  to authenticated
  using (user_id = (select auth.uid()));

grant select on table public.credit_ledger to authenticated;


-- ===========================================================================
-- D. deal_unlocks — read own, create own, never delete
-- ===========================================================================
--
-- No DELETE policy and no DELETE grant. AC10.7 makes unlocks permanent and
-- AC3.8 keeps them valid across deal retirement; a user who could delete an
-- unlock could be charged twice for the same information. T06 states the rule
-- as "grant DELETE for symmetry only if the product requires it" — it does not,
-- so neither the grant nor the policy exists.
--
-- Note for T07 and T09: `WITH CHECK (user_id = auth.uid())` constrains *whose*
-- row this is, and nothing else on it — a client holding this INSERT can write
-- an unlock row with `credits_spent = 0`. That row buys nothing today, because
-- `deals` is unreadable by `authenticated` at both layers (section F) and the
-- unlock route resolves entitlement server-side. It does mean an unlock row is
-- not by itself evidence that credits were spent: the ledger is.

create policy deal_unlocks_select_own
  on public.deal_unlocks
  for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy deal_unlocks_insert_own
  on public.deal_unlocks
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

grant select, insert on table public.deal_unlocks to authenticated;


-- ===========================================================================
-- E. watchlist_items, purchase_records, barcode_lookups — read/create/delete own
-- ===========================================================================
--
-- Three tables with the identical shape: SELECT, INSERT and DELETE, all scoped
-- to `user_id = auth.uid()`, with matching per-operation grants. `user_id` is
-- NOT NULL on all three, so no row can exist without an owner.
--
-- No UPDATE policy and no UPDATE grant on any of them. For watchlist_items and
-- barcode_lookups nothing in PRODUCT_SPEC edits a row in place — a watchlist
-- entry is added or removed, a lookup is a historical fact. For
-- purchase_records the `outcome` column does move (pending -> sold/unsold) and
-- T06 grants no UPDATE for it, so that transition runs server-side as
-- service_role via POST /api/v1/purchases until a task opens it deliberately.
-- Noted rather than silently widened: an ungranted operation is recoverable, an
-- unreviewed grant on the MVP validation instrument is not.
--
-- A DELETE policy needs USING and not WITH CHECK — WITH CHECK does not apply to
-- DELETE, and the T06 ownership rule for these three is "you may delete the
-- rows you own", which USING expresses exactly.

create policy watchlist_items_select_own
  on public.watchlist_items
  for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy watchlist_items_insert_own
  on public.watchlist_items
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy watchlist_items_delete_own
  on public.watchlist_items
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

grant select, insert, delete on table public.watchlist_items to authenticated;

create policy purchase_records_select_own
  on public.purchase_records
  for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy purchase_records_insert_own
  on public.purchase_records
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy purchase_records_delete_own
  on public.purchase_records
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

grant select, insert, delete on table public.purchase_records to authenticated;

create policy barcode_lookups_select_own
  on public.barcode_lookups
  for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy barcode_lookups_insert_own
  on public.barcode_lookups
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy barcode_lookups_delete_own
  on public.barcode_lookups
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

grant select, insert, delete on table public.barcode_lookups to authenticated;


-- ===========================================================================
-- F. Service-role-only tables — stated, not left implicit
-- ===========================================================================
--
-- These thirteen tables receive NO policy and NO anon/authenticated grant of
-- any kind in this migration or any other. They are listed by name so that a
-- reviewer can see the decision was made for each one rather than inferred from
-- an absence, and so that a future table added to the schema is conspicuously
-- missing from every list in this file:
--
--   deals                  the paid product. Column-level RLS to hide the
--                          product identity is fragile and one mistake from
--                          giving it away; redaction is one server function,
--                          one test, one place to get right (§6.3, risk #10).
--   retailers              retailer identity is part of the redacted payload.
--   retailer_products      likewise — this is the "where to buy it" half.
--   marketplace_products   likewise — the "what it is" half.
--   product_matches        exposes the matching method and confidence, which is
--                          the deal identity by another route.
--   marketplaces           carries adapter_key and capabilities, which are
--                          integration internals (ADR-008). Removed from the
--                          public-read set in v2.1 and NOT re-added here: it is
--                          reference data, and that is not a reason. If a client
--                          need emerges, expose a view with the specific columns
--                          required — do not grant the table.
--   tax_schedules          commercial/regulatory configuration; resolved into a
--                          MarketContext server-side (§1.3).
--   fee_schedules          likewise.
--   credit_purchases       another user's payment history. Read server-side.
--   stripe_webhook_events  raw Stripe payloads. Section G below adds a trigger,
--                          not a grant.
--   api_usage_log          provider quota and cost — operational.
--   ingestion_runs         pipeline state — operational.
--   app_events             analytics; may carry other users' behaviour.
--
-- With sections A–E, all 24 public tables are accounted for: 5 public-read,
-- 6 user-owned, 13 closed. Section H asserts the arithmetic.
--
-- No statement is issued for these tables. T03 already revoked everything and
-- set ALTER DEFAULT PRIVILEGES so nothing is granted by default; a REVOKE here
-- would be a no-op that reads like a fix and would hide a regression rather
-- than surface one. The assertion belongs in the tests, and it is there.


-- ===========================================================================
-- G. stripe_webhook_events — restricted UPDATE, not immutability
-- ===========================================================================
--
-- The row records two different things with two different lifetimes (§2.3,
-- ADR-0010 decision 5):
--
--   identity — stripe_event_id, type, payload, received_at. This is the
--              evidence and the replay guard. It must never move.
--   outcome  — processed_at, error. Written after the fact by T35's fulfilment
--              path. It must remain writable.
--
-- So this is deliberately NOT the credit_ledger treatment. A blanket
-- immutability trigger here would break webhook fulfilment, which is precisely
-- why ADR-0010 separated the two tables' rules.
--
-- DELETE is already revoked from service_role in T05. The trigger additionally
-- rejects it for any role that does hold the privilege — the migration owner, a
-- support script connected as `postgres`, a dashboard SQL session. Deleting an
-- event re-opens the duplicate-grant window the table exists to close, and that
-- argument does not care which role does the deleting.
--
-- Function posture: SECURITY INVOKER (not DEFINER — nothing here needs
-- privileges the caller lacks, and a DEFINER trigger function on a financial
-- table would be a privilege the docs do not justify), search_path pinned to
-- 'pg_catalog, pg_temp', owner-only EXECUTE. This matches
-- enforce_credit_ledger_append_only and enforce_deal_lifecycle exactly.

create function public.enforce_webhook_event_restricted_update()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'pg_temp'
as $fn$
begin
  if tg_op = 'DELETE' then
    raise exception
      using errcode = '0A000',
            message = 'stripe_webhook_events rows may not be deleted',
            detail  = 'The row is the replay guard for Stripe event delivery; deleting it re-opens the duplicate-grant window it exists to close (ADR-0010 decision 5).',
            hint    = 'Mark the event processed, or record the failure in `error`. Never remove the evidence.';
  end if;

  -- UPDATE. Each identity column is compared with IS DISTINCT FROM rather than
  -- <>, so a change to or from NULL is caught too. Three of the four are NOT
  -- NULL today; received_at has a default and stripe_event_id is the primary
  -- key, but the comparison must not depend on those staying true.
  --
  -- The columns are named individually rather than compared as whole rows, so
  -- that the error says which one moved. A future column added to this table is
  -- unlisted and therefore mutable by default — that is the honest failure
  -- direction here, because the identity set is fixed by ADR-0010 and a new
  -- column would be a new decision requiring its own review.
  if new.stripe_event_id is distinct from old.stripe_event_id then
    raise exception
      using errcode = '0A000',
            message = 'stripe_webhook_events.stripe_event_id is immutable',
            detail  = 'Event identity is frozen after insert (ADR-0010 decision 5).',
            hint    = 'Only processed_at and error may be updated.';
  end if;

  if new.type is distinct from old.type then
    raise exception
      using errcode = '0A000',
            message = 'stripe_webhook_events.type is immutable',
            detail  = 'Event identity is frozen after insert (ADR-0010 decision 5).',
            hint    = 'Only processed_at and error may be updated.';
  end if;

  if new.payload is distinct from old.payload then
    raise exception
      using errcode = '0A000',
            message = 'stripe_webhook_events.payload is immutable',
            detail  = 'The payload is the evidence of what Stripe sent (ADR-0010 decision 5).',
            hint    = 'Only processed_at and error may be updated.';
  end if;

  if new.received_at is distinct from old.received_at then
    raise exception
      using errcode = '0A000',
            message = 'stripe_webhook_events.received_at is immutable',
            detail  = 'Event identity is frozen after insert (ADR-0010 decision 5).',
            hint    = 'Only processed_at and error may be updated.';
  end if;

  return new;
end;
$fn$;

-- Owner-only, in the same migration as the body (ADR-004 consequence, RUNBOOK
-- function checklist). PostgreSQL grants EXECUTE to PUBLIC on creation, and
-- T03's ALTER DEFAULT PRIVILEGES covers future functions but not the built-in
-- PUBLIC default, so this REVOKE is not redundant. It must be repeated after
-- any future CREATE OR REPLACE of this function.
revoke all on function public.enforce_webhook_event_restricted_update()
  from public, anon, authenticated;

-- BEFORE, so the write is rejected before it happens rather than compensated
-- afterwards. FOR EACH ROW, because the rule compares OLD to NEW.
create trigger stripe_webhook_events_restricted_update
  before update or delete on public.stripe_webhook_events
  for each row
  execute function public.enforce_webhook_event_restricted_update();


-- ===========================================================================
-- H. Assertions — what this migration relies on and must not have changed
-- ===========================================================================
--
-- These abort the migration rather than documenting an expectation in prose.
-- Sections C and G both depend on T05 protections that this task verifies
-- instead of re-creating (ADR-0010 decision 3): a second ledger trigger would
-- mean either one could be dropped without a test going red.

do $$
begin
  -- 1. RLS is on for every public table. Nothing here enables it; if a table
  --    ever arrives without it, the policies in this file would be the only
  --    thing standing between a grant and a full-table read, and for the five
  --    public tables above there IS now a grant.
  if exists (
    select 1
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'r'
       and not c.relrowsecurity
  ) then
    raise exception 'T06: a public table has RLS disabled; refusing to add grants';
  end if;

  -- 2. The T05 ledger append-only trigger is still present, on both the row and
  --    the truncate path (ADR-0011 decision 5). Verified, not re-created.
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.credit_ledger'::regclass
       and tgname = 'credit_ledger_append_only'
       and not tgisinternal
  ) then
    raise exception 'T06: credit_ledger_append_only trigger is missing (owned by T05)';
  end if;

  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.credit_ledger'::regclass
       and tgname = 'credit_ledger_no_truncate'
       and not tgisinternal
  ) then
    raise exception 'T06: credit_ledger_no_truncate trigger is missing (owned by T05)';
  end if;

  -- 3. The T05 revokes are still in place. UPDATE and DELETE on credit_ledger,
  --    and DELETE on stripe_webhook_events, are not held by service_role.
  if has_table_privilege('service_role', 'public.credit_ledger', 'UPDATE')
     or has_table_privilege('service_role', 'public.credit_ledger', 'DELETE') then
    raise exception 'T06: service_role has regained UPDATE/DELETE on credit_ledger';
  end if;

  if has_table_privilege('service_role', 'public.stripe_webhook_events', 'DELETE') then
    raise exception 'T06: service_role has regained DELETE on stripe_webhook_events';
  end if;

  -- 4. service_role still holds the UPDATE this task's trigger is designed to
  --    constrain. Without it the trigger would be unreachable by the only role
  --    that is supposed to reach it, and T35's fulfilment path would fail with
  --    a privilege error instead.
  if not has_table_privilege('service_role', 'public.stripe_webhook_events', 'UPDATE') then
    raise exception 'T06: service_role lost UPDATE on stripe_webhook_events; T35 cannot record outcomes';
  end if;

  -- 5. Grant/policy correspondence, in both directions, over every public
  --    table. This is ADR-004 decision 4 as an executable check rather than a
  --    review question: a table with a grant to anon/authenticated but no
  --    policy is an ungoverned privilege; a table with a policy but no grant is
  --    an inert policy. Either is a defect, and either aborts this migration.
  if exists (
    select 1
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'r'
       and (
         exists (
           select 1 from information_schema.role_table_grants g
            where g.table_schema = 'public'
              and g.table_name = c.relname
              and g.grantee in ('anon', 'authenticated')
         )
         or exists (
           select 1 from information_schema.column_privileges cp
            where cp.table_schema = 'public'
              and cp.table_name = c.relname
              and cp.grantee in ('anon', 'authenticated')
         )
       )
       <> exists (
         select 1 from pg_policy p where p.polrelid = c.oid
       )
  ) then
    raise exception 'T06: a public table has a grant without a policy, or a policy without a grant';
  end if;
end
$$;
