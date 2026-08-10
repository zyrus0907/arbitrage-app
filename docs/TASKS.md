# TASKS.md

**Project:** Global Retail-to-Marketplace Arbitrage App
**Document owner:** Technical Project Manager
**Version:** 2.2 — global-first, marketplace-agnostic, Amazon-first MVP
**Source documents:** `ARCHITECTURE.md` v2.0 (technical contract) · `PRODUCT_SPEC.md` v2.0 (scope contract)
**Status:** In execution. **T01–T04 complete.** Next task: T05.

> **Execution scope:** Build a global-first core, but operate exactly one launch market during MVP. Amazon is the only marketplace integration in MVP. Country, currency, tax regime and marketplace must be data/configuration concepts, not hard-coded application assumptions.

---

## Changelog: v1.0 → v2.0

- Reconciled all tasks with `ARCHITECTURE.md` v2.0 and `PRODUCT_SPEC.md` v2.0.
- Replaced UK/GBP/VAT hard-coding with market, currency and tax-regime configuration.
- Replaced Amazon-specific core tables/types with marketplace-generic models; Amazon/Keepa remains the only MVP adapter.
- Replaced EAN→ASIN core matching with canonical GTIN-14 → marketplace listing matching.
- Added `MarketContext`, marketplace capabilities, market-scoped APIs/pipelines, multi-currency credit pricing and cross-market isolation tests.
- Preserved single-market launch, Amazon-only MVP integration and the original phased delivery discipline.

## Changelog: v2.0 → v2.1

Planning corrections arising from the T03 post-completion review. **No product scope changed. No priority changed. No task was removed.**

- Marked T01–T03 complete with outcome notes.
- Corrected two corrupted acceptance criteria in T03 that instructed deletion of the table T03 was built to create.
- Recorded the T03 privilege posture (ADR-004) and propagated its consequences into T04, T05, T06, T07 and T08.
- **Added T05A** — temporal exclusion constraints on `tax_schedules` and `fee_schedules`. Blocks T08.
- Added cross-market consistency enforcement to T04 and replaced an incoherent T04 test criterion.
- Enumerated the previously under-specified `deals` and `watchlist_items` columns in T04.
- Rewrote T09's assertions so a missing SQL grant can no longer produce a false pass.
- Deferred `fx_rates` to Phase 3 (ADR-005); stated as out of scope in T08.
- Added global rule 8 (privilege posture on every migration).

## Changelog: v2.1 → v2.2

A **product decision** taken during T04, when the schema work surfaced that `ARCHITECTURE.md`'s `deal_status` (`active | stale | retired`) had no unpublished state, while T19 and AC3.3 both require one. Recorded as ADR-0009. **No product scope changed. No priority changed. No task was removed.**

- `deal_status` becomes **`draft | active | retired`**, defaulting to `draft`. `stale` is removed: staleness is derived from `deals.expires_at` and `marketplace_products.refreshed_at`, never stored.
- **Retired is terminal.** The legal transitions are enforced in the database by a trigger; T04 owns the transition rules, not who may request one.
- Added publish/retire audit columns to `deals`.
- The deal-pair unique index predicate becomes `status <> 'retired'` — one *live* deal per pair, and a retired deal never blocks its replacement.
- **Added T20A** — admin deal lifecycle API (publish/retire). Depends on T19 and T20, blocks T33.
- Propagated into T19 (drafts only, never publishes, auto-retires on suppression, skips rejected matches), T22 and T29 (feed predicate is exactly `status = 'active'`), T24 (a confirmed bad match marks `product_matches` rejected), T27 (the pipeline test proves zero active deals without an admin publish) and T33 (publish/retire call T20A).
- Added AC3.7–AC3.10 and AC15.6 to `PRODUCT_SPEC.md`.

---

## 0. How to use this document

46 tasks: **T01–T40 (including T05A and T20A) are P0** (beta cannot start without them), **T41–T44 are P1** (ship during beta only if the P0 loop is stable). P2 items from `PRODUCT_SPEC.md` §5.3 appear nowhere in this plan by design.

**Rules of engagement for every task:**

1. **One task per session.** Do not start the next until the current one's acceptance criteria are verified.
2. **Every task prompt to a coding agent must reference `ARCHITECTURE.md` and `PRODUCT_SPEC.md`.** Architecture drift is risk #9.
3. **Do not rewrite working code** unless the task explicitly requires it. Preserve existing interfaces.
4. **Do not change architecture silently.** Any deviation gets an ADR in `docs/DECISIONS.md` before merge.
5. **All money is integer minor units with an explicit ISO 4217 currency; all rates are basis points.** `src/lib/money/` is the only place currency arithmetic exists. Currency exponent is data, never an assumed ×100.
6. **Every task ships with tests and testing instructions.** No exceptions for "obvious" tasks.
7. **State assumptions explicitly** in the PR description.
8. **Every migration that creates a table, function, view or sequence must state its privilege posture explicitly** — which of `anon`, `authenticated` and `service_role` receive which privileges, and why. Silence is not a posture. Default-deny is the baseline established in T03 (ADR-004): new objects receive **no** `anon` or `authenticated` privileges unless a later task grants them deliberately, and any privilege Supabase or Postgres grants by default is revoked in the same migration. RLS being enabled is not a substitute — RLS filters rows *within* granted privileges, so a policy without a matching grant is inert, and a grant without a matching policy is a leak.

**Agent roles:** Backend Engineer · Frontend Engineer · Database Engineer · Integration Engineer · Code Reviewer / Security Reviewer · QA Engineer

**Traceability:** `AC*` references are acceptance criteria in `PRODUCT_SPEC.md` §7. `§` references without a document name refer to `ARCHITECTURE.md`.

---

# PHASE 1 — FOUNDATION (T01–T11, including T05A)

---

## ✅ T01 — Repository, tooling, CI and first deploy

> **Status: COMPLETE.**

- **Goal:** A running, deployed, type-safe Next.js skeleton with validated environment variables and a green CI pipeline. Nothing else.
- **Agent:** Backend Engineer
- **Dependencies:** None
- **Files / areas:** `package.json`, `tsconfig.json`, `next.config.ts`, `tailwind.config.ts`, `.github/workflows/ci.yml`, `src/app/layout.tsx`, `src/app/page.tsx`, `src/lib/env.ts`, `.env.example`, `docs/DECISIONS.md`
- **Acceptance criteria:**
  - Next.js (App Router) + TypeScript strict mode + Tailwind, single repo, single deployable per §13.
  - Folder skeleton created exactly as §13: `app/`, `components/`, `services/`, `lib/`, `types/`, `supabase/`, `tests/`, `docs/`, `scripts/`. Empty directories carry a `README.md` stating their rule (e.g. "`services/` never imports React").
  - `src/lib/env.ts` parses all environment variables through a Zod schema and **throws at boot** on a missing or malformed variable. Public variables are separated from server variables in the schema.
  - `.env.example` lists every variable name with a comment, and **no values**.
  - CI runs typecheck, lint, test and build on every push and PR, and blocks merge on failure.
  - Deployed to Vercel; preview deploys work on PRs.
  - GitHub secret scanning and push protection enabled.
- **Testing requirements:** One smoke test asserting the home route renders. One unit test asserting `env.ts` throws when a required variable is absent. Verification: push a branch, confirm CI green and a preview URL loads.
- **Priority:** P0
- **Completion note:** Next.js + TypeScript repo foundation in place. CI green on GitHub. Vercel deployment working.

---

## ✅ T02 — Supabase project, migrations harness and typed clients

> **Status: COMPLETE.**

- **Goal:** Three correctly scoped Supabase clients and a working local-to-remote migration workflow. No tables yet.
- **Agent:** Database Engineer
- **Dependencies:** T01
- **Files / areas:** `supabase/config.toml`, `supabase/migrations/`, `src/lib/supabase/{browser,server,admin}.ts`, `src/types/database.ts`, `package.json` scripts
- **Acceptance criteria:**
  - Supabase project created (dev). Migration workflow documented in `docs/RUNBOOK.md`: how to create, apply and roll back a migration.
  - Three clients per §6.2: `createBrowserClient` (anon), `createServerClient` (anon + session, `@supabase/ssr`, httpOnly cookies), `createAdminClient` (service role).
  - `src/lib/supabase/admin.ts` has `import 'server-only'` as its **first line**.
  - `npm run db:types` generates `src/types/database.ts`; generated types are committed.
  - No Supabase key other than `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` is referenced anywhere reachable from client code.
- **Testing requirements:** A build-time test that importing `admin.ts` from a `'use client'` module fails the build. Manual: apply an empty migration end to end.
- **Priority:** P0
- **Completion note:** Supabase dev project created and linked. Local Supabase tooling configured. Browser/server/admin clients added. Generated database types working. Migration workflow documented in `docs/RUNBOOK.md`.

---

## ✅ T03 — Schema A: global reference data, identity and catalogue

> **Status: COMPLETE.**

- **Goal:** Create the global configuration layer and core catalogue without hard-coding a country, currency or marketplace.
- **Agent:** Database Engineer
- **Dependencies:** T02
- **Files / areas:** `supabase/migrations/*_schema_a.sql`, `src/types/database.ts`, `supabase/seed/`
- **Acceptance criteria:**
  - Create reference tables per ARCHITECTURE.md v2.0: `countries`, `currencies`, `marketplaces`, `markets`, `tax_schedules`, `fee_schedules`.
  - Create identity/catalogue tables: `profiles`, `retailers`, `retailer_products`, `marketplace_products`, `product_matches`.
  - `profiles` contains `country_code`, `default_market_id`, `locale`, `timezone`, `tax_registered`, `tax_registration_country`, `tax_scheme`, `default_fulfilment`, default cost assumptions and `assumption_currency`.
  - `retailer_products` stores canonical `gtin14` plus `gtin_raw` and `gtin_format`; there are no GTIN-only or UPC-only primary matching columns.
  - `marketplace_products` uses `(marketplace_id, external_id)` as the marketplace identity. **ASIN is not a schema-level concept** — it is one possible value of `external_id`, and the string "asin" appears only inside adapter code and `provider_raw`.
  - All monetary columns are `bigint` minor units and every monetary record carries an explicit `currency` code.
  - `currencies.minor_unit_exponent` supports 0-, 2- and 3-decimal currencies.
  - `markets` connects source country, marketplace and currency and has `launch_status`.
  - `profiles.id` FKs `auth.users.id` with cascade delete; a trigger creates a profile on signup.
  - Unique constraints and indexes follow ARCHITECTURE.md §2, including `(retailer_id, retailer_sku)`, GIN on marketplace-product GTINs, `retailer_products.gtin14`, and refreshed timestamps.
  - RLS enabled on every table with no policies yet.
  - **No table named `amazon_products` exists.** The v1.0 Amazon-specific table is replaced by `marketplace_products`; no marketplace-specific table may be created in its place.
  - **Privilege posture (added v2.1, see ADR-004):** `anon` and `authenticated` receive no table privileges. `service_role` receives table DML only. Functions are owner-only by default. Any Postgres or Supabase default grant is revoked in the same migration.
- **Testing requirements:** SQL tests for key unique constraints and cascade deletion. Seed at least GBP, USD and JPY currency rows and prove the schema accepts each. Test that a UPC-12 and EAN-13 form can normalise to the same canonical GTIN-14 fixture at the application-test layer.
- **Priority:** P0
- **Completion note:** 11 core tables and 9 enum types created. RLS enabled on all 11 tables with zero policies. Local and remote privilege state normalised — `anon`/`authenticated` hold no table privileges, `service_role` holds table DML only, functions are owner-only. Database tests pass; local and remote migration history match.
- **Decisions recorded:** ADR-004 (database privilege posture). **Two downstream consequences, now written into the tasks themselves:** T06 must issue explicit `GRANT SELECT` alongside every public-read RLS policy, and T07 must issue explicit `GRANT EXECUTE … TO service_role` for the credit RPCs. Neither is optional; without them the policies and functions are unreachable.
- **Known gaps found during T03, now owned elsewhere:** `fx_rates` is deferred to Phase 3 (ADR-005, stated in T08); `tax_schedules` and `fee_schedules` temporal overlap is owned by the new **T05A**.

---

## ✅ T04 — Schema B: deals, user activity and market scoping

> **Status: COMPLETE.**

