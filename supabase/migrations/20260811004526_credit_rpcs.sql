-- T07 — Atomic credit RPCs: the only sanctioned path for credits to move.
--
-- Two functions, one private helper, and the explicit privilege statements that
-- ADR-004 makes non-optional. Nothing else: no table, column, constraint,
-- index, trigger, policy or RLS setting is created or altered here, and no row
-- is written. T05 built the ledger, T06 opened the client surface around it,
-- and this migration adds the single writer both of them assumed.
--
-- ---------------------------------------------------------------------------
-- WHAT THE LEDGER IS, AND WHAT THESE FUNCTIONS THEREFORE ARE
-- ---------------------------------------------------------------------------
--
-- ADR-0013 decision 3 settled the question T07 has to act on: a `deal_unlocks`
-- or `barcode_lookups` row is an ACTIVITY record and proves nothing about
-- payment — `authenticated` can insert one with `credits_spent = 0`. The
-- FINANCIAL record is `credit_ledger`, which no client can write at either
-- layer. So these functions never read an activity row to decide anything, and
-- they never accept a caller's idea of what a spend cost: `spend_credits`
-- derives `delta` from its own `p_amount` after validating it, and the balance
-- it checks comes from a locked `profiles` row, not from an argument.
--
-- They also do not WRITE an activity row. §6.5 requires unlock to be
-- `spend_credits` + `insert deal_unlocks` in one transaction, and AC10.4
-- requires neither half to exist without the other — but T07's acceptance
-- criteria list two functions and their privileges, and folding a deal_id and a
-- market_id into a credit primitive would make every future consumer of credits
-- a change to this file. The transaction is the caller's to open; T23 owns the
-- unlock route. See the note at the foot of this migration for the one thing
-- T23 has to solve that is not solvable through PostgREST.
--
-- ---------------------------------------------------------------------------
-- DIRECTION: WHY `grant_credits` TAKES A SIGNED AMOUNT
-- ---------------------------------------------------------------------------
--
-- T07 says grant_credits "permits a negative resulting balance (refunds and
-- chargebacks, §9.2)". A POSITIVE grant onto a non-negative balance can never
-- produce a negative balance, so that sentence is only satisfiable if
-- grant_credits accepts a negative amount — which is exactly the chargeback
-- clawback of §9.2 rule 4 and AC17.5. The split is therefore:
--
--   spend_credits   consumption.  p_amount > 0, writes delta = -p_amount,
--                   refuses to overdraw.  Reasons: unlock_deal, barcode_lookup.
--   grant_credits   everything else.  p_amount signed and non-zero, writes
--                   delta = p_amount, permits the result to go negative.
--                   Reasons: signup_grant / purchase / refund / promo (must be
--                   positive), chargeback (must be negative), admin_adjust
--                   (signed by definition).
--
-- `chargeback` is deliberately NOT routable through spend_credits. There it
-- would meet the INSUFFICIENT_CREDITS guard, and a Stripe reversal that fails
-- because the user already spent the credits is the precise opposite of AC17.5
-- ("permitting a negative balance; history is never erased").
--
-- The per-reason direction rules restate, at the one writer, the check
-- constraint `credit_ledger_reversal_direction` already enforces for `refund`
-- and `chargeback`, and extend it to the four reasons T05 deliberately left
-- unconstrained at the storage layer. Nothing here weakens that constraint: a
-- row this file would refuse to build is still refused by the table if some
-- future writer tries it.
--
-- ---------------------------------------------------------------------------
-- ERROR CODES — chosen to be distinguishable, per the precedent set by
-- enforce_credit_ledger_append_only (0A000) and enforce_deal_lifecycle (23514)
-- ---------------------------------------------------------------------------
--
--   23514  check_violation           INSUFFICIENT_CREDITS. A business rule
--                                    refused, which is what 23514 already means
--                                    in this schema (enforce_deal_lifecycle).
--   22023  invalid_parameter_value   INVALID_CREDIT_OPERATION. Amount, reason
--                                    direction, blank idempotency key, ref
--                                    shape — everything caught before a lock is
--                                    taken or a row is written.
--   23505  unique_violation          IDEMPOTENCY_KEY_CONFLICT. Literally true:
--                                    the key is unique and was reused for a
--                                    different operation.
--   23503  foreign_key_violation     USER_NOT_FOUND. The same code the ledger
--                                    insert would have raised a moment later.
--
-- Each message begins with the stable token, so a caller can match on the
-- token, the SQLSTATE, or both. `INSUFFICIENT_CREDITS` is spelled exactly as
-- §6.5 and AC10.3 name it.
--
-- ---------------------------------------------------------------------------
-- PRIVILEGE POSTURE (TASKS.md rule 8, ADR-004, RUNBOOK migration checklist)
-- ---------------------------------------------------------------------------
--
--   anon           → nothing. No EXECUTE on any of the three functions.
--   authenticated  → nothing. No EXECUTE on any of the three functions.
--                    A user does not spend their own credits directly; the
--                    server does it on their behalf, because the amount and the
--                    reason are server decisions (ADR-0013 decision 3).
--   service_role   → EXECUTE on spend_credits and grant_credits only.
--   PUBLIC         → revoked explicitly on all three.
--   owner          → EXECUTE, as always.
--
-- The REVOKE is not redundant even though T03 set
-- `ALTER DEFAULT PRIVILEGES ... REVOKE ALL ON FUNCTIONS FROM public, anon,
-- authenticated, service_role`. T07's acceptance criteria require it in the
-- same file as the body and immediately after every CREATE OR REPLACE, and the
-- reason is worth restating: a default privilege applies to functions created
-- by the role it was declared for, in the schema it was declared for, and a
-- later migration that fixes a bug in one of these functions with a plain
-- CREATE OR REPLACE inherits whatever ACL is in force at that moment. A
-- SECURITY DEFINER credit function carrying a PUBLIC execute grant is a direct
-- route to minting credits, so the revoke travels with the body.
--
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER — required by T07, and its authority is minimised
-- ---------------------------------------------------------------------------
--
-- The two RPCs are SECURITY DEFINER because T07 requires it. Being honest about
-- what that buys today: `service_role` already holds INSERT on credit_ledger
-- and UPDATE on profiles (T05, T06) and bypasses RLS, so it could perform these
-- writes without a definer function. The value is in what it makes possible
-- LATER — those two grants can be narrowed to nothing without breaking this
-- path, which is the direction ADR-004 pushes and the direction a T26 review of
-- the credit surface should take. It also means the function's authority does
-- not vary with the caller, so a future decision to grant EXECUTE to
-- `authenticated` would be a privilege decision in one line rather than a
-- rewrite.
--
-- Authority is minimised in the ways available:
--   - `set search_path = public, pg_temp` on all three, exactly as T07 requires.
--     pg_temp last, never first, so a caller's temporary schema cannot shadow a
--     name the body resolves.
--   - Every reference inside the bodies is schema-qualified anyway, so the
--     search_path is a second line rather than the only one.
--   - The bodies touch exactly two tables, `public.profiles` and
--     `public.credit_ledger`, and no other object.
--   - The helper is SECURITY INVOKER. It only reads, it is only ever reached
--     from inside a definer function that is already running as the owner, and
--     definer rights it does not need are definer rights it does not get.

