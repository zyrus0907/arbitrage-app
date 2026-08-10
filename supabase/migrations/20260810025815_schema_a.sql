-- T03 — Schema A: global reference data, identity and catalogue.
--
-- Source of truth: docs/ARCHITECTURE.md v2.0 §2 (entities), §6.3 (RLS default
-- deny), §11.2 (database security), §1.3 (MVP currency invariant).
--
-- Conventions applied throughout, per §2:
--   * snake_case names, uuid primary keys (countries/currencies are the two
--     documented exceptions: their ISO code is the natural key),
--   * timestamptz for every timestamp,
--   * money as bigint MINOR UNITS, never a float, always beside an explicit
--     ISO 4217 currency column that cannot be null while the amount is not,
--   * rates as integer basis points.
--
-- No country, currency, marketplace or tax rate is written into this file.
-- Every one of them is a row (§0.3): adding a market must be an insert.
--
-- RLS is enabled on all eleven tables and NO policy is created. That is the
-- default-deny baseline of §6.3 — the anon and authenticated keys can reach
-- none of this. T06 adds the few policies that are meant to exist.

-- ---------------------------------------------------------------------------
-- 1. Enum types
-- ---------------------------------------------------------------------------
--
-- Enums are used only for domains that are genuinely closed, because adding a
-- value to one is a migration. Deliberately NOT enums:
--
--   marketplaces.provider     ('amazon' | 'ebay' | …)
--   marketplaces.adapter_key  ('keepa' | …)
--
-- Those two must be plain text: §0.3 requires that a new marketplace costs one
-- adapter implementation and configuration rows, never a schema change.

do $$
begin
  -- Which tax system a country operates (§7.4). A new regime needs a new
  -- strategy module in services/tax/regimes/, so it is a code change anyway.
  if not exists (select 1 from pg_type where typname = 'tax_regime') then
    create type public.tax_regime as enum ('vat', 'gst', 'sales_tax', 'none');
  end if;

  -- Whether a displayed price already contains tax. §2.2: getting this wrong
  -- silently inflates or deflates every profit figure in a country by the tax
  -- rate, so it is stored per country AND per retailer AND per product.
  if not exists (select 1 from pg_type where typname = 'price_tax_treatment') then
    create type public.price_tax_treatment as enum ('inclusive', 'exclusive');
  end if;

  -- §2.2 markets.launch_status.
  if not exists (select 1 from pg_type where typname = 'market_launch_status') then
    create type public.market_launch_status as enum ('live', 'beta', 'planned');
  end if;

  -- §2.3 profiles.tax_scheme. Regime-specific variants are Phase 3.
  if not exists (select 1 from pg_type where typname = 'tax_scheme') then
    create type public.tax_scheme as enum ('standard', 'simplified');
  end if;

  -- §1.0→2.0 changelog: fba|fbm became marketplace-neutral roles. The
  -- marketplace's own programme codes live in marketplaces.fulfilment_programs.
  if not exists (select 1 from pg_type where typname = 'fulfilment_type') then
    create type public.fulfilment_type as enum ('marketplace_fulfilled', 'seller_fulfilled');
  end if;

  -- §2.3 retailer_products.gtin_format — the ORIGINAL form as supplied, kept
  -- for debugging only. gtin14 is the matching key.
  if not exists (select 1 from pg_type where typname = 'gtin_format') then
    create type public.gtin_format as enum ('upc_a', 'ean_13', 'ean_8', 'isbn_13');
  end if;

  -- §2.3 retailers.source_type (§10.4 ranks these by risk).
  if not exists (select 1 from pg_type where typname = 'retailer_source_type') then
    create type public.retailer_source_type as enum ('affiliate_feed', 'api', 'curated', 'manual');
  end if;

  -- §2.3 product_matches.method / .verified_by. Risk #1 lives in this table:
  -- every match records how it was made and who stands behind it.
  if not exists (select 1 from pg_type where typname = 'match_method') then
    create type public.match_method as enum ('gtin_exact', 'retailer_hint', 'title_fuzzy', 'manual', 'barcode_scan');
  end if;

  if not exists (select 1 from pg_type where typname = 'match_verified_by') then
    create type public.match_verified_by as enum ('system', 'admin', 'user_report');
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 2. Shared trigger function: updated_at
-- ---------------------------------------------------------------------------
-- Not SECURITY DEFINER — it needs no privileges beyond the caller's. The
-- search_path is still pinned so the function cannot be hijacked by a
-- schema shadowing pg_catalog (§11.2).

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Maintains updated_at on every table in Schema A. Attached by trigger, never called directly.';

