-- T04 — Schema B: deals, user activity and market scoping.
--
-- Source of truth: docs/TASKS.md v2.1 T04, docs/ARCHITECTURE.md v2.0 §2.3
-- (entities), §2.4 (money), §6.3 (RLS default deny), §7.6 (one deal, one
-- currency), and docs/DECISIONS.md ADR-004 (privilege posture) and ADR-007
-- (deal market-consistency enforced declaratively).
--
-- Conventions carried forward from Schema A, unchanged: snake_case, uuid
-- primary keys, timestamptz timestamps, money as bigint MINOR UNITS beside an
-- explicit ISO 4217 currency that cannot be absent, rates as integer basis
-- points. No country, currency, marketplace, retailer or tax rate is written
-- into this file; every one of them is a row (§0.3).
--
-- ===========================================================================
-- PRIVILEGE POSTURE (global rule 8 / ADR-004) — stated, not implied
-- ===========================================================================
--
--   anon           → nothing. No privilege of any kind on any table here.
--   authenticated  → nothing. deal_unlocks, watchlist_items, purchase_records
--                    and barcode_lookups are user-owned tables and WILL be
--                    reachable by their owner, but their policies AND their
--                    matching per-operation grants both land in T06. A grant
--                    without a policy is an ungoverned privilege; a policy
--                    without a grant is inert. They ship together or not at
--                    all.
--   service_role   → table DML only (SELECT, INSERT, UPDATE, DELETE). No
--                    TRUNCATE, TRIGGER or REFERENCES.
--   functions      → one created, public.enforce_deal_lifecycle(), and it is
--                    owner-only: EXECUTE revoked from PUBLIC, anon,
--                    authenticated and service_role in the same section as its
--                    body (ADR-0007). It is a trigger function, not an RPC, and
--                    not SECURITY DEFINER. The shared set_updated_at() from
--                    Schema A is reused unchanged and stays owner-only too.
--   sequences      → none created. Every key here is a uuid with a
--                    gen_random_uuid() default, so there is no sequence for a
--                    default grant to attach to. Section 7 asserts that rather
--                    than assuming it.
--   RLS            → enabled on all five new tables with ZERO policies, which
--                    is T04's acceptance criterion. Policies are T06's.
--
-- The revokes in section 7 are belt-and-braces: 20260810033236's ALTER DEFAULT
-- PRIVILEGES already means a table postgres creates in public grants nothing to
-- anon or authenticated. They are written anyway, because a posture that
-- depends on a default set in another file is a posture nobody can read here.
--
-- This migration also adds four composite UNIQUE constraints to Schema A tables
-- (section 2). That is additive — no T03 migration is edited, no column is
-- added, altered or dropped, no data is touched, and no privilege changes.

-- ---------------------------------------------------------------------------
-- 1. Enum types
-- ---------------------------------------------------------------------------
--
-- T03 created nine. They were inventoried before anything here was written and
-- one of them is reused rather than duplicated:
--
--   REUSED  price_tax_treatment  ('inclusive' | 'exclusive')
--           → deals.buy_price_tax_treatment. Identical domain to
--             retailer_products.price_tax_treatment; a second type would be a
--             near-duplicate of exactly the kind T04 forbids.
--
-- Three are genuinely new. Each is listed with why an existing type would not
-- serve:
--
--   NEW  component_band     No existing type carries low|medium|high. ONE type
--                           is created and reused by all four band columns
--                           (demand, competition, stability, confidence),
--                           which is T04's explicit requirement. Named for a
--                           score *component* rather than 'score_band' or
--                           'deal_band' on purpose: §8.3's overall deal-score
--                           bands are Excellent/Good/Fair/Weak, and T21 defines
--                           separate profit and ROI bands. Three different
--                           banding concepts, three different names.
--
--   NEW  deal_status        draft | active | retired (ADR-0009). No existing
--                           type has these values.
--
--                           There is deliberately no `stale`. Staleness is a
--                           function of two timestamps — deals.expires_at and
--                           marketplace_products.refreshed_at — and a derived
--                           fact stored as a state is a fact that goes wrong:
--                           it needs a writer, the writer needs a schedule, and
--                           between runs the column lies. `draft` takes its
--                           place as the state the pipeline writes, so a newly
--                           computed deal is invisible until an admin publishes
--                           it (AC3.3).
--
--   NEW  purchase_outcome   §2.3: pending | sold | partial | unsold | returned.
--                           This is the MVP's measurement instrument (F14) and
--                           the domain is closed by the product spec (AC14.4).
--
-- Closed domains only, per ADR-0005 decision 3. Nothing here is a provider,
-- adapter, country, currency or marketplace name — those stay data.