- **Goal:** Create the market-scoped deal read model and user activity tables.
- **Agent:** Database Engineer
- **Dependencies:** T03
- **Files / areas:** `supabase/migrations/*_schema_b.sql`, `src/types/database.ts`
- **Acceptance criteria:**

  **`deals` — full column set per ARCHITECTURE.md §2.3.** Enumerated here because "matches §2.3" has previously been read loosely; a missing column here is not discovered until T19:
  - Identity and scope: `id`, `market_id` FK, `retailer_product_id` FK, `marketplace_product_id` FK, `match_confidence` (numeric, copied from `product_matches` for fast filtering), `currency` FK
  - Costs: `buy_price_minor`, `buy_price_tax_treatment`, `buy_tax_reclaim_minor`, `inbound_shipping_minor`, `prep_cost_minor`
  - Revenue: `sell_price_minor`, `sell_tax_liability_minor`
  - Fees: `referral_fee_minor`, `fulfilment_fee_minor`, `storage_fee_minor`, `other_fees_minor`, `surcharges jsonb`, `fee_schedule_id` FK, `tax_schedule_id` FK
  - Outputs: `net_profit_minor`, `roi_bps` int, `margin_bps` int, `deal_score` int, `demand_band`, `competition_band`, `stability_band`, `confidence_band`, `score_breakdown jsonb`
  - Provenance: `calc_version`, `score_version`, `inputs_snapshot jsonb`, `computed_at`, `expires_at`, `status`
  - Lifecycle audit (added v2.2, ADR-0009): `published_at`, `published_by`, `retired_at`, `retired_by`, `retire_reason`
  - `deals` references `retailer_product_id` and `marketplace_product_id`, never a marketplace external ID directly.
  - One **live** deal per `(retailer_product_id, marketplace_product_id)` via partial unique index on **`status <> 'retired'`**. Draft and active are both "the current answer for this pair", so only one may exist across the two; retired rows drop out of the index so history is kept and a fresh draft can always replace a retired deal.
  - Market leads feed indexes: `(market_id, status, deal_score desc)`, `(market_id, status, roi_bps desc)`, `(market_id, status, computed_at desc)`.
  - Check constraints: `deal_score` between 0 and 100; `roi_bps` and `margin_bps` are integers; no money-bearing row without a currency; the audit columns cannot disagree with the state they describe (an `active` deal has a `published_at`; `retired_at` is present exactly when `status = 'retired'`; a `retire_reason` requires retirement).

  **Deal lifecycle — new in v2.2 (ADR-0009, product decision taken during T04).** `deal_status` is **`draft | active | retired`**. There is no `stale`.
  - `deals.status` is `NOT NULL DEFAULT 'draft'`, so a writer that omits it fails closed into an unpublished state.
  - Allowed: INSERT → `draft` only · `draft → draft` · `draft → active` · `draft → retired` · `active → active` · `active → retired`. A retired row may still have its other columns corrected, but its state never changes again.
  - Rejected: `active → draft` · `retired → active` · `retired → draft`. **Retired is terminal.**
  - Enforced by a `BEFORE INSERT OR UPDATE ... FOR EACH ROW` trigger, because a transition rule compares OLD to NEW and PostgreSQL has no declarative form for that. This is the one place a trigger is correct; the cross-market rules below stay declarative.
  - Because an INSERT must be `draft`, **publication is always a later UPDATE** — no ingestion or recompute path can produce a user-visible deal (AC3.3, AC3.7).
  - The trigger stamps `published_at`/`retired_at` when a caller leaves them absent, and never touches `published_by`/`retired_by`. **T04 enforces valid transitions only. It does not enforce actor authorization** — who may publish or retire is T20A's and T33's.
  - `published_by`/`retired_by` reference `auth.users` with `ON DELETE SET NULL`: deleting an account must neither delete the fact that a deal was published nor block the deletion AC1.5 requires.
  - **Staleness is not a status.** It is derived at read time from `deals.expires_at` and `marketplace_products.refreshed_at`. No `stale` enum value, no equivalent boolean, no stored freshness column.

  **Cross-market consistency — new in v2.1 (ADR-007).** A `deals` row must not be able to reference a retailer product and a marketplace product that do not both belong to its market. This is enforced **in the database**, not by pipeline convention:
  - `deals.market_id` must equal the market of `retailer_product_id`'s retailer.
  - `deals.marketplace_product_id`'s `marketplace_id` must equal the `marketplace_id` of `deals.market_id`.
  - Implement by whichever of the two available mechanisms the engineer judges cleaner, and record the choice in the PR: (a) denormalise the parent keys onto `deals` and enforce with composite foreign keys, or (b) a `CONSTRAINT TRIGGER` on insert and update. Prefer (a) — declarative constraints cannot be bypassed by a `COPY` or a service-role bulk upsert, and the ingestion pipeline in T19 does bulk upserts.
  - Whichever is chosen, the violation must fail the write. A cross-market deal that merely fails to appear in a feed is not acceptable: it is a user in one country seeing another country's price.

  **Other tables:**
  - `deal_unlocks`: `id`, `user_id`, `deal_id`, `credits_spent`, `unlocked_at`; unique `(user_id, deal_id)`.
  - `watchlist_items` — full column set per §2.3: `id`, `user_id`, `deal_id`, `marketplace_product_id`, `target_profit_minor`, `currency`, `note`, `created_at`; unique `(user_id, deal_id)`.
  - `purchase_records`: `id`, `user_id`, `deal_id`, `market_id`, `units`, `actual_buy_price_minor`, `currency`, `expected_profit_minor` (frozen snapshot), `purchased_at`, `outcome`, `actual_sale_price_minor`, `actual_profit_minor`, `notes`, plus a frozen inputs snapshot.
  - `barcode_lookups`: `id`, `user_id`, `market_id`, `barcode_raw`, `gtin14`, `resolved_marketplace_product_id`, `credits_spent`, `result jsonb`, `created_at`.

  **Enum discipline — new in v2.1:**
  - T03 created 9 enum types. **Inventory the existing types before creating any new one** and reuse where the domain matches. In particular, the four band columns share one domain (`low|medium|high`) and must use **one** shared enum type reused four times, not four near-identical types.
  - Any genuinely new type is listed in the PR description with a one-line justification for why an existing type would not serve.
  - The retail price basis (`buy_price_tax_treatment`) reuses T03's `price_tax_treatment`; it is not a new type.

  **Privilege posture — new in v2.1 (ADR-004, global rule 8):**
  - RLS enabled on every new table, **no policies yet** — policies and grants both land in T06.
  - **No privileges granted to `anon` or `authenticated`** by this migration. `service_role` receives table DML only.
  - Any default grant applied by Postgres or Supabase to new tables **and their sequences** is revoked in the same migration.
  - The migration states its privilege posture in a header comment.

  **Types:**
  - After the migration is applied remotely, regenerate `src/types/database.ts` via `npm run db:types` and commit it. Local-only generation does not satisfy this.

- **Testing requirements:** SQL tests for: the live-pair partial unique index; the 0–100 score constraint at both boundaries and outside them; currency-required constraints; enum reuse verified by inspecting `pg_type` for near-duplicates.

  **Cross-market rejection tests — replaces the previous two-markets test, which was incoherent** (if the marketplace differs then `marketplace_product_id` differs, so the pair is not the same pair; and a retailer product cannot belong to two markets because its retailer has exactly one `market_id`). Using two seeded markets in fixtures:
  - Inserting a deal whose `market_id` differs from the market of its retailer product's retailer is **rejected**.
  - Inserting a deal whose marketplace product belongs to a marketplace other than the one its `market_id` resolves to is **rejected**.
  - A correctly-scoped deal in each of the two markets is **accepted**, and the two coexist without interference.
  - Updating a valid deal's `market_id` to the other market is **rejected** (not just insert-time enforcement).
  - The rejection must occur on a bulk/`COPY`-style write as well as a single-row insert.

  **Lifecycle tests — new in v2.2 (ADR-0009):**
  - An insert that omits `status` lands as `draft`.
  - `draft → active`, `draft → retired`, `active → active` and `active → retired` all succeed.
  - `active → draft`, `retired → active` and `retired → draft` are all **rejected**.
  - Two non-retired deals for the same product pair are **rejected**; one retired deal plus one new draft for that pair is **accepted**.
  - `deal_status` carries no `stale` value, and no Schema B column stores staleness or freshness.
  - `published_at`/`retired_at` are stamped on transition; a supplied `published_by`/`retired_by` is stored as given; deleting the actor's account nulls the reference and keeps the timestamp.
  - Bulk and upsert paths bypass neither the lifecycle nor the live-pair uniqueness: a multi-row insert or `INSERT … SELECT` containing a non-draft row is rejected, and an upsert's `DO UPDATE` branch cannot resurrect a retired deal.
  - The existing cross-market, RLS and privilege assertions still pass unchanged.