-- ---------------------------------------------------------------------------
-- 3. Reference / configuration tables (§2.2)
-- ---------------------------------------------------------------------------
-- These are the tables that make the system global. All are seeded data
-- (supabase/seed/, T08), editable by an admin, and never constants in code.

-- currencies -----------------------------------------------------------------
-- minor_unit_exponent MUST be data. Assuming x100 everywhere breaks the moment
-- the product touches JPY (0) or KWD (3) — §2.2.
create table if not exists public.currencies (
  code                text        primary key
                      constraint currencies_code_iso4217 check (code ~ '^[A-Z]{3}$'),
  minor_unit_exponent smallint    not null
                      constraint currencies_minor_unit_exponent_range check (minor_unit_exponent between 0 and 4),
  symbol              text,
  name                text        not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

comment on column public.currencies.minor_unit_exponent is
  'ISO 4217 exponent: 2 for GBP/USD/EUR, 0 for JPY, 3 for KWD. The single source of the minor-unit scale; lib/money reads it and nothing assumes x100.';

-- countries ------------------------------------------------------------------
create table if not exists public.countries (
  code                 text        primary key
                       constraint countries_code_iso3166 check (code ~ '^[A-Z]{2}$'),
  name                 text        not null,
  default_currency     text        not null references public.currencies (code) on delete restrict,
  default_locale       text        not null,
  tax_regime           public.tax_regime not null,
  retail_price_display public.price_tax_treatment not null,
  timezone_default     text        not null,
  active               boolean     not null default false,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

comment on column public.countries.retail_price_display is
  'Whether shelf prices in this country include tax. UK/EU/AU: inclusive. US: exclusive. Not a detail — §2.2.';

-- marketplaces ---------------------------------------------------------------
-- provider and adapter_key are text, not enums, on purpose: adding eBay must
-- cost one adapter class and one row, not a migration (§0.3, §10.1).
create table if not exists public.marketplaces (
  id                   uuid        primary key default gen_random_uuid(),
  provider             text        not null,
  code                 text        not null,
  country_code         text        not null references public.countries (code) on delete restrict,
  currency             text        not null references public.currencies (code) on delete restrict,
  domain               text        not null,
  adapter_key          text        not null,
  capabilities         jsonb       not null default '{}'::jsonb,
  fulfilment_programs  jsonb       not null default '{}'::jsonb,
  active               boolean     not null default false,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint marketplaces_code_key unique (code),
  -- Referenced by markets to guarantee the §1.3 currency invariant.
  constraint marketplaces_id_currency_key unique (id, currency)
);

comment on column public.marketplaces.code is
  'Stable human-readable identifier, e.g. the value MarketContext carries as marketplace.id. The uuid is the storage key; this is the one written in seeds and logs.';
comment on column public.marketplaces.capabilities is
  'MarketplaceCapabilities (§8.7). Drives which score components can be computed at all; a missing capability drops a component visibly, it is never defaulted.';
comment on column public.marketplaces.fulfilment_programs is
  'Maps generic fulfilment roles to this marketplace''s own codes, e.g. {"marketplace_fulfilled":"FBA","seller_fulfilled":"FBM"}.';

-- markets --------------------------------------------------------------------
-- The operating unit a deal belongs to: a source country plus a marketplace.
create table if not exists public.markets (
  id                  uuid        primary key default gen_random_uuid(),
  slug                text        not null,
  source_country_code text        not null references public.countries (code) on delete restrict,
  marketplace_id      uuid        not null references public.marketplaces (id) on delete restrict,
  currency            text        not null references public.currencies (code) on delete restrict,
  active              boolean     not null default false,
  launch_status       public.market_launch_status not null default 'planned',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint markets_slug_key unique (slug),
  constraint markets_country_marketplace_key unique (source_country_code, marketplace_id),
  -- Referenced by retailers to guarantee the §1.3 currency invariant.
  constraint markets_id_currency_key unique (id, currency),
  -- §1.3 MVP invariant, enforced in storage rather than by convention: a
  -- market's currency IS its marketplace's currency. A deal that would need an
  -- FX conversion cannot be represented, let alone approximated (§7.6).
  constraint markets_currency_matches_marketplace
    foreign key (marketplace_id, currency)
    references public.marketplaces (id, currency)
    on delete restrict
);

-- tax_schedules --------------------------------------------------------------
-- Versioned, per country. Risk #2: an unverified schedule makes every profit
-- figure in that market systematically wrong, so source and verification date
-- are first-class columns, not notes.
create table if not exists public.tax_schedules (
  id                        uuid        primary key default gen_random_uuid(),
  country_code              text        not null references public.countries (code) on delete restrict,
  regime                    public.tax_regime not null,
  standard_rate_bps         integer     not null
                            constraint tax_schedules_standard_rate_bps_range check (standard_rate_bps between 0 and 10000),
  reduced_rates             jsonb       not null default '[]'::jsonb,
  registration_supported    boolean     not null default true,
  input_reclaim_supported   boolean     not null default false,
  marketplace_fees_taxed    boolean     not null default false,
  effective_from            date        not null,
  effective_to              date,
  source_url                text,
  verified_at               timestamptz,
  notes                     text,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  constraint tax_schedules_country_effective_from_key unique (country_code, effective_from),
  constraint tax_schedules_effective_range check (effective_to is null or effective_to > effective_from)
);

comment on column public.tax_schedules.standard_rate_bps is
  'Basis points (§2.4): 20% = 2000. Never a float, never a percentage.';

-- fee_schedules --------------------------------------------------------------
-- Versioned, per MARKETPLACE. surcharges is a list rather than a column, which
-- is what replaces v1.0's hardcoded digital_services_fee_bps: a new levy is a
-- row edit (§2.2).
create table if not exists public.fee_schedules (
  id                uuid        primary key default gen_random_uuid(),
  marketplace_id    uuid        not null references public.marketplaces (id) on delete restrict,
  version           text        not null,
  effective_from    date        not null,
  effective_to      date,
  referral_rules    jsonb       not null default '[]'::jsonb,
  fulfilment_bands  jsonb       not null default '[]'::jsonb,
  storage_rules     jsonb       not null default '{}'::jsonb,
  surcharges        jsonb       not null default '[]'::jsonb,
  currency          text        not null references public.currencies (code) on delete restrict,
  source_url        text,
  verified_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint fee_schedules_marketplace_version_key unique (marketplace_id, version),
  constraint fee_schedules_effective_range check (effective_to is null or effective_to > effective_from)
);

comment on column public.fee_schedules.surcharges is
  'List of {code,label,basis,rate_bps|amount_minor,applies_to_countries?} (§2.2). Replaces v1.0''s digital-services-fee column.';

-- ---------------------------------------------------------------------------
-- 4. Identity (§2.3)
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
  id                              uuid        primary key references auth.users (id) on delete cascade,
  display_name                    text,
  -- Cached. The authoritative source is credit_ledger (T05). Deliberately NOT
  -- constrained non-negative: §9.2 requires refunds and chargebacks to be able
  -- to push a balance negative — spending is blocked, history is never erased.
  credit_balance                  integer     not null default 0,
  country_code                    text        references public.countries (code) on delete restrict,
  default_market_id               uuid        references public.markets (id) on delete restrict,
  locale                          text,
  timezone                        text,
  -- Conservative default, per §7.4: most users are not registered, and it is
  -- the safer assumption to be wrong about.
  tax_registered                  boolean     not null default false,
  tax_registration_country        text        references public.countries (code) on delete restrict,
  tax_scheme                      public.tax_scheme not null default 'standard',
  default_fulfilment              public.fulfilment_type not null default 'marketplace_fulfilled',
  default_budget_minor            bigint,
  prep_cost_per_unit_minor        bigint,
  inbound_shipping_per_unit_minor bigint,
  assumption_currency             text        references public.currencies (code) on delete restrict,
  onboarded_at                    timestamptz,
  created_at                      timestamptz not null default now(),
  updated_at                      timestamptz not null default now(),
  -- §11.2: a currency-free amount must be impossible at the storage layer.
  constraint profiles_assumptions_require_currency check (
    assumption_currency is not null
    or (default_budget_minor is null
        and prep_cost_per_unit_minor is null
        and inbound_shipping_per_unit_minor is null)
  ),
  constraint profiles_assumptions_non_negative check (
    coalesce(default_budget_minor, 0) >= 0
    and coalesce(prep_cost_per_unit_minor, 0) >= 0
    and coalesce(inbound_shipping_per_unit_minor, 0) >= 0
  )
);

comment on column public.profiles.credit_balance is
  'Cached balance. credit_ledger (T05) is authoritative; only spend_credits/grant_credits (T07) may move this. May go negative on refund or chargeback (§9.2).';

-- A profile is created for every auth user at signup. SECURITY DEFINER because
-- the inserting role is auth's, not the table owner's; search_path is pinned
-- per §11.2. Nothing but the id is written — onboarding (T10) fills the rest.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id)
  values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