do $$
begin
  -- The four §2.3 band columns share one domain. One type, reused four times.
  if not exists (select 1 from pg_type where typname = 'component_band') then
    create type public.component_band as enum ('low', 'medium', 'high');
  end if;

  -- The deal lifecycle (ADR-0009). Declared in transition order.
  if not exists (select 1 from pg_type where typname = 'deal_status') then
    create type public.deal_status as enum ('draft', 'active', 'retired');
  end if;

  -- §2.3 purchase_records.outcome (AC14.4).
  if not exists (select 1 from pg_type where typname = 'purchase_outcome') then
    create type public.purchase_outcome as enum ('pending', 'sold', 'partial', 'unsold', 'returned');
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 2. Composite unique keys on Schema A — the parents the deal FKs reference
-- ---------------------------------------------------------------------------
--
-- ADR-007 requires deal market-consistency to be enforced by the database on
-- insert AND update, and prefers declarative constraints over a CONSTRAINT
-- TRIGGER because "declarative constraints cannot be bypassed by a COPY or a
-- service-role bulk upsert, and the ingestion pipeline in T19 does bulk
-- upserts."
--
-- A composite foreign key needs a unique key on the parent side to point at.
-- Each of these is (primary key, one parent key) — already unique by virtue of
-- the primary key, so the constraint adds no restriction whatsoever on what
-- rows those tables may hold. It exists solely to be referenceable. This is the
-- whole cost of choosing option (a), and it is why option (a) needs no new
-- column on any T03 table: the denormalisation lands on `deals`, where ADR-007
-- says it should, and nowhere else.
--
-- markets already carries UNIQUE (id, currency) from Schema A — added there for
-- the §1.3 currency invariant — and deals reuses it directly.

do $$
declare
  spec record;
begin
  for spec in
    select *
      from (values
        -- so deals can assert: this retailer belongs to this market
        ('retailers',            'retailers_id_market_key',                'id, market_id'),
        -- so deals can assert: this product belongs to this retailer
        ('retailer_products',    'retailer_products_id_retailer_key',      'id, retailer_id'),
        -- so deals can assert: this market resolves to this marketplace
        ('markets',              'markets_id_marketplace_key',             'id, marketplace_id'),
        -- so deals can assert: this listing belongs to this marketplace
        ('marketplace_products', 'marketplace_products_id_marketplace_key', 'id, marketplace_id')
      ) as t(tbl, con, cols)
  loop
    if not exists (
      select 1
        from pg_constraint
       where conname = spec.con
         and conrelid = format('public.%I', spec.tbl)::regclass
    ) then
      execute format(
        'alter table public.%I add constraint %I unique (%s)',
        spec.tbl, spec.con, spec.cols);
    end if;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- 3. deals — the central read model (§2.3)
