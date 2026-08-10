-- T05 — Schema C: credits, multi-currency billing and operational logs.
--
-- Source of truth: docs/TASKS.md v2.3 T05, docs/ARCHITECTURE.md v2.0 §2.3
-- (entities), §2.4 (money), §6.3 (RLS default deny), §9.1–9.3 (credit and
-- payment architecture), §11.2 and §11.4 (financial integrity), and
-- docs/DECISIONS.md ADR-004 (privilege posture), ADR-0005 (enum policy),
-- ADR-0006/ADR-0007 (declared privileges, owner-only functions) and above all
-- ADR-0010 (reversal semantics, retention, double-enforced ledger
-- immutability).
--
-- Conventions carried forward from Schema A and Schema B, unchanged: snake_case,
-- uuid primary keys, timestamptz timestamps, money as bigint MINOR UNITS beside
-- an explicit ISO 4217 currency that cannot be absent, credits as integers
-- (profiles.credit_balance is integer and the ledger must agree with it). No
-- country, currency, marketplace, tax regime or provider name is written into
-- this file; every one of them is a row (§0.3). "Stripe" appears only as the
-- name of the payment processor whose event and object identifiers these
-- columns store — it is the one integration §10.5 names, and no core pricing,
-- deal or market concept depends on it.
--
-- ===========================================================================
-- PRIVILEGE POSTURE (global rule 8 / ADR-004, NARROWED by ADR-0010)
-- ===========================================================================
--
--   anon           → nothing. No privilege of any kind on any table here.
--                    This includes credit_packs and credit_pack_prices: they
--                    are public-read tables eventually, but their GRANT SELECT
--                    lands in T06 alongside the policy that governs it
--                    (`active = true AND stripe_price_id IS NOT NULL`). A grant
--                    without a policy is an ungoverned privilege.
--   authenticated  → nothing. credit_ledger becomes readable by its owner in
--                    T06 — SELECT only, with its policy, and never INSERT,
--                    UPDATE or DELETE at any point in the project's life.
--   service_role   → table DML, EXCEPT for the two narrowings below. This is
--                    the first deviation from ADR-0006's uniform posture and it
--                    is deliberate (ADR-0010 decision 6): service_role is not a
--                    trusted actor, it is the identity every server-side bug
--                    runs as.
--
--                    NARROWING 1 — credit_ledger: SELECT, INSERT only.
--                      UPDATE and DELETE are revoked and must stay revoked.
--                      The ledger is the source of truth for money (§2.3,
--                      AC10.5); nothing in the design edits or removes a ledger
--                      row. A correction is a compensating INSERT, not an edit.
--                      T07's RPCs are SECURITY DEFINER and run as owner, so
--                      this revoke does not constrain the one sanctioned write
--                      path — that is the intended shape, not a loophole.
--
--                    NARROWING 2 — stripe_webhook_events: SELECT, INSERT,
--                      UPDATE. DELETE is revoked. The row IS the replay guard
--                      (AC17.3): deleting one re-opens the duplicate-grant
--                      window it exists to close. UPDATE is retained on purpose
--                      — processed_at and error are written after the fact by
--                      T35, and T06 adds the trigger that restricts UPDATE to
--                      exactly those two columns.
--
--                    A later migration that "restores the standard grants" on
--                    either table would be a regression, not tidying. Both
--                    narrowings are asserted by
--                    supabase/tests/database/schema_c.test.sql.
--   functions      → one created, public.enforce_credit_ledger_append_only(),
--                    owner-only: EXECUTE revoked from PUBLIC, anon,
--                    authenticated and service_role in the same section as its
--                    body (ADR-0007). It is a trigger function, not an RPC, and
--                    not SECURITY DEFINER. The shared set_updated_at() from
--                    Schema A is reused unchanged and stays owner-only too.
--   sequences      → none created. Every key here is a uuid with a
--                    gen_random_uuid() default, except stripe_webhook_events
--                    whose key is the Stripe event id itself. Section 9 asserts
--                    that rather than assuming it.
--   RLS            → enabled on all eight new tables with ZERO policies, which
--                    is T05's acceptance criterion. Policies are T06's.
--
-- ===========================================================================
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- ===========================================================================
--
--   * No immutability trigger on stripe_webhook_events. That table records a
--     process whose outcome is written after the row is inserted; a blanket
--     trigger here would break T35's fulfilment path and would be removed by
--     the next task (ADR-0010 decision 5). T06 adds the RESTRICTED-update
--     trigger: processed_at and error writable, identity/type/payload/
--     received_at frozen.
--   * No RLS policies and no anon/authenticated grants — T06 owns both, and
--     owns them together.
--   * No account-deletion mechanism. This migration fixes the RETENTION shape
--     (ON DELETE RESTRICT on the two financial tables) and therefore makes a
--     plain `delete from auth.users` fail with 23503 while ledger or purchase
--     rows exist. De-identifying the retained rows is a product and privacy
--     decision owned by T10 (ADR-0010, "why account deletion is not solved
--     here"). That consequence is stated here so T10 does not discover it.
--   * No temporal exclusion constraints on tax_schedules / fee_schedules —
--     that is T05A, sequenced immediately after this task.
--   * No fx_rates table (ADR-005, deferred to Phase 3). Not created "for
--     later".

-- ---------------------------------------------------------------------------
-- 1. Enum types
-- ---------------------------------------------------------------------------
--
-- Twelve types exist after T03 and T04. They were inventoried before anything
-- here was written:
--
--   component_band, deal_status, fulfilment_type, gtin_format,
--   market_launch_status, match_method, match_verified_by,
--   price_tax_treatment, purchase_outcome, retailer_source_type, tax_regime,
--   tax_scheme
--
-- None carries a credit reason or a purchase lifecycle, so nothing here is a
-- near-duplicate of an existing type. Two are genuinely new, each listed with
-- why an existing type would not serve:
--
--   NEW  credit_reason            The eight ledger reasons (§2.3, ADR-0010
--                                 decision 1). No existing type is close.
--
--                                 refund and chargeback are BOTH present and
--                                 are NOT interchangeable:
--                                   refund     → POSITIVE. A credit restored
--                                                because WE were wrong about a
--                                                deal (AC15.4, §9.3). A
--                                                product-quality event, counted
--                                                by the "credit refunds issued"
--                                                trust-damage metric
--                                                (PRODUCT_SPEC §9.4).
--                                   chargeback → NEGATIVE. Credits clawed back
--                                                because Stripe reversed the
--                                                payment that created them
--                                                (charge.refunded,
--                                                charge.dispute.created —
--                                                AC17.5, §9.2 rule 4). A
--                                                payment event, reconciled
--                                                against Stripe, and it may
--                                                drive the balance negative.
--                                 Collapsing them would make a payment dispute
--                                 count as product goodwill and would leave
--                                 T35's reconciliation unable to tell a product
--                                 failure from a payment failure. The SIGN
--                                 cannot separate them after the fact either,
--                                 because admin_adjust may also be negative.
--
--   NEW  credit_purchase_status   pending | paid | failed | refunded (§2.3).
--                                 A closed domain fixed by the purchase flow in
--                                 §9.2; purchase_outcome (T04) is the user's
--                                 resale outcome for a physical purchase and
--                                 shares neither values nor meaning.
--
-- Three columns that could have been enums are deliberately text, per ADR-0005
-- decision 3 ("enums only for closed domains"):
--
--   api_usage_log.status   No document closes this domain. It is a provider
--   ingestion_runs.status  call/run outcome vocabulary owned by T17 and T19,
--                          and an enum would mean a migration every time a
--                          provider surfaces a new failure mode — the same
--                          objection that keeps marketplaces.provider text.
--   credit_ledger.ref_type §2.3 types it as a free reference discriminator. The
--                          set of referable things grows with every feature that
--                          moves credits.

do $$
begin
  -- §2.3 credit_ledger.reason, in the order ARCHITECTURE.md lists them.
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
     where n.nspname = 'public' and t.typname = 'credit_reason'
  ) then
    create type public.credit_reason as enum (
      'signup_grant', 'purchase', 'unlock_deal', 'barcode_lookup',
      'refund', 'chargeback', 'admin_adjust', 'promo');
  end if;

  -- §2.3 credit_purchases.status, declared in lifecycle order.
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
     where n.nspname = 'public' and t.typname = 'credit_purchase_status'
  ) then
    create type public.credit_purchase_status as enum (
      'pending', 'paid', 'failed', 'refunded');
  end if;