comment on function public.handle_new_user() is
  'Creates the profiles row for a new auth.users row. Idempotent, so a replayed signup cannot fail account creation.';

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- 5. Catalogue (§2.3)
-- ---------------------------------------------------------------------------

-- retailers ------------------------------------------------------------------
create table if not exists public.retailers (
  id                          uuid        primary key default gen_random_uuid(),
  name                        text        not null,
  slug                        text        not null,
  market_id                   uuid        not null references public.markets (id) on delete restrict,
  country_code                text        not null references public.countries (code) on delete restrict,
  currency                    text        not null references public.currencies (code) on delete restrict,
  website_url                 text,
  source_type                 public.retailer_source_type not null,
  affiliate_network           text,
  affiliate_tracking_template text,
  price_display               public.price_tax_treatment not null,
  active                      boolean     not null default false,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  -- Scoped to the market, not global: the same retailer brand may legitimately
  -- operate in two markets as two rows.
  constraint retailers_market_slug_key unique (market_id, slug),
  -- §1.3 MVP invariant again: a retailer prices in its market's currency, so a
  -- cross-currency deal cannot be assembled from these rows at all.
  constraint retailers_currency_matches_market
    foreign key (market_id, currency)
    references public.markets (id, currency)
    on delete restrict
);

comment on column public.retailers.price_display is
  'Whether this retailer''s prices include tax. Defaults from countries.retail_price_display at seed time but is stored per retailer, because the assumption is systematically wrong when borrowed (§7.4).';