-- ---------------------------------------------------------------------------
--
-- Every column T04 enumerates is present. The two beyond that enumeration are
-- retailer_id and marketplace_id: the denormalised parent keys ADR-007's
-- preferred mechanism calls for. Both are NOT NULL, and that is load-bearing
-- rather than tidiness — a composite foreign key is MATCH SIMPLE, so a single
-- NULL in the referencing columns makes PostgreSQL skip the check entirely.
-- A nullable retailer_id would be a hole straight through the cross-market
-- guarantee.
--
-- The money columns are NOT NULL by design. A deal exists only because the
-- pricing engine produced a complete itemised breakdown; AC5.2 and §12.2
-- principle 5 both say a missing input suppresses the deal rather than
-- producing a partial one. NULL here would mean "we did not know", and that
-- state must not be representable in the table users are shown from.
--
-- CROSS-MARKET CONSISTENCY (ADR-007) — five foreign keys, two guarantees.
--
-- ADR-007 states the two rules:
--
--   1. deals.market_id equals the market of retailer_product_id's retailer.
--   2. deals.marketplace_product_id's marketplace_id equals the marketplace_id
--      that deals.market_id resolves to.
--
-- Neither is expressible as a single foreign key, because neither parent key is
-- one hop away. Both are expressible as a *composition* of two, which is what
-- the denormalised retailer_id and marketplace_id are for:
--
--   rule 1  =  deals_retailer_product_fkey  ∘  deals_retailer_market_fkey
--              (product ∈ retailer)            (retailer ∈ market)
--
--   rule 2  =  deals_marketplace_product_fkey  ∘  deals_market_marketplace_fkey
--              (listing ∈ marketplace)            (market → marketplace)
--
-- Why this and not a CONSTRAINT TRIGGER — the mechanism choice ADR-007 asks to
-- be recorded:
--
--   * A foreign key is enforced by the same referential-integrity machinery on
--     INSERT, on UPDATE, on INSERT ... ON CONFLICT DO UPDATE, and on COPY.
--     T19's pipeline does bulk upserts; T20 loads admin CSV. Neither can find a
--     path around this, and neither needs to know it exists.
--   * A trigger can be disabled (ALTER TABLE ... DISABLE TRIGGER) by a role
--     holding table ownership, and `session_replication_role = replica` skips
--     user triggers wholesale. Restore and bulk-load tooling uses both.
--   * The failure is a plain 23503 the pipeline already handles as a row-level
--     error, not a bespoke exception with a bespoke message to parse.
--
-- The cost, stated plainly: two denormalised columns on deals that must not
-- drift, and four unique constraints on Schema A that exist only to be pointed
-- at. ADR-007 accepts the first — "the columns are immutable for the row's
-- lifetime" — and the second is index maintenance on tables that are written by
-- ingestion, not by users.
--
-- Update is covered because PostgreSQL re-checks a foreign key whenever any of
-- its referencing columns changes: moving a valid deal's market_id to another
-- market fails on deals_retailer_market_fkey, since that deal's retailer still
-- belongs to the first market.
--
-- ON DELETE, deliberately mixed:
--   cascade  on the two catalogue parents — a deal is a derived, recomputable
--            artefact (§0.1 assumption 9); when the product it describes is
--            gone the deal is meaningless.
--   no action on the scope parents (market, retailer, marketplace) — NOT
--            restrict. RESTRICT fires immediately, NO ACTION at end of
--            statement, and deleting a retailer legitimately cascades through
--            retailer_products to the deal in the same statement. RESTRICT
--            would reject that valid chain; NO ACTION sees the row already
--            gone. Deletion is still blocked where it must be: deal_unlocks
--            and purchase_records restrict against deals (section 4), so
--            anything a user paid for or acted on cannot be deleted out from
--            under them.