end
$$;

comment on type public.credit_reason is
  'Why credits moved. refund is a POSITIVE restoration after our own error (AC15.4); chargeback is a NEGATIVE clawback after Stripe reversed a payment (AC17.5). One is a quality event, the other a payment event, and they are reported and reconciled separately (ADR-0010).';

-- ---------------------------------------------------------------------------
-- 2. Credit packs and their per-currency prices (§2.3, §9.1)
-- ---------------------------------------------------------------------------
--
-- The split is the whole reason selling into a second country is a seeding
-- exercise rather than a refactor: pack VALUE is credits (currency-neutral),
-- pack PRICE is per currency. One credit costs one unlock in Manchester and in
-- Munich; only the price list differs.

create table if not exists public.credit_packs (
  id         uuid        primary key default gen_random_uuid(),
  name       text        not null,
  -- A free or negative pack is not a product (T05, §2.3).
  credits    integer     not null
             constraint credit_packs_credits_positive check (credits > 0),
  -- Inactive until deliberately switched on, the same posture markets and
  -- marketplaces take. A pack that appears because someone forgot a flag is a
  -- pricing incident.
  active     boolean     not null default false,
  sort_order integer     not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.credit_packs is
  'What a pack is worth, in credits — currency-neutral by design (§9.1). What it costs is credit_pack_prices, one row per currency.';
comment on column public.credit_packs.credits is
  'Credit quantity. Never a price: credits are the unit of value, currency is only the unit of payment.';

create table if not exists public.credit_pack_prices (
  id              uuid        primary key default gen_random_uuid(),
  credit_pack_id  uuid        not null references public.credit_packs (id) on delete restrict,
  -- §11.2: money never travels without its currency, and the currency is a real
  -- reference rather than a free string.
  currency        text        not null references public.currencies (code) on delete restrict,
  amount_minor    bigint      not null
                  constraint credit_pack_prices_amount_positive check (amount_minor > 0),
  -- NULLABLE ON PURPOSE (ADR-0010 decision 4). T08 seeds pack prices in week 2;
  -- T34 creates the Stripe Prices in week 5. A NOT NULL column here would force
  -- T08 to invent a placeholder, and a fake id like 'price_TODO' is worse than
  -- a NULL in three ways: it satisfies every IS NOT NULL check, it is
  -- indistinguishable from a real id on inspection, and it fails at the
  -- Checkout call rather than at seed time. The safety is a READ PREDICATE, not
  -- a column constraint — T06 makes a price publicly readable only where
  -- `active = true AND stripe_price_id IS NOT NULL`, so an unbuyable price is
  -- invisible rather than clickable.
  stripe_price_id text,
  active          boolean     not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- One price per pack per currency (§2.3). This is what lets a single pack
  -- carry GBP, USD and EUR prices without duplicating the pack.
  constraint credit_pack_prices_pack_currency_key unique (credit_pack_id, currency),
  -- Referenced by credit_purchases' composite foreign key so a purchase cannot
  -- record a currency its price row does not carry. Adds no restriction on what
  -- rows this table may hold — (primary key, any column) is unique already —
  -- it exists solely to be referenceable, exactly as markets UNIQUE(id,
  -- currency) does in Schema A.
  constraint credit_pack_prices_id_currency_key unique (id, currency),
  -- ADDITION beyond the literal T05 criteria, stated so it is a decision rather
  -- than an accident: two price rows must not point at the same Stripe Price,
  -- or one Stripe object sells two different credit quantities and the
  -- reconciliation in T35 cannot say which. Many NULLs do not conflict in a
  -- unique index, so this constrains nothing until T34 populates the column —
  -- which is precisely the window in which it must not get in T08's way.
  constraint credit_pack_prices_stripe_price_key unique (stripe_price_id)
);

comment on table public.credit_pack_prices is
  'Per-currency price for a pack (§9.1). Prices are set deliberately per market, never FX-converted from a base currency into an odd local number.';
comment on column public.credit_pack_prices.stripe_price_id is
  'Nullable until T34 creates the Stripe Price (ADR-0010). NEVER a placeholder: T08 seeds NULL, and T06 hides NULL-priced rows from clients rather than showing a button that cannot check out.';
comment on column public.credit_pack_prices.amount_minor is
  'Integer MINOR units of `currency` (§2.4). The minor-unit exponent is data in currencies, never an assumed x100.';

-- ---------------------------------------------------------------------------
-- 3. credit_ledger — the source of truth for money (§2.3, §11.2, §11.4)
-- ---------------------------------------------------------------------------
--
-- Columns are exactly §2.3's list. There is deliberately NO updated_at and no
-- set_updated_at trigger: ADR-0005 decision 5 put updated_at on every Schema A
-- table because reference data is edited, and an "when was this last changed"
-- column on an append-only table is a contradiction the append-only trigger
-- below would raise on anyway.

create table if not exists public.credit_ledger (
  id              uuid        primary key default gen_random_uuid(),
  -- ON DELETE RESTRICT, deliberately NOT the cascade the four Schema B user
  -- activity tables use (ADR-0010 decision 2, §11.4, §11.5, AC1.6). Financial
  -- history is audit and reconciliation evidence: evidence a user can delete by
  -- closing their account is not evidence, and a chargeback can arrive months
  -- after the account is gone.
  --
  -- CASCADE CHAIN, TRACED END TO END so T10 does not discover it: profiles.id
  -- cascades FROM auth.users, so this RESTRICT sits two levels down and a plain
  -- `delete from auth.users` fails with 23503 while any ledger row exists.
  -- Account deletion therefore becomes a PSEUDONYMISATION problem. This
  -- migration does not invent that mechanism — T10 owns it and records its own
  -- ADR.
  user_id         uuid        not null references public.profiles (id) on delete restrict,
  -- Integer credits, matching profiles.credit_balance, so the §11.4
  -- reconciliation invariant `sum(delta) == credit_balance` compares like with
  -- like. Signed: negative for spend and clawback, positive for grant and
  -- restoration.
  delta           integer     not null
                  constraint credit_ledger_delta_non_zero check (delta <> 0),
  reason          public.credit_reason not null,
  ref_type        text,
  ref_id          uuid,
  -- NOT NULL and deliberately WITHOUT a non-negative check (§2.3, AC17.5): a
  -- chargeback must be able to take the balance below zero. Spending is blocked
  -- at a negative balance by T07; history is never erased to make the number
  -- look tidy.
  balance_after   integer     not null,
  -- NOT NULL and UNIQUE. Nullable would defeat the guard entirely — several
  -- NULLs do not conflict in a unique index, so every unkeyed write would pass.
  -- T07's "same key twice charges once" and T35's exactly-once webhook
  -- fulfilment both rest on this column being mandatory.
  idempotency_key text        not null,
  created_at      timestamptz not null default now(),
  constraint credit_ledger_idempotency_key_key unique (idempotency_key),
  -- ADDITION beyond the literal T05 criteria, stated so it is a decision rather
  -- than an accident. ADR-0010 decision 1, ARCHITECTURE.md §2.3's reason table
  -- and AC15.4/AC17.5 all fix the direction of these two reasons; this is that
  -- rule at the storage layer, where a reversed sign cannot become a metric
  -- that says the product is fine. The other six reasons are unconstrained on
  -- purpose: admin_adjust is signed by definition, and a promo or grant that
  -- someone later needs to reverse should be an admin_adjust rather than a
  -- backwards refund.
  constraint credit_ledger_reversal_direction check (
        (reason <> 'refund'     or delta > 0)
    and (reason <> 'chargeback' or delta < 0)
  )
);

comment on table public.credit_ledger is
  'Append-only source of truth for credits (§2.3). Credits are currency-neutral by design (§9.1), so this table carries no money column and no currency. Enforced immutable at two independent layers: the trigger below AND the absence of UPDATE/DELETE from service_role (ADR-0010).';
comment on column public.credit_ledger.delta is
  'Signed credit movement. Never zero: a zero-delta row is either a bug or a no-op that silently consumes an idempotency key.';
comment on column public.credit_ledger.balance_after is
  'The balance after this row was applied. MAY BE NEGATIVE (AC17.5) — a chargeback takes the balance below zero rather than erasing history, and spend is blocked instead.';
comment on column public.credit_ledger.idempotency_key is
  'Mandatory and unique. The second of the two idempotency layers in §9.2 rule 3; the first is stripe_webhook_events.stripe_event_id.';
comment on column public.credit_ledger.ref_type is
  'What ref_id points at (deal_unlock, credit_purchase, barcode_lookup, ...). Text rather than an enum: the set of referable things grows with every feature that moves credits (ADR-0005 decision 3).';
comment on column public.credit_ledger.user_id is
  'ON DELETE RESTRICT (ADR-0010): financial history survives account deletion. profiles cascades from auth.users, so this blocks the auth delete too — T10 owns the pseudonymisation that unblocks it.';

-- (user_id, created_at desc) — "my credit history, newest first" (§2.3, T05).
create index if not exists credit_ledger_user_created_at_idx
  on public.credit_ledger (user_id, created_at desc);

-- Append-only enforcement, layer (a) of two (ADR-0010 decision 3) ------------
--
-- Layer (b) is the REVOKE in section 9. NEITHER MAKES THE OTHER REDUNDANT:
--
--   the revoke  stops our own admin client and anything holding the
--               service-role key — the identity every server-side bug runs as;
--   the trigger stops a role that DOES hold UPDATE: the migration owner, a
--               future support script, a Supabase dashboard SQL session — the
--               contexts in which someone "just fixes one row" at 2am.
--
-- AC10.5 promises the DATABASE rejects it, not that our application happens not
-- to try. One layer alone would leave that true by accident of privilege.
--
-- This trigger is created in the SAME MIGRATION as the table, not in T06. A
-- table that holds money must never exist in a mutable state, not even between
-- two migrations.

create or replace function public.enforce_credit_ledger_append_only()
returns trigger
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
begin
  -- Unconditional. There is no privileged caller, no maintenance window and no
  -- correction that justifies editing a ledger row: a mistake is corrected by
  -- INSERTing a compensating row, which is what leaves an audit trail.
  --
  -- OLD and NEW are never referenced, so the same function serves the row-level
  -- UPDATE/DELETE trigger and the statement-level TRUNCATE trigger below.
  --
  -- SQLSTATE 0A000 (feature_not_supported) is chosen so the failure is
  -- distinguishable from 42501 (insufficient_privilege). The two layers must be
  -- tellable apart in a test, or a test that only ever runs as service_role
  -- would pass unchanged if this trigger were dropped.
  raise exception
    using errcode = '0A000',
          message = format('credit_ledger is append-only: %s is not permitted', tg_op),
          detail  = 'The credit ledger is the source of truth for money (AC10.5) and is immutable at two layers: this trigger, and the absence of UPDATE/DELETE from service_role.',
          hint    = 'Correct a ledger error by inserting a compensating row (reason admin_adjust), never by editing or deleting history.';
end;
$$;

comment on function public.enforce_credit_ledger_append_only() is
  'Rejects every UPDATE, DELETE and TRUNCATE on credit_ledger, unconditionally (ADR-0010). Layer (a) of the two-layer append-only guarantee; layer (b) is the REVOKE UPDATE, DELETE FROM service_role in the same migration.';

-- Privilege posture for this function (ADR-0007, RUNBOOK migration checklist):
-- owner-only, stated next to the body rather than inherited from a default set
-- in another migration. It is not SECURITY DEFINER — it needs no privilege the
-- caller lacks — and its search_path is pinned regardless (§11.2). Revoking
-- EXECUTE does not stop the trigger: PostgreSQL checks EXECUTE when a trigger
-- is created, not when it fires, which T03 verified against a probe table and
-- privileges.test.sql asserts permanently.
revoke all on function public.enforce_credit_ledger_append_only()
  from public, anon, authenticated, service_role;

drop trigger if exists credit_ledger_append_only on public.credit_ledger;
create trigger credit_ledger_append_only
  before update or delete on public.credit_ledger
  for each row execute function public.enforce_credit_ledger_append_only();

-- ADDITION beyond the literal T05 criteria, stated so it is a decision rather
-- than an accident: TRUNCATE is neither UPDATE nor DELETE and a row-level
-- trigger never sees it, so `truncate credit_ledger` as the owner would empty
-- the source of truth for money without firing anything above. service_role
-- cannot reach it (it holds no TRUNCATE, here or anywhere — section 9), so this
-- closes the same gap for the privileged roles the row trigger exists to catch.
drop trigger if exists credit_ledger_no_truncate on public.credit_ledger;
create trigger credit_ledger_no_truncate
  before truncate on public.credit_ledger
  for each statement execute function public.enforce_credit_ledger_append_only();

-- ---------------------------------------------------------------------------
-- 4. credit_purchases (§2.3, §9.2)
-- ---------------------------------------------------------------------------

create table if not exists public.credit_purchases (
  id                         uuid        primary key default gen_random_uuid(),
  -- ON DELETE RESTRICT for the same reason as the ledger: purchase history is
  -- the evidence reconciled against Stripe, per currency, daily (§11.4). Same
  -- traced cascade chain, same T10 consequence.
  user_id                    uuid        not null references public.profiles (id) on delete restrict,
  credit_pack_id             uuid        not null references public.credit_packs (id) on delete restrict,
  -- Nullable (§2.3, T05): the price row may be retired after the sale, and a
  -- manual or admin grant has no price row at all. The reference is carried by
  -- the composite foreign key at the foot of this table, which asserts the
  -- purchase's currency against the price row's currency at the same time.
  credit_pack_price_id       uuid,
  -- Nullable, and unique when present. §9.2 creates the credit_purchases row
  -- BEFORE the Stripe Checkout Session exists, so a NOT NULL column here would
  -- make the documented purchase flow impossible; §2.3 lists the column as
  -- UNIQUE and is silent on nullability. Unique still does the work that
  -- matters: one session, one purchase.
  stripe_checkout_session_id text,
  -- Nullable and unique (§2.3, T05): absent until Stripe confirms the payment,
  -- and never shared by two purchases once present.
  stripe_payment_intent_id   text,
  stripe_customer_id         text,
  -- IMMUTABLE PURCHASE SNAPSHOTS (§2.3, T05, ADR-0010). credits, amount_minor
  -- and currency record what was bought and what was paid, frozen at purchase
  -- time, so re-pricing a pack later cannot rewrite what was sold. They are
  -- deliberately NOT looked up through credit_pack_id at read time. status and
  -- completed_at remain mutable: the row records a process, and only those two
  -- describe its progress.
  credits                    integer     not null
                             constraint credit_purchases_credits_positive check (credits > 0),
  amount_minor               bigint      not null
                             constraint credit_purchases_amount_positive check (amount_minor > 0),
  currency                   text        not null references public.currencies (code) on delete restrict,
  status                     public.credit_purchase_status not null default 'pending',
  created_at                 timestamptz not null default now(),
  completed_at               timestamptz,
  updated_at                 timestamptz not null default now(),
  constraint credit_purchases_checkout_session_key unique (stripe_checkout_session_id),
  constraint credit_purchases_payment_intent_key   unique (stripe_payment_intent_id),
  -- ADDITION beyond the literal T05 criteria, stated so it is a decision rather
  -- than an accident, and the same technique ADR-0008 chose for deals: a
  -- purchase recorded in USD against a GBP price row is a reconciliation defect
  -- that a per-currency Stripe comparison (§11.4) would surface months later as
  -- an unexplained gap. MATCH SIMPLE means a NULL credit_pack_price_id skips
  -- the check entirely, which is exactly right — no price row, nothing to
  -- agree with. This constraint also carries the plain reference to
  -- credit_pack_prices, so no separate single-column FK is needed.
  constraint credit_purchases_price_currency_fkey
    foreign key (credit_pack_price_id, currency)
    references public.credit_pack_prices (id, currency)
    on delete restrict
);

comment on table public.credit_purchases is
  'One row per pack purchase (§9.2). Reconciliation evidence against Stripe, per currency (§11.4), retained through account deletion (ADR-0010).';
comment on column public.credit_purchases.credits is
  'Immutable snapshot: how many credits this sale delivered. Frozen at purchase time so re-pricing a pack cannot rewrite what was sold.';
comment on column public.credit_purchases.amount_minor is
  'Immutable snapshot, integer MINOR units of `currency` (§2.4). What the user actually paid.';
comment on column public.credit_purchases.currency is
  'Immutable snapshot. FK-validated and NOT NULL: a currency-free or currency-ambiguous amount must be impossible at the storage layer (§11.2).';
comment on column public.credit_purchases.status is
  'The one genuinely mutable field besides completed_at — the row records a process (§2.3).';
comment on column public.credit_purchases.stripe_checkout_session_id is
  'Nullable because §9.2 inserts this row before creating the Checkout Session; unique so one session can never fulfil two purchases.';
comment on column public.credit_purchases.credit_pack_price_id is
  'Which per-currency price the sale was made at. Nullable: a price row may be retired, and an admin grant has none.';
comment on column public.credit_purchases.user_id is
  'ON DELETE RESTRICT (ADR-0010, AC1.6): purchase history is reconciliation evidence and survives account deletion.';

create index if not exists credit_purchases_user_created_at_idx
  on public.credit_purchases (user_id, created_at desc);

-- Reconciliation and the "stuck pending" sweep both read by status (§11.4).
create index if not exists credit_purchases_status_idx
  on public.credit_purchases (status);

-- ---------------------------------------------------------------------------
-- 5. stripe_webhook_events — the replay guard (§2.3, §9.2 rule 3, AC17.3)
-- ---------------------------------------------------------------------------
--
-- NOT IMMUTABLE, and deliberately so (ADR-0010 decision 5). Unlike the ledger,
-- this row describes a process whose outcome is written after the fact. T05
-- creates it plainly mutable and T06 adds the RESTRICTED-update trigger:
-- processed_at and error writable; stripe_event_id, type, payload and
-- received_at frozen. A blanket immutability trigger here would make the table
-- unusable by T35 and would be removed by the next task.
--
-- Columns are exactly §2.3's list: no created_at (received_at is the arrival
-- time) and no updated_at, which would otherwise become a fourth column T06's
-- restricted-update trigger has to carve out an exception for.

