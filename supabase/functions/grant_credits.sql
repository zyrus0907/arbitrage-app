-- `grant_credits` — every credit movement that is not consumption (T07).
--
-- THE MIGRATION IS AUTHORITATIVE. This file is the reference copy; the database
-- only ever receives this SQL by way of
-- `supabase/migrations/20260811004526_credit_rpcs.sql`, which contains the text
-- below verbatim, and a vitest guard fails if the two diverge.
--
-- Changing the function means writing a NEW migration and updating this file to
-- match. Never edit an applied migration (RUNBOOK §8).
--
-- Note the two deliberate asymmetries with spend_credits: p_amount is SIGNED,
-- and there is no sufficiency check, because §9.2 rule 4 and AC17.5 require a
-- chargeback to take the balance below zero rather than fail.

create or replace function public.grant_credits(
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

  if p_amount is null or p_amount = 0 then
    raise exception
      using errcode = '22023',
            message = format('INVALID_CREDIT_OPERATION: grant amount must be a non-zero number of credits, got %s',
                             coalesce(p_amount::text, 'null')),
            detail  = 'credit_ledger_delta_non_zero rejects a zero delta; a no-op that consumes an idempotency key is worse than an error.';
  end if;

  if p_reason is null then
    raise exception
      using errcode = '22023',
            message = 'INVALID_CREDIT_OPERATION: p_reason is required';
  end if;

  if p_reason in ('unlock_deal', 'barcode_lookup') then
    raise exception
      using errcode = '22023',
            message = format('INVALID_CREDIT_OPERATION: %s is a consumption reason', p_reason),
            detail  = 'grant_credits does not check the balance, so routing consumption through it would bypass INSUFFICIENT_CREDITS entirely.',
            hint    = 'unlock_deal and barcode_lookup move through spend_credits';
  end if;

  -- Direction per reason. refund and chargeback are already fixed by
  -- credit_ledger_reversal_direction; the other three are fixed here, at the
  -- writer, because T05 deliberately left them unconstrained at the storage
  -- layer so that admin_adjust could stay signed (ADR-0010 decision 1).
  if p_reason in ('signup_grant', 'purchase', 'refund', 'promo') and p_amount < 0 then
    raise exception
      using errcode = '22023',
            message = format('INVALID_CREDIT_OPERATION: %s restores or adds credits and must be positive, got %s',
                             p_reason, p_amount),
            hint    = 'a reversal of a grant is admin_adjust; a payment reversal is chargeback';
  end if;

  if p_reason = 'chargeback' and p_amount > 0 then
    raise exception
      using errcode = '22023',
            message = format('INVALID_CREDIT_OPERATION: chargeback claws credits back and must be negative, got %s', p_amount),
            detail  = 'AC17.5: a Stripe reversal deducts with a negative delta. A positive restoration after OUR error is reason refund (AC15.4).';
  end if;

  if p_idem is null or btrim(p_idem) = '' then
    raise exception
      using errcode = '22023',
            message = 'INVALID_CREDIT_OPERATION: p_idem is required and may not be blank',
            hint    = 'the Stripe event id is the natural key for a webhook-driven grant (§9.2 rule 3)';
  end if;

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

  --------------------------------------------------------------- idempotency
  v_prior := public.credit_ledger_idempotent_match(
               p_idem, p_user, p_amount, p_reason, p_ref_type, p_ref_id);

  if v_prior.id is not null then
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

  -- No sufficiency check. See the header: this is the path AC17.5 requires to
  -- be able to end below zero.
  v_new := v_balance + p_amount;

  ------------------------------------------------------------------- write
  begin
    insert into public.credit_ledger
      (user_id, delta, reason, ref_type, ref_id, balance_after, idempotency_key)
    values
      (p_user, p_amount, p_reason, p_ref_type, p_ref_id, v_new, p_idem)
    returning id into v_id;
  exception when unique_violation then
    v_prior := public.credit_ledger_idempotent_match(
                 p_idem, p_user, p_amount, p_reason, p_ref_type, p_ref_id);
    if v_prior.id is null then
      raise;
    end if;
    return query select v_prior.balance_after, v_prior.id;
    return;
  end;

  update public.profiles
     set credit_balance = v_new
   where id = p_user;

  return query select v_new, v_id;
end;
$$;

comment on function public.grant_credits(uuid, integer, public.credit_reason, text, uuid, text) is
  'Atomically move credits for every reason that is not consumption (§9.2, AC15.4, AC17.5). p_amount is SIGNED — positive for signup_grant/purchase/refund/promo, negative for chargeback, either for admin_adjust — and the resulting balance MAY be negative, which is why chargebacks come here rather than through spend_credits. Locks the profiles row so balance_after stays reconcilable, and is idempotent on credit_ledger.idempotency_key. EXECUTE: service_role only.';

revoke all on function public.grant_credits(uuid, integer, public.credit_reason, text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.grant_credits(uuid, integer, public.credit_reason, text, uuid, text)
  to service_role;