create table if not exists public.deals (
  id                     uuid        primary key default gen_random_uuid(),

  -- Scope --------------------------------------------------------------------
  -- market_id scopes the whole row and leads every feed index (§2.3).
  market_id              uuid        not null,
  -- Denormalised parents (ADR-007). Immutable for the row's lifetime.
  retailer_id            uuid        not null,
  marketplace_id         uuid        not null,

  retailer_product_id    uuid        not null,
  marketplace_product_id uuid        not null,
  -- Copied from product_matches for fast filtering (§2.3). Same numeric(3,2)
  -- domain as the column it is copied from, so the copy cannot widen it.
  match_confidence       numeric(3, 2) not null
                         constraint deals_match_confidence_range check (match_confidence >= 0 and match_confidence <= 1),
  -- One currency for every money column below (§7.6). Tied to the market's
  -- currency by foreign key in section 4, not by convention.
  currency               text        not null,

  -- Costs --------------------------------------------------------------------
  buy_price_minor          bigint  not null
                           constraint deals_buy_price_non_negative check (buy_price_minor >= 0),
  -- Reused enum: the retail price basis is the same closed domain everywhere.
  buy_price_tax_treatment  public.price_tax_treatment not null,
  -- 0 where the regime offers no reclaim or the user is not registered (§7.4).
  buy_tax_reclaim_minor    bigint  not null default 0
                           constraint deals_buy_tax_reclaim_non_negative check (buy_tax_reclaim_minor >= 0),
  inbound_shipping_minor   bigint  not null default 0
                           constraint deals_inbound_shipping_non_negative check (inbound_shipping_minor >= 0),
  prep_cost_minor          bigint  not null default 0
                           constraint deals_prep_cost_non_negative check (prep_cost_minor >= 0),

  -- Revenue ------------------------------------------------------------------
  sell_price_minor         bigint  not null
                           constraint deals_sell_price_non_negative check (sell_price_minor >= 0),
  -- Output tax owed on the sale; 0 when not registered (§7.4).
  sell_tax_liability_minor bigint  not null default 0
                           constraint deals_sell_tax_liability_non_negative check (sell_tax_liability_minor >= 0),

  -- Fees ---------------------------------------------------------------------
  referral_fee_minor       bigint  not null default 0
                           constraint deals_referral_fee_non_negative check (referral_fee_minor >= 0),
  fulfilment_fee_minor     bigint  not null default 0
                           constraint deals_fulfilment_fee_non_negative check (fulfilment_fee_minor >= 0),
  storage_fee_minor        bigint  not null default 0
                           constraint deals_storage_fee_non_negative check (storage_fee_minor >= 0),
  other_fees_minor         bigint  not null default 0
                           constraint deals_other_fees_non_negative check (other_fees_minor >= 0),
  -- Itemised [{code,label,amount_minor}] (§2.3). A list, not a column: this is
  -- what replaces v1.0's hardcoded digital-services-fee, so a new marketplace
  -- levy is a row edit rather than a migration.
  surcharges               jsonb   not null default '[]'::jsonb
                           constraint deals_surcharges_is_array check (jsonb_typeof(surcharges) = 'array'),
  -- The exact schedule versions used, so any historical figure is reproducible
  -- (AC6.10). restrict: a schedule a deal was priced with cannot be deleted out
  -- from under it.
  fee_schedule_id          uuid    not null references public.fee_schedules (id) on delete restrict,
  tax_schedule_id          uuid    not null references public.tax_schedules (id) on delete restrict,

  -- Outputs ------------------------------------------------------------------
  -- Per unit, and signed: a negative net profit is a real result the engine may
  -- produce. §8.3 suppresses it from publication; it is not unrepresentable.
  net_profit_minor         bigint  not null,
  -- Basis points as integers (§2.4). Signed for the same reason.
  roi_bps                  integer not null,
  margin_bps               integer not null,
  deal_score               integer not null
                           constraint deals_score_range check (deal_score between 0 and 100),
  -- One shared enum, four columns.
  demand_band              public.component_band not null,
  competition_band         public.component_band not null,
  stability_band           public.component_band not null,
  confidence_band          public.component_band not null,
  -- Components, weights, renormalisation and penalties (§8.5, AC7.2). No
  -- default: a score whose workings were not persisted is not displayable, and
  -- the workings are the product.
  score_breakdown          jsonb   not null
                           constraint deals_score_breakdown_is_object check (jsonb_typeof(score_breakdown) = 'object'),

  -- Provenance ---------------------------------------------------------------
  calc_version             text    not null,
  score_version            text    not null,
  -- Every input, frozen, including the resolved MarketContext (AC6.10). No
  -- default, for the same reason as score_breakdown.
  inputs_snapshot          jsonb   not null
                           constraint deals_inputs_snapshot_is_object check (jsonb_typeof(inputs_snapshot) = 'object'),
  computed_at              timestamptz not null default now(),
  -- The freshness horizon. Together with marketplace_products.refreshed_at this
  -- is where staleness lives — it is derived from timestamps and is NOT a
  -- status (ADR-0009). A deal past its expiry is still `active`; the read layer
  -- labels it stale, and §12.2 principle 4 says stale-but-labelled is
  -- trustworthy while missing is not.
  expires_at               timestamptz,

  -- Lifecycle ----------------------------------------------------------------
  -- draft → active → retired, retired terminal (ADR-0009). Defaulting to draft
  -- is the fail-closed half of AC3.3: a pipeline that forgets to set a status
  -- produces an invisible deal, not a published one. The transition rules are
  -- enforced by trigger in section 5.
  status                   public.deal_status not null default 'draft',

  -- Audit. Who and when, for the two irreversible-ish acts in a deal's life.
  -- T04 records them; T20A and T33 own who is *allowed* to perform them.
  published_at             timestamptz,
  published_by             uuid        references auth.users (id) on delete set null,
  retired_at               timestamptz,
  retired_by               uuid        references auth.users (id) on delete set null,
  retire_reason            text,

  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),

  constraint deals_expires_after_computed check (expires_at is null or expires_at > computed_at),

  -- The audit columns cannot disagree with the state they describe. The trigger
  -- in section 5 stamps the timestamps, so these checks are a second opinion on
  -- its behaviour rather than the only thing holding the invariant up.
  constraint deals_active_is_published
    check (status <> 'active' or published_at is not null),
  constraint deals_retired_has_timestamp
    check ((status = 'retired') = (retired_at is not null)),
  constraint deals_retire_reason_requires_retired
    check (retire_reason is null or status = 'retired'),

  -- Referenceable by the user-activity tables in section 4, so a watchlist item
  -- or a purchase record cannot disagree with the deal it points at. Each is
  -- (primary key, one column) and therefore constrains nothing on its own.
  constraint deals_id_market_key              unique (id, market_id),
  constraint deals_id_currency_key            unique (id, currency),
  constraint deals_id_marketplace_product_key unique (id, marketplace_product_id),

  -- rule 1, first half: this retailer product belongs to this retailer
  constraint deals_retailer_product_fkey
    foreign key (retailer_product_id, retailer_id)
    references public.retailer_products (id, retailer_id)
    on delete cascade,

  -- rule 1, second half: this retailer belongs to this market
  constraint deals_retailer_market_fkey
    foreign key (retailer_id, market_id)
    references public.retailers (id, market_id)
    on delete no action,

  -- rule 2, first half: this listing belongs to this marketplace
  constraint deals_marketplace_product_fkey
    foreign key (marketplace_product_id, marketplace_id)
    references public.marketplace_products (id, marketplace_id)
    on delete cascade,

  -- rule 2, second half: this market resolves to this marketplace
  constraint deals_market_marketplace_fkey
    foreign key (market_id, marketplace_id)
    references public.markets (id, marketplace_id)
    on delete no action,

  -- §7.6, layer one: one deal, one currency, and that currency is the market's.
  -- Schema A already ties the retailer and the listing to the same market
  -- currency by the same technique, so a deal needing an FX conversion cannot
  -- be assembled from these rows at all — it is unrepresentable, not merely
  -- rejected downstream.
  constraint deals_market_currency_fkey
    foreign key (market_id, currency)
    references public.markets (id, currency)
    on delete no action,

  -- Explicit, though implied transitively through markets. Money and its
  -- currency travel together and the currency is a real reference (§11.2).
  constraint deals_currency_fkey
    foreign key (currency)
    references public.currencies (code)
    on delete restrict
);