create table if not exists public.stripe_webhook_events (
  -- The event id IS the primary key — the first of §9.2's two idempotency
  -- layers. A duplicate delivery collides here and the handler returns 200
  -- without granting anything twice (AC17.3).
  stripe_event_id text        primary key,
  type            text        not null,
  payload         jsonb       not null
                  constraint stripe_webhook_events_payload_is_object check (jsonb_typeof(payload) = 'object'),
  received_at     timestamptz not null default now(),
  -- NULL means received but not yet fulfilled. This is the column T35 writes on
  -- success and the column a reconciliation sweep looks for.
  processed_at    timestamptz,
  error           text
);

comment on table public.stripe_webhook_events is
  'Every webhook delivery, keyed by Stripe''s event id — the first idempotency layer (§9.2 rule 3, AC17.3). Restricted rather than immutable: identity/type/payload/received_at are frozen by T06''s trigger, processed_at and error are written after the fact. DELETE is revoked from service_role: the row IS the replay guard.';
comment on column public.stripe_webhook_events.processed_at is
  'NULL until the event has been fulfilled. Writable on purpose (ADR-0010) — with `error`, one of exactly two columns T06''s restricted-UPDATE trigger permits changing.';
comment on column public.stripe_webhook_events.payload is
  'The raw Stripe event body, frozen. Signature verification happens against the raw request body before this row is written (§9.2 rule 2).';

