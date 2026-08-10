# ARCHITECTURE.md

**Project:** Global Retail-to-Marketplace Arbitrage App
**Document owner:** Solution Architect
**Status:** Pre-development design. No application code written yet.
**Version:** 2.0 — global-first, marketplace-agnostic
**Supersedes:** v1.0 (UK-only, Amazon-hardcoded)

---

## Changelog: v1.0 → v2.0

v2.0 removes two hardcoded assumptions — *the country is the UK* and *the marketplace is Amazon* — without changing the shape of the system. The monolith, the credit model, the redaction rule, the scoring philosophy and the development order all survive intact.

| Area | v1.0 | v2.0 |
|---|---|---|
| Geography | UK only, GBP, UK VAT | `countries`, `currencies`, `tax_regimes` as **data**; any country addable without a migration |
| Marketplace | `amazon_products` table, ASIN as PK | `marketplaces` + `marketplace_products` (`marketplace_id`, `external_id`); ASIN is one kind of external id |
| Data provider | "Keepa client" service | `MarketplaceAdapter` interface; **Keepa is one adapter**, covering all Amazon locales |
| Money | `bigint` pence, GBP implied | `bigint` **minor units + explicit currency code**, exponent-aware (JPY has 0 decimals) |
| Tax | `vat_registered` boolean, 20% inline | `TaxRegime` strategy: VAT / GST / US sales tax / none, rates from `tax_schedules` |
| Fees | `fba_fee_bands`, `digital_services_fee_bps` columns | `fee_schedules` **per marketplace**, versioned, with a generic surcharge list |
| Fulfilment | `fba` \| `fbm` | `marketplace_fulfilled` \| `seller_fulfilled`, with marketplace-specific program codes as data |
| Identifiers | `ean`, `upc` columns | canonical **GTIN-14** + original form (UPC-12 and EAN-13 are the same product) |
| Scoring | fixed 5 components | capability-aware: components that a marketplace cannot supply are dropped and weights renormalised, visibly |
| Pricing display | £ hardcoded | `Intl.NumberFormat` with user locale + deal currency; no currency symbol in code |

**Reconciliation status:** ✅ **Complete.** `PRODUCT_SPEC.md` v2.0 and `TASKS.md` v2.1 are both reconciled to this document and reference it as the technical contract. The earlier v1.0 UK-only assumptions no longer exist in either document. Nothing in v2.0 invalidated their *sequence* — only their geographic and marketplace assumptions.

---

## 0. Preamble: assumptions, and what I am pushing back on

### 0.1 Assumptions

1. **Single founder, AI-assisted development, low budget.** Target infrastructure cost < £100/month equivalent at MVP.
2. **Global-first architecture, single-market launch.** The system must be able to add a country or a marketplace as configuration. It must **not** try to operate in many markets at once during the MVP (see §0.3).
3. **Amazon is the only marketplace integration in the MVP**, via Keepa, across whichever Amazon locales the launch market needs. The abstraction exists so the second marketplace is cheap; the second marketplace is not built now.
4. **Users are individuals** doing retail arbitrage, mostly not tax-registered at first, mostly using marketplace fulfilment or shipping from home.
5. **No marketplace seller account required to use the MVP.** This is a sourcing tool.
6. **The MVP hypothesis is a trust hypothesis**, not a coverage hypothesis: *will users trust the recommendation enough to spend real money?* Every decision below is subordinate to that.
7. **Domestic arbitrage only in MVP:** the retailer and the marketplace are in the same country and the same currency. Cross-border sourcing is a Phase 3 feature (§7.7).
8. Money is always **integer minor units with an explicit currency**. Never floats. Never a bare number.
9. Deal data is a **derived, cacheable artefact**, not user data.

### 0.2 Complexity I am removing from the MVP

| Proposed | Verdict | Reason |
|---|---|---|
| Next.js + TypeScript + PWA | **Keep** | One language, one deploy, App Router server components suit a data-read-heavy app. PWA is a manifest + service worker, not a project. |
| Supabase Postgres + Auth | **Keep** | Auth, DB, RLS, storage and cron in one free-tier product. Correct for one founder. |
| **Python for data processing** | **Defer to Phase 4** | You do not need a second language, runtime, deploy target and dependency tree to compute a weighted score over a few thousand rows. Everything in the MVP is `fetch → normalise → arithmetic → upsert`. Introduce Python only for fuzzy/vector matching at scale or statistical modelling, as an isolated worker. |
| **Amazon SP-API** | **Defer to Phase 3** | Seller account, developer registration, approval, LWA OAuth, restricted-data roles, per-region endpoints. Weeks of work for data Keepa already gives you — and it is *more* work under a global model, not less, because it is per-region. |
| Stripe | **Keep**, **Checkout only** | Hosted Checkout + webhooks. No custom card forms, no Elements, no PCI surface. |
| Vercel + GitHub | **Keep** | Free tier, preview deploys, cron. |
| **Retailer scraping engine** | **Cut hard for MVP** | A resilient multi-retailer scraper is a full product, and multiplying it by countries is how you never ship. Affiliate feeds + curated ingestion (§10.4). |
| **Operating in many countries at launch** | **Cut** | See §0.3. Architecture is global; operations start with one market. |
| **A second marketplace integration** | **Cut** | The adapter interface is MVP scope. A second adapter is not. |
| **Runtime translation / i18n framework** | **Cut, but design for it** | Copy lives in one message catalogue and no currency symbol or date format is hardcoded. Actual translation is a Phase 3 data exercise, not an MVP dependency. |
| Microservices / queues / Redis / separate API server | **Cut** | Postgres is your queue, cache and job log at this scale. |
| Real-time subscriptions | **Cut** | Deals refresh on a schedule. |
| Native barcode scanning app | **Cut** | Browser `BarcodeDetector` + manual entry fallback. |

### 0.3 What "global-first" means here — and what it does not

**It means:** country, currency, tax regime, marketplace and fee schedule are all **rows in tables**, resolved at runtime, never constants in code. The acceptance test for this document is a single sentence:

> **Adding a new country or a new Amazon locale must require inserting configuration rows and nothing else — no migration, no code change, no redeploy of business logic. Adding a non-Amazon marketplace must require exactly one new adapter implementation and nothing else.**

If a task ever forces a schema change to support a new market, the abstraction has failed and it gets an ADR, not a workaround.

**It does not mean:** launching everywhere. Deal supply at MVP is manually curated, and curation does not scale across countries — spreading fifty curated deals over four markets gives every user twelve deals and no reason to trust you. **Launch one market. Add the second only when the first has deal supply you would defend.** Global-first is an insurance policy against a rewrite, not a launch plan.

**Net effect:** MVP is still one Next.js repo, one Postgres database, one data provider, one payment provider — now with the country and marketplace pulled out into configuration.

---

## 1. System Architecture

### 1.1 High-level shape

A **modular monolith on Vercel**, backed by Supabase Postgres, with scheduled ingestion jobs and a strict rule that all third-party data access happens server-side only, behind provider adapters.

```
┌──────────────────────────────────────────────────────────────┐
│                    CLIENT (PWA, mobile-first)                │
│  Next.js App Router · React Server Components · Tailwind     │
│  Locale-aware formatting · Service worker · BarcodeDetector  │
└───────────────┬──────────────────────────────────────────────┘
                │ HTTPS, session cookie (Supabase Auth)
┌───────────────▼──────────────────────────────────────────────┐
│              VERCEL — Next.js server runtime                  │
│                                                               │
│  Route Handlers (/api/v1/*)     Server Components / Actions   │
│  Auth-guarded, Zod-validated,   Read paths: feed, deal detail │
│  rate-limited, market-scoped    (redacted unless unlocked)    │
│                                                               │
│  ┌─────────────────── SERVICE LAYER (§3) ──────────────────┐  │
│  │ ingestion │ matching │ pricing │ tax │ scoring │ credits │  │
│  │ recommendation │ watchlist │ barcode │ billing │ market  │  │
│  └───────────────────────────────────────────────────────┘   │
│                                                               │
│  ┌──────────── MARKETPLACE ADAPTER LAYER (§10.1) ─────────┐   │
│  │  MarketplaceAdapter interface + capability flags        │   │
│  │  ├─ KeepaAmazonAdapter  (all Amazon locales) ← MVP ONLY │   │
│  │  ├─ SpApiAmazonAdapter                       (Phase 3)  │   │
│  │  └─ (eBay / Walmart / …)                     (Phase 4)  │   │
│  └────────────────────────────────────────────────────────┘   │
│                                                               │
│  Cron routes (Vercel Cron) → ingestion & refresh pipelines    │
└───────┬──────────────────────────┬───────────────────┬────────┘
        │ service_role (server only)│                   │
┌───────▼──────────┐    ┌───────────▼────────┐  ┌───────▼───────┐
│ SUPABASE         │    │ KEEPA API          │  │ STRIPE        │
│ Postgres + RLS   │    │ (Amazon, all       │  │ Checkout +    │
│ Auth · Storage   │    │  supported locales)│  │ Webhooks      │
└──────────────────┘    └────────────────────┘  │ multi-currency│
                        ┌────────────────────┐  └───────────────┘
                        │ RETAILER FEEDS     │
                        │ per-country        │
                        │ affiliate networks │
                        └────────────────────┘
```

### 1.2 Core architectural rules

1. **No third-party API key ever reaches the browser.** Provider keys, Stripe secret, Supabase service role — server-only, in Vercel environment variables.
2. **The client never computes money.** Profit, ROI and score are computed server-side, persisted and versioned. The client renders and *formats* numbers it is given — formatting is locale-aware, arithmetic is not the client's job.
3. **Deals are precomputed, not computed on request.**
4. **Redaction happens on the server.** A locked deal never has its retailer/product identity serialised to the client at all.
5. **All external calls go through one adapter per provider**, with retry, timeout, quota accounting and caching.
6. **Every computed artefact carries version stamps** (`calc_version`, `score_version`, `fee_schedule_id`, `tax_schedule_id`) and an `inputs_snapshot`.
7. **Nothing in business logic knows what country or marketplace it is in.** It receives a resolved `MarketContext` and operates on it. No `if (country === 'GB')` anywhere outside a regime strategy module.
8. **Every monetary value travels with its currency.** A bare integer crossing a service boundary is a bug.

### 1.3 The `MarketContext` — the object that replaces every hardcoded assumption

Resolved once per request or per pipeline run, passed down, never re-derived:

```ts
type MarketContext = {
  marketId: string;
  sourceCountry: CountryCode;        // where the retail purchase happens
  marketplace: {
    id: string;                       // 'amazon_uk'
    provider: 'amazon';               // MVP: always 'amazon'
    country: CountryCode;
    currency: CurrencyCode;
    capabilities: MarketplaceCapabilities;   // §8.7
  };
  currency: CurrencyCode;             // MVP invariant: == marketplace.currency
  taxSchedule: TaxSchedule;           // §7.4
  feeSchedule: FeeSchedule;           // §7.3
  locale: string;                     // formatting only
};
```

**MVP invariant, enforced at deal creation:** `retailer.currency === marketplace.currency`. A deal that would need an FX conversion is rejected, not approximated. FX belongs to Phase 3 and arrives with its own architecture (§7.7).

### 1.4 Data flow