comment on table public.deals is
  'The market-scoped read model a user sees. market_id, retailer_id and marketplace_id are the scope keys; the five composite foreign keys make a cross-market row unrepresentable (ADR-007).';
comment on column public.deals.retailer_id is
  'Denormalised from retailer_products.retailer_id (ADR-007). Not for querying — it exists so a composite FK can assert the retailer product and the market agree. NOT NULL is load-bearing: a NULL would make the composite FK skip its check.';
comment on column public.deals.marketplace_id is
  'Denormalised from marketplace_products.marketplace_id (ADR-007). Same purpose, same NOT NULL reason.';
comment on column public.deals.currency is
  'The single currency of every money column on this row. Tied by FK to the market''s currency (§7.6): a cross-currency deal cannot be written.';
comment on column public.deals.inputs_snapshot is
  'Every input used, frozen, including the resolved MarketContext, fee schedule id and tax schedule id — so any historical figure can be reproduced exactly (AC6.10).';
comment on column public.deals.status is
  'draft | active | retired (ADR-0009). Defaults to draft so a newly computed deal is invisible until an admin publishes it (AC3.3). Retired is terminal. Staleness is NOT a status — it is derived from expires_at and marketplace_products.refreshed_at.';
comment on column public.deals.expires_at is
  'Freshness horizon. Staleness is derived from this and marketplace_products.refreshed_at, never stored as a state (ADR-0009).';
comment on column public.deals.published_by is
  'The actor who published, referencing auth.users. ON DELETE SET NULL: deleting an account must not delete the fact that a deal was published, nor block the deletion AC1.5 requires — the timestamp survives, the personal link does not.';
comment on column public.deals.retired_by is
  'The actor who retired, on the same terms as published_by.';

-- Indexes --------------------------------------------------------------------
--
-- market_id leads every feed index because "show me deals" always means "in my
-- market" (§2.3). A feed query that forgot the scope would surface as a user in
-- one country seeing another country's price.

create index if not exists deals_market_status_score_idx
  on public.deals (market_id, status, deal_score desc);

create index if not exists deals_market_status_roi_idx
  on public.deals (market_id, status, roi_bps desc);

create index if not exists deals_market_status_computed_idx
  on public.deals (market_id, status, computed_at desc);

-- One *live* deal per canonical pair (§2.1), where live means "not retired".
--
-- The predicate is `status <> 'retired'` rather than `status = 'active'`
-- (ADR-0009). Draft and active are the two states in which a deal is the
-- current answer for its pair, so only one may exist across both — otherwise a
-- recompute could stack up drafts behind an already-published deal and an
-- admin would be choosing between duplicates. Retired rows drop out entirely,
-- so the history of past deals for a pair is kept AND a fresh draft can always
-- be created to replace a retired one.
create unique index if not exists deals_live_pair_uniq
  on public.deals (retailer_product_id, marketplace_product_id)
  where status <> 'retired';