-- ---------------------------------------------------------------------------
-- 6. Operational logs (§2.3, §9.3 funnel, §10.2 quota budgeting)
-- ---------------------------------------------------------------------------
--
-- All three carry exactly §2.3's column set. They are records of things that
-- happened, so their own timestamp is their creation time and none carries
-- updated_at.

-- api_usage_log --------------------------------------------------------------
-- Provider cost is technical risk #6: unbounded refresh loops exhaust a token
-- quota by lunchtime, and the cost of adding a market must be visible before
-- the invoice is (§10.2). Hence the per-marketplace index below.
create table if not exists public.api_usage_log (
  id             uuid        primary key default gen_random_uuid(),
  -- text, not an enum: adding a provider must never need a migration (§0.3,
  -- ADR-0005 decision 3). Matches marketplaces.provider.
  provider       text        not null,
  -- Nullable: not every provider call is marketplace-scoped — a retailer feed
  -- fetch or a payment-processor call has no marketplace — and a NOT NULL
  -- column would simply mean those calls go unlogged, which is the opposite of
  -- what a cost log is for. RESTRICT rather than SET NULL: a marketplace is
  -- configuration that is effectively never deleted, and cost history that
  -- silently loses its attribution stops answering the question it exists for.
  marketplace_id uuid        references public.marketplaces (id) on delete restrict,
  endpoint       text        not null,
  -- Generic units: Keepa bills in tokens, another provider bills in requests.
  -- The word "token" stays inside the adapter (§10.1).
  units_used     integer     not null default 0
                 constraint api_usage_log_units_non_negative check (units_used >= 0),
  -- An ESTIMATE, and optional: a provider that does not price a call per unit
  -- still produced a call worth logging.
  cost_minor_est bigint
                 constraint api_usage_log_cost_non_negative check (cost_minor_est is null or cost_minor_est >= 0),
  currency       text        references public.currencies (code) on delete restrict,
  -- text, not an enum: no document closes this domain, and it is owned by the
  -- adapter layer in T17.
  status         text        not null,
  latency_ms     integer
                 constraint api_usage_log_latency_non_negative check (latency_ms is null or latency_ms >= 0),
  created_at     timestamptz not null default now(),
  -- §11.2: an amount without its currency must be impossible at the storage
  -- layer. The pairing runs both ways — a currency with no amount is
  -- meaningless too. Same form as watchlist_items in Schema B, because the
  -- money here is genuinely optional.
  constraint api_usage_log_cost_requires_currency
    check ((cost_minor_est is null) = (currency is null))
);