- **Priority:** P0
- **Completion note:** Schema B (`20260810125436_schema_b.sql`) applied locally from a clean `db:reset` and pushed to the linked development project; local and remote migration history match. Five tables added — `deals`, `deal_unlocks`, `watchlist_items`, `purchase_records`, `barcode_lookups` — bringing `public` to 16. Three new enum types (`component_band` shared by all four band columns, `deal_status`, `purchase_outcome`); `price_tax_treatment` reused for the retail price basis. The deal lifecycle is **`draft | active | retired`**, defaulting to `draft`, with retirement terminal and transitions enforced by a `BEFORE INSERT OR UPDATE` trigger; staleness is derived from `expires_at` and `marketplace_products.refreshed_at`, never stored. Cross-market consistency is enforced **declaratively** by composite foreign keys — the ADR-007 preference — so no bulk, `COPY` or upsert path can bypass it. RLS is enabled on all 16 tables with zero policies; `anon` and `authenticated` hold no table privileges and `service_role` holds table DML only, verified on both environments. `src/types/database.ts` regenerated from the remote and current. Test suite green: 214 pgTAP assertions (139 new in `schema_b.test.sql`) plus 50 application tests, with typecheck, lint and build clean.
- **Decisions recorded:** ADR-0008 (cross-market consistency by composite foreign key, implementing ADR-007) and ADR-0009 (deal lifecycle — the Product Manager's resolution of the `deal_status` contradiction found during this task, which also added T20A and revised T19, T22, T24, T27, T29 and T33).

---

## T05 — Schema C: credits, multi-currency billing and operational logs

- **Goal:** Create the currency-neutral credit ledger, per-currency pack pricing, and market-aware operational logs.
- **Agent:** Database Engineer
- **Dependencies:** T03
- **Files / areas:** `supabase/migrations/*_schema_c.sql`, `src/types/database.ts`
- **Acceptance criteria:**
  - `credit_ledger` per ARCHITECTURE.md v2.0 with append-only deltas, `balance_after`, reason enum and unique `idempotency_key`.
  - `credit_purchases` stores `amount_minor` and `currency`.
  - Split credit packs into `credit_packs` (credit quantity/value) and `credit_pack_prices` (currency, amount_minor, Stripe Price ID), unique per `(credit_pack_id, currency)`.
  - `stripe_webhook_events.stripe_event_id` is the PK.
  - `api_usage_log` records provider, `marketplace_id`, endpoint, units/tokens, estimated cost, cost currency, status and latency.
  - `ingestion_runs` includes `market_id`.
  - `app_events` includes `market_id`.
  - RLS enabled, no policies yet.
  - **Privilege posture — new in v2.1 (ADR-004, global rule 8):** no privileges granted to `anon` or `authenticated` by this migration; `service_role` receives table DML only; any Postgres or Supabase default grant on the new tables **and their sequences** is revoked in the same migration; the migration states its posture in a header comment. This applies to `credit_packs` and `credit_pack_prices` too — their public-read grants belong to T06, alongside their policies, not here.
- **Testing requirements:** Duplicate ledger idempotency key and Stripe event IDs are rejected. A pack can have GBP and USD prices without duplicating the pack itself. Regenerate `src/types/database.ts` against the remote database and commit it.
- **Priority:** P0

---

## T05A — Temporal integrity constraints on versioned schedules

- **Goal:** Make overlapping effective ranges impossible for `tax_schedules` and `fee_schedules`, so that "the schedule effective for this market on this date" always resolves to exactly one row.
- **Agent:** Database Engineer
- **Dependencies:** T03 (creates both tables). Sequenced after T05. **Blocks T08** — the seed must be written against enforced constraints, or the seed itself can create the defect the constraint exists to prevent, and it will be committed as fixture data.
- **Files / areas:** `supabase/migrations/*_schedule_temporal_integrity.sql`, `src/types/database.ts` (only if generated types change)
- **Why this is schema and not seeding discipline:** `MarketContext` (T13) resolves a schedule by country/marketplace and date. With two overlapping rows, Postgres returns whichever row the plan happens to reach first — deterministic enough to pass tests, non-deterministic enough to change after an unrelated `VACUUM`. Every profit figure in that market is then systematically wrong, which is ARCHITECTURE.md risk #2 ("trust gone market-wide") and risk #3. Seeding discipline cannot hold it either, because T08 is not the only writer: T33 gives the admin console versioned fee-schedule editing (AC16.4), so a human will eventually create an overlap by hand, and the failure is silent.
- **Acceptance criteria:**
  - Enable the `btree_gist` extension **only if** the chosen constraint form requires it (an `EXCLUDE` mixing an equality key with a range overlap does; check whether it is already enabled before adding it).
  - `tax_schedules`: exclusion constraint preventing two rows for the **same `country_code`** whose effective ranges overlap.
  - `fee_schedules`: exclusion constraint preventing two rows for the **same `marketplace_id`** whose effective ranges overlap.
  - **Half-open `[)` semantics.** A row ending at time T and a row starting at time T are adjacent, not overlapping, and both must be accepted — this is the normal shape of a schedule version bump and must not be rejected.
  - **`effective_to IS NULL` means open-ended/current and must participate correctly in overlap detection.** A NULL that silently drops out of the constraint defeats the entire task, because the current schedule is exactly the row most likely to be NULL-terminated. Choose one representation — `tstzrange(effective_from, effective_to, '[)')` treats NULL as unbounded, or a generated range column — and record the choice in the ADR. Two open-ended rows for the same key must be rejected.
  - `CHECK (effective_to IS NULL OR effective_to > effective_from)` on both tables.
  - The migration must **not** silently drop or alter existing rows. If T03 or an earlier seed left data that violates the new constraint, the migration fails loudly and the data is corrected deliberately.
  - **Privilege posture (global rule 8):** this migration adds constraints only. It grants nothing, revokes nothing, and says so in its header comment. If `btree_gist` is newly created, note that extension objects are not granted to `anon` or `authenticated`.
  - Regenerate and commit `src/types/database.ts` **only if** the generated types change; a no-op regeneration should produce no diff.
- **Testing requirements:** SQL tests proving, for both tables:
  - Two rows for the same key with overlapping ranges → **rejected**.
  - Two rows for the same key that are exactly adjacent under `[)` → **accepted**.
  - Two open-ended rows (`effective_to IS NULL`) for the same key → **rejected**.
  - One closed row and one open-ended row for the same key that overlap → **rejected**.
  - Overlapping rows for **different** keys (different country, different marketplace) → **accepted**.
  - `effective_to <= effective_from` → **rejected**.
  - A resolution query for a given key and date returns exactly one row across all the accepted fixtures above.
- **Priority:** P0

---

## T06 — RLS policies (default deny) and append-only enforcement

- **Goal:** Every table locked down per §6.3, with ledger immutability enforced by the database rather than by convention — and, after T03, with **grants and policies written together**, because neither works alone.
- **Agent:** Database Engineer
- **Dependencies:** T03, T04, T05, T05A
- **Files / areas:** `supabase/migrations/*_rls.sql`
- **The rule this task now turns on (ADR-004):** T03 normalised privileges so `anon` and `authenticated` hold **nothing**. A policy grants no access on its own — RLS filters rows *within* privileges already held. So every policy in this task requires a deliberate, matching SQL `GRANT`, and every `GRANT` requires a deliberate, matching policy. One without the other is a defect in one of two directions: an inert policy, or an ungoverned privilege.
- **Acceptance criteria:**
  - RLS enabled on **every** table. Any table with neither a policy nor a grant is unreachable by the `anon` and `authenticated` roles.
  - **Every policy added has a matching minimum grant, and every grant added has a matching policy.** The PR description contains a two-column table listing each table, its policies and its grants, so the correspondence is reviewable at a glance.
  - **Grants are minimum-necessary and per-operation** — `GRANT SELECT` where only reads are needed, never blanket `ALL`.

  **User-owned tables** (`authenticated` only):
  - `profiles`: policy SELECT/UPDATE where `id = auth.uid()`; grant `SELECT, UPDATE`. `credit_balance` is **not** directly updatable by the user — enforce with a column-level grant restriction or an update trigger rejecting a changed balance.
  - `credit_ledger`: policy SELECT own rows only; grant `SELECT` **only**. **No INSERT, UPDATE or DELETE policy and no such grant exists at all** — belt and braces, because this table is the source of truth for money.
  - `deal_unlocks`, `watchlist_items`, `purchase_records`, `barcode_lookups`: policies SELECT/INSERT/DELETE where `user_id = auth.uid()`; grants `SELECT, INSERT, DELETE` to match. Note `deal_unlocks` DELETE is granted for symmetry only if the product requires it — if unlocks are permanent (AC10.7), **do not** grant DELETE and do not write the policy.

  **Public reference tables** (`anon, authenticated`, `SELECT` only, active rows only):
  - `countries`, `currencies`, `markets` (active/live rows only): policy + `GRANT SELECT`.
  - `credit_packs` and active `credit_pack_prices`: policy + `GRANT SELECT`.
  - **`marketplaces` is removed from the public-read set (new in v2.1, ADR-008).** It carries `adapter_key` and `capabilities`, which are integration internals. Nothing in the MVP client needs it: the feed is market-scoped server-side, and currency formatting needs `currencies` and `markets` only. Neither PRODUCT_SPEC nor ARCHITECTURE requires client access to it. If a client need emerges later, expose a view with the specific columns required — do not grant the table.

  **Service-role-only tables** — `deals`, `retailer_products`, `marketplace_products`, `product_matches`, `tax_schedules`, `fee_schedules`, `credit_purchases`, `stripe_webhook_events`, `api_usage_log`, `ingestion_runs`, `app_events`:
  - **No policies and no `anon`/`authenticated` grants of any kind.** Stated explicitly in the migration rather than left implicit, so a reviewer can see the decision was made.

  **Immutability:**
  - Triggers on `credit_ledger` and `stripe_webhook_events` raise on UPDATE and DELETE (AC10.5).
- **Testing requirements:** T09 covers this formally, but this task ships its own SQL smoke tests proving: (a) the ledger rejects an UPDATE and a DELETE **from the service role itself**; (b) for one representative public-read table and one representative user-owned table, the `authenticated` role can actually read the rows it should — a policy that is inert for want of a grant must fail here, not at T09.
- **Priority:** P0

---

## T07 — Atomic credit RPCs (`spend_credits`, `grant_credits`)

- **Goal:** The only sanctioned path for credits to move. Race-free, idempotent, auditable.
- **Agent:** Database Engineer
- **Dependencies:** T05, T06
- **Files / areas:** `supabase/functions/spend_credits.sql`, `supabase/functions/grant_credits.sql`, `supabase/migrations/*_credit_rpcs.sql`
- **Acceptance criteria:**
  - Both functions are `SECURITY DEFINER` with `set search_path = public, pg_temp`.
  - `spend_credits(p_user, p_amount, p_reason, p_ref_type, p_ref_id, p_idem)` in one transaction: idempotency check (existing key ⇒ return the prior result, do not double-charge) → `SELECT ... FOR UPDATE` on the profile row → raise `INSUFFICIENT_CREDITS` if balance is short → insert ledger row with `balance_after` → update cached balance. Returns `(new_balance, ledger_id)`.
  - `grant_credits` mirrors this and permits a negative resulting balance (refunds and chargebacks, §9.2).
  - **Execute privileges are explicit (new in v2.1, ADR-004).** In the same migration as each function, and immediately after every `CREATE OR REPLACE`:
    - `REVOKE ALL ON FUNCTION … FROM PUBLIC, anon, authenticated;`
    - `GRANT EXECUTE ON FUNCTION … TO service_role;`
    - The revoke is **not optional even under T03's owner-only default**. Postgres grants `EXECUTE` to `PUBLIC` on function creation by default, and a later "fix the RPC" migration that uses `CREATE OR REPLACE` without re-revoking silently reopens it. A `SECURITY DEFINER` function with a public execute grant is a direct route to minting credits.
    - Both statements appear in the same migration file as the function body, not in a separate hardening migration, so they cannot drift apart.
  - No "check then deduct" logic exists anywhere in application code.
- **Testing requirements:** SQL/pgTAP tests: (a) insufficient balance raises and writes nothing; (b) the same idempotency key twice charges once; (c) two concurrent sessions spending the last credit — exactly one succeeds; (d) **a session acting as `authenticated` calling `spend_credits` or `grant_credits` receives a permission error and no ledger row is written**; (e) the same for `anon`. Test (c) is the release gate for AC10.1 and must be automated, not manual. Tests (d) and (e) must assert a *privilege* failure, not merely an absent result.
- **Priority:** P0

---

## T08 — Seed data: currencies, countries, launch market, Amazon locale, tax/fee schedules and credit packs

- **Goal:** Seed global reference data plus one fully verified launch market. This task proves the architecture is global while operations remain single-market.
- **Agent:** Database Engineer
- **Dependencies:** T03, T04, T05, **T05A** — the temporal exclusion constraints must exist before any schedule row is seeded, or the seed can create the overlap the constraint prevents and commit it as fixture data.
- **Files / areas:** `supabase/seed/`, `docs/DECISIONS.md`, `docs/MARKET_PLAYBOOK.md`
- **Acceptance criteria:**
  - Seed ISO currency metadata for at least GBP, USD, EUR and JPY including `minor_unit_exponent`.
  - Seed multiple country and Amazon-locale rows so the abstraction is exercised, but mark **exactly one operating market as live/beta** for MVP.
  - Seed the chosen launch market's verified tax schedule and Amazon marketplace fee schedule, including source URLs and verification dates.
  - Fee schedules use generic referral rules, fulfilment bands, storage rules and `surcharges`; **no hard-coded digital-services-fee column is required**.
  - Seed at least three credit packs and per-currency `credit_pack_prices` for the launch currency. Other-currency prices may remain inactive until those markets open.
  - Seed 3–5 retailers in the chosen launch market with `source_type = 'curated'`.
  - Seed is idempotent.
  - **`fx_rates` is out of MVP scope (ADR-005).** The table is not created and not seeded. The MVP is single-currency per deal (§7.6, AC2.7) and there is no MVP consumer; it arrives in Phase 3 with the first genuine cross-border or multi-currency reporting requirement. Do not create it "for later".
  - **Seed operations are DML-only and execute as owner or `service_role`.** The seed performs no DDL, creates no privileges and alters no policies. If a seed appears to need DDL, that is a missing migration, not a seed change.
  - **Exactly one live market is seeding and operational discipline, not a database constraint.** `launch_status` is a lever the admin console legitimately flips (T33), so no uniqueness constraint is added on it. The rule lives in `docs/MARKET_PLAYBOOK.md` and in the T40 release checklist, and is verified there.
  - `docs/MARKET_PLAYBOOK.md` contains the checklist for opening a new market: provider coverage, tax verification, fee verification, Stripe support, retailer supply, legal review, seed rows, launch status.
  - **Demonstrate a synthetic second market can be seeded without a migration or business-logic code change.**
- **Testing requirements:** Run seed twice; counts remain stable. Resolve both the live launch market and the synthetic second market through the future `MarketContext` shape using fixtures. Verify fee-band coverage in the launch market has no gaps/overlaps.
- **Priority:** P0

---

## T09 — QA: anon-key and RLS access verification suite

- **Goal:** Prove, automatically and permanently, that a browser holding the anon key can read nothing it shouldn't.
- **Agent:** QA Engineer
- **Dependencies:** T06, T07, T08
- **Files / areas:** `tests/integration/rls.test.ts`, `.github/workflows/ci.yml`
- **Test users:** authenticated fixtures are created via the **Supabase admin auth API using the service-role key**. This task does **not** depend on T10 — app-layer signup does not exist yet and is not required. Users A and B are created, used and torn down by the suite itself.
- **The failure-mode rule (new in v2.1).** After T03, an `anon` query against a service-role-only table fails with a **privilege error**, not an empty result set. A test that catches broadly and asserts "no rows" therefore **passes for the wrong reason** — and would keep passing on the day someone adds a permissive policy to a table that still lacks a grant, then stop protecting anything the day someone adds the grant. Each assertion must therefore state *which mechanism* is expected to do the work:
  - **Service-role-only tables → assert a privilege/permission error.** An empty result set is a **failure** of the test, because it means a grant exists that should not.
  - **Policy-governed tables → assert the query succeeds and returns correctly filtered rows.** A privilege error is a **failure** of the test, because it means the policy is inert for want of a grant.
  - **Public reference tables → assert the query succeeds and returns only the allowed (active) rows.** Both a privilege error and the presence of an inactive row are failures.
- **Acceptance criteria:**
  - With the **anon key only**, a **privilege error** is returned for: `deals`, `retailer_products`, `marketplace_products`, `product_matches`, `fee_schedules`, `tax_schedules`, `marketplaces`, `credit_purchases`, `api_usage_log`, `ingestion_runs`, `app_events`, `stripe_webhook_events`.
  - With the anon key, `countries`, `currencies`, `markets`, `credit_packs` and active `credit_pack_prices` **succeed** and return **only active/live rows** — inactive rows are absent, and their absence is asserted against a seeded inactive fixture row, not merely assumed.
  - As authenticated user A, queries against `profiles`, `credit_ledger`, `deal_unlocks`, `watchlist_items`, `purchase_records`, `barcode_lookups` **succeed** and return only A's rows. User B's seeded rows are absent. A privilege error on any of these fails the suite.
  - User A cannot UPDATE own `credit_balance` directly — assert the specific rejection, not just an unchanged value.
  - User A cannot INSERT into `credit_ledger` — assert a privilege or policy rejection.
  - User A cannot call `spend_credits` or `grant_credits` (privilege error), duplicating T07's check at the integration layer.
  - **Every table in the schema appears in exactly one of the three categories above.** The suite enumerates tables from the live catalogue (`information_schema`) and **fails if a table exists that no assertion covers** — otherwise the suite silently stops protecting each new table added between here and T44.
  - The suite is a **CI blocker**.
- **Testing requirements:** This task *is* the test. It must run against a seeded ephemeral database in CI and be re-run after every future schema, grant or policy change. Include one deliberately inverted assertion during review — grant `SELECT` on `deals` to `anon` in a scratch branch and confirm the suite goes red — to prove the tests detect a real leak rather than merely passing.
- **Priority:** P0

---

## T10 — Authentication, session middleware and onboarding profile

- **Goal:** A user can sign up, verify, sign in, complete onboarding, and be correctly blocked from app routes when logged out (F1, F2).
- **Agent:** Backend Engineer
- **Dependencies:** T02, T06, T09
- **Files / areas:** `src/app/(auth)/*`, `src/middleware.ts`, `src/app/(app)/settings/*`, `src/app/api/v1/profile/route.ts`, `src/services/profile/`, `src/lib/validation/profile.ts`
- **Acceptance criteria:**
  - Email/password and magic-link sign-in via Supabase Auth; verification email sent on signup (AC1.1).
  - Session in **httpOnly cookies**. Nothing in `localStorage` or `sessionStorage` (AC1.4).
  - Middleware refreshes the session and protects `/(app)/*` and `/admin/*`; a logged-out visitor is redirected to sign-in and returned to the intended route afterwards (AC1.3).
  - Onboarding collects, in order: country/market → tax-registration status → fulfilment → budget → prep cost per unit → inbound shipping per unit. If no live market exists for the user's country, the user is waitlisted instead of shown foreign deals.
  - Tax-registration status defaults conservatively to not registered where applicable, with the consequence explained for the resolved market tax regime.
  - Money inputs use the active market currency; values are stored as integer minor units with explicit currency. No currency symbol or ×100 assumption is hard-coded.
  - `GET/PATCH /api/v1/profile` is Zod-validated and updates only the caller's own row.
  - Signup grants 5 credits via `grant_credits` with reason `signup_grant` (AC10.6).
  - Account deletion available in settings, cascading personal rows (AC1.5).
- **Testing requirements:** Integration tests for redirect-and-return, profile update authorisation (user A cannot PATCH user B), and the signup grant landing in the ledger exactly once. Manual: complete onboarding in under 60 seconds on a mid-range Android phone (AC2.4) and record the timing in the PR.
- **Priority:** P0

---

## T11 — Security review #1: authentication, RLS and secrets

- **Goal:** Independent verification that the foundation is sound before any money logic is built on it.
- **Agent:** Code Reviewer / Security Reviewer
- **Dependencies:** T09, T10
- **Files / areas:** Review only. Findings land in `docs/DECISIONS.md` and new issues.
- **Acceptance criteria:**
  - Confirms: no service-role key or third-party secret is reachable from the client bundle (inspect the built bundle, do not take it on trust).
  - Confirms `import 'server-only'` present in every secret-touching module.
  - Confirms RLS default-deny holds and T09 genuinely covers every table (checks the table list against the migrations, not against the test file).
  - Confirms session storage mechanism and cookie flags (`httpOnly`, `secure`, `sameSite`).
  - Confirms email verification blocks credit spend with no partial state (AC1.2).
  - Confirms `spend_credits` cannot be bypassed by any application code path.
  - Produces a written findings list; **P0 findings block T12 onward**.
- **Testing requirements:** Reviewer re-runs T09 and T07's concurrency test independently and records the results.
- **Priority:** P0

---

# PHASE 2 — DEAL ENGINE (T12–T20A)

> These come before data plumbing deliberately. They are pure, testable, and they are the actual product.

---

## T12 — `lib/money`, `AppError` and shared validation primitives

- **Goal:** Build the single explicit-currency arithmetic module and the single error type before any business calculation depends on them.
- **Agent:** Backend Engineer
- **Dependencies:** T01, T03
- **Files / areas:** `src/lib/money/{money.ts,currency.ts,format.ts}`, `src/lib/errors.ts`, `src/lib/validation/index.ts`
- **Acceptance criteria:**
  - Money is represented as `{ amountMinor: bigint|number-safe-integer, currency: ISO4217 }` according to the architecture's chosen TS representation.
  - Exports include explicit-currency `add`, `subtract`, `mulBps`, allocation/division helpers and formatting.
  - Adding/subtracting different currencies throws `CURRENCY_MISMATCH`.
  - Currency exponent is resolved from currency configuration; `format` uses `Intl.NumberFormat(locale, { style:'currency', currency })`.
  - No `formatMoney`, no pound symbol and no fixed two-decimal assumption exists in production code.
  - Rounding contract is documented and tested: round half away from zero at the final required monetary step, with conservative profit/ROI output rounding per pricing rules.
  - Unsafe integer/invalid money input throws rather than coercing.
  - `AppError` includes `CURRENCY_MISMATCH`, `MARKET_NOT_LIVE`, `INSUFFICIENT_CREDITS`, `DEAL_EXPIRED`, `VALIDATION_FAILED`, `RATE_LIMITED`, `UPSTREAM_UNAVAILABLE`.
  - CI grep/lint prevents currency arithmetic outside `src/lib/money/` and prevents hard-coded `£`, `$`, `GBP`, `USD` in `src/` outside explicit allowed config/test areas.
- **Testing requirements:** Unit tests in GBP, USD and JPY (0 exponent), negative/zero values, boundary rounding, mixed-currency failure and locale formatting.
- **Priority:** P0

---

## T13 — `MarketContext`, fee resolution and tax-regime strategies

- **Goal:** Resolve all market-specific assumptions once, then keep pricing country-blind.
- **Agent:** Backend Engineer
- **Dependencies:** T08, T12
- **Files / areas:** `src/services/market/{context.ts,resolve.ts,capabilities.ts}`, `src/services/pricing/{fees.ts,types.ts}`, `src/services/tax/{resolve.ts,regimes/vat.ts,regimes/gst.ts,regimes/sales-tax.ts,regimes/none.ts}`
- **Acceptance criteria:**
  - `resolveMarketContext(marketId)` resolves source country, marketplace, currency, locale, active tax schedule, active fee schedule and marketplace capabilities.
  - Pricing/tax callers receive a resolved context and do not query country/marketplace constants themselves.
  - Fee functions resolve referral fees, generic surcharges, fulfilment fees and storage from the versioned fee schedule.
  - Missing required dimensions/weight returns explicit `unknown`, never an estimate.
  - Tax service implements the strategy interface for VAT, GST, sales tax and none, driven by `tax_schedules`.
  - No tax rate is hard-coded. No `if (country === 'GB')`-style business logic exists.
  - Tax output describes input relief/reclaim, output liability and uncertainty flags as applicable.
  - Advanced local schemes and cross-border tax remain out of scope and produce an explicit unsupported/uncertain result, not a guess.
- **Testing requirements:** Hand-worked fixtures for at least: VAT registered/non-registered; GST registered/non-registered; US-style tax-exclusive purchase with and without resale exemption; no-tax regime. Test that two markets resolve different fee/tax schedules without branching changes.
- **Priority:** P0

---

## T14 — Pricing engine: `calculateDeal`

- **Goal:** One pure function, inputs → full itemised breakdown. This is the product (F6).
- **Agent:** Backend Engineer
- **Dependencies:** T13
- **Files / areas:** `src/services/pricing/calculate.ts`, `src/services/pricing/types.ts`
- **Acceptance criteria:**
  - Signature is `calculateDeal(inputs: DealInputs) => DealBreakdown`. **Pure. No IO, no database, no clock, no randomness.**
  - `DealInputs` matches §7.2 exactly.
  - Calculation follows ARCHITECTURE.md §7.3: price/tax basis normalisation → referral → generic surcharges → fulfilment → storage → prep + inbound → returns allowance → tax treatment → net profit → ROI → margin.
  - Output is an **itemised breakdown**, never a bare number, with at minimum: buy price, tax treatment, referral fee, fulfilment fee, storage, prep, inbound shipping, returns allowance, net profit, ROI, margin (AC6.1).
  - Sell price is the **lower** of current featured-offer/Buy Box and 90-day average where price-history capability exists (AC6.4). Never the peak.
  - A returns allowance and at least one month of storage are included by default (AC6.5).
  - ROI is computed on **cash deployed** = buy price + prep + inbound shipping, and the breakdown labels the denominator (AC6.7).
  - Profit and ROI use the conservative output-rounding rules from ARCHITECTURE.md; no intermediate float arithmetic (AC6.6).
  - All monetary inputs must share one currency; mismatch returns/throws `CURRENCY_MISMATCH`. Any missing required input produces an explicit `insufficient_inputs` result — **never a guessed number** (§12.2 principle 4).
  - Returns `calcVersion: 'calc.v1'` and an `inputsSnapshot` containing every input used, including `marketId`, currency, fee schedule ID and tax schedule ID (AC6.10).
- **Testing requirements:** Covered formally by T15. This task ships at least a smoke test per branch.
- **Priority:** P0

---

## T15 — QA: hand-worked pricing test suite

- **Goal:** Independent verification that the pricing engine is arithmetically correct, by someone other than its author (Gate A).
- **Agent:** QA Engineer
- **Dependencies:** T14
- **Files / areas:** `tests/unit/pricing/*.test.ts`, `tests/fixtures/pricing-cases.json`, `docs/SCORING.md`
- **Acceptance criteria:**
  - **At least 15 hand-worked cases** pass, each with its expected values computed by hand and shown in a comment or fixture, covering (AC6.9): multiple tax-regime cases · marketplace-fulfilled and seller-fulfilled · minimum referral fee · fulfilment-band boundaries · generic surcharge application · zero profit · negative profit · heavy/oversize · missing dimensions (suppress, never estimate) · multipack-priced item · **at least two currencies including a 0-decimal currency**.
  - Cases are expressed as data, not as bespoke test code, so future fee schedule versions can be re-run against them.
  - The hand-worked expected values are **derived independently of the implementation** — a case that was produced by running the code and pasting the output does not count and must be rejected in review.
  - Suite is a CI blocker.
- **Testing requirements:** This task is the test. Reviewer spot-checks three cases with a calculator and signs off in the PR.
- **Priority:** P0

---

## T16 — Deal Score and unit recommendation engines

- **Goal:** The five-component score with visible workings (F7) and the constrained unit recommendation (F13). Both pure.
- **Agent:** Backend Engineer
- **Dependencies:** T14
- **Files / areas:** `src/services/scoring/{score.ts,weights.ts,penalties.ts}`, `src/services/recommendation/units.ts`, `docs/SCORING.md`
- **Acceptance criteria:**
  - Score 0–100. Amazon-MVP defaults use profitability 35%, demand 25%, competition 20%, price stability 10%, confidence 10% (AC7.1).
  - Demand/rank is normalised **within marketplace and category** before scoring (AC7.4).
  - Penalties applied multiplicatively and capped, per §8.3: marketplace operator on listing/in stock, match confidence < 0.8, stale/thin data, gating-risk brand, profit below floor.
  - Hard suppressions return "do not publish": net profit ≤ 0, match confidence < 0.6, required inputs missing (AC7.5).
  - Persisted breakdown matches the §8.4 shape: every component's score, weight and **raw inputs**, plus every applied penalty with its code and factor (AC7.2, AC7.3).
  - **All weights, penalty factors and market-specific thresholds live in controlled configuration.** No magic constant appears elsewhere in scoring code (AC7.7).
  - Returns `scoreVersion: 'score.v1'`.
  - Capability-aware scoring is implemented: unavailable marketplace components are dropped, remaining weights renormalised, the missing capability disclosed, and confidence reduced. Never substitute fabricated default component values.
  - `recommendUnits` returns `min(maxByBudget, maxByVelocity, maxByRisk, maxByCapitalRisk)`, floored at 1 (AC13.1, AC13.4), **and names the binding constraint** as a structured value the UI can render in plain English (AC13.2).
  - `docs/SCORING.md` documents every component, weight, penalty and the recommendation formula in prose.
- **Testing requirements:** Table-driven determinism test: identical inputs → identical score, run 100× (AC7.6). Tests for each penalty in isolation and in combination. Include a synthetic low-capability marketplace fixture and assert correct weight renormalisation/disclosure. Tests for each of the four recommendation constraints being the binding one, asserting the correct constraint is named. Snapshot tests on the breakdown JSON shape.
- **Priority:** P0

---

## T17 — Marketplace adapter interface + Keepa Amazon provider

- **Goal:** Implement the marketplace abstraction and the only MVP provider, Keepa for Amazon, with strict quota control.
- **Agent:** Integration Engineer
- **Dependencies:** T05, T08, T12, T13
- **Files / areas:** `src/services/marketplace/{adapter.ts,registry.ts,refresh-policy.ts}`, `src/services/marketplace/providers/keepa/{client.ts,mapper.ts,capabilities.ts}`, `src/app/api/cron/refresh-listings/route.ts`, `tests/fixtures/keepa/*.json`
- **Acceptance criteria:**
  - Define `MarketplaceAdapter` and canonical types per ARCHITECTURE.md §10.1.
  - Adapter registry resolves `marketplace_id → adapter_key` from database/configuration.
  - `KeepaAmazonAdapter` is the **only MVP implementation**, but supports the chosen Amazon locale and can map additional Amazon locales without changing business logic.
  - Nothing outside the Keepa provider folder knows Keepa response shapes or assumes marketplace external ID as the generic product ID.
  - Provider calls are server-only and credentials come from validated env.
  - Per-run budget and daily cap enforced; every call logs provider, marketplace ID, units/tokens, cost estimate, status and latency.
  - Mapper writes canonical `marketplace_products`: external ID, GTINs, featured offer, demand/rank, offers, history, dimensions, flags and `provider_raw`.
  - Missing weight/dimensions remain null.
  - Capability flags accurately describe price history, demand proxy, offer counts, fee preview and taxonomy availability.
  - Tiered refresh cadence is market-scoped; cron is secret-protected, idempotent, batched and resumable.
  - CI grep prevents direct Keepa network calls outside the provider client.
- **Testing requirements:** Fixture mapper tests; token-cap and retry tests; adapter registry test for two Amazon locale rows; one manual live call in the chosen launch locale with quota cost recorded.
- **Priority:** P0

---

## T18 — GTIN normalisation and marketplace matching service

- **Goal:** Resolve retailer product → marketplace listing with an honest confidence score. Risk #1 lives here.
- **Agent:** Backend Engineer
- **Dependencies:** T17
- **Files / areas:** `src/services/matching/{gtin.ts,confidence.ts,index.ts}`
- **Acceptance criteria:**
  - Normalise supported barcode forms into canonical GTIN-14 while retaining the original raw code/format.
  - Exact GTIN matching only for automatic MVP publication. Title/fuzzy matching is not implemented.
  - Matching calls the marketplace adapter by GTIN and stores `marketplace_product_id`, method and confidence.
  - Confidence accounts for exact identifier match, brand agreement and pack-size signals from title/weight.
  - Confidence < 0.6 → no deal; review queue. 0.6–0.8 → penalty + mandatory admin review. Multiple candidates → none auto-published.
  - Emits structured `packSizeSuspicion`.
  - No core matching code refers to marketplace external ID except inside Amazon-specific provider fixtures.
  - Every output includes method and confidence; never guesses silently.
- **Testing requirements:** UPC-12 and GTIN-13 canonicalisation fixtures; clean single match; multiple candidates; single-vs-multipack mismatch both directions; code not found; same GTIN fixture against two marketplace adapter responses.
- **Priority:** P0

---

## T19 — Deal computation pipeline

- **Goal:** Compose everything built so far into `retailer_products → deals`, idempotently and resumably.
- **Agent:** Backend Engineer
- **Dependencies:** T14, T16, T17, T18
- **Files / areas:** `src/services/ingestion/run.ts`, `src/services/deals/compute.ts`, `src/app/api/cron/recompute-deals/route.ts`
- **Acceptance criteria:**
  - Pipeline order exactly per §1.4: market resolve → match → enrich → price → score → upsert `deals`.
  - Every computed deal stores `market_id`, currency, fee/tax schedule IDs, `calc_version`, `score_version`, `score_breakdown` and a complete `inputs_snapshot` such that any historical figure can be reproduced exactly (AC6.10).
  - **New computations insert as `draft`** (ADR-0009). The database defaults `deals.status` to `draft` and rejects an insert in any other state, so this is enforced rather than trusted — but the pipeline states it explicitly rather than relying on the default.
  - **T19 never writes `active`.** There is no code path in the pipeline that publishes a deal. Publication is an explicit admin act through T20A (AC3.3, AC3.7).
  - Suppression rules from T16 are enforced here: **a hard-suppressed candidate is not inserted into `deals` at all**, and the suppression reason is logged against the ingestion run. A suppressed deal is not a draft — a draft is a candidate awaiting review, and a suppressed candidate has already failed review.
  - **An `active` deal that becomes hard-suppressed on recompute is retired**, with `retire_reason = 'suppressed_on_recompute'` (AC3.9). It is never left live and never downgraded to draft — `active → draft` is rejected by the database, and a deal that no longer passes its own publication bar must stop being shown.
  - **Rejected `product_matches` are skipped.** A match an admin has rejected after a confirmed bad-match report (T24, AC15.6) never produces a deal again — otherwise the next run recomputes the same wrong deal from the same wrong match.
  - Because only one non-retired deal may exist per product pair, a recompute updates the existing draft/active row for that pair rather than inserting a second one.
  - Recompute is idempotent: running twice over the same inputs produces identical outputs and does not duplicate rows.
  - Partial failure is normal: a failed row increments `rows_failed` with a reason and the batch continues (§12.2 principle 6).
  - Run is batched, time-boxed within Vercel's function limits, and resumable via a cursor in `ingestion_runs`.
  - Fee and tax schedules are resolved through `MarketContext` by version — never from constants in code. Retailer/marketplace currency mismatch suppresses the deal with `CURRENCY_MISMATCH`; no FX conversion occurs.
- **Testing requirements:** Integration test over a fixture set of 20 products asserting: correct count published, correct count suppressed with reasons, identical output on a second run, and a deliberately broken row failing without aborting the batch.
- **Priority:** P0

---

## T20 — Admin ingestion: CSV upload and single-URL paste

- **Goal:** The founder can get verified candidate products into the system today, without a scraper (F3).
- **Agent:** Backend Engineer
- **Dependencies:** T19
- **Files / areas:** `src/services/ingestion/sources/{csv.ts,manual.ts}`, `src/services/ingestion/normalise.ts`, `src/app/api/v1/admin/ingest/route.ts`
- **Acceptance criteria:**
  - Both sources implement the same `IngestionSource` interface (`fetch() => NormalisedProduct[]`) so future affiliate feeds drop in without touching anything downstream (§10.3).
  - CSV upload accepts market, retailer, SKU, title, GTIN/GTIN/UPC, price, currency, URL and returns a **per-row result**: matched / unmatched / failed, each with a reason (AC3.1).
  - Single-URL paste plus GTIN, price/currency and selected market produces one candidate (AC3.2).
  - Every run records rows in, rows upserted, rows failed and per-row errors in `ingestion_runs` (AC3.4).
  - Prices are parsed to integer minor units using the selected currency exponent, with explicit failure on ambiguity — never a silent coercion.
  - Admin-only, server-side role check.
  - **No affiliate feed adapter and no scraper is written.** Out of MVP scope.
- **Testing requirements:** Tests for a well-formed CSV, a CSV with malformed prices, a CSV with a missing GTIN column, a duplicate SKU (upsert not duplicate), and a 500-row file completing within the function time limit.
- **Priority:** P0

---

## T20A — Admin deal lifecycle API: publish and retire

- **Goal:** The only sanctioned path from `draft` to `active` and from either state to `retired` (AC3.3, AC3.6, AC3.7, AC3.8, AC3.9). T04 made the transitions valid-or-rejected; this task decides **who** may request one.
- **Agent:** Backend Engineer
- **Dependencies:** T19, T20. **Blocks T33.**
- **Files / areas:** `src/app/api/v1/admin/deals/[id]/{publish,retire}/route.ts`, `src/services/deals/lifecycle.ts`
- **Why this is its own task:** the database enforces that a transition is *legal*; nothing in T04 enforces that the requester is *allowed*, and ADR-0009 says so explicitly. Left to T33 it would be written inside a React route as a side effect of a button, which is where authorization goes to die. It is small, and it is the gate in front of the only thing that makes a deal visible to a paying user.
- **Acceptance criteria:**
  - `POST /api/v1/admin/deals/:id/publish` moves `draft → active`, setting `published_by` to the acting admin. `POST /api/v1/admin/deals/:id/retire` moves `draft|active → retired`, setting `retired_by` and a required `retire_reason`.
  - **Admin-only, server-side role check** on both, per §5.1 and AC16.1. No client-side hiding, no inference from a URL.
  - Both follow the §5.1 pipeline (authenticate → resolve `MarketContext` → rate-limit → Zod-validate → delegate → typed envelope) and contain no business logic in the handler.
  - The service is the **only** caller that writes `deals.status` outside the pipeline's draft inserts. `grep` for `status.*active` under `src/` returns nothing else that writes it.
  - An illegal transition returns a business-rule error from the §12.1 taxonomy (409/422), **translated from the database's rejection** rather than pre-checked in application code and then re-checked. The database is the authority; the API reports it.
  - Retiring is idempotent from the caller's point of view: retiring an already-retired deal returns success without a second write and without changing `retired_at`.
  - Publishing a deal whose pair already has a live deal is impossible by construction (T04's index); the resulting error is surfaced as a named business rule, not a 500.
  - Every transition writes an `app_events` row with the actor, the deal, the transition and the reason.
  - **Reason codes are a closed set**, including `suppressed_on_recompute` (written by T19), `confirmed_bad_match` (written by T24) and admin-initiated values.
- **Testing requirements:** Integration tests: a non-admin session receives 403 on both routes and **no state changes**; publish moves a draft to active and stamps the actor; retire from draft and from active both succeed; retire twice writes once; `retired → active` returns a business-rule error and not a 500; an `app_events` row is written per transition. A test asserting no other module writes `deals.status`.
- **Priority:** P0

---

# PHASE 3 — CORE APIS (T21–T27)

---

## T21 — Redaction service and CI payload-leak test

- **Goal:** The one place that decides what a user may see. The paid product is protected here or nowhere (§6.3, risk #6).
- **Agent:** Backend Engineer
- **Dependencies:** T19
- **Files / areas:** `src/services/redaction/{redact-deal.ts,redact-deal.test.ts}`
- **Acceptance criteria:**
  - `redactDeal(deal, { unlocked })` returns a locked or full shape. It is the **only** function producing a client-facing deal object; no route serialises a deal directly.
  - A locked deal's returned object contains **no** product title, image, marketplace external ID, retailer name, retailer URL, GTIN, brand or `retailer_product_id` — the fields are **absent from the object**, not nulled, not hidden client-side (AC8.2, AC9.4).
  - A locked deal **does** contain: Deal Score, full score breakdown with component inputs, named penalties, risk flags, profit band, ROI band, marketplace category, retailer *type*, assumption set, data freshness (AC9.1–AC9.3).
  - The automated test asserts against the **serialised JSON string**, using a deny-list of substrings drawn from the fixture deal, and fails if any appears.
  - The test is a **CI blocker**.
  - Banding functions for profit and ROI are defined here so the same bands are used everywhere.
- **Testing requirements:** Property-style test: for a fixture deal with distinctive sentinel values in every identity field, assert none of those sentinels appears anywhere in `JSON.stringify(redactDeal(deal, { unlocked: false }))`. Add a deliberately failing variant in review to prove the test actually catches a leak.
- **Priority:** P0

---

## T22 — Deal read APIs: feed, detail and personalised recalculate

- **Goal:** `GET /deals`, `GET /deals/:id`, `POST /deals/:id/recalculate` (F8, F9, F11, F12 backend).
- **Agent:** Backend Engineer
- **Dependencies:** T21
- **Files / areas:** `src/app/api/v1/deals/**`, `src/services/deals/query.ts`
- **Acceptance criteria:**
  - All three follow ARCHITECTURE.md §5.1: authenticate → resolve `MarketContext` → rate-limit → Zod-validate → delegate to service → typed envelope. **Handlers contain no business logic.**
  - Response envelope exactly per §5.2, with `requestId`, `marketId` and currency metadata where applicable.
  - **Every user-facing deal query filters on exactly `status = 'active'`** (AC3.7). Not `<> 'retired'`, not "published-ish" — a draft is a candidate the admin has not approved, and one loose predicate puts unreviewed deals in front of paying users. A single query builder owns this predicate so it cannot be forgotten per route.
  - `GET /deals/:id` returns a non-active deal **only** to a user who already unlocked it (AC3.6, AC10.7), and then with a `retired` flag. A draft is never returned to any user, unlocked or not.
  - Feed filters applied **server-side and market-scoped**: minimum profit, minimum ROI, minimum score, category, budget ceiling (AC8.3).
  - Default sort is Deal Score descending; deals scoring under 50 are excluded from the default feed (AC8.4).
  - Cursor pagination. No offset pagination.
  - Every returned row passes through `redactDeal`. Unlock state is resolved server-side from `deal_unlocks`.
  - `POST /deals/:id/recalculate` applies user overrides (sell price, prep, inbound shipping, storage months, units) against the stored `inputs_snapshot`, returns a fresh breakdown, **costs no credits**, and **never mutates the stored deal** (AC12.2, AC12.4).
  - An override producing zero or negative profit returns that plainly — never floored at zero (AC12.5).
  - Personalisation is an in-request overlay only. **No per-user precomputed table is created** (§2.2 note).
- **Testing requirements:** Integration tests: unauthenticated request rejected; locked payload leak test re-asserted at the route level; each filter narrows correctly; cursor pagination returns no duplicates and no gaps across pages; recalculate with a negative-profit override; recalculate does not write to `deals`. Performance: feed query p95 under 300ms on a seeded 5,000-row table. Cross-market test: user/request for market A cannot retrieve a deal ID belonging to market B. **Lifecycle tests: a seeded `draft` deal never appears in the feed and returns not-found by ID even for a user who unlocked a different deal; a `retired` deal is absent from the feed but still retrievable by a user who unlocked it.**
- **Priority:** P0

---

## T23 — Unlock and credits APIs

- **Goal:** `POST /deals/:id/unlock`, `GET /credits/balance`, `GET /credits/history` (F10, F20). The money path.
- **Agent:** Backend Engineer
- **Dependencies:** T07, T22
- **Files / areas:** `src/app/api/v1/deals/[id]/unlock/route.ts`, `src/app/api/v1/credits/**`, `src/services/{credits,unlocks}/`
- **Acceptance criteria:**
  - Unlock requires an `Idempotency-Key` header, stored as `credit_ledger.idempotency_key` (§5.4).
  - Already unlocked → returns the full deal and **charges nothing** (AC10.2).
  - Insufficient credits → `INSUFFICIENT_CREDITS` with a route to obtain more, and **no partial state written** (AC10.3).
  - The credit spend and the `deal_unlocks` insert occur in the **same transaction** (AC10.4). Neither can exist without the other.
  - Credits move **only** through `spend_credits`. No direct ledger insert exists in application code.
  - Unlocks are permanent and survive deal retirement (AC10.7); a retired unlocked deal returns full data plus a `retired` flag for the banner (AC3.6).
  - Unverified email → spend refused, **no credit deducted** (AC1.2).
  - `GET /credits/history` returns the user's ledger with reason and reference, most recent first.
- **Testing requirements:** **Automated concurrency test: 10 parallel unlocks at balance 1 → exactly one succeeds, final balance 0** (AC10.1) — this is a release gate. Idempotency test: the same key replayed 5× charges once. Test that a failed unlock writes neither a ledger row nor an unlock row. Test that unlock returns unredacted data only after the transaction commits.
- **Priority:** P0

---

## T24 — Purchases and report-a-deal APIs

- **Goal:** `POST /purchases`, outcome update, `POST /feedback` (F14, F15). The measurement instrument.
- **Agent:** Backend Engineer
- **Dependencies:** T23
- **Files / areas:** `src/app/api/v1/{purchases,feedback}/**`, `src/services/purchases/`
- **Acceptance criteria:**
  - Creating a purchase requires only unit count; actual price paid is optional and defaults to the deal's buy price (AC14.2).
  - On save, the deal's **predicted per-unit profit and full inputs snapshot are frozen onto the purchase record** (AC14.3). Later changes to the deal never alter a recorded purchase.
  - Outcome update accepts sold / partial / unsold / returned plus optional actual proceeds (AC14.4).
  - A purchase can be recorded up to 90 days after unlock; beyond that it is rejected with a clear code (AC14.7).
  - Only the owning user may create or read their purchases; RLS plus a server-side check.
  - Report accepts the fixed reason set: wrong product · wrong pack size · price wrong · out of stock · other + free text (AC15.2), and lands in the admin queue with deal, reporter and reason (AC15.3).
  - An admin confirming a report retires the deal and refunds the credit to **every** user who unlocked it, each recorded with reason `refund` (AC15.4). Refund is idempotent — confirming twice refunds once.
  - Retirement goes through **T20A**, with `retire_reason = 'confirmed_bad_match'` where that is the confirmed reason. No route writes `deals.status` directly.
  - **A confirmed bad-match report marks the underlying `product_matches` row rejected** (AC15.6), so T19 skips it on the next run. Retiring the deal alone is not enough: the match is what was wrong, and the pipeline would recompute the same deal from the same match and republish the same error. This task **adds the rejection marker to `product_matches` in its own migration** — T03 created that table with `method`, `confidence` and `verified_by` and no rejection concept, and T04 deliberately did not add one for a workflow that does not exist yet.
  - Reversing a rejected match is a deliberate admin act, never automatic.
- **Testing requirements:** Test that a purchase snapshot is unaffected by a subsequent deal recompute. Test the 90-day boundary either side. Test bulk refund across 5 unlockers, run twice, asserting 5 refund rows total. Test cross-user access is denied. **Test that after a confirmed bad-match report, a recompute over the same inputs produces no deal for that pair — the rejected match is skipped, not merely retired downstream.**
- **Priority:** P0

---

## T25 — Rate limiting, error envelope and request IDs

- **Goal:** Cross-cutting hardening applied uniformly rather than sprinkled per route (§5.4, §12).
- **Agent:** Backend Engineer
- **Dependencies:** T22, T23, T24
- **Files / areas:** `src/lib/rate-limit.ts`, `src/lib/logger.ts`, `src/app/api/**` wrapper, `supabase/migrations/*_rate_limits.sql`
- **Acceptance criteria:**
  - Rate limits per §5.4: unlock 30/min, barcode 20/min, feed 120/min, per user **and** per IP. Webhook exempt. Auth endpoints limited.
  - Implemented as a Postgres counter table. **No Redis, no Upstash** — swap only when a measured bottleneck exists.
  - Exceeding a limit returns 429 with `Retry-After` and a calm message.
  - One error handler translates `AppError` to the §12.1 taxonomy: 400 validation, 401/403 auth, 404, 409/422 business rule, 429, 502/503 upstream, 500 internal.
  - A 500 returns a generic message plus a `requestId`; full detail goes to logs only, never to the client.
  - Every response carries a `requestId` in `meta`, and it is present in the corresponding log line.
  - Route-segment error boundaries exist so a broken widget cannot blank the feed (§12.2 principle 8).
- **Testing requirements:** Integration tests: 31 unlock requests in a minute — the 31st is 429 with `Retry-After`. Test that an internal error leaks no stack trace, no SQL and no table name to the client. Test that `requestId` correlates a response with a log line.
- **Priority:** P0

---

## T26 — Security review #2: credits, unlock and redaction

- **Goal:** Independent verification of the paid product's integrity before any UI or payment work depends on it.
- **Agent:** Code Reviewer / Security Reviewer
- **Dependencies:** T21, T23, T24, T25
- **Files / areas:** Review only.
- **Acceptance criteria:**
  - Independently re-runs and confirms the concurrency test (AC10.1) and the payload-leak test (AC8.2).
  - Traces **every** code path that can reach `credit_ledger` and confirms all pass through `spend_credits` or `grant_credits`.
  - Confirms no route serialises a deal without `redactDeal`, by inspection of every deal-returning handler.
  - Confirms idempotency keys are required, stored and honoured on unlock.
  - Attempts, and fails, to obtain locked-deal identity via: the recalculate endpoint, filter side-channels (e.g. binary-searching a filter to identify a product), error messages, and cache headers. **Filter side-channels are an explicit part of this review.**
  - Confirms authorisation is checked server-side per request and never inferred from URL or hidden field.
  - Written findings; P0 findings block Phase 4.
- **Testing requirements:** Reviewer writes at least one new adversarial test that did not previously exist and commits it.
- **Priority:** P0

---

## T27 — QA: end-to-end pipeline integration test

- **Goal:** Prove 20 real products go from CSV to believable published deals before any UI is built on top (Architecture §15 step 7 verification).
- **Agent:** QA Engineer
- **Dependencies:** T20, T22
- **Files / areas:** `tests/integration/pipeline.test.ts`, `tests/fixtures/real-products.csv`
- **Acceptance criteria:**
  - 20 **real** retailer products from the chosen launch market with real GTINs go through ingest → match → enrich → price → score → deals.
  - **Every generated deal lands as `draft`, and the run produces exactly zero `active` deals.** Asserted by counting rows by status after the run, not by inspecting the code. If the pipeline can publish, this test is the place it gets caught (AC3.7).
  - Publishing a subset through **T20A** then shows exactly that subset in the feed, and nothing else — the two halves of AC3.3 verified end to end.
  - A human reviews the 20 outputs and confirms each profit figure is **believable** — checked by hand against the launch-market marketplace listing and retailer for at least 5 of them.
  - Suppressed deals are suppressed for the stated correct reason, and are **absent from `deals` entirely** rather than present as drafts.
  - Keepa token cost for the launch marketplace run is recorded, and the projected cost per published deal is documented in the PR. This number feeds the credit pricing decision (Open Question B2).
  - Any discrepancy between hand calculation and engine output is raised as a **blocking defect**, not a note.
- **Testing requirements:** This task is the test. Output is a written verification report committed to `docs/`, including the 5 hand-checked deals with workings.
- **Priority:** P0

---

# PHASE 4 — FRONTEND (T28–T33)

---

## T28 — App shell, navigation and marketing pages

- **Goal:** The mobile-first frame everything else renders inside.
- **Agent:** Frontend Engineer
- **Dependencies:** T10
- **Files / areas:** `src/app/(app)/layout.tsx`, `src/app/(marketing)/*`, `src/components/{layout,ui}/*`, `src/app/globals.css`
- **Acceptance criteria:**
  - Server Components by default. Client Components only where interaction requires it (§4.1).
  - **No Redux, Zustand or React Query.** Server Components + `useState` + Server Actions only.
  - Mobile-first: fully usable at **375px wide with no horizontal scrolling** (AC11.7).
  - Bottom navigation: Feed · Scan (placeholder until T42) · Purchases · Credits · Settings. A `MarketSwitcher` component exists but renders only when more than one market is live.
  - Marketing routes: landing, pricing, "how scoring works". The last of these explains the five components and the conservatism policy in plain English — it is a trust asset, not filler.
  - shadcn/ui primitives in `components/ui/`. Legibility and clarity over polish (§12.4 non-criteria).
  - Loading and empty states exist for every route; **no blank screens** (AC8.6).
- **Testing requirements:** Component tests for navigation and auth-state rendering. Manual: every route inspected at 375px on a real device, screenshots attached to the PR.
- **Priority:** P0

---

## T29 — Deal feed UI: locked `DealCard` and filters

- **Goal:** The discovery surface (F8).
- **Agent:** Frontend Engineer
- **Dependencies:** T22, T28
- **Files / areas:** `src/app/(app)/feed/page.tsx`, `src/components/deals/{DealCard,FeedFilters,ConfidenceBadge}.tsx`
- **Acceptance criteria:**
  - Server-rendered feed reading the redacted, active-market-scoped API. **No client-side data-fetching library.**
  - The feed shows **exactly `status = 'active'` deals** (AC3.7). Drafts are admin-only and belong in T33's review queue; retired deals are reachable only by a user who unlocked them (AC3.6). The UI never widens the predicate the API applies.
  - `DealCard` shows: Deal Score, profit band, ROI band, marketplace category, retailer *type*, data freshness (AC8.1).
  - `DealCard` shows **no** product name, image, marketplace external ID or retailer name — and the component has no props that could carry them.
  - Filters: minimum profit, minimum ROI, minimum score, category, budget ceiling; applied server-side via URL search params so state is shareable and back-button-correct (AC8.3).
  - Data older than 48 hours is **visually marked stale** (AC5.3). Stale data must look stale, not merely be labelled somewhere.
  - Over-filtered or empty feed shows an explanatory state naming which filter is excluding results (AC8.6).
  - Feed renders in **under 2 seconds on a mid-range Android phone over 4G** (AC8.5).
- **Testing requirements:** Component test asserting `DealCard` renders no identity fields from a full deal object passed in error. Lighthouse mobile run attached to the PR. Manual timing on a real mid-range Android device over 4G, recorded in the PR — emulator throttling is not sufficient evidence.
- **Priority:** P0

---

## T30 — Deal detail: locked view, unlock flow and unlocked view

- **Goal:** Where trust is earned before the spend, and the purchase decision is made after it (F9, F11).
- **Agent:** Frontend Engineer
- **Dependencies:** T23, T29
- **Files / areas:** `src/app/(app)/deal/[id]/page.tsx`, `src/components/deals/{DealDetail,ScoreBreakdown,RiskFlags,UnlockButton,ProfitBreakdown}.tsx`
- **Acceptance criteria:**
  - **Locked state** shows the complete score breakdown — all five components with scores, weights and raw inputs (AC9.1) — every named penalty and risk flag in plain English (AC9.2, AC7.3), profit and ROI bands, the assumption set, and data freshness (AC9.3). It withholds only identity.
  - Locked state shows the credit cost and the user's current balance **before** committing (AC9.5), and the refund policy link adjacent to the unlock button (AC9.6).
  - Unlock sends an `Idempotency-Key`, disables on submit, and handles `INSUFFICIENT_CREDITS` with a route to buy credits (or, pre-Stripe, a clear "contact the founder" path).
  - **Unlocked state** shows product title, image, brand, exact retailer name and pack size (AC11.1); one-tap links to the retailer page and the marketplace listing (Amazon in MVP), both opening in a new tab (AC11.2).
  - Unlocked state shows the full itemised breakdown per AC6.1, personalised to the user's tax status, `MarketContext` and cost assumptions (AC11.3), with the ROI denominator labelled (AC6.7) and the market-appropriate tax evidence/invoice caveat shown where applicable (AC6.3).
  - Gating warning displayed: the user is responsible for checking their own selling eligibility (AC11.5).
  - **"Estimates, not guarantees. Not financial or tax advice." appears on the same screen as the profit figure** — not in a footer, not behind a link (AC11.6).
  - The entire breakdown is legible at 375px without horizontal scrolling (AC11.7).
  - A retired-but-unlocked deal shows the retired banner and retains full access (AC3.6).
- **Testing requirements:** Component test asserting the locked view's rendered DOM contains none of the fixture's identity sentinels. Manual: complete the unlock flow on a real phone, screenshot both states. Verify the breakdown fits above two folds on a 375px viewport.
- **Priority:** P0

---

## T31 — Assumptions panel and unit recommendation UI

- **Goal:** "I can check your working with my own costs" — the single strongest trust affordance in the product (F12, F13).
- **Agent:** Frontend Engineer
- **Dependencies:** T30
- **Files / areas:** `src/components/deals/{AssumptionsPanel,UnitRecommendation}.tsx`
- **Acceptance criteria:**
  - User can override: assumed sell price, prep cost, inbound shipping, expected storage months, number of units (AC12.1).
  - Recalculation is **immediate and costs no credits** (AC12.2), via the recalculate endpoint.
  - Overrides are session-scoped by default, with an explicit "save as my defaults" action updating the profile (AC12.3).
  - The canonical stored deal is never mutated (AC12.4) — the UI makes clear it is showing a personalised view.
  - When overrides push net profit to zero or below, this is **stated plainly**, not hidden and not floored at zero (AC12.5).
  - `UnitRecommendation` shows the suggested count, total cash required and total expected profit (AC13.3).
  - The **binding constraint is rendered in plain English**, e.g. "Limited to 6 units by estimated demand: 8 sellers are already sharing roughly 90 sales a month" (AC13.2).
  - Recommendation updates live when budget changes (AC13.5).
  - Never recommends fewer than 1 unit (AC13.4).
- **Testing requirements:** Component tests for each of the four binding constraints rendering the correct sentence. Test for the negative-profit override message. Manual: adjust the sell price on a phone and confirm the recalculation feels instant (under 500ms perceived).
- **Priority:** P0

---

## T32 — Purchase recording and report-a-deal UI

- **Goal:** The measurement instrument, made frictionless (F14, F15). Friction here destroys the primary metric.
- **Agent:** Frontend Engineer
- **Dependencies:** T24, T30
- **Files / areas:** `src/app/(app)/purchases/*`, `src/components/deals/{BoughtThisButton,ReportDealDialog}.tsx`
- **Acceptance criteria:**
  - "I bought this" is reachable in **one tap** from any unlocked deal (AC14.1).
  - Requires only unit count; actual price is optional and pre-filled with the deal's buy price (AC14.2).
  - Recording a purchase takes **under 10 seconds end to end on a phone** (AC14.8) — measured, not assumed.
  - Outcome recording: sold / partial / unsold / returned plus optional actual proceeds (AC14.4).
  - Purchase list shows predicted versus actual side by side where both exist (AC14.5).
  - **In-app banner on any deal unlocked more than 48 hours ago and not marked** (PRODUCT_SPEC §10.5 mitigation 2). This is a measurement-integrity requirement, not a nicety.
  - Report control on every unlocked deal (AC15.1) with the fixed reason set (AC15.2).
- **Testing requirements:** Timed manual test on a real phone from unlocked deal to saved purchase, recorded in the PR with the actual seconds. Component tests for the unmarked-unlock banner appearing at the 48-hour boundary and not before.
- **Priority:** P0

---

## T33 — Admin console

- **Goal:** The founder can run curation, review matches, publish, retire, refund and compare predicted versus actual (F16).
- **Agent:** Frontend Engineer
- **Dependencies:** T20, **T20A**, T24, T28
- **Files / areas:** `src/app/admin/**`, `src/components/admin/*`
- **Acceptance criteria:**
  - Access gated by a **server-side role check** and a separate layout. **No client-side hiding** (AC16.1).
  - Provides: market/marketplace reference view, fee/tax schedule management, ingestion upload and run history · match review queue with approve/override/reject · **draft queue** with deal preview before publish · publish and retire · report queue · credit adjustment · predicted-vs-actual view grouped by score band (AC16.2, AC14.6).
  - **Publish and retire call T20A. The console issues no `deals.status` write of its own** — the authorization decision lives in one server-side place, not behind a button. Retirement requires a reason from T20A's closed set, and the UI surfaces T20A's business-rule errors (an illegal transition, a pair that already has a live deal) as clear messages rather than a 500.
  - The draft queue is the only surface where a non-active deal is visible, and it is admin-only.
  - **The match review UI surfaces the pack-size discrepancy from title and weight before publish** (AC4.5), prominently, using the `packSizeSuspicion` signal from T18. This is the single highest-value screen in the console.
  - Retiring a deal removes it from user feeds **within 60 seconds** (AC3.6).
  - Every admin credit adjustment writes a ledger row with reason `admin_adjust` and an actor reference (AC16.3).
  - Fee and tax schedules editable through the console and **versioned** — editing creates a new version, never mutating the current one (AC16.4).
  - Deal preview renders the exact user-facing locked and unlocked views, so the founder verifies what a user will actually see.
- **Testing requirements:** Test that a non-admin session receives 403 on every admin route and API. Test that a fee schedule edit creates a new version and leaves existing deals' `fee_schedule_version` untouched. Manual: publish and retire a deal, timing the feed disappearance.
- **Priority:** P0

---

# PHASE 5 — PAYMENTS (T34–T36)

> P0-late. Ships weeks 5–6. **If it slips, beta proceeds on manual credit grants** and Stripe lands mid-beta. Its absence must never block beta week 1.

---

## T34 — Stripe Checkout and credit packs

- **Goal:** `POST /billing/checkout` and the credits purchase screen (F17, first half).
- **Agent:** Integration Engineer
- **Dependencies:** T23, T28
- **Files / areas:** `src/services/billing/{checkout.ts,packs.ts}`, `src/app/api/v1/billing/checkout/route.ts`, `src/app/(app)/credits/*`
- **Acceptance criteria:**
  - **Stripe Checkout (hosted) only.** No Elements, no custom card form, no saved-card UI, no PCI surface.
  - Server resolves user/market currency, validates the pack and active currency price, creates a `credit_purchases` row with status `pending`, then creates the Checkout Session with `client_reference_id = userId` and metadata `{ userId, packId, purchaseId }`.
  - **Credit quantity is read from `credit_packs`; amount and Stripe Price ID are read server-side from `credit_pack_prices` for the user's resolved currency.** No client-supplied price or quantity is ever trusted (AC17.4).
  - Credits screen shows balance, packs, and full ledger history with reasons (F20).
  - Success page **polls the balance** rather than asserting success from the redirect (AC17.6).
  - Test mode throughout; live keys are a separate deployment step in T39.
- **Testing requirements:** Test that tampered client currency/price/credit count is ignored in favour of server-resolved market currency and database values. Test that an inactive pack is rejected. Manual: complete a test-mode purchase end to end.
- **Priority:** P0 (late)

---

## T35 — Stripe webhook, credit fulfilment, refunds and reconciliation

- **Goal:** Credits granted exactly once, by the webhook, forever (F17, second half). Financial integrity lives here.
- **Agent:** Integration Engineer
- **Dependencies:** T34
- **Files / areas:** `src/services/billing/webhook.ts`, `src/app/api/v1/billing/webhook/route.ts`, `src/app/api/cron/reconcile/route.ts`
- **Acceptance criteria:**
  - **Credits are granted only by the verified webhook, never by the success redirect** (AC17.1). The redirect is cosmetic and forgeable.
  - Signature verified against the **raw request body**; body parsing disabled on that route (AC17.2).
  - Idempotency at two layers: `stripe_webhook_events` primary key (duplicate ⇒ 200 no-op) **and** `credit_ledger.idempotency_key = event.id` (AC17.3).
  - Handles `checkout.session.completed` → `grant_credits` → mark `credit_purchases` paid.
  - Handles `charge.refunded` and `charge.dispute.created` → deduct credits, **permitting a negative balance**; block spend, never erase history (AC17.5).
  - Route is unauthenticated by design and exempt from rate limiting, but signature-gated and replay-protected.
  - Nightly reconciliation cron asserts `sum(credit_ledger.delta) == profiles.credit_balance` for **every** user and alerts on any mismatch (AC10.8, §11.4).
  - Nightly reconciliation of `credit_purchases` against Stripe **per currency**.
  - Fails **closed** on any ambiguity: abort, do not grant, log loudly (§12.2 principle 2).
- **Testing requirements:** **Stripe CLI replay of the same event 5× grants credits exactly once** — this is a release gate (AC17.3). Test an invalid signature is rejected with no state written. Test a refund taking a balance negative and blocking a subsequent spend. Test the reconciliation job detecting a deliberately introduced mismatch and alerting.
- **Priority:** P0 (late)

---

## T36 — Security review #3: payments and financial integrity

- **Goal:** Independent verification of the payment path before real money moves.
- **Agent:** Code Reviewer / Security Reviewer
- **Dependencies:** T34, T35
- **Files / areas:** Review only.
- **Acceptance criteria:**
  - Independently replays webhooks via the Stripe CLI and confirms exactly-once granting.
  - Confirms **no code path grants credits outside the webhook**, by tracing every `grant_credits` caller.
  - Confirms raw-body signature verification cannot be bypassed by a body-parsing middleware or framework default.
  - Confirms the success redirect grants nothing and that forging it changes no state.
  - Confirms price, currency and credit quantities are never trusted from the client.
  - Confirms reconciliation covers refunds, chargebacks and admin adjustments.
  - Confirms `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` are absent from the client bundle.
  - Written findings; **any P0 finding blocks Gate B.**
- **Testing requirements:** Reviewer attempts at least three concrete attacks — forged redirect, replayed event, tampered pack/currency payload — and documents the outcome of each.
- **Priority:** P0 (late)

---

# PHASE 6 — QUALITY AND LAUNCH (T37–T40)

---

## T37 — Legal pages, disclaimers and global privacy baseline

- **Goal:** F21. Non-negotiable before any real user sees a profit figure.
- **Agent:** Frontend Engineer
- **Dependencies:** T28, T30
- **Files / areas:** `src/app/(marketing)/{terms,privacy,refund-policy}/page.tsx`, `src/components/layout/Disclaimer.tsx`, `src/app/(app)/settings/data/*`
- **Acceptance criteria:**
  - Terms of service, privacy policy and refund policy published and linked from the footer and from signup (AC21.1).
  - **"Estimates, not guarantees. Not financial or tax advice." appears on every screen displaying a profit figure** (AC21.2) — enforced by a shared component, and by a test that fails if a profit-rendering screen omits it.
  - Gating and eligibility warning on every unlocked deal (AC21.3).
  - GDPR-grade baseline: data export and account deletion available from settings; market-specific notices are content/configuration added before each market opens (AC21.4, AC1.5).
  - The refund policy is published and linked from the unlock button and the credits page (AC15.5).
  - Language uses "estimate" and "opportunity" only. **The words "guaranteed", "guaranteed return" and "investment" do not appear anywhere in the product copy** — enforced by a CI copy-lint (risk #12).
- **Testing requirements:** Automated test enumerating every route that renders a profit figure and asserting the disclaimer component is present. CI grep for prohibited copy. Manual: complete a data export and an account deletion.
- **Priority:** P0

---

## T38 — QA: end-to-end mobile, performance and error-handling pass

- **Goal:** A full adversarial pass over the assembled product on real hardware, before launch tasks begin.
- **Agent:** QA Engineer
- **Dependencies:** T31, T32, T33, T35
- **Files / areas:** `tests/integration/*`, `docs/QA-REPORT.md`
- **Acceptance criteria:**
  - **Full critical path completed on a real phone by someone other than the founder** (Gate B): sign up → onboard → feed → locked detail → unlock → unlocked detail → adjust assumptions → record purchase → record outcome.
  - Feed loads in **under 2 seconds on a mid-range Android phone over 4G**, measured on device (AC8.5, Gate B).
  - Every §12.1 error class is deliberately triggered and its UI verified: validation, auth, 404, `INSUFFICIENT_CREDITS`, `ALREADY_UNLOCKED`, `DEAL_EXPIRED`, `MARKET_NOT_LIVE`, `CURRENCY_MISMATCH`, 429, Keepa unavailable, internal 500.
  - **Marketplace-provider outage behaviour verified (Keepa in MVP): cached deal served with a clear staleness banner. No fabricated number, ever** (§12.2 principles 3 and 4).
  - Every screen verified at 375px with no horizontal scrolling.
  - A written QA report is committed listing every defect found, with severity. **No P0 defect may remain open.**
- **Testing requirements:** This task is the test. Video or screenshots of the full path on device attached. Defects raised as individual issues, not fixed inline in this task.
- **Priority:** P0

---

## T39 — Production environment, observability, deployment and runbook

- **Goal:** A production deployment that can be operated and debugged by one person at 11pm.
- **Agent:** Backend Engineer
- **Dependencies:** T35, T37
- **Files / areas:** `next.config.ts` headers, `src/lib/logger.ts`, `src/services/analytics/`, `docs/RUNBOOK.md`, Vercel and Supabase production configuration
- **Acceptance criteria:**
  - Separate production Supabase project and Vercel production environment; all secrets set as production environment variables; **no secret shared between preview and production**.
  - Stripe live mode keys configured and the live webhook endpoint registered and verified.
  - Security headers configured: CSP, HSTS, `X-Content-Type-Options`, `Referrer-Policy` (§11.3).
  - Sentry live on client and server; the founder is alerted on error spikes (Gate B).
  - Structured logging with `requestId` correlation; **no secret, token, session or PII is ever logged**.
  - `app_events` instrumented for the §9.3 funnel only: signup, onboarding complete, first deal detail viewed, unlock, purchase recorded, outcome recorded, pack purchased. **No generic analytics sprawl.**
  - All cron jobs registered and verified in production: `ingest`, `refresh-listings`, `recompute-deals`, `reconcile`; ingestion/refresh/recompute jobs are market-scoped. Each protected by `CRON_SECRET`.
  - Alerting on: provider daily quota cap reached, reconciliation mismatch, error rate spike, cron failure.
  - **`docs/RUNBOOK.md` written and complete** for: bad deal published · marketplace-provider outage (Keepa in MVP) · Stripe webhook failure · credit reconciliation mismatch · rollback procedure (Gate B).
- **Testing requirements:** Deliberately trigger each alert in production and confirm the founder receives it. Verify security headers with an external scanner. Verify a production error reaches Sentry with a usable stack trace and correlates to a `requestId`. Confirm no secret appears in any log line.
- **Priority:** P0

---

## T40 — Beta readiness: Gate A and Gate B checklist execution

- **Goal:** Formally close out every release criterion in `PRODUCT_SPEC.md` §12.1 and §12.2 before a single external user arrives.
- **Agent:** QA Engineer
- **Dependencies:** T36, T38, T39
- **Files / areas:** `docs/RELEASE-CHECKLIST.md`, `docs/QA-REPORT.md`
- **Acceptance criteria:**
  - **Gate A** signed off item by item: 15+ pricing cases pass · launch-market tax-regime cases verified **by someone other than the author** · redaction leak test green and blocking CI · concurrency test green · ledger append-only verified at database level · scoring determinism verified · RLS default-deny verified · no secret in the client bundle · rate limits live · security headers set.
  - **Data readiness:** 60+ published deals in the chosen launch market across ≥3 retailers and ≥4 marketplace categories (AC3.5); **100% manually spot-verified** for correct marketplace listing, correct pack size, live retailer link and live price; launch-market fee and tax schedules verified against current sources with the verification date recorded.
  - **Market readiness:** exactly one MVP market is live; its currency/tax/fee/provider/Stripe/retailer-supply checks are complete; a synthetic second market has been seeded/resolved without business-logic changes.
  - **The reality check:** the founder has personally bought **at least 5 deals from the app with their own money** and the actual outcomes are recorded. *Do not put this product in front of a user until you have taken your own advice and it worked.*
  - **Gate B** signed off: legal pages live · disclaimers present on every profit screen · Sentry live · admin console operational · runbook written · feed under 2s on device · full flow completed by someone other than the founder · support channel live with a stated response commitment · **15 deals/week curation capacity confirmed and calendared** · Stripe verified in test mode.
  - Every unchecked item is either completed or explicitly waived in writing with a named reason. **No silent waivers.**
- **Testing requirements:** This task is the verification. Output is a signed checklist committed to the repo with dates and the name of whoever verified each item.
- **Priority:** P0

---

# PHASE 7 — P1 (T41–T44)

> Ship during beta **only if the P0 loop is stable**. If week 5 is not calm, these do not ship, and nothing is lost.

---

## T41 — Watchlist (API and UI)

- **Goal:** F18. Save, list, remove an unlocked deal.
- **Agent:** Backend Engineer, then Frontend Engineer
- **Dependencies:** T30
- **Files / areas:** `src/app/api/v1/watchlist/route.ts`, `src/services/watchlist/`, `src/app/(app)/watchlist/page.tsx`
- **Acceptance criteria:**
  - `GET`, `POST`, `DELETE` on `/api/v1/watchlist`, RLS-backed, own rows only.
  - Unique `(user_id, deal_id)`; adding twice is a no-op, not an error.
  - Watchlist page shows saved deals with their **current** figures and flags any that have moved materially since saving.
  - Watchlisted deals enter the more frequent marketplace-provider refresh tier (§10.1).
  - **No alerts, no notifications.** A watchlist without alerts is a bookmark, and that is all this is at P1.
- **Testing requirements:** Cross-user access denied. Duplicate add is idempotent. Removing a deal another user watchlisted does not affect them.
- **Priority:** P1

---

## T42 — Barcode lookup

- **Goal:** F19. Scan or type a barcode in a shop, get a launch-market Amazon profit estimate through the generic marketplace path.
- **Agent:** Frontend Engineer, with Integration Engineer for the adapter path
- **Dependencies:** T17, T18, T23, T28
- **Files / areas:** `src/app/(app)/scan/page.tsx`, `src/components/scan/*`, `src/app/api/v1/barcode/lookup/route.ts`, `src/services/barcode/`
- **Acceptance criteria:**
  - Browser `BarcodeDetector` where available, with a manual entry fallback always visible.
  - Barcode is normalised to canonical GTIN-14, then resolved through the active market's `MarketplaceAdapter` (Amazon/Keepa in MVP).
  - User enters shelf price in the active market currency; cross-currency lookup is rejected.
  - Charges 1 credit only on a successful resolve. Failed lookup costs nothing.
  - Idempotency key required; result stores market ID, raw barcode, GTIN-14 and resolved marketplace product ID.
  - Rate limited to 20/min.
  - Camera permission denial handled gracefully.
  - Core barcode service contains no marketplace external ID-specific assumptions.
- **Testing requirements:** Real UPC/GTIN barcodes on supported devices; canonicalisation test; failed resolve writes no ledger row; permission-denied path; cross-currency rejection.
- **Priority:** P1

---

## T43 — PWA shell

- **Goal:** F22. Manifest, icons, add-to-home-screen, cached app shell.
- **Agent:** Frontend Engineer
- **Dependencies:** T28
- **Files / areas:** `public/manifest.json`, `public/icons/*`, service worker configuration
- **Acceptance criteria:**
  - Manifest, icon set, theme colour, add-to-home-screen prompt.
  - Service worker caches the app shell and the last-fetched feed only.
  - **No offline writes, no background sync, no push notifications** (§4.4).
  - Installs and launches standalone on Android and iOS.
  - The service worker never caches an unlocked deal payload beyond the session, and never caches an authenticated API response.
- **Testing requirements:** Install on a real Android and a real iOS device. Verify that going offline shows the cached shell with a clear offline state, and that no locked-deal identity or authenticated marketplace payload is present in any cache entry.
- **Priority:** P1

---

## T44 — Outcome email prompt automation

- **Goal:** F23. Automate the T+14 outcome nudge only if manual chasing proves unsustainable.
- **Agent:** Backend Engineer
- **Dependencies:** T24, T39
- **Files / areas:** `src/app/api/cron/outcome-prompts/route.ts`, `src/services/notifications/`
- **Acceptance criteria:**
  - Daily cron identifies purchases with `outcome = 'pending'` at T+14 and sends one email with a direct link to record the outcome.
  - **Maximum one email per purchase.** No sequences, no drip, no re-nudging.
  - Unsubscribe honoured.
  - **Build this only if manual founder emails at 35 users have proven unsustainable.** At beta scale the manual version doubles as qualitative research and is the better option — do not automate away a research channel to save an hour.
- **Testing requirements:** Test the T+14 boundary either side. Test that a purchase already given an outcome receives nothing. Test that no purchase can receive two emails.
- **Priority:** P1

---

# NEXT 5 TASKS TO EXECUTE

**Completed:** T01 (repo, CI, deploy) · T02 (Supabase, clients, migrations) · T03 (11 core tables, 9 enums, RLS enabled, privileges normalised — ADR-004).

Give these to coding agents in this exact order. Do not start one until the previous task's acceptance criteria are verified.

### 1. T04 — Market-scoped deals and user activity schema
**Agent:** Database Engineer · **Depends on:** T03  
Create the central `deals` model plus unlock/watchlist/purchase/barcode records, all market- and currency-aware, with declarative cross-market consistency enforcement and the full column set enumerated in the task.  
*Why first:* feed isolation, pricing snapshots and future marketplace support depend on getting the read model right now — and a cross-market deal is a user in one country seeing another country's price.

### 2. T05 — Credits, per-currency billing and operational logs
**Agent:** Database Engineer · **Depends on:** T03  
Create the append-only ledger, currency-neutral packs, per-currency pack prices, webhook events and market/provider operational logs.  
*Why second:* this makes credits global without making every unlock price country-specific.

### 3. T05A — Temporal integrity constraints on versioned schedules
**Agent:** Database Engineer · **Depends on:** T03 · **Blocks:** T08  
Exclusion constraints preventing overlapping effective ranges on `tax_schedules` (per country) and `fee_schedules` (per marketplace), with `[)` semantics and correct open-ended handling.  
*Why third:* it must exist before T08 seeds a single schedule row, and it permanently removes a class of silent, market-wide wrongness (risks #2 and #3).

### 4. T06 — RLS policies, SQL grants and append-only enforcement
**Agent:** Database Engineer · **Depends on:** T03, T04, T05, T05A  
Every policy paired with its minimum matching grant, every grant paired with its policy, service-role-only tables explicitly granted nothing, ledger immutability enforced by trigger.  
*Why fourth:* after T03's normalisation, a policy without a grant is inert and a grant without a policy is a leak. This is the task where that correspondence is established for the whole schema.

### 5. T07 — Atomic credit RPCs (`spend_credits`, `grant_credits`)
**Agent:** Database Engineer · **Depends on:** T05, T06  
Race-free, idempotent, `SECURITY DEFINER`, with `EXECUTE` revoked from `PUBLIC`/`anon`/`authenticated` and granted only to `service_role`.  
*Why fifth:* every later money path depends on this being the only way credits move.

**After these five:** T08 (global seed + one launch market) → T09 (RLS/privilege QA) → T10 (auth/onboarding) → T11 (security review).  
Do not begin the deal engine until T11 has no open P0 findings.
---

## Appendix — Task index

| Phase | Tasks | Priority |
|---|---|---|
| 1. Foundation | T01–T11 (incl. T05A) | P0 |
| 2. Deal engine | T12–T20 | P0 |
| 3. Core APIs | T21–T27 | P0 |
| 4. Frontend | T28–T33 | P0 |
| 5. Payments | T34–T36 | P0 (late) |
| 6. Quality and launch | T37–T40 | P0 |
| 7. Deferred | T41–T44 | P1 |

**Security reviews:** T11 (auth, RLS, secrets) · T26 (credits, unlock, redaction) · T36 (payments).
**QA checkpoints:** T09 (RLS) · T15 (pricing) · T27 (pipeline) · T38 (mobile and errors) · T40 (release gates).

**Not in this plan, by design:** automated scraping · affiliate feed adapters · SP-API · seller-specific gating checks · portfolio P&L · push notifications · local sourcing maps · AI assistant · fuzzy matching · subscriptions · CSV export · additional marketplace integrations · simultaneous multi-market launch · cross-border/FX arbitrage · native apps · Python services · 3PL workflow. See `PRODUCT_SPEC.md` §8 for the reason and the revisit condition for each.

---

*End of document. Any change to a task's scope, or to a P0 boundary, belongs in `docs/DECISIONS.md` as an ADR — and none of it changes silently.*
