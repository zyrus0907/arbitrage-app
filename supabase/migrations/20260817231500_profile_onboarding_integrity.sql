-- T11 findings F3, F4, F7 — profile / onboarding integrity, enforced by the
-- database rather than by the application.
--
-- WHAT WAS WRONG
--
--   F4  `onboarded_at` was in T06's authenticated column-UPDATE allowlist. A
--       normal signed-in client could `PATCH /profiles?id=eq.<self>` with
--       nothing but `{"onboarded_at": "now"}` over PostgREST and be treated as
--       onboarded by `profileStage()` — country unset, market unset, currency
--       unset, cost assumptions unset. It was a stage-bypass switch that
--       happened to be spelled like a timestamp.
--
--   F3  Nothing tied "onboarded" to a coherent market/country state, so the
--       bypass above produced a profile the rest of the product would treat as
--       ready to be shown deals it has no market, currency or cost basis for.
--
--   F7  `country_code`, `default_market_id` and `assumption_currency` were
--       cross-checked only in `src/services/profile/`. A direct PostgREST call,
--       a future API, or any other client could write GB + the US market, or a
--       GBP budget against a EUR market. §11.3's rule — never trust a
--       client-supplied currency or market id — was being kept by one code
--       path rather than by the storage layer.
--
-- WHY TRIGGERS AND NOT CHECK CONSTRAINTS
--
-- Every invariant here is a statement about a `profiles` row RELATIVE TO a
-- `markets` row. A CHECK constraint may not read another table (it must be
-- immutable, and Postgres will accept a subquery-free approximation only), so
-- the coherence rules are BEFORE-triggers. They are SECURITY DEFINER for one
-- specific reason: `markets` is under RLS and its public-read policy is
-- restricted to `active AND launch_status = 'live'` (ADR-0013). A SECURITY
-- INVOKER trigger would therefore fail to see a market that had since been
-- retired, and an unrelated settings edit by that user would start raising an
-- error about a market they cannot even name. The trigger must read the
-- catalogue as it is, not as the caller may see it.
--
-- NO GRANT AND NO POLICY IS WIDENED BY THIS MIGRATION. One column-level UPDATE
-- grant is REMOVED (`onboarded_at`), and nothing is added.

-- ---------------------------------------------------------------------------
-- 1. F7 — country, market and currency may not contradict one another
-- ---------------------------------------------------------------------------

create or replace function public.profiles_enforce_market_coherence()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  market_country text;
  market_currency text;
  has_money boolean;
begin
  if new.default_market_id is null then
    -- No market selected: the waitlist case (AC2.2) and the fresh-signup case.
    -- There is nothing to be incoherent with, and a country on its own is
    -- exactly what a waitlisted profile is.
    return new;
  end if;

  select m.source_country_code, m.currency
    into market_country, market_currency
    from public.markets m
   where m.id = new.default_market_id;

  if not found then
    -- Unreachable while the foreign key stands; stated anyway so that a future
    -- migration dropping it does not silently turn this trigger into a no-op.
    raise exception 'profiles.default_market_id % does not name a market', new.default_market_id
      using errcode = '23503';
  end if;

  -- The messages below name NO value read from `markets`. This function is
  -- SECURITY DEFINER, so it can see market rows RLS hides from the caller
  -- (ADR-0013 restricts the public read to active + live); echoing the market's
  -- country or currency back in an error would turn it into an oracle that
  -- reports two columns of any market whose id the caller can name. The caller
  -- is told which of THEIR OWN fields is wrong, which is all they need.
  if new.country_code is null or new.country_code <> market_country then
    raise exception
      'profiles.country_code does not match the country the selected market operates in'
      using errcode = '23514',
            constraint = 'profiles_country_matches_market';
  end if;

  has_money := new.default_budget_minor is not null
            or new.prep_cost_per_unit_minor is not null
            or new.inbound_shipping_per_unit_minor is not null;

  -- The currency must match the market whenever it is stated at all. Stating a
  -- currency the market does not trade in is meaningless even with no amounts
  -- attached yet, and allowing it would leave the row one money field away from
  -- a mispriced assumption.
  if new.assumption_currency is not null and new.assumption_currency <> market_currency then
    raise exception
      'profiles.assumption_currency is not the currency of the selected market'
      using errcode = '23514',
            constraint = 'profiles_assumption_currency_matches_market';
  end if;

  if has_money and new.assumption_currency is null then
    -- profiles_assumptions_require_currency already rejects this; stating it
    -- against the resolved market is the part that is new.
    raise exception
      'profiles cost assumptions need an explicit currency matching the selected market'
      using errcode = '23514',
            constraint = 'profiles_assumption_currency_matches_market';
  end if;

  return new;