comment on table public.api_usage_log is
  'One row per outbound provider call. Quota budgeting is an architectural concern (§10.2, risk #6): this is where the cost of an extra market becomes visible before the invoice does.';
comment on column public.api_usage_log.cost_minor_est is
  'ESTIMATED cost in integer MINOR units of `currency` (§2.4). Estimated, because provider billing is reconciled monthly and this is a running signal, not an invoice.';

create index if not exists api_usage_log_provider_created_at_idx
  on public.api_usage_log (provider, created_at desc);

create index if not exists api_usage_log_marketplace_created_at_idx
  on public.api_usage_log (marketplace_id, created_at desc);

-- ingestion_runs -------------------------------------------------------------
create table if not exists public.ingestion_runs (
  id            uuid        primary key default gen_random_uuid(),
  -- NOT NULL: an ingestion run always happens in exactly one market (§1.4).
  -- RESTRICT keeps the run history attributable.
  market_id     uuid        not null references public.markets (id) on delete restrict,
  source        text        not null,
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  -- text, not an enum: the run vocabulary is owned by T19 and no document closes
  -- it (ADR-0005 decision 3).
  status        text        not null,
  -- AC3.4: every run records rows in, rows upserted and rows failed.
  rows_in       integer     not null default 0
                constraint ingestion_runs_rows_in_non_negative check (rows_in >= 0),
  rows_upserted integer     not null default 0
                constraint ingestion_runs_rows_upserted_non_negative check (rows_upserted >= 0),
  rows_failed   integer     not null default 0
                constraint ingestion_runs_rows_failed_non_negative check (rows_failed >= 0),
  -- Per-row errors (AC3.4) and, in T19, the resumption cursor.
  error         jsonb,
  constraint ingestion_runs_finished_after_started
    check (finished_at is null or finished_at >= started_at)
);

