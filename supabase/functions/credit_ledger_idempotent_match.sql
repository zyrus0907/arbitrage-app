-- `credit_ledger_idempotent_match` — one definition of "the same operation" (T07).
--
-- Private to spend_credits and grant_credits: SECURITY INVOKER, and granted to
-- nobody at all, not even service_role. It is here because the directory is the
-- reference copy of the SQL functions, not because it is an RPC.
--
-- THE MIGRATION IS AUTHORITATIVE. The text below appears verbatim in
-- `supabase/migrations/20260811004526_credit_rpcs.sql`, and a vitest guard fails
-- if the two diverge.

create or replace function public.credit_ledger_idempotent_match(
  p_idem     text,
  p_user     uuid,
  p_delta    integer,
  p_reason   public.credit_reason,
  p_ref_type text,
  p_ref_id   uuid
)
returns public.credit_ledger
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_row public.credit_ledger;
begin
  select * into v_row
    from public.credit_ledger
   where idempotency_key = p_idem;

  if not found then
    return null;
  end if;

  -- IS DISTINCT FROM, not <>, because ref_type and ref_id are nullable and a
  -- null-vs-null comparison with <> yields NULL — which would make every
  -- reference-free replay look like a mismatch that is not a mismatch.
  if v_row.user_id  is distinct from p_user
  or v_row.delta    is distinct from p_delta
  or v_row.reason   is distinct from p_reason
  or v_row.ref_type is distinct from p_ref_type
  or v_row.ref_id   is distinct from p_ref_id then
    raise exception
      using errcode    = '23505',
            constraint = 'credit_ledger_idempotency_key_key',
            message    = format('IDEMPOTENCY_KEY_CONFLICT: %L was already used for a different credit operation', p_idem),
            detail     = format('recorded: user %s, delta %s, reason %s, ref %s/%s; requested: user %s, delta %s, reason %s, ref %s/%s',
                                v_row.user_id, v_row.delta, v_row.reason,
                                coalesce(v_row.ref_type, '-'), coalesce(v_row.ref_id::text, '-'),
                                p_user, p_delta, p_reason,
                                coalesce(p_ref_type, '-'), coalesce(p_ref_id::text, '-')),
            hint       = 'a retry reuses the key with identical arguments; a different operation needs a different key';
  end if;

  return v_row;
end;
$$;

comment on function public.credit_ledger_idempotent_match(text, uuid, integer, public.credit_reason, text, uuid) is
  'Internal to T07. Resolves an idempotency key to its ledger row, returning NULL when unused and raising 23505 IDEMPOTENCY_KEY_CONFLICT when the key was used for a different (user, delta, reason, ref) tuple. SECURITY INVOKER and granted to nobody: it is reached only from spend_credits and grant_credits, which are already running as the owner.';

-- Owner-only. Not even service_role: this is an implementation detail of the
-- two RPCs, and an execute grant on it would be a way to probe which
-- idempotency keys exist.
revoke all on function public.credit_ledger_idempotent_match(text, uuid, integer, public.credit_reason, text, uuid)
  from public, anon, authenticated, service_role;