```
Retailer feed / curated entry (country-scoped)
        ↓ ingestion + GTIN normalisation
retailer_products (price + currency + tax treatment, gtin14)
        ↓ matching (GTIN → marketplace listing, confidence scored)
product_matches
        ↓ enrichment via MarketplaceAdapter (rank, offers, buybox, history, dims)
marketplace_products
        ↓ pricing engine (fee schedule + tax regime → net profit, ROI)
        ↓ scoring engine (capability-aware components)
deals  ← the single row a user sees, scoped to a market
        ↓ recommendation (budget, velocity, risk caps)
suggested units
```

---

## 2. Database Entities and Relationships

Postgres via Supabase. All tables `snake_case`, PKs `uuid`, timestamps `timestamptz`, money `bigint` **minor units** accompanied by a `currency` column.

### 2.1 Entity relationship overview

```
countries ─1:N─ marketplaces ─1:N─ markets
countries ─1:N─ tax_schedules
marketplaces ─1:N─ fee_schedules
markets ─1:N─ retailers ─1:N─ retailer_products
markets ─1:N─ deals

auth.users ─1:1─ profiles ─N:1─ markets (default_market_id)
profiles ─1:N─ credit_ledger · deal_unlocks · watchlist_items
              · purchase_records · barcode_lookups · credit_purchases

retailer_products ─1:N─ product_matches ─N:1─ marketplace_products
(retailer_product, marketplace_product) ─1:1─ deals  [one LIVE deal per pair:
                                                     unique where status <> 'retired']
deals ─N:1─ fee_schedules · tax_schedules
```

### 2.2 Reference / configuration tables (new in v2.0)

These are the tables that make the system global. **All are seeded data, editable by an admin, never constants in code.**

**`countries`**
`code (ISO 3166-1 alpha-2) PK, name, default_currency (ISO 4217), default_locale, tax_regime (vat|gst|sales_tax|none), retail_price_display (inclusive|exclusive), timezone_default, active`

> `retail_price_display` is not a detail. UK/EU/AU shelf prices include tax; US shelf prices do not. Getting this wrong silently inflates or deflates every profit figure in that country by the tax rate.

**`currencies`**
`code PK, minor_unit_exponent (2 for GBP/USD/EUR, 0 for JPY, 3 for KWD), symbol, name`

> The exponent must be data. Assuming "×100" everywhere breaks the moment you touch JPY.

**`marketplaces`**
`id PK, provider (amazon|ebay|walmart|…), code ('amazon_uk'), country_code FK, currency FK, domain, adapter_key, capabilities jsonb, fulfilment_programs jsonb, active, created_at`

MVP seeds: Amazon locales only. `capabilities` drives §8.7. `fulfilment_programs` maps generic roles to marketplace codes, e.g. `{"marketplace_fulfilled":"FBA","seller_fulfilled":"FBM"}`.

**`markets`** — the operating unit a deal belongs to
`id PK, slug ('uk','us','de'), source_country_code FK, marketplace_id FK, currency FK, active, launch_status (live|beta|planned)`

**`tax_schedules`** — versioned, per country
`id PK, country_code FK, regime, standard_rate_bps, reduced_rates jsonb, registration_supported bool, input_reclaim_supported bool, marketplace_fees_taxed bool, effective_from, effective_to, notes`

**`fee_schedules`** — versioned, **per marketplace**
`id PK, marketplace_id FK, version, effective_from, effective_to, referral_rules jsonb, fulfilment_bands jsonb, storage_rules jsonb, surcharges jsonb, currency, source_url, verified_at, created_at`

`surcharges` is a list, not a column — this is what replaces v1.0's hardcoded `digital_services_fee_bps`. Each entry: `{code, label, basis: 'referral_fee'|'sell_price'|'flat', rate_bps|amount_minor, applies_to_countries?}`. A new marketplace levy becomes a row edit.

**`fx_rates`** — **deferred to Phase 3. Not created in the MVP** (ADR-005)
Shape when it arrives: `base_currency, quote_currency, rate_ppm (parts per million, bigint), as_of, source`.

> **Why it is not created now.** The MVP has no consumer for it: deals are single-currency (§7.6), cross-border sourcing is Phase 3 (§0.1 assumption 7, §7.7), risk #4 states plainly that there is **no FX in the MVP at all**, and `PRODUCT_SPEC.md` AC2.7 forbids the user from even selecting a combination that would require conversion. An empty table with no consumer is not free — it is an invitation for a later service to join it and convert a currency, and a silent FX error looks exactly like a great deal. It is created in Phase 3, at the point of the first genuine cross-border or multi-currency reporting requirement, and never before. Until then, no table, no FK, no reference to it anywhere under `src/services/`.

**Temporal convention for versioned schedules.** `tax_schedules` and `fee_schedules` are versioned by an `effective_from`/`effective_to` pair, and the resolution query ("the schedule effective for this key on this date") must return **exactly one row**. This is enforced in the database by exclusion constraints, not by seeding convention (ADR-006):

- Ranges are **half-open, `[)`** — inclusive of `effective_from`, exclusive of `effective_to`. A version ending at time T and its successor starting at time T are adjacent, not overlapping, and both are valid. This is the normal shape of a version bump.
- **`effective_to IS NULL` means open-ended/current**, and participates in overlap detection as an unbounded upper edge. Two open-ended rows for the same key are rejected — the current row is precisely the one most likely to be NULL-terminated, so a NULL that dropped out of the constraint would defeat its purpose.
- Overlapping ranges are rejected per `country_code` for `tax_schedules` and per `marketplace_id` for `fee_schedules`. Overlaps across *different* keys are of course permitted.
- `effective_to`, when non-null, must be strictly greater than `effective_from`.

> Without this, two overlapping rows make the resolver return whichever row the query plan happens to reach first — stable enough to pass tests, unstable enough to change after an unrelated `VACUUM`. Every profit figure in that market then becomes systematically wrong, which is risk #2 and risk #3 realised silently.

### 2.3 Core tables

**`profiles`** — extends `auth.users`
| column | type | notes |
|---|---|---|
| id | uuid PK | FK → auth.users.id, cascade delete |
| display_name | text | |
| credit_balance | int | cached; authoritative source is `credit_ledger` |
| country_code | text FK | user's operating country |
| default_market_id | uuid FK | which feed they see |
| locale, timezone | text | formatting only |
| **tax_registered** | bool | replaces `vat_registered` |
| tax_registration_country | text FK | may differ from `country_code` |
| tax_scheme | enum | `standard` \| `simplified` (regime-specific variants are Phase 3) |
| default_fulfilment | enum | `marketplace_fulfilled` \| `seller_fulfilled` |
| default_budget_minor, prep_cost_per_unit_minor, inbound_shipping_per_unit_minor | bigint | |
| assumption_currency | text FK | currency the above are denominated in |
| onboarded_at, created_at | timestamptz | |

**`credit_ledger`** — append-only, source of truth for credits (credits are currency-neutral by design — see §9.1)
`id, user_id, delta, reason (signup_grant|purchase|unlock_deal|barcode_lookup|refund|chargeback|admin_adjust|promo), ref_type, ref_id, balance_after, idempotency_key NOT NULL UNIQUE, created_at NOT NULL DEFAULT now()`
Index `(user_id, created_at desc)`. `CHECK (delta <> 0)`. `balance_after` is `NOT NULL` and **may be negative** (§9.2 rule 4).

**`refund` and `chargeback` are opposite directions and must not be merged** (ADR-0010):

| Reason | Sign | Means |
|---|---|---|
| `refund` | **positive** | A credit **restored** to the user — a confirmed bad deal, honoured under the published refund policy (§9.3). |
| `chargeback` | **negative** | A credit **clawed back** because Stripe reversed the payment that created it (`charge.refunded`, `charge.dispute.created`). |

One is a product-quality event and the other is a payment event; they are read by different metrics and reconciled against different sources. The sign alone cannot distinguish them after the fact, since `admin_adjust` may also be negative.

**No UPDATE, no DELETE, ever — enforced at two layers.** An append-only trigger rejects both, *and* `service_role` holds only `SELECT, INSERT` on this table: `UPDATE` and `DELETE` are revoked from it (ADR-0010). The revoke stops the role our own server code runs as; the trigger stops any role that does hold the privilege. **`user_id` is `ON DELETE RESTRICT`** — financial history survives account deletion (§11.5).

**`credit_purchases`**
`id, user_id (ON DELETE RESTRICT), stripe_checkout_session_id UNIQUE, stripe_payment_intent_id NULLABLE UNIQUE, stripe_customer_id NULLABLE, credit_pack_id, credit_pack_price_id NULLABLE FK, credits, amount_minor, currency, status (pending|paid|failed|refunded), created_at, completed_at`
Indexes `(user_id, created_at desc)` and `(status)`.

`credits`, `amount_minor` and `currency` are **immutable purchase snapshots** — what was bought and paid, frozen at purchase time, so re-pricing a pack later cannot rewrite what was sold. `status` and `completed_at` remain mutable: the row records a process. `credit_pack_price_id` records which per-currency price the sale was made at, and is nullable because a price row may be retired and an admin grant has none.

**`stripe_webhook_events`** — `stripe_event_id PK, type, payload jsonb, received_at NOT NULL DEFAULT now(), processed_at NULLABLE, error`

**This row is not immutable, and deliberately so.** Its **identity is frozen** — `stripe_event_id`, `type`, `payload` and `received_at` may never change, because the row is the evidence and the replay guard. Its **processing outcome is written after the fact**: `processed_at` (null until fulfilled) and `error` are the only mutable columns, enforced by a restricted-UPDATE trigger. `DELETE` is revoked from `service_role`: deleting an event re-opens the duplicate-grant window it exists to close.

**`credit_packs`** — `id, name, credits, active, sort_order` — `CHECK (credits > 0)`
**`credit_pack_prices`** — `id, credit_pack_id FK, currency FK → currencies, amount_minor, stripe_price_id NULLABLE, active` — unique `(credit_pack_id, currency)`, `CHECK (amount_minor > 0)`.

> Pack *value* is credits; pack *price* is per-currency. This one split is what makes selling in USD, EUR and GBP a seeding exercise rather than a refactor.

> **`stripe_price_id` is nullable on purpose.** Pack prices are seeded long before any Stripe object exists, and a placeholder id is worse than a null: it satisfies every not-null check and then fails at the checkout call. The safety is a read predicate rather than a column constraint — a pack price is publicly readable only where `active = true AND stripe_price_id IS NOT NULL`, so an unbuyable price is invisible rather than clickable.

**`retailers`**
`id, name, slug, market_id FK, country_code FK, currency FK, website_url, source_type (affiliate_feed|api|curated|manual), affiliate_network, affiliate_tracking_template, price_display (inclusive|exclusive, defaults from country), active, created_at`

**`retailer_products`**
| column | type | notes |
|---|---|---|
| id | uuid PK | |
| retailer_id | uuid FK | |
| retailer_sku | text | unique with retailer_id |
| title, brand | text | |
| **gtin14** | text | **canonical, zero-padded**; the matching key |
| gtin_raw, gtin_format | text | original as supplied (`upc_a`, `ean_13`, `ean_8`, `isbn_13`) |
| mpn, asin_hint | text | `asin_hint` = retailer-supplied marketplace id, when present |
| product_url, image_url | text | |
| price_minor, currency | bigint, text | |
| price_tax_treatment | enum | `inclusive` \| `exclusive` — from retailer, not assumed |
| was_price_minor | bigint | for discount % |
| in_stock, stock_qty | bool, int | |
| source_batch_id | uuid | |
| first_seen_at, last_seen_at | timestamptz | |
| raw | jsonb | |