-- ===========================================================================
-- 1. credit_ledger_idempotent_match — one definition of "the same operation"
-- ===========================================================================
--
-- Both RPCs need to answer the same question in two places each: "has this
-- idempotency key already been used, and if so was it for THIS operation?"
-- Four copies of that predicate is four chances for the definition of identity
-- to drift, and the whole no-double-charge guarantee rests on it, so it is
-- written once.
--
-- Identity is (user_id, delta, reason, ref_type, ref_id). The key alone is not
-- identity: T07 requires a replay to "return the prior result", and returning
-- the prior result for a DIFFERENT operation would silently report success for
-- something that never happened. TASKS.md does not specify what to do with a
-- conflicting reuse, so this is a decision and it is recorded in ADR-0014: it
-- is rejected, with 23505. A caller that wants a different operation wants a
-- different key.
--
-- `created_at` and `balance_after` are excluded from the comparison on purpose:
-- they are outcomes of the first call, not inputs to it, and a replay must not
-- be judged against them.
--
-- Returns NULL when the key is unused. Callers test `.id is null` rather than
-- `IS NULL` on the composite, which is the reliable form for a rowtype.

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

-- ===========================================================================
-- 2. spend_credits — consumption, refuses to overdraw
-- ===========================================================================
--
-- Order of operations is T07's, and each step is where it is for a reason:
--
--   1. validate            — before a lock is taken, so a malformed call costs
--                            nothing and blocks nobody.
--   2. idempotency check   — before the lock, so the overwhelmingly common
--                            retry-of-a-completed-call returns without
--                            contending for the row at all.
--   3. SELECT ... FOR UPDATE on profiles
--                          — the serialisation point. Every credit movement for
--                            a user passes through this one row lock, so two
--                            concurrent spends cannot both read the same
--                            balance. This is the release gate for AC10.1.
--   4. sufficiency         — inside the lock, against the freshly re-read
--                            balance. A check performed before the lock would
--                            be exactly the "check then deduct" §6.5 forbids.
--   5. insert the ledger row
--   6. update the cached balance
--
-- 5 BEFORE 6 IS LOAD-BEARING, not cosmetic. The unique index on
-- idempotency_key is the last line of defence against a double charge, and two
-- transactions that both got past step 2 before either committed will collide
-- there. Because the ledger insert comes first, that collision aborts a plpgsql
-- sub-transaction in which nothing else has happened — the cached balance has
-- not moved — and the handler can resolve the key to the winner's row and
-- return it as a replay. Reverse the order and the losing transaction would
-- have to unwind a balance update to say the same thing.
--
-- Both writes are ordinary statements in the caller's transaction. There is no
-- COMMIT here and there must not be: §6.5's unlock is spend_credits AND the
-- deal_unlocks insert committing together, and a function that committed on its
-- own would make the half-applied state AC10.4 forbids reachable.

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