comment on table public.ingestion_runs is
  'One row per ingestion run, scoped to a market. Records rows in, upserted and failed with per-row errors (AC3.4); T19 also keeps its resumption cursor here.';

create index if not exists ingestion_runs_market_started_at_idx
  on public.ingestion_runs (market_id, started_at desc);

-- app_events -----------------------------------------------------------------
create table if not exists public.app_events (
  id         uuid        primary key default gen_random_uuid(),
  -- Nullable, ON DELETE SET NULL. §11.5 enumerates what cascades from
  -- auth.users and app_events is not on that list, so the behaviour is a
  -- decision rather than an inheritance: the funnel question (§9.3) is a COUNT,
  -- not a person, and the ADR-0009 precedent for a provenance reference is SET
  -- NULL. Deleting an account therefore de-identifies the event instead of
  -- deleting it, and — unlike the two financial tables — never blocks the
  -- delete. Also nullable because an event can precede any account at all.
  user_id    uuid        references public.profiles (id) on delete set null,
  -- Nullable: signup and marketing events happen before a market is chosen.
  market_id  uuid        references public.markets (id) on delete restrict,
  event      text        not null,
  properties jsonb       not null default '{}'::jsonb
             constraint app_events_properties_is_object check (jsonb_typeof(properties) = 'object'),
  created_at timestamptz not null default now()
);