Unique `(retailer_id, retailer_sku)`. Index on `gtin14`, `last_seen_at`.

> **GTIN normalisation is a global-first requirement, not tidiness.** A UPC-12 in the US and an EAN-13 in the UK identify the same product. Store the zero-padded GTIN-14 as canonical and keep the original for debugging. Without this, matching silently fails across countries.

**`marketplace_products`** — replaces `amazon_products`
| column | type | notes |
|---|---|---|
| id | uuid PK | |
| marketplace_id | text FK | |
| **external_id** | text | ASIN for Amazon; whatever the marketplace uses otherwise |
| title, brand, category_id, category_path | text | |
| gtins | text[] | canonical GTIN-14s |
| image_key, listing_url | text | |
| rank_value, rank_avg_90d | int | generic "demand rank" (Amazon: sales rank) — nullable |
| est_monthly_sales | int | nullable, **explicitly an estimate** |
| buybox_price_minor, currency | bigint, text | generic "featured offer price" |
| buybox_is_marketplace_owned | bool | Amazon: "Amazon is the seller" |
| offer_count_marketplace_fulfilled / _seller_fulfilled | int | |
| marketplace_owned_in_stock_pct_90d | int | 0–100, nullable |
| price_avg_90d_minor, price_stddev_90d_minor, price_min_90d_minor, price_max_90d_minor | bigint | nullable — history is a capability, not a guarantee |
| item_weight_g, dims_mm | int, jsonb | for fulfilment fee bands |
| hazmat, oversize, restricted_flags | bool, bool, jsonb | |
| provider_key, provider_raw | text, jsonb | which adapter produced this, and its raw payload |
| refreshed_at | timestamptz | drives staleness display |

PK/unique: `(marketplace_id, external_id)`. Index on `gtins` (GIN), `refreshed_at`.

> Amazon-specific vocabulary survives only inside `provider_raw` and the adapter's mapper. Everything above the adapter speaks in generic terms.

**`product_matches`**
`id, retailer_product_id FK, marketplace_product_id FK, method (gtin_exact|retailer_hint|title_fuzzy|manual|barcode_scan), confidence numeric(3,2), verified_by (system|admin|user_report), created_at` — unique `(retailer_product_id, marketplace_product_id)`.

**`deals`** — the central read model
| column | type | notes |
|---|---|---|
| id | uuid PK | |
| **market_id** | uuid FK | scopes the whole row |
| retailer_product_id, marketplace_product_id | uuid FK | |
| match_confidence | numeric | copied for fast filtering |
| **currency** | text FK | one currency for every money column below |
| **Costs** | | |
| buy_price_minor | bigint | as displayed at retail, with `buy_price_tax_treatment` |
| buy_tax_reclaim_minor | bigint | 0 when reclaim unavailable — see §7.4 |
| inbound_shipping_minor, prep_cost_minor | bigint | |
| **Revenue** | | |
| sell_price_minor | bigint | assumed achievable sale price |
| sell_tax_liability_minor | bigint | output tax owed, 0 if not registered |
| **Fees** | | |
| referral_fee_minor, fulfilment_fee_minor, storage_fee_minor, other_fees_minor | bigint | |
| surcharges | jsonb | itemised `[{code,label,amount_minor}]` — replaces the DSF column |
| fee_schedule_id, tax_schedule_id | uuid FK | exact versions used |
| **Outputs** | | |
| net_profit_minor | bigint | per unit |
| roi_bps, margin_bps | int | basis points, integers only |
| deal_score | int | 0–100 |
| demand_band, competition_band, stability_band, confidence_band | enum | `low\|medium\|high` |
| score_breakdown | jsonb | components, weights, renormalisation, penalties |
| calc_version, score_version | text | |
| inputs_snapshot | jsonb | every input, frozen, including the resolved MarketContext |
| computed_at, expires_at | timestamptz | `expires_at` is the freshness horizon — see the staleness note below |
| **status** | enum | `draft` \| `active` \| `retired`, **NOT NULL DEFAULT `draft`** (ADR-0009) |
| **published_at, published_by** | timestamptz, uuid | when and by whom the deal was published; `published_by` → `auth.users`, `ON DELETE SET NULL` |
| **retired_at, retired_by, retire_reason** | timestamptz, uuid, text | the same for retirement, plus why |

Indexes: `(market_id, status, deal_score desc)`, `(market_id, status, roi_bps desc)`, `(market_id, status, computed_at desc)`.

**Deal lifecycle (ADR-0009).** A deal is created `draft`, may be published to `active`, and may be retired from either state. **Retired is terminal.**

```
INSERT ──▶ draft ──▶ active ──▶ retired ✗ (terminal)
             │                    ▲
             └────────────────────┘
  draft→draft ✓   active→active ✓   (recompute in place)
  active→draft ✗  retired→active ✗  retired→draft ✗
```

Enforced in the database by a `BEFORE INSERT OR UPDATE` trigger, because a transition rule compares OLD to NEW and PostgreSQL has no declarative form for that. Two consequences that are load-bearing, not incidental:

- **An INSERT must be `draft`.** Publication is therefore always a later UPDATE. The computation pipeline (§1.4, T19) has no path that produces a user-visible deal, whatever it intends — this is AC3.3 enforced at the storage layer rather than trusted to a service.
- **Only the timestamps are stamped by the database**; `published_by` and `retired_by` are supplied by the caller. The database knows *when*, only the API knows *who*, and **who is allowed** to publish or retire is an authorization question owned by the admin lifecycle API (T20A) and the console (T33) — never by this trigger.

**Staleness is derived, never stored.** There is deliberately no `stale` status. Freshness is a function of two timestamps — `deals.expires_at` and `marketplace_products.refreshed_at` — evaluated at read time. A derived fact stored as a state needs a writer, the writer needs a schedule, and between runs the column lies; §12.2 principle 4 wants stale-but-labelled data, which requires knowing the age, not a flag. A deal past its expiry is still `active` and the read layer labels it (AC5.3).

**Uniqueness: one *live* deal per pair.** The partial unique index on `(retailer_product_id, marketplace_product_id)` uses the predicate **`WHERE status <> 'retired'`**. Draft and active are both "the current answer for this pair", so only one may exist across the two — otherwise a recompute stacks drafts behind a published deal and an admin is choosing between duplicates. Retired rows drop out of the index entirely, which keeps the history *and* lets a fresh draft replace a retired deal.

> **Every feed query is market-scoped.** `market_id` leads every composite index because "show me deals" always means "in my market". A query that forgets it is a bug that will surface as a user in Germany seeing a Tesco price in pounds.

> **Note on personalisation (unchanged from v1.0):** profit depends on the user's tax status and prep costs. Store the **canonical deal** computed under the market's *standard assumption profile* (not tax-registered, marketplace-fulfilled, default prep/shipping), and recompute a **personalised overlay in-request** from `inputs_snapshot`. Do not build per-user precomputation.

**`deal_unlocks`** — `id, user_id, deal_id, credits_spent, unlocked_at`, unique `(user_id, deal_id)`. Permanent.

**`watchlist_items`** — `id, user_id, deal_id, marketplace_product_id, target_profit_minor, currency, note, created_at`, unique `(user_id, deal_id)`.

**`barcode_lookups`** — `id, user_id, market_id, barcode_raw, gtin14, resolved_marketplace_product_id, credits_spent, result jsonb, created_at`

**`purchase_records`** — **the MVP validation instrument**
`id, user_id, deal_id, market_id, units, actual_buy_price_minor, currency, expected_profit_minor (snapshot), purchased_at, outcome (pending|sold|partial|unsold|returned), actual_sale_price_minor, actual_profit_minor, notes`

**`api_usage_log`** — `id, provider, marketplace_id, endpoint, units_used, cost_minor_est, currency, status, latency_ms, created_at`

**`ingestion_runs`** — `id, market_id, source, started_at, finished_at, status, rows_in, rows_upserted, rows_failed, error jsonb`

**`app_events`** — `id, user_id, market_id, event, properties jsonb, created_at`

### 2.4 Money and numeric conventions

- All currency: `bigint` **minor units**, always paired with an ISO 4217 `currency` column. Minor-unit exponent comes from `currencies`, never from an assumed ×100.
- All rates: **basis points** as `int` (25% = 2500).
- **A `Money` value is `{ amountMinor, currency }`.** Adding two `Money` values of different currencies throws. There is no implicit conversion anywhere in the codebase.
- One shared `lib/money` module: `add`, `subtract`, `mulBps`, `allocate`, `format`. Rounding: **round half away from zero at the final step only**.
- Formatting is `Intl.NumberFormat(userLocale, { style:'currency', currency: deal.currency })`. **No currency symbol appears in application code.** A grep for `£` or `$` in `src/` should return nothing outside test fixtures.
- Every fee-bearing calculation is unit-tested against hand-worked examples **in at least two currencies, one of which has a non-2 exponent**.

---

## 3. Main Backend Services

Modules inside the Next.js app (`/src/services/*`). Pure functions where possible, IO at the edges.

| Service | Responsibility | Never does |
|---|---|---|
| **`market`** | Resolve and cache `MarketContext`: market → marketplace, currency, active fee schedule, active tax schedule, capabilities. | Contain per-country branching logic. |
| **`ingestion`** | Pull retailer feeds / accept curated CSV, normalise to `retailer_products` (including GTIN-14 and tax treatment), dedupe, record `ingestion_runs`. | Match, price or score. |
| **`matching`** | `retailer_product → marketplace_product` with a confidence score. Tier 1: GTIN-14 exact via adapter code lookup. Tier 2: retailer-supplied id. Tier 3: brand+title heuristic (flagged, low confidence). Tier 4: manual. | Guess silently, or match across marketplaces. |
| **`marketplace`** | The adapter interface + registry + provider implementations (§10.1). Quota accounting, backoff, caching, `api_usage_log`, mapping provider payloads to `marketplace_products`. | Leak provider vocabulary upward. Be called directly from routes. |
| **`tax`** | Resolve a `TaxRegime` strategy from `MarketContext` + user profile; compute input reclaim and output liability. Pure. | Hardcode a rate or a country. |
| **`pricing`** | Pure function: inputs + fee schedule + tax result → full itemised breakdown. Deterministic, versioned, no IO. | Read the DB, call APIs, or know which country it is in. |
| **`scoring`** | Pure function: deal + demand metrics + capabilities → score, components, bands. Deterministic, versioned. | Assume every metric is available (§8.7). |
| **`recommendation`** | Budget + velocity + risk → suggested units and rationale. | Promise outcomes. |
| **`credits`** | Balance reads; `spend_credits` / `grant_credits` via Postgres RPC (atomic), idempotent. | Be bypassed by a direct ledger insert. |
| **`billing`** | Stripe Checkout in the user's currency, webhook verification and fulfilment. | Grant credits outside the credits service. |
| **`unlocks`** | Spend → record unlock → return full deal, one transaction. | Return data before the spend commits. |
| **`watchlist`** | CRUD. | |
| **`barcode`** | Barcode → GTIN-14 → adapter lookup in the user's market. Charges only on a successful resolve. | Charge for a failed lookup. |
| **`redaction`** | The single place deciding which deal fields a user may see. | Be duplicated anywhere. |