-- retailer_products ----------------------------------------------------------
-- GTIN normalisation is a global-first requirement, not tidiness: a UPC-12 in
-- the US and an EAN-13 in the UK identify the same product. gtin14 is the
-- canonical zero-padded matching key; gtin_raw/gtin_format preserve what the
-- source actually said (§2.3).
create table if not exists public.retailer_products (
  id                  uuid        primary key default gen_random_uuid(),
  retailer_id         uuid        not null references public.retailers (id) on delete cascade,
  retailer_sku        text        not null,
  title               text,
  brand               text,
  gtin14              text
                      constraint retailer_products_gtin14_format check (gtin14 ~ '^[0-9]{14}$'),
  gtin_raw            text,
  gtin_format         public.gtin_format,
  mpn                 text,
  -- A retailer-supplied marketplace identifier (an ASIN, for Amazon). A hint
  -- for matching tier 2 only — never an identity (§3 matching).
  asin_hint           text,
  product_url         text,
  image_url           text,
  price_minor         bigint      not null
                      constraint retailer_products_price_non_negative check (price_minor >= 0),
  currency            text        not null references public.currencies (code) on delete restrict,
  price_tax_treatment public.price_tax_treatment not null,
  was_price_minor     bigint
                      constraint retailer_products_was_price_non_negative check (was_price_minor is null or was_price_minor >= 0),
  in_stock            boolean     not null default true,
  stock_qty           integer,
  source_batch_id     uuid,
  first_seen_at       timestamptz not null default now(),
  last_seen_at        timestamptz not null default now(),
  raw                 jsonb,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint retailer_products_retailer_sku_key unique (retailer_id, retailer_sku),
  -- The raw code and its declared format travel together or not at all.
  constraint retailer_products_gtin_raw_pairing check ((gtin_raw is null) = (gtin_format is null))
);