comment on table public.app_events is
  'Market-tagged product events for the §9.3 funnel only — signup, onboarding complete, first deal detail viewed, unlock, purchase recorded, outcome recorded, pack purchased. Not general analytics sprawl (T39).';

-- The rule is written where the next author will see it, which is the point.
comment on column public.app_events.properties is
  'NO PII. Never an email address, a name, free text typed by a user, a raw barcode, an IP address or any other identifier of a person. This is an event-SHAPE bag for funnel questions (§9.3) and it is the least governed column in the schema: nothing validates its contents, so the rule has to hold by discipline. "GDPR-grade baseline for everyone" (§11.5) is not maintainable if arbitrary personal data can arrive here through a helper someone writes in T25. Use ids and enums that resolve against a governed table, or a bucketed value. If a property needs to identify a person, it belongs in a table with a policy, not here.';
comment on column public.app_events.user_id is
  'ON DELETE SET NULL: the funnel keeps the count, the row stops identifying anyone, and account deletion is never blocked by an analytics row (§11.5).';

create index if not exists app_events_event_created_at_idx
  on public.app_events (event, created_at desc);

create index if not exists app_events_user_created_at_idx
  on public.app_events (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 7. updated_at triggers
-- ---------------------------------------------------------------------------
--
-- The shared Schema A function, reused. It stays owner-only (ADR-0007):
-- EXECUTE on a trigger function is checked when the trigger is created, not
-- when it fires.
--
-- Only the three tables that are genuinely edited get one. credit_ledger is
-- append-only; stripe_webhook_events must expose exactly two writable columns
-- to T06's restricted-update trigger; the three operational logs are records of
-- events that already happened.

do $$
declare
  t text;
begin
  foreach t in array array[
    'credit_packs', 'credit_pack_prices', 'credit_purchases'
  ]
  loop
    execute format('drop trigger if exists set_updated_at on public.%I', t);
    execute format(
      'create trigger set_updated_at before update on public.%I
         for each row execute function public.set_updated_at()', t);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- 8. Row Level Security — enabled, no policies (§6.3, T05 acceptance criteria)
-- ---------------------------------------------------------------------------
--
-- What T06 will do with each of these, recorded here so the absence of a policy
-- reads as a decision rather than an omission:
--
--   credit_ledger        → SELECT own rows, for `authenticated`, and nothing
--                          else ever. No INSERT/UPDATE/DELETE policy and no
--                          such grant, at any point.
--   credit_packs         → public read, active rows only.
--   credit_pack_prices   → public read where `active = true AND
--                          stripe_price_id IS NOT NULL` (ADR-0010 decision 4).
--   credit_purchases     → service-role only. No policy.
--   stripe_webhook_events, api_usage_log, ingestion_runs, app_events
--                        → service-role only. No policy.

alter table public.credit_packs          enable row level security;
alter table public.credit_pack_prices    enable row level security;
alter table public.credit_ledger         enable row level security;
alter table public.credit_purchases      enable row level security;
alter table public.stripe_webhook_events enable row level security;
alter table public.api_usage_log         enable row level security;
alter table public.ingestion_runs        enable row level security;
alter table public.app_events            enable row level security;

-- ---------------------------------------------------------------------------
-- 9. Privileges (ADR-004 and global rule 8, narrowed by ADR-0010)
-- ---------------------------------------------------------------------------
--
-- The posture declared in this file's header, made real. REVOKE first so the
-- result does not depend on what any default privilege happened to grant —
-- that dependence is precisely the local<->remote divergence
-- 20260810033236_normalise_privileges.sql was written to remove, and a table
-- created in a later migration must not quietly re-import it.

revoke all on table
  public.credit_packs,
  public.credit_pack_prices,
  public.credit_ledger,
  public.credit_purchases,
  public.stripe_webhook_events,
  public.api_usage_log,
  public.ingestion_runs,
  public.app_events
from anon, authenticated, service_role;

-- The standard posture, for the six tables whose write path genuinely performs
-- all four operations. No TRUNCATE, TRIGGER or REFERENCES.
grant select, insert, update, delete on table
  public.credit_packs,
  public.credit_pack_prices,
  public.credit_purchases,
  public.api_usage_log,
  public.ingestion_runs,
  public.app_events
to service_role;

-- NARROWING 1 (ADR-0010 decision 3) — credit_ledger: SELECT and INSERT only.
--
-- UPDATE and DELETE are NOT granted, and this is not an oversight to be tidied
-- up by a later migration restoring the standard four. The role our own server
-- code runs as holds exactly the ledger privileges the design uses: read a
-- balance, append a row. Every correction is a compensating INSERT.
--
-- T07's spend_credits and grant_credits are SECURITY DEFINER and execute as the
-- owner, so this revoke does not constrain the one sanctioned write path. One
-- implementation consequence, recorded in ADR-0010 and repeated where the code
-- will be written: T07's idempotency check must be ON CONFLICT DO NOTHING plus
-- a read of the existing row, never ON CONFLICT DO UPDATE — an upsert on this
-- table is an UPDATE, and the append-only trigger will raise on it, correctly.
grant select, insert on table public.credit_ledger to service_role;

-- NARROWING 2 (ADR-0010 decision 5) — stripe_webhook_events: no DELETE.
--
-- Nothing in the design deletes an event. The row IS the replay protection
-- (AC17.3), and deleting one re-opens the duplicate-grant window it exists to
-- close. UPDATE is retained deliberately — T35 writes processed_at and error
-- after the fact, and T06 adds the trigger that restricts UPDATE to exactly
-- those two columns.
grant select, insert, update on table public.stripe_webhook_events to service_role;

-- Sequences: this migration creates none. Every primary key here is either a
-- uuid with a gen_random_uuid() default or, for stripe_webhook_events, the
-- Stripe event id itself, so there is no sequence for a default grant to attach
-- to. Asserted rather than assumed, because "I did not create one" is exactly
-- the kind of claim that stops being true after a later ALTER TABLE.
do $$
declare
  n integer;
begin
  select count(*) into n
    from pg_class c
    join pg_namespace ns on ns.oid = c.relnamespace
   where ns.nspname = 'public'
     and c.relkind = 'S'
     and c.relname like any (array[
       'credit_packs_%', 'credit_pack_prices_%', 'credit_ledger_%',
       'credit_purchases_%', 'stripe_webhook_events_%', 'api_usage_log_%',
       'ingestion_runs_%', 'app_events_%']);

  if n > 0 then
    raise exception
      'Schema C created % sequence(s); this migration must revoke their default grants explicitly (ADR-004).', n;
  end if;
end
$$;

-- Belt and braces on the two narrowings. The grants above are already narrow,
-- but ADR-0010 states the guarantee as a REVOKE, and a REVOKE of a privilege
-- that was never granted is a no-op that documents intent at the point a future
-- reader will look for it. If a later migration re-grants blanket DML on either
-- table, schema_c.test.sql fails.
revoke update, delete on table public.credit_ledger         from service_role;
revoke delete         on table public.stripe_webhook_events from service_role;