**Pipeline orchestration:** Vercel Cron hits protected cron routes. Each run is **market-scoped** (`/api/cron/refresh?market=uk`), idempotent, batched, time-boxed and resumable via a cursor. Markets are processed independently so one market's provider outage cannot stall another's.

---

## 4. Frontend Architecture

**Next.js App Router, mobile-first, PWA.**

### 4.1 Rendering strategy

- **Server Components by default.** Feed, deal detail, watchlist are server-rendered.
- **Client Components only for interaction:** filters, unlock button, scanner, budget slider, Stripe redirect.
- **No Redux/Zustand/React Query in MVP.**

### 4.2 Locale and currency handling

- User locale and timezone live on the profile; default from `Accept-Language` and the market, overridable in settings.
- **All money is formatted from `{amountMinor, currency}` at the render boundary.** Never in a service, never concatenated with a symbol.
- All timestamps stored UTC, rendered in the user's timezone.
- **All user-facing strings live in one catalogue** (`src/messages/en.ts`) accessed by key. This is not i18n tooling — it is the thing that makes i18n tooling a later data exercise instead of a rewrite. Cost now: near zero. Cost later if skipped: every component.
- Number and date formats via `Intl`. No hand-rolled `toFixed(2)` on money.

### 4.3 Route map

```
/(marketing)/            landing, pricing, how-scoring-works
/(auth)/                 sign-in, sign-up, callback
/(app)/feed              deal feed (locked cards), scoped to active market
/(app)/deal/[id]         deal detail (redacted or full)
/(app)/scan              barcode scanner
/(app)/watchlist
/(app)/credits           balance, packs (priced in user's currency), history
/(app)/settings          market, tax status, fulfilment, prep costs, budget, locale
/(app)/purchases         "I bought this" log (validation)
/admin/*                 markets, marketplaces, fee & tax schedules,
                         ingestion runs, match review
```

Market is a **profile setting, not a URL segment**, in MVP. Locale-prefixed routing (`/en-gb/…`) is a Phase 3 concern and adding it later does not disturb this map.

### 4.4 Key UI components (trust-first)

- **`DealCard` (locked)** — category, ROI band, profit band, Deal Score, retailer *type*, marketplace, data freshness. **Never** the product name, image, external id, or retailer name.
- **`DealDetail` (unlocked)** — exact product, retailer link, marketplace listing link, and a **fully itemised breakdown**: buy price, tax treatment, referral fee, fulfilment fee, itemised surcharges, prep, shipping, net, ROI.
- **`ScoreBreakdown`** — components, weights, raw inputs, penalties, and **which components were unavailable and how weights were renormalised** (§8.7).
- **`AssumptionsPanel`** — every assumption, editable inline, with live recalculation.
- **`ConfidenceBadge`** — match confidence + data age.
- **`UnitRecommendation`** — suggested units, capital required, expected total profit, reasoning in words.
- **`RiskFlags`** — marketplace competes on the listing / brand gating risk / few offers / volatile price / low match confidence / **tax treatment uncertain**.
- **`MarketSwitcher`** — only rendered when more than one market is live. One market at launch means this component exists and shows nothing.

> **Design principle:** the app's product is not a number, it is a *defensible* number.

### 4.5 PWA scope

`manifest.json`, icons, service worker caching the app shell and last-fetched feed. Add-to-home-screen. **No offline writes, no background sync, no push in MVP.**

---

## 5. API Architecture

### 5.1 Style

REST-ish Route Handlers under `/api/v1/*`, plus Server Actions for simple mutations. **No tRPC, no GraphQL.**

Every handler:
```
1. authenticate (session → user)
2. resolve MarketContext (user's active market, or explicit ?market=)
3. rate-limit (per user + per IP)
4. validate (Zod, parse don't validate)
5. delegate to a service (handlers contain no business logic)
6. return a typed envelope
```

Step 2 is new in v2.0 and is not optional: **a handler that does not resolve a market cannot safely touch deals.**

### 5.2 Response envelope

```jsonc
// success
{ "ok": true, "data": { ... },
  "meta": { "requestId": "...", "version": "v1", "marketId": "uk", "currency": "GBP" } }
// failure
{ "ok": false, "error": { "code": "INSUFFICIENT_CREDITS", "message": "…", "details": {} },
  "meta": { "requestId": "..." } }
```

Money in payloads is always `{ "amountMinor": 1299, "currency": "GBP" }` — never a bare number, never a preformatted string. The server decides the value; the client decides the presentation.

### 5.3 Endpoints (MVP)

| Method | Path | Notes |
|---|---|---|
| GET | `/api/v1/markets` | Live markets (public — drives signup). |
| GET | `/api/v1/deals` | Feed, **market-scoped**. Filters: min ROI, min profit, min score, category, budget. Cursor pagination. **Redacted rows.** |
| GET | `/api/v1/deals/:id` | Redacted unless unlocked. |
| POST | `/api/v1/deals/:id/unlock` | Idempotent. Atomic credit spend. Returns full deal. |
| POST | `/api/v1/deals/:id/recalculate` | Personalised recompute with user overrides. Free. |
| GET/POST/DELETE | `/api/v1/watchlist` | |
| POST | `/api/v1/barcode/lookup` | Market-scoped. Charges on success only. |
| GET | `/api/v1/credits/balance` · `/history` | |
| POST | `/api/v1/billing/checkout` | Pack + user currency → Stripe session. |
| POST | `/api/v1/billing/webhook` | **Unauthenticated, signature-verified, raw body.** |
| GET/PATCH | `/api/v1/profile` | Market, tax status, costs, budget, locale. |
| POST | `/api/v1/purchases` | "I bought this." |
| POST | `/api/v1/feedback` | "This deal looks wrong." |
| POST | `/api/cron/*` | `CRON_SECRET`, market-scoped. |

### 5.4 Cross-cutting

- **Idempotency:** `Idempotency-Key` required on `unlock`, `barcode/lookup`, `checkout`.
- **Rate limits:** unlock 30/min, barcode 20/min, feed 120/min, webhook exempt. Postgres counter table.
- **Versioning:** `/v1` from day one.

---

## 6. Authentication and Authorization Model

Unchanged from v1.0 in substance. Two additions for global operation.

### 6.1 Authentication

- **Supabase Auth**, email/password + magic link. Google OAuth if signup friction shows.
- `@supabase/ssr`, **httpOnly cookies**. No tokens in `localStorage`.
- Middleware protects `/(app)/*` and `/admin/*`.
- Email verification required before credits can be spent.
- **Signup captures country → market.** If no live market matches the user's country, they are waitlisted for that market rather than shown an empty or foreign feed. An empty feed is worse than an honest "not live here yet".

### 6.2 Supabase clients

| Client | Key | Where | Bypasses RLS |
|---|---|---|---|
| `createBrowserClient` | anon | browser | No |
| `createServerClient` | anon + session | RSC / handlers | No |
| `createAdminClient` | **service_role** | server only, `import 'server-only'` | **Yes** |

### 6.3 Authorization: RLS policy design

**Default deny, at two layers.** RLS is enabled on every table, and — established in T03, ADR-004 — `anon` and `authenticated` hold **no table privileges by default**; `service_role` holds table DML only; functions are owner-only. **A policy and a SQL grant are both required for access, and neither works alone:** RLS filters rows *within* privileges already held, so a policy without a matching grant is inert, and a grant without a matching policy is an ungoverned privilege. Every migration that creates a table, function, view or sequence states its privilege posture explicitly and revokes any Postgres or Supabase default grant in the same migration.

| Table | Policy | Grant to `anon`/`authenticated` |
|---|---|---|
| `profiles` | SELECT/UPDATE where `id = auth.uid()`; `credit_balance` not directly updatable. | `SELECT, UPDATE` (authenticated) |
| `credit_ledger` | SELECT own rows. **No write policy at all** — writes only via `SECURITY DEFINER` RPC. Additionally, `service_role` holds `SELECT, INSERT` only: `UPDATE` and `DELETE` are revoked from it (ADR-0010). | `SELECT` only (authenticated) |
| `deal_unlocks`, `watchlist_items`, `purchase_records`, `barcode_lookups` | SELECT/INSERT/DELETE where `user_id = auth.uid()`. | matching per-operation grants (authenticated) |
| `deals`, `retailer_products`, `marketplace_products`, `product_matches` | **No policies. Service-role only.** Access via server routes that apply redaction. | **none** |
| `markets`, `countries`, `currencies` | SELECT where `active = true` (public read — the client needs to render a currency and a market name). | `SELECT` |
| `credit_packs` | SELECT where `active = true`. | `SELECT` |
| `credit_pack_prices` | SELECT where `active = true` **and `stripe_price_id IS NOT NULL`** — a price with no Stripe Price ID cannot be bought and is not shown (ADR-0010). | `SELECT` |
| `marketplaces` | **No policy. Service-role only** (ADR-008). | **none** |
| `fee_schedules`, `tax_schedules`, logs, runs | service-role only. | **none** |

**Why `marketplaces` is not public read:** it carries `adapter_key` and `capabilities`, which are integration internals, and no MVP client surface needs it — the feed is market-scoped server-side, and rendering a currency and a market name needs `currencies` and `markets` only. If a client need emerges, expose a view with the specific columns required rather than granting the table.

**Why deals are not client-readable:** the paid product *is* the identity of the product. Column-level RLS to hide it is fragile and one mistake from giving it away. Server-side redaction is one function, one test, one place to get right.

### 6.4 Roles

`user` and `admin` only. No RBAC system for a user base of one admin. (Multi-market admin delegation is a Phase 4 problem and will need a real role table when it arrives — not before.)

### 6.5 Credit spending must be atomic

```sql
-- SECURITY DEFINER, search_path locked
create function spend_credits(p_user uuid, p_amount int, p_reason text,
                              p_ref_type text, p_ref_id uuid, p_idem text)
returns table (new_balance int, ledger_id uuid)
-- 1. insert into credit_ledger with idempotency_key -> ON CONFLICT return existing
-- 2. select profiles.credit_balance FOR UPDATE   (row lock)
-- 3. if balance < amount -> raise 'INSUFFICIENT_CREDITS'
-- 4. update profiles.credit_balance, write ledger row with balance_after
-- all in one transaction
```
Unlock = `spend_credits` + `insert deal_unlocks` in the **same transaction**. Never "check balance, then deduct" in application code.

---

## 7. Deal Calculation Architecture

### 7.1 Design rules

1. `calculateDeal(inputs) → breakdown` is a **pure function**. No IO. Fully unit-testable.
2. Inputs are explicit and snapshotted. Fee rates come from `fee_schedules`, tax rates from `tax_schedules`. **No rate, threshold or country name appears in code.**
3. Output is an **itemised breakdown**, not a single number.
4. Versioned via `calc_version`, plus the exact `fee_schedule_id` and `tax_schedule_id` used.
5. **The function is country-blind.** It receives a resolved fee schedule and a tax result. If it ever needs to know which country it is in, the abstraction has leaked.