-- Lifecycle enforcement (ADR-0009) -------------------------------------------
--
--   INSERT            → must be 'draft'
--   draft   → draft   ✓      draft  → active  ✓      draft  → retired ✓
--   active  → active  ✓      active → retired ✓
--   retired → retired ✓ (other columns may still be corrected)
--   everything else   ✗      — notably active → draft, retired → active,
--                              retired → draft. Retired is terminal.
--
-- Why a trigger here when ADR-0008 argued for declarative constraints
-- everywhere else: a transition rule compares OLD to NEW, and PostgreSQL has no
-- declarative form for that — no assertions, no temporal constraints. A CHECK
-- constraint cannot see the previous row. So the choice is not "trigger versus
-- foreign key", it is "trigger versus nothing", and the cross-market invariant
-- stays declarative regardless.
--
-- What this does NOT do: decide *who* may publish or retire. Authorization is
-- T20A's and T33's, per the product decision. This function only rejects
-- transitions that are invalid no matter who asks for them.
--
-- The timestamps are stamped here rather than left to callers, because an audit
-- column that depends on every writer remembering is an audit column that is
-- eventually wrong. A caller that supplies its own value keeps it — the
-- coalesce fills a gap, it does not overwrite an intent. The *actor* columns
-- are deliberately untouched: the database knows when, only the API knows who.

create or replace function public.enforce_deal_lifecycle()
returns trigger
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    -- Fail closed. A deal is born unpublished, whatever the writer intended,
    -- so no ingestion path can put a row in front of a user without an
    -- explicit later publish (AC3.3). Publication is therefore always an
    -- UPDATE, which is what T20A will issue.
    if new.status <> 'draft' then
      raise exception
        using errcode  = '23514',
              constraint = 'deals_status_lifecycle',
              message  = format('a deal must be created as draft, not %s', new.status),
              hint     = 'publish by updating an existing draft; the pipeline never writes active';
    end if;

  elsif old.status is distinct from new.status then
    if not (   (old.status = 'draft'  and new.status in ('active', 'retired'))
            or (old.status = 'active' and new.status = 'retired')) then
      raise exception
        using errcode  = '23514',
              constraint = 'deals_status_lifecycle',
              message  = format('deal status transition %s -> %s is not permitted',
                                old.status, new.status),
              hint     = 'retired is terminal, and a published deal cannot return to draft';
    end if;
  end if;

  if new.status = 'active' and new.published_at is null then
    new.published_at := now();
  end if;

  if new.status = 'retired' and new.retired_at is null then
    new.retired_at := now();
  end if;

  return new;
end;
$$;

comment on function public.enforce_deal_lifecycle() is
  'Enforces the deal lifecycle draft -> active -> retired, retired terminal (ADR-0009), and stamps published_at/retired_at when a caller leaves them absent. Enforces transitions only, never actor authorization — that is T20A/T33.';

-- Privilege posture for this function (ADR-0007, RUNBOOK migration checklist):
-- owner-only, stated next to the body rather than inherited from a default set
-- in another migration. It is not SECURITY DEFINER — it needs no privilege the
-- caller lacks — and its search_path is pinned regardless (§11.2). Revoking
-- EXECUTE does not stop the trigger: PostgreSQL checks EXECUTE when a trigger
-- is created, not when it fires, which T03 verified against a probe table and
-- privileges.test.sql asserts permanently.
revoke all on function public.enforce_deal_lifecycle()
  from public, anon, authenticated, service_role;

drop trigger if exists enforce_deal_lifecycle on public.deals;
create trigger enforce_deal_lifecycle
  before insert or update on public.deals
  for each row execute function public.enforce_deal_lifecycle();

-- ---------------------------------------------------------------------------
-- 4. User activity (§2.3)
-- ---------------------------------------------------------------------------
--
-- All four cascade from profiles: account deletion removes the user's personal
-- rows (AC1.5). None cascades from deals — a deal is derived data and a user's
-- record of what they unlocked, watched or bought is not. deal_unlocks in
-- particular is permanent (AC10.7) and is the referent of a credit ledger row
-- (T05), so it restricts.

-- deal_unlocks ---------------------------------------------------------------
create table if not exists public.deal_unlocks (
  id            uuid        primary key default gen_random_uuid(),
  user_id       uuid        not null references public.profiles (id) on delete cascade,
  -- restrict, not cascade: a paid unlock outlives the deal's retirement
  -- (AC10.7) and must not be erasable by deleting the deal.
  deal_id       uuid        not null references public.deals (id) on delete restrict,
  credits_spent integer     not null
                constraint deal_unlocks_credits_non_negative check (credits_spent >= 0),
  unlocked_at   timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  -- Unlocks are permanent and paid once: the same user cannot be charged twice
  -- for the same deal (AC10.2).
  constraint deal_unlocks_user_deal_key unique (user_id, deal_id)
);