-- ===========================================================================
-- 3. grant_credits — every other movement, signed, may end below zero
-- ===========================================================================
--
-- Mirrors spend_credits step for step. The two differences are the whole point
-- of there being two functions:
--
--   - p_amount is SIGNED. Positive for signup_grant, purchase, refund and
--     promo; negative for chargeback; either for admin_adjust.
--   - THERE IS NO SUFFICIENCY CHECK. §9.2 rule 4 and AC17.5 require a
--     chargeback to take the balance below zero rather than fail, and AC17.5
--     requires that history is never erased to make the number look tidy. The
--     profile row is still locked FOR UPDATE, for the same reason as in
--     spend_credits: two concurrent movements must not both compute
--     balance_after from the same stale balance, or the ledger stops
--     reconciling with the cache (AC10.8).
--
-- The lock is therefore about ACCOUNTING INTEGRITY here, not about refusing an
-- operation. Removing it would not let anything through that should be blocked;
-- it would silently corrupt balance_after.

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

-- ===========================================================================
-- 4. What this migration deliberately does not do
-- ===========================================================================
--
-- NO CHANGE TO T05 OR T06. service_role keeps SELECT, INSERT on credit_ledger
-- and no UPDATE or DELETE; the append-only trigger and the TRUNCATE trigger are
-- untouched; profiles keeps its column-level UPDATE grant to `authenticated`
-- with credit_balance excluded; no policy is added, dropped or altered.
--
-- TWO THINGS ARE FLAGGED HERE RATHER THAN FIXED, because T07 does not own them:
--
-- (a) "The only sanctioned path" is a convention, not yet a privilege.
--     service_role holds INSERT on credit_ledger and UPDATE on profiles, so
--     server code CAN move credits without these functions. T07's answer is the
--     acceptance criterion "no check-then-deduct logic exists anywhere in
--     application code", which is asserted statically in
--     tests/unit/supabase/credit-rpcs-are-the-only-writer.test.ts. Turning the
--     convention into a privilege means revoking INSERT on credit_ledger and
--     UPDATE (credit_balance) on profiles from service_role — which these
--     SECURITY DEFINER functions would survive unchanged, and which is exactly
--     why they are SECURITY DEFINER. It is not done here because T08's seed and
--     T35's purchase bookkeeping have not been written yet and the blast radius
--     is theirs to measure. Raised for T26 (security review #2: credits).
--
-- (b) §6.5's "spend_credits + insert deal_unlocks in the SAME transaction" is
--     not expressible over PostgREST, which gives one statement per request.
--     T23 will need either a wrapping RPC that does both, or a direct Postgres
--     connection. That is a T23 decision and it needs one; AC10.4 is not
--     satisfiable by two supabase-js calls in a row.