### 7.2 Inputs

```ts
type DealInputs = {
  currency: CurrencyCode;
  buyPrice: Money;
  buyPriceTaxTreatment: 'inclusive' | 'exclusive';
  sellPrice: Money;
  sellPriceTaxTreatment: 'inclusive' | 'exclusive';
  categoryId: string;
  itemWeightG: number;
  dimsMm: { l: number; w: number; h: number };
  fulfilment: 'marketplace_fulfilled' | 'seller_fulfilled';
  taxProfile: {                       // resolved by the tax service, §7.4
    regime: 'vat' | 'gst' | 'sales_tax' | 'none';
    registered: boolean;
    standardRateBps: number;
    inputReclaimSupported: boolean;
    marketplaceFeesTaxed: boolean;
  };
  prepCost: Money;
  inboundShipping: Money;
  expectedStorageMonths: number;      // default 1
  returnsAllowanceBps: number;        // category-informed default
  feeSchedule: FeeSchedule;           // resolved, versioned
}
```

Every `Money` carries the currency. The engine asserts all inputs share one currency and throws otherwise — that assertion is the guardrail that keeps FX out of MVP maths.

### 7.3 Calculation order

```
1. Normalise sell/buy prices to a common tax basis (using taxProfile + treatment flags)
2. Referral fee      = sellPrice × categoryReferralBps from feeSchedule (min fee applies)
3. Surcharges        = for each entry in feeSchedule.surcharges, apply by its basis
                       (replaces v1.0's hardcoded digital services fee)
4. Fulfilment fee    = band lookup(weight, dims) from feeSchedule.fulfilment_bands
                       | seller-fulfilled shipping estimate
5. Storage fee       = volume × rate × months, from feeSchedule.storage_rules
6. Prep + inbound shipping (user assumptions)
7. Returns allowance = sellPrice × returnsAllowanceBps
8. Tax treatment     → §7.4
9. Net profit = sellPriceNetOfOutputTax
                − buyCostNetOfReclaim
                − allFees − prep − shipping − storage − returnsAllowance
10. ROI (bps)    = netProfit / totalCashOut × 10000
11. Margin (bps) = netProfit / sellPrice × 10000
```

`totalCashOut` = buy price + prep + inbound shipping — the money the user actually parts with. ROI on *cash deployed* is what an arbitrageur cares about; state the denominator in the UI.

### 7.4 Tax — generalised from v1.0's UK VAT section

Tax status changes profit by double-digit percentages and **differs by regime, not just by rate**. It is resolved by a strategy, selected from `tax_schedules.regime`.

| Regime | Retail price basis | Not registered | Registered |
|---|---|---|---|
| **VAT** (UK, EU) | tax-inclusive | Buy cost is the full shelf price; no reclaim. No output tax on sale. Marketplace fees are tax-inclusive and that tax is sunk. | Reclaim input tax on purchase (`price × rate/(1+rate)`) **only with a valid tax invoice** — surface this caveat. Owe output tax on sale. Reclaim tax on marketplace fees. |
| **GST** (AU, NZ, CA-GST, SG) | tax-inclusive | As VAT. | As VAT; registration thresholds differ — data, not code. |
| **Sales tax** (US) | **tax-exclusive** | Buy cost = shelf price **+ sales tax actually paid** unless exempt. No tax on the marketplace sale from the seller's side (marketplace facilitator laws generally shift collection to the marketplace). | Resale certificate ⇒ purchase exempt from sales tax; no reclaim mechanism, an exemption instead. |
| **None** | either | Straight arithmetic. | n/a |

Three consequences that must be built in, not bolted on:

1. **`price_tax_treatment` is per-retailer data**, because the US buys at shelf-price-plus-tax and the UK does not. Assuming inclusivity is a systematic error, not a rounding one.
2. **US sales tax is an exemption model, not a reclaim model.** The generic field is "cost of tax on purchase, after any relief" — computed by the regime strategy, stored as `buy_tax_reclaim_minor` for compatibility.
3. **Default new users to *not registered*** — the more conservative and more common case — and ask during onboarding.

> Flat-rate schemes, margin schemes, OSS/IOSS, US nexus determination and state-level rate lookup are **out of scope**. Where a regime's detail exceeds what the schedule models, flag the deal `tax treatment uncertain` rather than guessing. Show "estimates, not tax advice" wherever profit appears.

### 7.5 Conservatism policy

Trust is destroyed by optimism, not caution.
- Sell price = **lower of** current featured-offer price and 90-day average (never the peak). Where 90-day history is unavailable (a marketplace capability gap), use current price **and** lower the confidence component.
- Include a returns allowance by default.
- Include at least one month of storage.
- Round profit **down**, ROI **down**.
- Where an input is unknown (missing dims → no fulfilment fee), **do not guess**: mark low confidence or withhold the deal.

Optionally display **Conservative** (default) and **Optimistic**. Lead with conservative.

### 7.6 Multi-currency rule for MVP

One deal, one currency, no conversion. Enforced at three layers: a check constraint on `deals`, an assertion in the pricing engine, and a validation in the matching service. Belt, braces and a third belt — because a silent FX error looks exactly like a great deal.

### 7.7 Cross-border arbitrage — Phase 3, deliberately excluded

Buying in one currency and selling in another adds: FX rate selection and timing, spread and card fees, import duty and customs, import VAT/GST, cross-border shipping, and the marketplace's own currency conversion. Each is a source of error large enough to invert a profit figure.

The schema is *shaped* for it — deals carry an explicit currency and retailers carry a country — but **`fx_rates` is deliberately not created in the MVP** (ADR-005), and **no cross-currency deal may be computed until a dedicated landed-cost model exists.** The FX table arrives with the landed-cost model, not before it: an unused rate table is the thing a later service joins to by accident. Building it now would put the least reliable numbers in the product at exactly the moment you are trying to establish that your numbers can be trusted.

---

## 8. Deal Score Architecture

### 8.1 Philosophy

The Deal Score compresses several judgements into one number **without becoming a black box**. If a user cannot see why a deal scored 78, the score has no trust value and the hypothesis fails.

Deterministic, explainable, versioned, weights in one config, breakdown persisted and displayed.

### 8.2 Components (0–100 each, then weighted)

| Component | Weight | Inputs | Intuition |
|---|---|---|---|
| **Profitability** | 35% | ROI bps + absolute net profit (in deal currency) | Both matter: 200% ROI on a trivial amount is noise; a large profit at 6% ROI ties up capital. Hard floor: profit below the market's minimum viable threshold → heavy penalty. |
| **Demand** | 25% | rank, **rank percentile within (marketplace, category)**, 90-day trend, est. monthly sales | Rank must be normalised within *marketplace and category*. Rank 20,000 on Amazon.co.uk Grocery ≠ rank 20,000 on Amazon.com Grocery ≠ rank 20,000 in Books. |
| **Competition** | 20% | offer counts by fulfilment type, marketplace-owned presence/in-stock %, featured-offer rotation | The marketplace itself competing on the listing is close to disqualifying for a beginner. |
| **Price stability** | 10% | 90-day stddev ÷ mean, drawdown from average | Volatile prices turn a modelled profit into a real loss. |
| **Confidence** | 10% | match confidence, data freshness, input completeness, **capability coverage** | A great deal on the wrong listing is a loss. This component protects the user from *your* uncertainty — including uncertainty caused by a marketplace that supplies less data. |

### 8.3 Composition

```
base = Σ (component × renormalised weight)      // see §8.7

penalties (multiplicative, capped):
  marketplace_owned_on_listing_in_stock  × 0.55
  match_confidence < 0.8                 × 0.70
  sparse or stale data (> 48h)           × 0.80
  brand on gating-risk list (per market) × 0.65
  net profit below market floor          × 0.40
  tax treatment uncertain                × 0.85

hard suppressions (deal not published at all):
  net profit ≤ 0
  match confidence < 0.6
  required inputs missing (no weight/dims for marketplace fulfilment)
  currency mismatch between retailer and marketplace

final = clamp(round(base × penalties), 0, 100)
```

**Bands:** 80+ Excellent · 65–79 Good · 50–64 Fair · <50 Weak (hidden from the default feed).

### 8.4 Thresholds are per-market data

Minimum viable profit is not a universal constant — it depends on currency, local costs and local competition. Score thresholds, profit floors and velocity shares live in a per-market config row, not in the scoring code. The *shape* of the score is global; its *calibration* is local.

### 8.5 Persisted breakdown

```jsonc
{
  "version": "score.v1",
  "marketId": "uk",
  "marketplaceId": "amazon_uk",
  "currency": "GBP",
  "components": {
    "profitability": { "score": 82, "weight": 0.35, "inputs": { "roiBps": 4200, "netProfitMinor": 640 } },
    "demand":        { "score": 71, "weight": 0.25, "inputs": { "rank": 18400, "categoryPercentile": 12 } },
    "competition":   { "score": 55, "weight": 0.20, "inputs": { "marketplaceFulfilledOffers": 8, "marketplaceOwnedInStockPct90d": 0 } },
    "stability":     { "score": 68, "weight": 0.10, "inputs": { "cv90d": 0.11 } },
    "confidence":    { "score": 90, "weight": 0.10, "inputs": { "matchConfidence": 0.99, "dataAgeHours": 3, "capabilityCoverage": 1.0 } }
  },
  "unavailableComponents": [],
  "weightRenormalisation": null,
  "penalties": [{ "code": "LOW_OFFER_COUNT", "factor": 0.95 }],
  "base": 72, "final": 68
}
```

### 8.6 Calibration

`purchase_records` outcomes are the calibration dataset: after ~50–100 recorded outcomes **per market**, compare predicted vs actual profit per score band and retune → `score.v2`. **Never retro-edit v1 rows.** Calibrate per market where volume allows; where it does not, say so rather than borrowing another market's calibration.

### 8.7 Capability-aware scoring — the marketplace-agnostic part

Not every marketplace supplies every input. Amazon-via-Keepa gives rank history, offer counts and 90-day price series. A future marketplace may give none of these. The score must degrade **visibly and honestly**, never silently.

```ts
type MarketplaceCapabilities = {
  priceHistory: boolean;      // → stability component
  rankOrDemandProxy: boolean; // → demand component
  offerCounts: boolean;       // → competition component
  feePreview: boolean;        // → pricing accuracy
  categoryTaxonomy: boolean;  // → category normalisation
};
```

Rule: **a component whose inputs are unavailable is dropped, and the remaining weights are renormalised to sum to 1.** The dropped component is recorded in `unavailableComponents`, the renormalisation is recorded in `weightRenormalisation`, and the confidence component is reduced in proportion to lost coverage. The UI states plainly which parts of the assessment could not be made.

This is the difference between an architecture that is marketplace-agnostic and one that merely renamed its columns. **Never substitute a default value for a missing capability** — a fabricated stability score is worse than an absent one.

### 8.8 Unit recommendation