comment on table public.deal_unlocks is
  'One row per user per unlocked deal. Permanent (AC10.7). Written only inside the same transaction as the credit spend (T07, T23).';

-- watchlist_items ------------------------------------------------------------
create table if not exists public.watchlist_items (
  id                     uuid        primary key default gen_random_uuid(),
  user_id                uuid        not null references public.profiles (id) on delete cascade,
  deal_id                uuid        not null,
  marketplace_product_id uuid        not null,
  target_profit_minor    bigint
                         constraint watchlist_items_target_profit_non_negative check (target_profit_minor is null or target_profit_minor >= 0),
  currency               text        references public.currencies (code) on delete restrict,
  note                   text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint watchlist_items_user_deal_key unique (user_id, deal_id),
  -- §11.2: an amount without its currency must be impossible at the storage
  -- layer, not merely discouraged. The pairing runs both ways — a currency
  -- with no amount is meaningless too.
  constraint watchlist_items_target_requires_currency
    check ((target_profit_minor is null) = (currency is null)),
  -- The item and the deal agree about which listing is being watched. Also
  -- carries the reference to deals: (id, marketplace_product_id) contains the
  -- deal's primary key, so no separate deals FK is needed.
  constraint watchlist_items_deal_product_fkey
    foreign key (deal_id, marketplace_product_id)
    references public.deals (id, marketplace_product_id)
    on delete restrict,
  -- A target denominated in a currency the deal is not priced in is not a
  -- target, it is an FX error waiting to look like a great deal (§7.6). NULL
  -- currency skips this check, which is exactly right: no target, no currency.
  constraint watchlist_items_deal_currency_fkey
    foreign key (deal_id, currency)
    references public.deals (id, currency)
    on delete restrict
);

comment on table public.watchlist_items is
  'Saved deals (F18, P1). marketplace_product_id and currency are constrained by composite FK to agree with the deal they are saved from.';

-- purchase_records -----------------------------------------------------------
-- The MVP validation instrument (F14). This is the table the hypothesis is
-- answered from, so its snapshot columns are frozen at write time and never
-- recomputed.
create table if not exists public.purchase_records (
  id                      uuid        primary key default gen_random_uuid(),
  user_id                 uuid        not null references public.profiles (id) on delete cascade,
  deal_id                 uuid        not null,
  market_id               uuid        not null,
  units                   integer     not null
                          constraint purchase_records_units_positive check (units > 0),
  -- Optional: AC14.2 requires only a unit count, pre-filling the deal's price.
  actual_buy_price_minor  bigint
                          constraint purchase_records_actual_buy_price_non_negative check (actual_buy_price_minor is null or actual_buy_price_minor >= 0),
  currency                text        not null,
  -- Frozen at write time (AC14.3). Signed: what was predicted is recorded as
  -- predicted, whatever it was.
  expected_profit_minor   bigint      not null,
  purchased_at            timestamptz not null default now(),
  outcome                 public.purchase_outcome not null default 'pending',
  actual_sale_price_minor bigint
                          constraint purchase_records_actual_sale_price_non_negative check (actual_sale_price_minor is null or actual_sale_price_minor >= 0),
  actual_profit_minor     bigint,
  notes                   text,
  -- "plus a frozen inputs snapshot" (T04) / "the deal's predicted per-unit
  -- profit and full inputs snapshot are frozen onto the purchase record"
  -- (AC14.3). Frozen means frozen: a later recompute of the deal must not be
  -- able to move the thing the prediction is being judged against.
  inputs_snapshot         jsonb       not null
                          constraint purchase_records_inputs_snapshot_is_object check (jsonb_typeof(inputs_snapshot) = 'object'),
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  -- A purchase is recorded in the deal's market, never another. Same technique
  -- and same reason as ADR-007: predicted-vs-actual is reported per market and
  -- never pooled (§14.4), so a misattributed row corrupts the one number the
  -- MVP exists to measure. Carries the reference to deals as well.
  constraint purchase_records_deal_market_fkey
    foreign key (deal_id, market_id)
    references public.deals (id, market_id)
    on delete restrict,
  -- And in the deal's currency.
  constraint purchase_records_deal_currency_fkey
    foreign key (deal_id, currency)
    references public.deals (id, currency)
    on delete restrict
);

comment on table public.purchase_records is
  'The MVP validation instrument (F14): what the user actually bought, against what was predicted. expected_profit_minor and inputs_snapshot are frozen at write time (AC14.3).';

create index if not exists purchase_records_user_purchased_at_idx
  on public.purchase_records (user_id, purchased_at desc);