comment on column public.retailer_products.gtin14 is
  'Canonical zero-padded GTIN-14. The matching key. Nullable because ingestion accepts a product before a code is resolved; matching (T18) refuses to publish without one.';
comment on column public.retailer_products.source_batch_id is
  'The ingestion run that produced this row. Left unconstrained until ingestion_runs exists (T05).';

create index if not exists retailer_products_gtin14_idx
  on public.retailer_products (gtin14)
  where gtin14 is not null;

create index if not exists retailer_products_last_seen_at_idx
  on public.retailer_products (last_seen_at desc);

-- marketplace_products -------------------------------------------------------
-- Replaces v1.0's amazon_products. Identity is (marketplace_id, external_id):
-- an ASIN is one kind of external id, not a schema concept. Amazon vocabulary
-- survives only inside provider_raw and the adapter's mapper (§2.3).
create table if not exists public.marketplace_products (
  id                                   uuid        primary key default gen_random_uuid(),
  marketplace_id                       uuid        not null references public.marketplaces (id) on delete restrict,
  external_id                          text        not null,
  title                                text,
  brand                                text,
  category_id                          text,
  category_path                        text,
  gtins                                text[]      not null default '{}'::text[],
  image_key                            text,
  listing_url                          text,
  -- Generic demand rank (Amazon: sales rank). Nullable: rank is a capability,
  -- not a guarantee (§8.7).
  rank_value                           integer,
  rank_avg_90d                         integer,
  est_monthly_sales                    integer,
  -- Generic "featured offer price" (Amazon: Buy Box).
  buybox_price_minor                   bigint
                                       constraint marketplace_products_buybox_price_non_negative check (buybox_price_minor is null or buybox_price_minor >= 0),
  currency                             text        not null references public.currencies (code) on delete restrict,
  buybox_is_marketplace_owned          boolean,
  offer_count_marketplace_fulfilled    integer,
  offer_count_seller_fulfilled         integer,
  marketplace_owned_in_stock_pct_90d   smallint
                                       constraint marketplace_products_owned_pct_range check (marketplace_owned_in_stock_pct_90d is null or marketplace_owned_in_stock_pct_90d between 0 and 100),
  price_avg_90d_minor                  bigint,
  price_stddev_90d_minor               bigint,
  price_min_90d_minor                  bigint,
  price_max_90d_minor                  bigint,
  item_weight_g                        integer,
  dims_mm                              jsonb,
  hazmat                               boolean,
  oversize                             boolean,
  restricted_flags                     jsonb,
  provider_key                         text        not null,
  provider_raw                         jsonb,
  refreshed_at                         timestamptz not null default now(),
  created_at                           timestamptz not null default now(),
  updated_at                           timestamptz not null default now(),
  constraint marketplace_products_marketplace_external_id_key unique (marketplace_id, external_id),
  -- Every money column above is denominated in this row's currency, and that
  -- currency is the marketplace's — enforced, not assumed (§1.3, §11.2).
  constraint marketplace_products_currency_matches_marketplace
    foreign key (marketplace_id, currency)
    references public.marketplaces (id, currency)
    on delete restrict,
  -- Canonical GTIN-14s only. Written as one regex over the joined array
  -- because a check constraint may not contain a subquery.
  constraint marketplace_products_gtins_format check (
    gtins = '{}'::text[]
    or array_to_string(gtins, ',') ~ '^[0-9]{14}(,[0-9]{14})*$'
  )
);