```
maxByBudget      = floor(userBudget / cashOutPerUnit)          // same currency, asserted
maxByVelocity    = floor(estMonthlySales × velocityShare)      // per-market share, 5–15%
maxByRisk        = risk cap by score band (e.g. <65 → cap 3 units)
maxByCapitalRisk = floor(maxCapitalAtRiskPerDeal / cashOutPerUnit)  // default 20% of budget

recommended = max(1, min(all four))
```
Always render the binding constraint in words: *"Limited to 6 units by estimated demand — 8 sellers are already sharing roughly 90 sales a month."* The reasoning is the product. Where velocity cannot be estimated (capability gap), the velocity cap is **not** applied and the UI says the estimate is unavailable.

---

## 9. Credit / Payment Architecture

### 9.1 Model — and why credits are the right global abstraction

**Credits, prepaid in packs.** No subscription in MVP.

Credits do something specific for a global product: **they decouple the unit of value from the unit of currency.** One unlock costs one credit whether the user is in Manchester or Munich. Only the *pack price* is per-currency, and that is a table. Without credits you would be maintaining per-country pricing for every feature; with them you maintain a price list.

- Signup grant: e.g. 5 free credits — a product mechanic, not a promotion (a user must be able to survive a disappointing unlock and still reach a good one).
- Unlock a deal: 1 credit. Barcode lookup: 1 credit. Unlocks are permanent.
- Pack prices per currency in `credit_pack_prices`, each mapped to a Stripe Price. **Set local prices deliberately; do not FX-convert a GBP price into an odd USD number** — round to locally sensible price points.

### 9.2 Purchase flow

```
Client → POST /billing/checkout { packId }
Server → resolve user currency → look up credit_pack_prices → validate
       → create credit_purchases(pending)
       → Stripe Checkout Session (stripe_price_id for that currency,
         client_reference_id = userId, metadata { userId, packId, purchaseId })
Client → redirect to Stripe (hosted, localised by Stripe)
Stripe → POST /billing/webhook  checkout.session.completed
Server → verify signature (raw body)
       → INSERT stripe_webhook_events (PK = event id) — duplicate ⇒ 200, no-op
       → grant_credits(userId, credits, idempotency_key = event.id)
       → mark credit_purchases paid
Client → /credits?status=success — polls balance; UI never trusts the redirect
```