end;
$$;

comment on function public.profiles_enforce_market_coherence() is
  'T11/F7. Refuses a profiles row whose country_code or assumption_currency contradicts its default_market_id. SECURITY DEFINER so it reads markets as the catalogue has it, not as RLS shows it to the caller.';

revoke all on function public.profiles_enforce_market_coherence() from public, anon, authenticated, service_role;

drop trigger if exists profiles_coherence_before_write on public.profiles;
create trigger profiles_coherence_before_write
  before insert or update on public.profiles
  for each row execute function public.profiles_enforce_market_coherence();

-- ---------------------------------------------------------------------------
-- 2. F3 + F4 — onboarded_at is DERIVED, never asserted
-- ---------------------------------------------------------------------------
--
-- The column stops being an input. It is stamped when — and only when — the row
-- actually carries everything AC2.1 collects, and it is cleared the moment the
-- row stops carrying it. "Onboarded" therefore cannot disagree with the row it
-- describes, in either direction, whatever the writer intended.
--
-- The stamp is preserved once set (`coalesce(old.onboarded_at, now())`), so an
-- unrelated later edit does not move the recorded completion time.
--
-- The tombstone case falls out for free: `pseudonymise_account` nulls every
-- column below, so the row is incomplete and `onboarded_at` is cleared — which
-- is what `profiles_tombstone_carries_no_personal_data` already demands.

create or replace function public.profiles_derive_onboarded_at()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  complete boolean;
begin
  complete :=
        new.deleted_at                      is null
    and new.country_code                    is not null
    and new.default_market_id               is not null
    and new.assumption_currency             is not null
    and new.default_budget_minor            is not null
    and new.prep_cost_per_unit_minor        is not null
    and new.inbound_shipping_per_unit_minor is not null
    -- AC2.1 step 2. A registered seller with no registration country has not
    -- answered the question, and the tax treatment of every profit figure
    -- downstream depends on the answer.
    and (new.tax_registered = false or new.tax_registration_country is not null);

  if complete then
    new.onboarded_at := coalesce(
      case when tg_op = 'UPDATE' then old.onboarded_at else null end,
      now()
    );
  else
    new.onboarded_at := null;
  end if;

  return new;
end;
$$;

comment on function public.profiles_derive_onboarded_at() is
  'T11/F3,F4. onboarded_at is derived from the row, never accepted from a writer: stamped when the profile carries every field AC2.1 collects and coherent with its market, cleared otherwise. Removes onboarded_at as a stage-bypass switch.';

revoke all on function public.profiles_derive_onboarded_at() from public, anon, authenticated, service_role;

drop trigger if exists profiles_onboarded_at_before_write on public.profiles;
create trigger profiles_onboarded_at_before_write
  before insert or update on public.profiles
  for each row execute function public.profiles_derive_onboarded_at();

-- Trigger firing order is alphabetical by trigger name, so coherence
-- (`profiles_c…`) runs before derivation (`profiles_o…`) and before
-- `set_updated_at`. A row that is about to be refused is never stamped.

comment on column public.profiles.onboarded_at is
  'Server-derived, never client-supplied (T11/F3,F4). Set by profiles_derive_onboarded_at when the row holds every field AC2.1 collects; null otherwise. Absent from T06''s authenticated column-UPDATE allowlist.';

-- ---------------------------------------------------------------------------
-- 3. F4 — remove the column-level UPDATE grant
-- ---------------------------------------------------------------------------
--
-- Belt and braces, in the same shape T06 uses for `credit_balance`: the trigger
-- makes a forged value ineffective, and the grant makes attempting it a 42501
-- rather than a silently ignored key. Narrowing only — no grant is added here.

revoke update (onboarded_at) on table public.profiles from authenticated;

-- ---------------------------------------------------------------------------
-- 4. Existing rows
-- ---------------------------------------------------------------------------
--
-- Nothing here rejects a stored row: the coherence trigger fires only on write,
-- and derivation rewrites rather than raises. Rows whose `onboarded_at`
-- disagrees with their contents are corrected once, now, rather than left to be
-- corrected by whatever writes to them next — a profile marked onboarded while
-- carrying no market is the F3 condition itself, and leaving one behind would
-- leave the finding half-open.

update public.profiles p
   set onboarded_at = null
 where p.onboarded_at is not null
   and not (
         p.deleted_at                      is null
     and p.country_code                    is not null
     and p.default_market_id               is not null
     and p.assumption_currency             is not null
     and p.default_budget_minor            is not null
     and p.prep_cost_per_unit_minor        is not null
     and p.inbound_shipping_per_unit_minor is not null
     and (p.tax_registered = false or p.tax_registration_country is not null)
   );