-- Predicted-vs-actual is read per market and per outcome (AC14.6, §8.6).
create index if not exists purchase_records_market_outcome_idx
  on public.purchase_records (market_id, outcome, purchased_at desc);

-- barcode_lookups ------------------------------------------------------------
create table if not exists public.barcode_lookups (
  id                             uuid        primary key default gen_random_uuid(),
  user_id                        uuid        not null references public.profiles (id) on delete cascade,
  market_id                      uuid        not null references public.markets (id) on delete restrict,
  barcode_raw                    text        not null,
  -- Canonical, and nullable: a scan that could not be normalised is still a
  -- lookup that happened, and recording it is how the failure rate is known.
  gtin14                         text
                                 constraint barcode_lookups_gtin14_format check (gtin14 is null or gtin14 ~ '^[0-9]{14}$'),
  -- set null, not restrict: the lookup is a historical fact that survives the
  -- listing being purged, and blocking a catalogue delete on it would be the
  -- wrong trade.
  resolved_marketplace_product_id uuid       references public.marketplace_products (id) on delete set null,
  -- Defaults to zero because a failed lookup is not charged (§3, barcode).
  credits_spent                  integer     not null default 0
                                 constraint barcode_lookups_credits_non_negative check (credits_spent >= 0),
  result                         jsonb,
  created_at                     timestamptz not null default now(),
  updated_at                     timestamptz not null default now()
);

comment on table public.barcode_lookups is
  'Barcode → GTIN-14 → marketplace listing, scoped to a market (F19, P1). credits_spent is 0 for a lookup that resolved nothing: a failed lookup is never charged.';
comment on column public.barcode_lookups.resolved_marketplace_product_id is
  'Nullable and not denormalised against market_id: unlike deals, a lookup is a record of an attempt rather than a published figure, so an unresolved or later-purged listing must not prevent the row existing.';

create index if not exists barcode_lookups_user_created_at_idx
  on public.barcode_lookups (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 5. updated_at triggers
-- ---------------------------------------------------------------------------
-- The shared Schema A function, reused. It stays owner-only (ADR-0007):
-- EXECUTE on a trigger function is checked when the trigger is created, not
-- when it fires.

do $$
declare
  t text;
begin
  foreach t in array array[
    'deals', 'deal_unlocks', 'watchlist_items', 'purchase_records', 'barcode_lookups'
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
-- 6. Row Level Security — enabled, no policies (§6.3, T04 acceptance criteria)
-- ---------------------------------------------------------------------------
--
-- deals is service-role only permanently (§6.3, ADR-008): the paid product is
-- the identity of the product, and column-level RLS to hide it is one mistake
-- from giving it away. Redaction is server-side, in one function, in T21.
--
-- The four user-activity tables get SELECT/INSERT/DELETE policies for their
-- owner in T06, together with the matching grants. Not here: T04's criterion is
-- RLS on, zero policies.

alter table public.deals            enable row level security;
alter table public.deal_unlocks     enable row level security;
alter table public.watchlist_items  enable row level security;
alter table public.purchase_records enable row level security;
alter table public.barcode_lookups  enable row level security;

-- ---------------------------------------------------------------------------
-- 7. Privileges (ADR-004, global rule 8)
-- ---------------------------------------------------------------------------
--
-- The posture declared in this file's header, made real. REVOKE first so the
-- result does not depend on what any default privilege happened to grant —
-- that dependence is precisely the local↔remote divergence
-- 20260810033236_normalise_privileges.sql was written to remove, and a table
-- created in a later migration must not quietly re-import it.

revoke all on table
  public.deals,
  public.deal_unlocks,
  public.watchlist_items,
  public.purchase_records,
  public.barcode_lookups
from anon, authenticated, service_role;

-- The service role is the sanctioned server-side path (§6.2). Four DML
-- privileges, nothing more — no TRUNCATE, TRIGGER or REFERENCES.
grant select, insert, update, delete on table
  public.deals,
  public.deal_unlocks,
  public.watchlist_items,
  public.purchase_records,
  public.barcode_lookups
to service_role;

-- Sequences: this migration creates none. Every primary key here is a uuid with
-- a gen_random_uuid() default, so there is no sequence for a default grant to
-- attach to. Asserted rather than assumed, because "I did not create one" is
-- exactly the kind of claim that stops being true after a later ALTER TABLE.
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
       'deals_%', 'deal_unlocks_%', 'watchlist_items_%',
       'purchase_records_%', 'barcode_lookups_%']);

  if n > 0 then
    raise exception
      'Schema B created % sequence(s); this migration must revoke their default grants explicitly (ADR-004).', n;
  end if;
end
$$;