**Non-negotiables:**
1. **Credits are granted by the webhook, never by the success redirect.** The redirect is cosmetic and forgeable.
2. Signature verification against the **raw request body**.
3. Idempotency at two layers: `stripe_webhook_events` PK and `credit_ledger.idempotency_key`.
4. Handle `charge.refunded` / `charge.dispute.created` → deduct credits with reason **`chargeback`** (a **negative** delta; allow a negative balance; block spend, don't erase history). This is not the same event as a **`refund`**, which is a **positive** restoration granted when *we* got a deal wrong (§9.3). A Stripe reversal is a payment failure and a product refund is a quality failure — one ledger reason each, never one for both.
5. Prices and credit counts come from the database server-side. **Never** trust a price, currency or quantity from the client — currency in particular, since a client-chosen currency is a discount exploit.
6. Tax on the credit sale (VAT/GST on digital services, US sales tax) is handled by **Stripe Tax**, not by hand. Enable it before selling into a second country.

### 9.3 Consumption flow (unlock)

```
POST /deals/:id/unlock  (Idempotency-Key)
  → already unlocked? return full deal, charge nothing
  → BEGIN
      spend_credits(...)          -- row lock, raises INSUFFICIENT_CREDITS
      insert deal_unlocks
    COMMIT
  → return full deal
```
If a deal proves materially wrong (bad match, confirmed), refund the credit with `reason='refund'` — **a positive ledger delta restoring the credit**, one row per affected user. Publish the policy — a visible refund policy is a cheap, powerful trust signal. A Stripe-side reversal is the opposite direction and uses `reason='chargeback'` (§9.2 rule 4).

---

## 10. External Integrations

### 10.1 The `MarketplaceAdapter` interface — the central abstraction of v2.0

Every marketplace data provider implements one interface. Nothing above this layer knows the word "Keepa" or the word "ASIN".

```ts
interface MarketplaceAdapter {
  readonly key: string;                       // 'keepa'
  readonly supportedMarketplaces: string[];   // ['amazon_uk','amazon_de','amazon_us', …]
  capabilities(marketplaceId: string): MarketplaceCapabilities;

  lookupByGtin(gtin14: string, marketplaceId: string): Promise<CanonicalListing[]>;
  getListing(externalId: string, marketplaceId: string): Promise<CanonicalListing>;
  getDemandMetrics(externalId: string, marketplaceId: string): Promise<DemandMetrics>;
  getFeeInputs(listing: CanonicalListing): Promise<FeeInputs>;   // weight, dims, category
  quotaStatus(): Promise<{ remaining: number; resetAt: Date }>;
}
```

`CanonicalListing`, `DemandMetrics` and `FeeInputs` are **our** types, not the provider's. The adapter's mapper is the only code allowed to know a provider's payload shape, and the raw payload is preserved in `marketplace_products.provider_raw` for debugging.

An adapter registry resolves `marketplace_id → adapter` from `marketplaces.adapter_key`. Adding an Amazon locale is a row. Adding eBay is one new class.

### 10.2 Keepa — the only adapter in the MVP

- Server-side only, behind the interface above.
- **Covers all supported Amazon locales through one API key**, which is exactly why it is the right MVP choice for a global-first product: multi-country Amazon data without multi-country integration work.
- **Quota budgeting is an architectural concern.** Keepa bills in tokens; unbounded refresh loops exhaust quota by lunchtime. Enforce a per-run budget, a daily cap, and refusal-with-logging when exceeded. Log to `api_usage_log` **per marketplace**, so the cost of adding a market is visible before the invoice is.
- **Tiered refresh cadence**, applied per market:
  - Deals on the feed / watchlisted: every 6–12 h
  - Recently unlocked: every 12 h
  - Long tail: every 3–7 days
  - Never refresh anything nobody is looking at
- Cache in `marketplace_products`; always show `refreshed_at`.
- Respect Keepa's terms on storage and redistribution: derived metrics shown to the user who requested them, not bulk republication.
- **Verify locale coverage before committing to a launch market.** Provider coverage varies by Amazon locale and is a market-selection input, not an afterthought.

### 10.3 Amazon SP-API — deferred to Phase 3

Needed for real fee previews (`getMyFeesEstimate`), gating/restriction checks (`getListingsRestrictions`) and inventory sync. Under a global model it is *more* work than v1.0 assumed: per-region endpoints, per-region seller authorisation, per-marketplace rate limits. It arrives as a second `MarketplaceAdapter` implementation, with `feePreview: true` in its capabilities — which the scoring and pricing engines will pick up automatically because they are capability-driven.

### 10.4 Retailer data — the real risk, handled pragmatically

Ranked by risk/effort, and now **per country**:

1. **Affiliate product feeds** — *preferred*. Structured, legitimate, include GTINs, refresh daily, and add an affiliate revenue line. Networks differ by country (Awin, Rakuten, CJ, Impact, Sovrn, plus local networks); the `IngestionSource` interface makes that a configuration difference, not a code difference. Start with 3–5 retailers **in one country**.
2. **Official/public retailer APIs** where offered.
3. **Curated manual ingestion** — admin CSV upload + paste-a-URL parser. Unglamorous, and it is how you launch with 50 genuinely good deals next week instead of 5,000 mediocre ones in three months. **50 excellent verified deals beat 5,000 unverified ones**, and that ratio gets worse, not better, when you divide by four countries.
4. **Scraping** — last resort, per-retailer, robots.txt and ToS respected, isolated behind the same interface.

```ts
interface IngestionSource {
  readonly key: string;
  readonly marketId: string;
  fetch(cursor?: string): Promise<{ products: NormalisedProduct[]; nextCursor?: string }>;
}
```

`NormalisedProduct` carries GTIN-14, price + currency + tax treatment, and country. Everything downstream is indifferent to origin.

**Deal supply is the binding constraint on market expansion**, not engineering. Do not open a market you cannot supply.

### 10.5 Stripe

Checkout + webhooks only. Multi-currency Prices per pack. Stripe Tax for digital-services tax. Confirm supported countries and payout currencies before announcing a market. Test mode throughout; Stripe CLI to replay webhooks locally.

### 10.6 Supporting

- **Email:** Resend or Supabase built-in — verification and receipts only.
- **Errors:** Sentry free tier, with `marketId` as a tag so a market-specific failure is visible as one.
- **Analytics:** Vercel Analytics + `app_events` (market-tagged; funnel questions here are too specific for generic analytics).

---

## 11. Security Considerations

### 11.1 Secrets
- All secrets in Vercel env vars: `SUPABASE_SERVICE_ROLE_KEY`, `KEEPA_API_KEY`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `CRON_SECRET`.
- Only `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` are public.
- `import 'server-only'` in every module touching a secret.
- GitHub secret scanning + push protection on. A leaked service-role key is a total database compromise.

### 11.2 Database
- RLS on **every** table, default deny (§6.3).
- `SECURITY DEFINER` functions with `set search_path = public, pg_temp`.
- **`credit_ledger` is append-only, enforced twice:** a trigger rejecting UPDATE/DELETE, *and* the absence of the privilege — `service_role` holds `SELECT, INSERT` only. Either layer alone leaves AC10.5 true by accident (a revoke says nothing about a role that has the privilege; a trigger is one `DROP TRIGGER` from gone).
- **`stripe_webhook_events` is *restricted*, not immutable:** identity, `type`, `payload` and `received_at` are frozen by trigger; `processed_at` and `error` are writable, because the processing outcome is recorded after the event arrives. `DELETE` is revoked from `service_role`.
- No dynamic SQL built from user input.
- **Check constraints on money:** every table with a money column has a matching `currency` column and a constraint that it is non-null. A currency-free amount must be impossible at the storage layer, not merely discouraged. This applies to the financial tables without exception — `credit_purchases.amount_minor` and `credit_pack_prices.amount_minor` are `bigint` minor units with an FK-validated `currency`, positive by check constraint.

### 11.3 Application
- Zod-validate every input at the boundary. Never trust client-supplied prices, currencies, credit amounts, market ids, user ids or deal ids.
- Authorization checked per request, server-side.
- **Market scoping is an authorization concern, not a filter.** A deal id from another market must be rejected explicitly, not merely absent from a query.
- Rate limit auth, unlock, barcode and checkout endpoints.
- Deal redaction unit-tested: *"a locked deal's serialised payload must contain no retailer name, product title, image, URL or marketplace external id."* Automated test in CI, not a code-review habit.
- CSP, HSTS, `X-Content-Type-Options`, `Referrer-Policy` via `next.config` headers.
- Webhooks: signature-verified, raw body, replay-protected.
- Admin routes behind an explicit server-side role check *and* a separate layout.

### 11.4 Financial integrity
- Credits move only through the RPC. Scheduled reconciliation: `sum(credit_ledger.delta) == profiles.credit_balance` for every user; alert on mismatch.
- Reconcile `credit_purchases` against Stripe daily, **per currency** — a currency-blind total hides a per-currency bug.
- Log every credit movement with actor, reason and reference.
- **Financial records survive account deletion.** `credit_ledger.user_id` and `credit_purchases.user_id` are `ON DELETE RESTRICT`, so a deleted account cannot take its ledger or its purchase history with it. Reconciliation that could be emptied by a user closing their account is not reconciliation, and a chargeback can arrive months after the account is gone. Deletion is therefore pseudonymisation of the retained rows plus removal of everything else (§11.5, ADR-0010).

### 11.5 Privacy and compliance — now multi-jurisdiction
- **Baseline is GDPR-grade for everyone.** Building to the strictest regime and applying it globally is cheaper for one founder than maintaining per-region behaviour: privacy policy, data export, account deletion, lawful basis, minimal retention.
- **Account deletion is a cascade for personal data and a retention-plus-pseudonymisation for financial data** (ADR-0010). Profile, unlocks, watchlist, purchase records and barcode lookups cascade from `auth.users`. `credit_ledger` and `credit_purchases` do **not** — they are `ON DELETE RESTRICT` and are kept as audit and reconciliation evidence, which every privacy regime that matters here treats as a legitimate retention basis. The consequence is concrete: a plain `delete from auth.users` fails while ledger rows exist, so deletion must pseudonymise the retained rows. **The mechanism is an open T10 decision and is deliberately not fixed here** — it determines the FK shape, the reconciliation query and the strength of the privacy claim at once, and belongs to the task that implements and tests it.
- Add per-region notices as **content**, not code paths: CCPA/CPRA "do not sell" (nothing is sold), UK/EU cookie consent, and market-specific terms.
- **Data residency is not addressed in MVP.** Supabase runs in one region. If a market later requires local storage, that is a Phase 4 infrastructure decision with its own ADR — do not pretend it is solved.
- Minimal PII: email and preferences. No payment details — Stripe holds those.
- **Disclaimer wherever profit appears:** estimates, not guarantees; not financial or tax advice. Tax rules differ by country and change; the app models them approximately and says so. This is ethical and legal necessity for a product telling people what to buy.

---

## 12. Error Handling Strategy

### 12.1 Taxonomy

| Class | HTTP | Handling |
|---|---|---|
| Validation | 400 | Field-level messages, no retry |
| Auth | 401/403 | Redirect to sign-in / show forbidden |
| Not found | 404 | Friendly empty state |
| Business rule (`INSUFFICIENT_CREDITS`, `ALREADY_UNLOCKED`, `DEAL_EXPIRED`, `MARKET_NOT_LIVE`, `CURRENCY_MISMATCH`) | 409/422 | Actionable UI |
| Rate limit | 429 | Retry-After, calm message |
| Upstream (provider/Stripe down) | 502/503 | Serve cached data, label it stale, never fabricate |
| Internal | 500 | Generic message + request ID; detail to Sentry only |

### 12.2 Principles

1. **Typed errors, not thrown strings.** One `AppError` with a `code`; services throw, one handler translates.
2. **Fail closed on money.** Any ambiguity in a credit or payment operation → abort, do not charge, log loudly.
3. **Fail closed on currency.** A currency mismatch is never resolved by converting. It raises `CURRENCY_MISMATCH` and the deal is suppressed.
4. **Fail open on data freshness.** Provider down → show cached data with a clear staleness banner. Stale-but-labelled is trustworthy; missing is not.
5. **Never invent a number.** Missing weight → no fulfilment fee → no profit figure → deal suppressed or flagged. Missing capability → component dropped and disclosed, never defaulted.
6. **Retries:** exponential backoff with jitter for idempotent upstream reads; **never** blind-retry a credit spend.
7. **Partial failure in pipelines is normal.** A run records `rows_failed` and continues.
8. **Market isolation:** one market's pipeline failure must not fail another's run, and must be visible per market in logs and alerts.
9. **Request ID** on every response, surfaced in error UI.
10. **Error boundaries** per route segment — a broken score widget must not blank the feed.

---

## 13. Recommended Folder Structure

Single repo, single deployable.

```
/
├── .github/workflows/ci.yml         # typecheck, lint, test, build
├── src/
│   ├── app/
│   │   ├── (marketing)/             # landing, pricing, how-scoring-works
│   │   ├── (auth)/                  # sign-in, sign-up, callback
│   │   ├── (app)/                   # feed, deal/[id], scan, watchlist,
│   │   │                            # credits, settings, purchases
│   │   ├── admin/                   # markets, marketplaces, fee & tax schedules,
│   │   │                            # ingestion runs, match review
│   │   ├── api/
│   │   │   ├── v1/{markets,deals,credits,billing,watchlist,barcode,profile,purchases}/
│   │   │   └── cron/{ingest,refresh-listings,recompute-deals,reconcile}/
│   │   ├── layout.tsx  globals.css  error.tsx  not-found.tsx
│   │
│   ├── components/
│   │   ├── ui/                      # primitives (shadcn/ui)
│   │   ├── deals/                   # DealCard, DealDetail, ScoreBreakdown,
│   │   │                            # AssumptionsPanel, UnitRecommendation, RiskFlags
│   │   ├── market/                  # MarketSwitcher, CurrencyDisplay
│   │   ├── credits/  scan/  layout/
│   │
│   ├── services/                    # ★ business logic lives here, only here
│   │   ├── market/       { context.ts, resolve.ts, capabilities.ts }
│   │   ├── pricing/      { calculate.ts, fees.ts, surcharges.ts, types.ts, *.test.ts }
│   │   ├── tax/          { resolve.ts, regimes/{vat.ts,gst.ts,sales-tax.ts,none.ts}, *.test.ts }
│   │   ├── scoring/      { score.ts, weights.ts, penalties.ts, renormalise.ts, *.test.ts }
│   │   ├── matching/     { gtin.ts, fuzzy.ts, confidence.ts }
│   │   ├── ingestion/    { source.ts (interface), sources/{affiliate,csv,manual}.ts,
│   │   │                   normalise.ts, gtin-normalise.ts, run.ts }
│   │   ├── marketplace/  { adapter.ts (interface), registry.ts,
│   │   │                   providers/keepa/{client.ts,mapper.ts,capabilities.ts},
│   │   │                   refresh-policy.ts }
│   │   ├── credits/      { spend.ts, grant.ts, balance.ts }
│   │   ├── billing/      { checkout.ts, webhook.ts, packs.ts, pricing-table.ts }
│   │   ├── recommendation/ { units.ts }
│   │   └── redaction/    { redact-deal.ts, redact-deal.test.ts }
│   │
│   ├── lib/
│   │   ├── supabase/     { browser.ts, server.ts, admin.ts (server-only) }
│   │   ├── money/        { money.ts, currency.ts, format.ts, *.test.ts }
│   │   ├── errors.ts     # AppError, error codes
│   │   ├── validation/   # Zod schemas, shared client+server
│   │   ├── rate-limit.ts  logger.ts  config.ts  env.ts (Zod-validated env)
│   │
│   ├── messages/         # en.ts — every user-facing string, keyed
│   ├── types/            # domain types, generated Supabase types
│   └── middleware.ts     # session refresh + route protection
│
├── supabase/
│   ├── migrations/       # versioned SQL — the schema's source of truth
│   ├── functions/        # spend_credits.sql, grant_credits.sql
│   └── seed/             # countries, currencies, marketplaces, markets,
│                         # tax_schedules, fee_schedules, retailers, credit_packs
│
├── tests/ { unit/, integration/, fixtures/{gb,us,de}/ }
├── docs/  { ARCHITECTURE.md, PRODUCT_SPEC.md, TASKS.md,
│           DECISIONS.md (ADRs), RUNBOOK.md, SCORING.md, MARKET_PLAYBOOK.md }
└── scripts/
```

**Rules:**
- `app/` never contains business logic. `services/` never imports React.
- `lib/money` is the only place currency arithmetic exists; `messages/` the only place user-facing copy exists.
- **No country code, currency code, tax rate or marketplace name appears as a literal outside `supabase/seed/`, `services/tax/regimes/` and test fixtures.** This is greppable, and it should be grepped in code review.
- `MARKET_PLAYBOOK.md` documents the steps to open a new market — which should be a checklist of seed rows and supply work, not engineering.

---

## 14. MVP vs Future Features

### 14.1 MVP — in scope

| Feature | Scope boundary |
|---|---|
| Markets | **Architecture supports many; MVP operates one** (a second only when deal supply justifies it). Country/currency/tax/fees are seed data. |
| Marketplace | **Amazon only**, via the Keepa adapter, any supported locale. Adapter interface is MVP; second adapter is not. |
| Auth | Email + magic link. Profile with country, market, tax status, fulfilment, costs, budget, locale. |
| Deal feed | Precomputed, redacted, market-scoped. Filters: min ROI, min profit, min score, category, budget. |
| Retailer data | 3–5 retailers in the launch market via affiliate feeds + admin CSV/manual curation. |
| Product matching | GTIN-14 exact. Low-confidence matches suppressed, not shown. |
| Profit calculation | Itemised breakdown, regime-driven tax (VAT/GST/sales tax/none), conservative defaults, user-editable assumptions. |
| ROI + margin | On cash deployed, integers, explained, currency-explicit. |
| Deal Score | Weighted components, capability-aware renormalisation, penalties, visible breakdown, versioned. |
| Credit unlock | Signup grant, packs priced per currency via Stripe Checkout, atomic spend, permanent unlock. |
| Watchlist | Add/remove/list. |
| Barcode lookup | `BarcodeDetector` + manual entry → GTIN-14 → adapter → profit estimate. Charged on success. |
| Budget recommendation | Suggested units with the binding constraint stated. |
| **"I bought this" + outcome** | **The instrument that answers the MVP question. Non-negotiable.** |
| Admin | Markets, marketplaces, fee/tax schedules, ingestion runs, match review, credit adjust. |

### 14.2 Explicitly NOT in MVP

Additional marketplace integrations (eBay, Walmart, etc.) · **cross-border / cross-currency deals** · **runtime translation and localised marketing sites** · **multi-market operation at launch** · data residency · push notifications · price alerts · SP-API / seller-account integration · inventory & portfolio P&L · local/in-store deals · AI sourcing assistant · 3PL shipment workflow · subscriptions · teams · referrals · CSV bulk export · native apps · real-time updates · Python services.

### 14.3 Future roadmap (order of expected value)

**Phase 2 — retention and depth in one market:** watchlist price alerts + push; deal-quality feedback loop; score v2 calibrated on `purchase_records`; expanded retailer coverage; automated feed ingestion at scale.

**Phase 3 — breadth:** open market #2 and #3 (seed rows + supply, per `MARKET_PLAYBOOK.md`); SP-API adapter for real fee previews and gating checks; translation of the message catalogue; cross-border sourcing with a proper landed-cost model (§7.7).

**Phase 4 — intelligence:** the Python service finally earns its place — fuzzy/vector matching across languages (a real multi-country problem), demand forecasting, an AI sourcing assistant grounded in your structured data. Non-Amazon marketplace adapters. Local/in-store deals.

**Phase 5 — operations:** 3PL/FBA shipment workflow, bulk sourcing, team accounts, data residency if required.

### 14.4 The MVP success metric

> Of users who unlock at least one deal, what percentage record a purchase — and of those purchases, what percentage hit at least 70% of predicted profit?

Measured **per market**, never pooled. Pooling hides the thing you most need to know: whether your tax and fee model is right in each country you claim to serve.

---

## 15. Recommended Development Order

Each step is independently shippable and testable. Do not start the next until the current is verified. Changes from v1.0 are marked **[v2]**.

| # | Step | Deliverable | Verification |
|---|---|---|---|
| 1 | **Foundation** | Next.js + TS + Tailwind, repo, CI, Vercel deploy, Zod-validated env | Green build deployed |
| 2 | **Schema + RLS** | All migrations, RLS policies, generated types | Anon key can read *nothing* it shouldn't — test explicitly |
| 3 | **[v2] Reference data + `MarketContext`** | `countries`, `currencies`, `marketplaces`, `markets`, `tax_schedules`, `fee_schedules` seeded; market resolver service | Seeding a **second** market requires zero code change — prove it by seeding two and switching |
| 4 | **Auth** | Sign-up/in, session middleware, profile + onboarding (country, market, tax status, budget, costs) | Protected route redirects when logged out; user in an unsupported country is waitlisted, not shown an empty feed |
| 5 | **[v2] Money + currency** | `lib/money` with explicit currency, exponent-aware, locale formatting | Tests in GBP, USD and a 0-exponent currency; mixed-currency addition throws |
| 6 | **[v2] Tax engine** | `services/tax` regime strategies driven by `tax_schedules` | Hand-worked cases per regime: registered and not, inclusive and exclusive pricing |
| 7 | **Pricing engine** | Pure `calculate.ts` consuming fee schedule + tax result, itemised surcharges | Unit tests vs hand-worked examples in ≥2 markets; country-blindness verified by grep |
| 8 | **[v2] Scoring engine** | Pure scoring with capability-aware renormalisation, per-market thresholds | Table-driven tests, including a synthetic low-capability marketplace |
| 9 | **[v2] Marketplace adapter + Keepa provider** | Interface, registry, Keepa client, mappers, quota budgeting, `api_usage_log` | Fixture tests + one live call per locale; nothing above the adapter mentions Keepa or ASIN |
| 10 | **[v2] Ingestion + GTIN matching** | Admin CSV upload → normalise (GTIN-14, tax treatment) → match → enrich → compute → `deals` | 20 real products end-to-end produce believable deals; a UPC-12 and an EAN-13 for the same product match identically |
| 11 | **Deal feed + detail (redacted)** | Server-rendered, market-scoped feed, filters, locked cards, redaction service | Automated test: locked payload leaks nothing; cross-market deal id is rejected |
| 12 | **Credits (no payment)** | Ledger, `spend_credits` RPC, signup grant, unlock flow | Concurrency test: 10 parallel unlocks at balance 1 → exactly one succeeds |
| 13 | **[v2] Stripe multi-currency** | Packs, per-currency prices, Checkout, webhook, idempotency, Stripe Tax, reconciliation | Stripe CLI replay: duplicate events grant credits once; per-currency reconciliation passes |
| 14 | **Watchlist + recommendation + assumptions panel** | Complete the core loop | Manual flow test on a phone |
| 15 | **Barcode lookup** | Scanner + manual fallback + GTIN normalisation + credit charge on success | Real UPC and EAN barcodes on a real phone |
| 16 | **Purchase tracking** | "I bought this" + outcome follow-up | Rows land; admin can compare predicted vs actual per market |
| 17 | **Automated ingestion** | First affiliate feed behind `IngestionSource`, cron, tiered refresh, market-scoped | Nightly run populates deals unattended without stalling other markets |
| 18 | **Hardening + launch** | Rate limits, Sentry, security headers, PWA manifest, legal pages, `MARKET_PLAYBOOK.md`, runbook | Security checklist signed off |

**Deliberate ordering choices:** reference data and `MarketContext` come *third*, before anything that computes — retrofitting a market abstraction after the pricing engine exists is exactly the rewrite this document is meant to prevent. Money and tax precede pricing because pricing depends on both. Adapters come before ingestion because matching needs them. Credits are proven before Stripe touches them. Automated ingestion stays near the end: manual curation is enough to validate the hypothesis, and if the hypothesis fails you will not have spent a month on feeds.

---

## 16. Major Technical Risks and Mitigations

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| 1 | **Product mismatch** — right price, wrong listing | Catastrophic. One bad match and the user loses money and never returns. | GTIN-14 exact only in MVP; confidence threshold below which nothing publishes; confidence shown in UI; "report this deal" with credit refund; admin review queue; multipack/variation detection on the roadmap. |
| 2 | **[v2] Tax model wrong in a given country** | Every profit figure in that market is systematically wrong; trust gone market-wide. | Tax schedules versioned in data with `verified_at` and a source URL; regime strategies unit-tested per regime; `tax treatment uncertain` flag and score penalty rather than a guess; **verify against real invoices from a local user before opening a market**; never launch a market on an unverified schedule. |
| 3 | **[v2] Fee schedule drift per marketplace** | Predicted profit becomes fiction as fees change. | Per-marketplace versioned schedules with `verified_at`; admin review reminder; conservative defaults; user-editable assumptions; SP-API fee preview in Phase 3 (capability-driven, no engine change). |
| 4 | **[v2] Currency and rounding errors** | Silent, systematic, and invisible until a user reconciles. | `Money` type with explicit currency; mixed-currency arithmetic throws; exponent from data; DB constraints requiring a currency alongside every amount; no FX in MVP at all. |
| 5 | **Retailer data acquisition** — feeds vary by country, scraping is fragile and ToS-hostile | Blocks the pipeline; blocks market expansion. | Affiliate feeds first; curation as a legitimate launch path; `IngestionSource` abstraction; **deal supply gates market opening**, engineering does not. |
| 6 | **Provider cost / rate limits** | Runaway cost or a dead feed. | Hard token budget per run + daily cap; tiered refresh; caching; `api_usage_log` **per marketplace** so a new market's cost is visible immediately; credit pricing above blended data cost. |
| 7 | **[v2] Market sprawl** — opening markets faster than supply or verification | Thin feeds, wrong tax, no trust anywhere, founder spread across four sets of problems. | One live market at MVP; `MARKET_PLAYBOOK.md` gate list (verified tax schedule, verified fee schedule, ≥N curated deals, Stripe support, provider coverage) — **all boxes ticked or the market stays `planned`**. |
| 8 | **[v2] Marketplace capability gaps** (future adapters) | Scores silently degrade into fiction. | Capability flags drive component availability; weights renormalise visibly; missing data is disclosed, never defaulted; confidence component absorbs the loss. |
| 9 | **Credit race conditions / double-spend** | Direct revenue loss, corrupted ledger. | Atomic `SECURITY DEFINER` RPC with row lock; idempotency keys; append-only ledger; nightly reconciliation per currency; explicit concurrency tests. |
| 10 | **Locked-deal data leakage** | The paid product given away free. | Server-side redaction only; deals table unreadable by the anon key; automated payload-leak test in CI. |
| 11 | **Marketplace gating / IP restrictions** | User buys stock they cannot legally sell — and rules differ by country. | Prominent "check your own eligibility" warning; per-market brand risk list; suppress known problem brands; SP-API restrictions check in Phase 3. |
| 12 | **Scope creep (single founder)** — now with a global surface to creep into | The project never ships. | This document as the contract; one task at a time; ADRs in `docs/DECISIONS.md`; **"global-first" is never a licence to build market #2 before market #1 works.** |
| 13 | **AI-assisted code drifting from architecture** | Structural rot; duplicated money logic; a hardcoded `'GB'` appearing in a service. | Every task prompt references this document; strict folder rules; greppable literal ban (§13); PR checklist covering RLS, redaction, currency handling, market scoping and tests. |
| 14 | **Vercel serverless limits during ingestion** | Half-finished pipeline runs, worse with more markets. | Batch + cursor + resumable, market-scoped runs; time-boxed cron; dedicated worker only when batch size genuinely demands it. |
| 15 | **Users don't trust the numbers** (the core hypothesis failing) | The product has no market. | Radical transparency: itemised breakdowns, visible score maths, disclosed unavailable components, staleness labels, conservative defaults, refund policy, prediction-vs-actual published back to users. |
| 16 | **Legal/regulatory across jurisdictions** — appearing to give investment or tax advice | Liability, multiplied by countries. | GDPR-grade baseline everywhere; clear disclaimers; "estimate" and "opportunity", never "guaranteed return"; explicit "not tax advice"; per-market terms reviewed before that market goes live. |

---

## 17. Architectural Decision Summary

| Decision | Choice | Rationale |
|---|---|---|
| Geography model | Country/currency/tax/marketplace as seed data | New market = rows, not a migration |
| Launch strategy | Global architecture, **single-market launch** | Curation does not scale across countries; thin feeds kill trust |
| Marketplace model | `MarketplaceAdapter` interface + registry | Amazon today, others later, with no engine change |
| Marketplace scope (MVP) | **Amazon only**, via Keepa | One key covers every Amazon locale — the cheapest global data path |
| Runtime | Single Next.js app on Vercel | One language, one deploy, one founder |
| Python | Deferred to Phase 4 | Nothing in the MVP needs it |
| SP-API | Deferred to Phase 3 | Per-region auth and endpoints; arrives as a second adapter |
| Database | Supabase Postgres, RLS default-deny | Auth + DB + cron in one free tier |
| Deals table access | Service-role only, server-side redaction | Column-level RLS is too fragile to guard the paid product |
| Money | `bigint` minor units + explicit currency, exponent from data | Eliminates float error and currency ambiguity by construction |
| FX | **None in MVP**; deals are single-currency | A silent FX error looks exactly like a great deal |
| Tax | Regime strategies from `tax_schedules` | VAT, GST and sales tax differ structurally, not just numerically |
| Fees | Per-marketplace versioned schedules with a generic surcharge list | New levies are row edits |
| Identifiers | Canonical GTIN-14 + original form | UPC-12 and EAN-13 are the same product |
| Scoring | Transparent, weighted, capability-aware, versioned, per-market thresholds | Trust is the hypothesis; missing data is disclosed, never defaulted |
| Deal computation | Precomputed + versioned + snapshotted, market-scoped | Reproducible, auditable, fast to read |
| Personalisation | In-request overlay, not per-user precompute | Avoids N×M explosion |
| Credits | Prepaid packs, currency-neutral unit, per-currency pack prices | Decouples value from currency; global pricing becomes a table |
| Payments | Stripe Checkout, multi-currency Prices, Stripe Tax, webhook-granted credits | Minimal PCI surface, no forgeable client trust, no hand-rolled tax |
| Credit reversals | `refund` (positive, our error) and `chargeback` (negative, Stripe reversal) are separate ledger reasons | Product-quality events and payment events are reconciled against different sources |
| Ledger immutability | Append-only trigger **and** `UPDATE`/`DELETE` revoked from `service_role` | Two independent layers; neither is sufficient alone |
| Financial retention | `credit_ledger` and `credit_purchases` are `ON DELETE RESTRICT` and survive account deletion | Reconciliation that a user can empty is not reconciliation; deletion becomes pseudonymisation (T10) |
| i18n | Message catalogue now, translation later | Near-zero cost now; every component later |
| Compliance | GDPR-grade baseline globally | Cheaper for one founder than per-region behaviour |
| State management | Server Components, no client store | Nothing to synchronise yet |

---

*End of document. Update `docs/DECISIONS.md` with an ADR whenever any decision above changes — and change none of them silently. `PRODUCT_SPEC.md` and `TASKS.md` must be reconciled to v2.0 before the next task begins.*
