-- `spend_credits` — the sanctioned path for credits to leave an account (T07).
--
-- THE MIGRATION IS AUTHORITATIVE. This file is the reference copy that
-- `supabase/README.md` points at; the database only ever receives this SQL by
-- way of `supabase/migrations/20260811004526_credit_rpcs.sql`, which contains
-- the text below verbatim. A vitest guard
-- (tests/unit/supabase/credit-rpcs-are-the-only-writer.test.ts) fails if the two
-- diverge, so this copy cannot rot into a lie.
--
-- Changing the function means writing a NEW migration and updating this file to
-- match. Never edit an applied migration (RUNBOOK §8).
--
-- The rationale — the spend/grant direction split, the error codes, the
-- privilege posture, why SECURITY DEFINER, and why the ledger insert precedes
-- the balance update — lives in the migration header rather than being
-- duplicated here.

create or replace function public.spend_credits(
  p_user     uuid,
  p_amount   integer,
  p_reason   public.credit_reason,
  p_ref_type text,
  p_ref_id   uuid,
  p_idem     text
)
returns table (new_balance integer, ledger_id uuid)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_delta   integer;
  v_prior   public.credit_ledger;
  v_balance integer;
  v_new     integer;
  v_id      uuid;
begin
  ------------------------------------------------------------------ validate
  if p_user is null then
    raise exception
      using errcode = '22023',
            message = 'INVALID_CREDIT_OPERATION: p_user is required';
  end if;

  -- Zero is rejected here as well as by credit_ledger_delta_non_zero, because a
  -- zero-credit spend that reached the ledger would consume an idempotency key
  -- for a no-op and make every subsequent retry of that key a conflict.
  -- Negative is rejected because a negative spend is a grant wearing a
  -- disguise, and grants are the other function's job — the one that is allowed
  -- to take a balance below zero.
  if p_amount is null or p_amount <= 0 then
    raise exception
      using errcode = '22023',
            message = format('INVALID_CREDIT_OPERATION: spend amount must be a positive number of credits, got %s',
                             coalesce(p_amount::text, 'null')),
            hint    = 'a refund, a chargeback or an administrative correction is grant_credits, not a negative spend';
  end if;

  -- §9.1: unlocking a deal and looking up a barcode are the two things that
  -- cost credits. The other six reasons all describe credits arriving or being
  -- corrected, and every one of them is allowed to leave a negative balance,
  -- which this function is not.
  if p_reason is null or p_reason not in ('unlock_deal', 'barcode_lookup') then
    raise exception
      using errcode = '22023',
            message = format('INVALID_CREDIT_OPERATION: %s is not a consumption reason',
                             coalesce(p_reason::text, 'null')),
            detail  = 'spend_credits writes unlock_deal and barcode_lookup only (§9.1).',
            hint    = 'signup_grant, purchase, refund, chargeback, admin_adjust and promo move through grant_credits';
  end if;

  -- The column is NOT NULL and UNIQUE (T05), so a blank key would be accepted
  -- by the table and would then collide with every other blank key. Rejecting
  -- it here turns a confusing 23505 on the second call into a clear 22023 on
  -- the first.
  if p_idem is null or btrim(p_idem) = '' then
    raise exception
      using errcode = '22023',
            message = 'INVALID_CREDIT_OPERATION: p_idem is required and may not be blank',
            hint    = 'use a value derived from the request being retried, not a fresh uuid per attempt';
  end if;

  -- Ref shape. T05 left ref_type as free text on purpose (ADR-0005 decision 3),
  -- so the only rules worth enforcing are the ones that make a reference
  -- resolvable at all: it is not blank, and the discriminator and the id travel
  -- together. A ref_id with no ref_type points at an unknown table; a ref_type
  -- with no ref_id points at nothing.
  if p_ref_type is not null and btrim(p_ref_type) = '' then
    raise exception
      using errcode = '22023',
            message = 'INVALID_CREDIT_OPERATION: p_ref_type may not be blank',
            hint    = 'pass NULL for an unreferenced movement, never an empty string';
  end if;

  if (p_ref_type is null) <> (p_ref_id is null) then
    raise exception
      using errcode = '22023',
            message = format('INVALID_CREDIT_OPERATION: p_ref_type and p_ref_id are supplied together or not at all (got %s / %s)',
                             coalesce(p_ref_type, 'null'), coalesce(p_ref_id::text, 'null'));
  end if;

  v_delta := -p_amount;

  --------------------------------------------------------------- idempotency
  v_prior := public.credit_ledger_idempotent_match(
               p_idem, p_user, v_delta, p_reason, p_ref_type, p_ref_id);

  if v_prior.id is not null then
    -- The PRIOR result, not the current balance. A replay must be deterministic
    -- for the life of the row: if the user has spent more since, their balance
    -- has moved on, but the answer to "what did this operation do" has not.
    return query select v_prior.balance_after, v_prior.id;
    return;
  end if;

  ----------------------------------------------------------------- lock
  select p.credit_balance into v_balance
    from public.profiles p
   where p.id = p_user
     for update;

  if not found then
    raise exception
      using errcode = '23503',
            message = format('USER_NOT_FOUND: no profile %s', p_user),
            detail  = 'credit_ledger.user_id references profiles(id); the insert would have failed a moment later.';
  end if;

  ---------------------------------------------------------- sufficiency
  -- AC10.3: no partial state. Nothing has been written at this point, and the
  -- exception unwinds the lock with the row untouched.
  if v_balance < p_amount then
    raise exception
      using errcode    = '23514',
            constraint = 'credit_ledger_spend_within_balance',
            message    = format('INSUFFICIENT_CREDITS: balance %s, requested %s', v_balance, p_amount),
            detail     = 'Ordinary spend may not take a balance below zero (§9.2). Only refunds and chargebacks may, and they are grant_credits.',
            hint       = 'offer the credit packs route before retrying';
  end if;

  v_new := v_balance + v_delta;

  ------------------------------------------------------------------- write
  begin
    insert into public.credit_ledger
      (user_id, delta, reason, ref_type, ref_id, balance_after, idempotency_key)
    values
      (p_user, v_delta, p_reason, p_ref_type, p_ref_id, v_new, p_idem)
    returning id into v_id;
  exception when unique_violation then
    -- Two first attempts with the same key raced. The other one won and has
    -- committed — it must have, or this transaction would still be waiting on
    -- the profile row rather than on the unique index. Resolve the key and
    -- replay its result.
    --
    -- credit_ledger has exactly one unique constraint, so a 23505 here is
    -- always this. The `raise;` re-raises the original if the helper somehow
    -- finds nothing, which is the case under REPEATABLE READ: the caller's
    -- snapshot predates the winner's commit, so the row is invisible and the
    -- correct answer is a serialisation failure the caller retries, not a
    -- fabricated result.
    v_prior := public.credit_ledger_idempotent_match(
                 p_idem, p_user, v_delta, p_reason, p_ref_type, p_ref_id);
    if v_prior.id is null then
      raise;
    end if;
    return query select v_prior.balance_after, v_prior.id;
    return;
  end;

  -- The cache follows the ledger, never the other way round (§11.4). Both
  -- statements are in the caller's transaction, so balance_after and
  -- credit_balance become visible to everyone else at the same instant.
  update public.profiles
     set credit_balance = v_new
   where id = p_user;

  return query select v_new, v_id;
end;
$$;

comment on function public.spend_credits(uuid, integer, public.credit_reason, text, uuid, text) is
  'Atomically consume credits (§6.5, AC10.1–AC10.4). p_amount is positive and is written as a negative delta; reasons are unlock_deal and barcode_lookup only. Serialises on the profiles row with FOR UPDATE, refuses to overdraw with 23514 INSUFFICIENT_CREDITS, and is idempotent on credit_ledger.idempotency_key — a replay returns the recorded (balance_after, id), a conflicting reuse raises 23505. EXECUTE: service_role only.';

-- Immediately after CREATE OR REPLACE, in the same file as the body (ADR-004,
-- T07). Postgres grants EXECUTE to PUBLIC on function creation by default.
revoke all on function public.spend_credits(uuid, integer, public.credit_reason, text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.spend_credits(uuid, integer, public.credit_reason, text, uuid, text)
  to service_role;