comment on column public.marketplace_products.external_id is
  'The marketplace''s own identifier: an ASIN on Amazon, whatever the marketplace uses elsewhere. Never treated as a generic product id above the adapter layer.';
comment on column public.marketplace_products.est_monthly_sales is
  'Explicitly an estimate. Absent rather than guessed where the marketplace cannot supply it (§8.7).';
comment on column public.marketplace_products.refreshed_at is
  'Drives the staleness display. Data older than 48h must look stale, not merely be labelled (AC5.3).';

-- Matching resolves a canonical GTIN-14 to a listing; this is the index that
-- makes tier-1 matching a lookup rather than a scan (§3 matching).
create index if not exists marketplace_products_gtins_idx
  on public.marketplace_products using gin (gtins);

-- The tiered refresh policy (§10.2) selects by staleness.
create index if not exists marketplace_products_refreshed_at_idx
  on public.marketplace_products (refreshed_at desc);

-- product_matches ------------------------------------------------------------
-- Risk #1 (product mismatch) is recorded here honestly: every match carries the
-- method that produced it and the confidence it deserves.
create table if not exists public.product_matches (
  id                     uuid        primary key default gen_random_uuid(),
  retailer_product_id    uuid        not null references public.retailer_products (id) on delete cascade,
  marketplace_product_id uuid        not null references public.marketplace_products (id) on delete cascade,
  method                 public.match_method not null,
  confidence             numeric(3, 2) not null
                         constraint product_matches_confidence_range check (confidence >= 0 and confidence <= 1),
  verified_by            public.match_verified_by not null default 'system',
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint product_matches_pair_key unique (retailer_product_id, marketplace_product_id)
);

-- ---------------------------------------------------------------------------
-- 6. updated_at triggers
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array[
    'currencies', 'countries', 'marketplaces', 'markets', 'tax_schedules',
    'fee_schedules', 'profiles', 'retailers', 'retailer_products',
    'marketplace_products', 'product_matches'
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
-- 7. Row Level Security — default deny, no policies (§6.3)
-- ---------------------------------------------------------------------------
--
-- RLS on with zero policies means the anon and authenticated keys can read and
-- write nothing here. That is the intended state at T03: T06 adds the small
-- set of policies that are supposed to exist, and T09 proves the rest stay
-- unreachable. Server code reaches these tables through the service-role
-- client only.

alter table public.currencies           enable row level security;
alter table public.countries            enable row level security;
alter table public.marketplaces         enable row level security;
alter table public.markets              enable row level security;
alter table public.tax_schedules        enable row level security;
alter table public.fee_schedules        enable row level security;
alter table public.profiles             enable row level security;
alter table public.retailers            enable row level security;
alter table public.retailer_products    enable row level security;
alter table public.marketplace_products enable row level security;
alter table public.product_matches      enable row level security;
