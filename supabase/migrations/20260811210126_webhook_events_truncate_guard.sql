-- T09 — BEFORE TRUNCATE guard on stripe_webhook_events.
--
-- Source of truth: docs/TASKS.md T06 completion note ("Deferred to T09:
-- stripe_webhook_events has no TRUNCATE guard, while credit_ledger has one
-- (ADR-0011 decision 5) … T09 should decide it deliberately"), ADR-0010
-- decision 5 (the row is the replay guard and the evidence), ADR-0016.
--
-- ===========================================================================
-- THE HOLE, MEASURED RATHER THAN ASSUMED
-- ===========================================================================
--
-- T06 gave this table a BEFORE DELETE OR UPDATE **row** trigger. A row trigger
-- never fires for TRUNCATE — that is not a subtlety of this schema, it is how
-- TRUNCATE works — so the state before this migration was:
--
--   anon / authenticated  → no privilege of any kind. Unreachable.
--   service_role          → INSERT, SELECT, UPDATE. No DELETE, no TRUNCATE.
--                           Verified: `TRUNCATE` raises 42501.
--   owner (postgres)      → `DELETE` raises 0A000 from the row trigger, but
--                           `TRUNCATE` SUCCEEDED. Verified empirically before
--                           this migration was written.
--
-- So a table whose rows are the Stripe replay guard could be emptied in one
-- statement by a migration, a support script, or a Supabase dashboard SQL
-- editor session — the same three actors ADR-0011 decision 5 named when it put
-- the identical guard on credit_ledger. The trigger this table already carries
-- says, in its own DELETE branch, "Never remove the evidence." TRUNCATE walked
-- past that sentence.
--
-- ===========================================================================
-- WHY THIS IS WORTH A MIGRATION, AND WHY IT IS NOT ALARMING
-- ===========================================================================
--
-- Severity is bounded, and saying so is part of the decision rather than an
-- excuse for skipping it. Emptying this table does NOT by itself re-open the
-- duplicate-grant window, because §9.2 rule 3 has two layers and this is the
-- second one. The first is `credit_ledger.idempotency_key`, which is NOT NULL
-- UNIQUE, and which T35 will key on `stripe_event_id` for webhook fulfilment —
-- and `credit_ledger` is itself TRUNCATE-guarded. A replayed event after a
-- truncate still collides on that key.
--
-- What is genuinely lost is the evidence: what Stripe sent, when it arrived,
-- and whether it was processed. That is the table's other job, and ADR-0010
-- decision 5 treats it as the point rather than a side effect.
--
-- The operational cost of the guard is zero. Nothing legitimately truncates
-- this table today: `DELETE` is already refused unconditionally by the existing
-- trigger, so no pruning or retention path exists to be broken. If a retention
-- policy is ever designed, it needs a deliberate decision and its own migration
-- either way — this guard does not make that harder, it makes it explicit.
--
-- ===========================================================================
-- WHY A SECOND TRIGGER RATHER THAN EXTENDING THE EXISTING ONE
-- ===========================================================================
--
-- The existing `enforce_webhook_event_restricted_update` is a ROW trigger and
-- must stay one: it compares OLD and NEW column by column, which a statement
-- trigger cannot do (OLD and NEW are not defined there). TRUNCATE therefore
-- needs a separate STATEMENT trigger, which is exactly the shape credit_ledger
-- uses — `credit_ledger_append_only` (row) and `credit_ledger_no_truncate`
-- (statement) both calling one function.
--
-- credit_ledger can share one function between both triggers because its answer
-- is unconditional. This table's answer is not: UPDATE is *partially* allowed
-- (processed_at and error), so its row-trigger function must keep returning
-- NEW. A separate, unconditional function is therefore honest rather than
-- duplicative — the two functions say different things because the table
-- permits different things.
--
-- ===========================================================================
-- PRIVILEGE POSTURE (global rule 8 / ADR-004)
-- ===========================================================================
--
--   anon / authenticated → nothing granted, nothing revoked. Unchanged.
--   service_role         → nothing granted, nothing revoked. Keeps INSERT,
--                          SELECT, UPDATE exactly as T05 and T06 left them.
--   RLS                  → untouched. Still enabled, still zero policies.
--   tables / columns     → none created, none altered. No data is written.
--
-- This migration adds one function and one trigger. It grants nothing, revokes
-- nothing, and changes no existing object.

-- ---------------------------------------------------------------------------
-- 1. Precondition
-- ---------------------------------------------------------------------------
-- The row trigger is what makes this guard *complete* rather than decorative:
-- together they close UPDATE, DELETE and TRUNCATE. If it has gone, this
-- migration is being applied to a table whose protections someone has already
-- changed, and continuing would leave a misleading half-guard behind.

do $$
begin
  if not exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'public.stripe_webhook_events'::regclass
       and t.tgname  = 'stripe_webhook_events_restricted_update'
       and not t.tgisinternal)
  then
    raise exception
      'T09 precondition failed: stripe_webhook_events_restricted_update is missing. '
      'The TRUNCATE guard added here only completes the protection that trigger '
      'starts; on its own it would leave DELETE and identity-column UPDATE open.';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 2. The guard
-- ---------------------------------------------------------------------------
-- Not SECURITY DEFINER: it needs no privilege beyond the caller's — it only
-- raises. search_path is still pinned per §11.2 so the function cannot be
-- reached through a shadowed schema.
--
-- SQLSTATE 0A000 (feature_not_supported) matches credit_ledger's guard and is
-- deliberately NOT 42501: a test must be able to tell "the trigger refused
-- this" from "the role lacked the privilege", or a suite that only ever runs as
-- service_role would pass unchanged if this trigger were dropped.

create or replace function public.enforce_webhook_events_no_truncate()
returns trigger
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
begin
  raise exception
    using errcode = '0A000',
          message = 'stripe_webhook_events may not be truncated',
          detail  = 'These rows are the Stripe replay guard and the evidence of what Stripe sent (ADR-0010 decision 5). A row trigger cannot see TRUNCATE, so this statement trigger is the only thing standing between the table and one command.',
          hint    = 'Mark events processed, or record the failure in `error`. If a retention policy is genuinely needed, design it deliberately and give it its own migration.';
end;
$$;

comment on function public.enforce_webhook_events_no_truncate() is
  'ADR-0016: refuses TRUNCATE on stripe_webhook_events. Statement-level, because a row trigger never fires for TRUNCATE. Raises 0A000 so a trigger refusal is distinguishable from a 42501 privilege refusal.';

drop trigger if exists stripe_webhook_events_no_truncate on public.stripe_webhook_events;
create trigger stripe_webhook_events_no_truncate
  before truncate on public.stripe_webhook_events
  for each statement execute function public.enforce_webhook_events_no_truncate();

-- ---------------------------------------------------------------------------
-- 3. Function privileges (ADR-004 / global rule 8)
-- ---------------------------------------------------------------------------
-- Postgres grants EXECUTE to PUBLIC on function creation. A trigger function
-- does not need an execute grant to fire — the trigger machinery invokes it —
-- so PUBLIC keeps nothing here. This mirrors 20260810042445_functions_owner_only.sql
-- and is stated in the same file as the function so the two cannot drift apart.

revoke all on function public.enforce_webhook_events_no_truncate() from public, anon, authenticated;
