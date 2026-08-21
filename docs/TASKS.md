# TASKS.md

**Project:** Global Retail-to-Marketplace Arbitrage App
**Document owner:** Technical Project Manager
**Version:** 2.5 — global-first, marketplace-agnostic, Amazon-first MVP
**Source documents:** `ARCHITECTURE.md` v2.0 (technical contract) · `PRODUCT_SPEC.md` v2.0 (scope contract)
**Status:** In execution. **T01–T09 complete. T10 is implemented and deployed but NOT closed** — two acceptance criteria remain unverified (see T10). **T11 does not start until both pass.** ADR-0017 records how T10 solved account deletion; it is not evidence that T10's acceptance criteria were verified. **T11's review has produced findings and a hardening pass has landed (ADR-0019); T11 is not complete and T10 is not closed by it.**

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

## Changelog: v2.4 → v2.5

Product-review pass, recorded as **ADR-0018**. **No priority changes to any existing task. No schema, privilege or policy changes. T01–T09 are untouched, and T10's shipped scope is untouched.** Every item lands inside a task that has not yet been built, or in the new P1 follow-up **T10A**.

**The review ran while T10 was still in verification.** T10's implementation is deployed; two of its acceptance criteria are not yet verified. Nothing in this pass closes T10, and nothing in this pass is a T10 acceptance criterion.

- **The locked view bands its raw inputs; exact values are withheld.** As previously specified, `AC9.1` *required* a leak: category + exact rank + exact offer count + exact buybox is a fingerprint recoverable from Keepa in seconds, with no credit spent. `AC9.1` amended; T21 gains the banding rules and a **numeric-fingerprint test** — its existing name-based deny-list would have passed a fully identifying payload.
- **T22 gains a filter granularity floor** (profit to units of 5, ROI to 10 points, score to bands of 10), closing the same hole from the query side.
- **Unlock count shown on locked deals** (new `AC9.7`) — a real competition signal, and it makes a leaked deal self-limiting.
- **Unlock pricing settled: flat 1 credit.** Variable pricing by capital deployed was proposed and rejected as unenforceable — unlock is a one-time reveal and post-unlock behaviour is invisible. Recorded as a constraint so the design is not re-derived later.
- **Repeatability** added to T16 as a bounded modifier, explicitly **not** a sixth weighted component.
- **Added T10A — signup abuse refusal and prep-cost onboarding defaults.** A **separate P1 task**, sequenced after T10 closes, **not** a widening of T10 and **not** retroactively part of T10's scope: disposable-domain refusal on the signup grant, and prep-cost defaults in onboarding (Amazon ended European FBA prep on 1 July 2026 and most beginners do not know their real per-unit rate). T10 is verified against the criteria it shipped against; T10A is judged on its own.
- **T40 gains a competitor benchmark**, making the Deal Score falsifiable before launch.
- **T41 reframed** as monitoring rather than bookmarking. Same scope.
- **Five product ideas parked with explicit triggers** in the appendix, including community-sourced in-store deals and retailer data feeds.

---

## Changelog: v2.3 → v2.4

T08 execution decisions, recorded as **ADR-0015**. **No product scope changed. No priority changed. No task was removed. No migration was added.** T01–T07 outcomes are untouched.

- **The launch market is named for the first time: GB / `amazon_uk` / GBP.** Every document assumed it via examples; none recorded it. `PRODUCT_SPEC.md` keeps saying "the chosen launch market" on purpose, so the choice belongs in an ADR rather than there.
- **`surcharges.basis` widened from `referral_fee|sell_price|flat` to add `fulfilment_fee` and `selling_fees`, plus an optional `applies_to_categories`.** `ARCHITECTURE.md` §2.2 is amended to match. The launch market's Digital Services Fee applies to selling *and* fulfilment fees and the fuel surcharge applies to fulfilment fees alone; neither fits the old vocabulary, and forcing them onto `referral_fee` understates cost and so overstates profit. **T14 must implement all five bases and throw on an unknown one.**
- **T08 seed data is a local/ephemeral baseline and was deliberately not applied to the hosted development project.** `supabase db push` carries migrations only unless `--include-seed` is passed.
- **Credit pack prices are provisional planning values** pending `PRODUCT_SPEC.md` open question 3. Safe to be wrong because `stripe_price_id` stays NULL until T34, so no client can read them.

---

## Changelog: v2.2 → v2.3

T05 planning decisions, taken before T05 begins and recorded as **ADR-0010**. **No product scope changed. No priority changed. No task was removed.** T01–T04 and the ADR-0009 deal lifecycle (`draft | active | retired`) are untouched.

- **`chargeback` added to the credit reason enum**, and the two reversal reasons are separated: `refund` is a **positive** restoration (confirmed bad deal), `chargeback` is a **negative** Stripe reversal/clawback.
- **`credit_ledger` immutability is enforced twice and owned by T05** — the append-only trigger *and* `REVOKE UPDATE, DELETE FROM service_role`. T06 now **verifies** it rather than creating a second trigger.
- **`stripe_webhook_events` is explicitly not immutable.** Identity, type, payload and `received_at` are frozen; `processed_at` and `error` are writable. The restricted-UPDATE trigger is T06's; `DELETE` is revoked from `service_role` in T05.
- **Financial records survive account deletion.** `credit_ledger.user_id` and `credit_purchases.user_id` are `ON DELETE RESTRICT`. T10's account deletion becomes pseudonymisation of retained financial rows; **the mechanism is left as an explicit T10 decision.**
- **`stripe_price_id` is nullable and seeded NULL** (T05, T08) because T08 runs weeks before T34. Placeholder Stripe IDs are prohibited. T06's public-read predicate for `credit_pack_prices` becomes `active = true AND stripe_price_id IS NOT NULL`.
- T05 gained explicit column constraints (`idempotency_key NOT NULL UNIQUE`, `delta <> 0`, `balance_after NOT NULL`, money/currency invariants, `credits > 0`, `amount_minor > 0`), an explicit index list, a no-PII rule on `app_events.properties`, and an acceptance test list that distinguishes privilege failures from trigger failures.

---

## 0. How to use this document

47 tasks: **T01–T40 (including T05A and T20A) are P0** (beta cannot start without them), **T10A and T41–T44 are P1** (ship during beta only if the P0 loop is stable). P2 items from `PRODUCT_SPEC.md` §5.3 appear nowhere in this plan by design.

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

# PHASE 1 — FOUNDATION (T01–T11, including T05A; plus the P1 follow-up T10A)

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

## ✅ T05 — Schema C: credits, multi-currency billing and operational logs

> **Status: COMPLETE.**

- **Goal:** Create the currency-neutral credit ledger, per-currency pack pricing, and market-aware operational logs — with ledger immutability and financial-record retention established here rather than deferred.
- **Agent:** Database Engineer
- **Dependencies:** T03
- **Files / areas:** `supabase/migrations/*_schema_c.sql`, `src/types/database.ts`
- **Acceptance criteria:**

  **`credit_ledger` — the source of truth for money**
  - Columns per ARCHITECTURE.md §2.3: `id`, `user_id`, `delta`, `reason`, `ref_type`, `ref_id`, `balance_after`, `idempotency_key`, `created_at`.
  - **The `reason` enum is `signup_grant | purchase | unlock_deal | barcode_lookup | refund | chargeback | admin_adjust | promo`.** `chargeback` is added in v2.3 (ADR-0010), and the two reversal reasons are **not** interchangeable:
    - **`refund` is a positive restoration** — a credit given back to the user, typically after a confirmed bad deal (AC15.4). `delta > 0`.
    - **`chargeback` is a negative clawback** — credits removed because Stripe reversed the payment that created them (`charge.refunded`, `charge.dispute.created` — AC17.5, §9.2). `delta < 0`, and the resulting balance may go negative.
    - Collapsing the two would make the "credit refunds issued" trust-damage metric (`PRODUCT_SPEC.md` §9.4) count payment disputes as product goodwill, and would leave the T35 reconciliation unable to distinguish a product failure from a payment failure. The sign is not sufficient to tell them apart later: an `admin_adjust` can also be negative.
  - **`idempotency_key` is `NOT NULL` and `UNIQUE`.** Nullable would defeat the guard entirely — several NULLs do not conflict in a unique index, so every unkeyed write would pass. T07's "same key twice charges once" and T35's exactly-once webhook fulfilment both rest on this column being mandatory.
  - **`CHECK (delta <> 0)`.** A zero-delta row is either a bug or a no-op that silently consumes an idempotency key.
  - **`balance_after` is `NOT NULL` and may be negative** — AC17.5 requires a chargeback to take the balance below zero rather than erase history. No non-negative check.
  - **`created_at timestamptz NOT NULL DEFAULT now()`.**
  - **`user_id` references `profiles (id)` `ON DELETE RESTRICT`** — deliberately not the `ON DELETE CASCADE` that T04 uses for user activity tables. Financial history is retained for audit and reconciliation and does not belong to the user's personal-data footprint in the way a watchlist item does (ADR-0010). **Consequence, stated so it is not discovered in T10:** because `profiles.id` cascades from `auth.users`, a plain `delete from auth.users` will fail with `23503` while any ledger row exists. Account deletion therefore becomes a pseudonymisation problem, owned by T10 — this task does not invent that mechanism.
  - **Append-only, enforced at two independent layers:**
    - (a) A `BEFORE UPDATE OR DELETE` row trigger on `credit_ledger` that raises unconditionally. **This trigger is created here, in T05** — not in T06. It belongs with the table it protects, so the table is never reachable in a mutable state, not even between two migrations.
    - (b) **`REVOKE UPDATE, DELETE ON public.credit_ledger FROM service_role`**, so the role our own server code runs as holds only the ledger privileges it actually needs: `SELECT` and `INSERT`. This is a deliberate narrowing of the blanket table-DML grant ADR-0006 established, and the migration header says so.
    - Neither layer makes the other redundant: the revoke stops our own admin client and anything holding the service-role key; the trigger stops a role that *does* hold UPDATE (the migration owner, a future support script, a dashboard session). AC10.5 says the database rejects it — one layer would leave that true only by accident of privilege.
  - Index `(user_id, created_at desc)`.

  **`credit_purchases`**
  - **`user_id` references `profiles (id)` `ON DELETE RESTRICT`**, for the same reason as the ledger: purchase history is reconciliation evidence against Stripe.
  - Nullable **`credit_pack_price_id`** FK → `credit_pack_prices (id)`, recording *which* per-currency price the purchase was made at. Nullable because a price row can be retired and because manual/admin grants have no price row.
  - Nullable **`stripe_customer_id`**.
  - **`stripe_payment_intent_id` is nullable and `UNIQUE`** — absent until Stripe confirms, and never shared by two purchases once present.
  - **`credits`, `amount_minor` and `currency` are immutable purchase snapshots**, not lookups: what the user bought and paid, frozen at purchase time, so re-pricing a pack later cannot rewrite what was sold. `status` and `completed_at` remain mutable — the row records a process, and only these fields describe its progress.
  - Project money/currency invariants apply: `amount_minor bigint`, `currency` FK → `currencies` and `NOT NULL` alongside it, `CHECK (amount_minor > 0)` (§11.2 — a currency-free or currency-ambiguous amount must be impossible at the storage layer).
  - `stripe_checkout_session_id` `UNIQUE`.

  **`credit_packs` / `credit_pack_prices`**
  - Split as before: `credit_packs` carries the credit quantity/value, `credit_pack_prices` carries `(currency, amount_minor, stripe_price_id, active)`, unique per `(credit_pack_id, currency)`.
  - **`CHECK (credit_packs.credits > 0)`** and **`CHECK (credit_pack_prices.amount_minor > 0)`**. A free or negative pack is not a product.
  - `credit_pack_prices.currency` is an FK to `currencies` and `NOT NULL`.
  - **`stripe_price_id` is nullable**, because **T08 seeds pack prices weeks before T34 creates anything in Stripe**. A `NOT NULL` column here would force T08 to invent a placeholder, and a fake Stripe ID that reaches a Checkout call fails at the worst possible moment. T06 makes the nullability safe rather than merely tolerated: a price is publicly readable only when `active = true AND stripe_price_id IS NOT NULL`.

  **`stripe_webhook_events`**
  - `stripe_event_id` is the PK (the first of the two idempotency layers, AC17.3).
  - Records `type`, `payload jsonb`, **`received_at` (`NOT NULL DEFAULT now()`)**, **`processed_at` (nullable — null means received but not yet fulfilled)**, and `error`.
  - **This row is deliberately *not* immutable.** Unlike the ledger, it describes a process with an outcome that is written after the fact. T05 creates it plainly mutable; **T06 adds the restricted UPDATE protection** permitting changes to **`processed_at` and `error` only**, with `stripe_event_id`, `type`, `payload` and `received_at` immutable. Do not add a blanket immutability trigger here — it would make the table unusable by T35 and would be removed by the next task.
  - **`REVOKE DELETE ON public.stripe_webhook_events FROM service_role`.** Nothing in the design deletes an event: the row *is* the replay protection, and deleting one re-opens the duplicate-grant window. Consistent with the same narrowing applied to `credit_ledger`; `INSERT`, `SELECT` and `UPDATE` remain.

  **Operational logs**
  - `api_usage_log` records provider, `marketplace_id`, endpoint, units/tokens, estimated cost, cost currency, status and latency.
  - `ingestion_runs` includes `market_id`.
  - `app_events` includes `market_id`.
  - **`app_events.properties` is documented, in a column comment, as carrying no PII** — no email address, no name, no free text typed by a user, no raw barcode. It is an event-shape bag for funnel questions (§9.3), it is the least governed column in the schema, and "GDPR-grade baseline for everyone" (§11.5) is not maintainable if arbitrary personal data can arrive here through a helper someone wrote in T25. The rule is written where the next author will see it.

  **Indexes — required explicitly, not left to judgement**
  - `credit_ledger (user_id, created_at desc)`
  - `credit_purchases (user_id, created_at desc)`
  - `credit_purchases (status)`
  - `api_usage_log (provider, created_at desc)`
  - `api_usage_log (marketplace_id, created_at desc)`
  - `ingestion_runs (market_id, started_at desc)`
  - `app_events (event, created_at desc)`
  - `app_events (user_id, created_at desc)`

  **Privilege posture — v2.1 (ADR-004, global rule 8), narrowed in v2.3 (ADR-0010)**
  - No privileges granted to `anon` or `authenticated` by this migration; any Postgres or Supabase default grant on the new tables **and their sequences** is revoked in the same migration; the migration states its posture in a header comment. This applies to `credit_packs` and `credit_pack_prices` too — their public-read grants belong to T06, alongside their policies, not here.
  - `service_role` receives table DML **except** where narrowed above: **no `UPDATE` or `DELETE` on `credit_ledger`, no `DELETE` on `stripe_webhook_events`.** The header comment names both narrowings and why, so a later "restore the standard grants" migration cannot undo them by looking tidy.
  - RLS enabled on every new table, no policies yet.
- **Testing requirements:** pgTAP tests in `supabase/tests/database/` proving:
  - **`service_role` cannot UPDATE `credit_ledger`** — asserted as a *privilege* error.
  - **`service_role` cannot DELETE `credit_ledger`** — asserted as a *privilege* error.
  - **The append-only trigger independently rejects UPDATE and DELETE when exercised as a role that holds the privilege** (the migration owner, not `service_role`), so the test proves the trigger fires rather than re-proving the revoke. A test that only ever runs as `service_role` cannot tell the two mechanisms apart, and would pass unchanged if the trigger were dropped.
  - `delta = 0` is rejected.
  - A NULL `idempotency_key` is rejected; a duplicate `idempotency_key` is rejected.
  - Duplicate `stripe_event_id` is rejected.
  - **Deleting a user who has ledger rows is rejected** (`23503` from `ON DELETE RESTRICT`), asserted against `profiles` and against `auth.users`, since the cascade makes the second path fail too.
  - A `credit_pack_prices` row with `stripe_price_id IS NULL` is valid, and readable by `service_role`.
  - The money/currency constraints hold: a negative or zero `amount_minor`, a zero-or-negative `credits`, and an amount without a valid `currency` FK are each rejected.
  - A pack can have GBP and USD prices without duplicating the pack itself.
  - The privileges test asserts the **narrowed** per-table posture, not a blanket `service_role` DML grant — otherwise the revokes above regress silently.
  - Regenerate `src/types/database.ts` against the remote database and commit it.
- **Priority:** P0
- **Completion note:** Schema C (`20260810195812_schema_c.sql`) applied locally from a clean `db:reset` and pushed to the linked development project; local and remote migration history match, and `supabase db diff --linked` reports no schema changes. Eight tables added — `credit_packs`, `credit_pack_prices`, `credit_ledger`, `credit_purchases`, `stripe_webhook_events`, `api_usage_log`, `ingestion_runs`, `app_events` — bringing `public` to 24. Two new enum types (`credit_reason`, carrying `refund` and `chargeback` as separate reasons per ADR-0010, and `credit_purchase_status`); the existing twelve were inventoried first and none was near-duplicated. **`credit_ledger` is append-only at both layers and both are live in the same migration as the table:** a `BEFORE UPDATE OR DELETE` row trigger raising `0A000` (with a `BEFORE TRUNCATE` statement trigger closing the path no row trigger sees), *and* `service_role` holding `SELECT, INSERT` only. The tests exercise the trigger as the migration owner and the revoke as `service_role`, so a privilege failure and a trigger failure cannot be mistaken for each other. `stripe_webhook_events` is deliberately left mutable with `DELETE` revoked from `service_role` and **no trigger**, leaving T06's restricted-UPDATE trigger as the only one that will ever exist there. Both `service_role` narrowings verified on local and remote. Financial retention is `ON DELETE RESTRICT` on `credit_ledger.user_id` and `credit_purchases.user_id`, so deleting an account holding financial rows fails `23503` through `profiles` and through `auth.users` — the pseudonymisation that unblocks it remains T10's. `stripe_price_id` is nullable and no placeholder exists. RLS is enabled on all 24 tables with zero policies; `anon` and `authenticated` hold no privilege of any kind anywhere in `public`, verified on both environments. All eight required indexes exist, no sequence was created, and `app_events.properties` carries its no-PII rule as a column comment. `src/types/database.ts` regenerated from the remote and current. Test suite green: **366 pgTAP assertions** (152 new in `schema_c.test.sql`) plus 50 application tests, with typecheck, lint and build clean.
- **Decisions recorded:** ADR-0011 (Schema C), implementing the ADR-0010 planning decisions. It records four invariants the documents stated in prose and no constraint would have caught — the `refund > 0` / `chargeback < 0` direction check, `UNIQUE` on `stripe_price_id`, a composite foreign key tying a purchase's currency to its price row's currency, and `TRUNCATE` protection on the ledger — and resolves four points where `ARCHITECTURE.md` §2.3 was silent or disagreed with another section: `stripe_checkout_session_id` nullable (§9.2 creates the row before the Checkout Session exists), `app_events.user_id` `ON DELETE SET NULL`, `updated_at` only on the three genuinely edited tables, and `api_usage_log.marketplace_id` nullable.

---

## ✅ T05A — Temporal integrity constraints on versioned schedules

> **Status: COMPLETE.**

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
- **Completion note:** `20260810230623_schedule_temporal_integrity.sql` applied locally from a clean `db:reset` and pushed to the linked development project; all six migrations match local and remote, and `supabase db diff --linked --schema public` reports no schema changes. Two `EXCLUDE USING gist` constraints added — `tax_schedules_no_overlapping_periods` keyed by `country_code` and `fee_schedules_no_overlapping_periods` keyed by `marketplace_id` — both over **`daterange(effective_from, effective_to, '[)')`** inline, with no stored range column and no new table, column, sequence, function or trigger. **`daterange`, not the `tstzrange` ADR-006 offered:** T03 created both period columns as `date`, and a cast to `timestamptz` would invent a timezone for a boundary that must fall on the same calendar day everywhere the schedule applies (ADR-0012). `btree_gist` 1.7 created idempotently in `extensions` — required only by the equality half of each constraint, since GiST indexes ranges natively but not scalars. **T03's `CHECK (effective_to IS NULL OR effective_to > effective_from)` is verified by a `do` block, not duplicated:** it is what keeps the exclusion constraints total, because `daterange(d, d, '[)')` is the *empty* range and would otherwise escape them entirely. Both constraints govern `UPDATE` as well as `INSERT`, which is the path T33's editor takes. **76 new pgTAP assertions** in `schedule_temporal_integrity.test.sql` — 15 tax cases and 16 fee cases covering bounded, adjacent, overlapping, containing, identical, open-ended, second-open-ended, bounded-against-open-ended, gap-filling-adjacent-on-both-edges, degenerate and update paths, plus resolution-query proofs that a key/date returns exactly one row mid-period, on a boundary (the successor, per `[)`), and far in the future — and zero rows in a gap, which the resolver must treat as a missing schedule rather than fall back on. Suite green: **442 pgTAP assertions** (76 new, 366 prior unchanged) plus 88 application tests, with typecheck, lint and build clean. The migration grants nothing and revokes nothing: `anon` and `authenticated` still hold no privilege of any kind in `public`, `service_role` keeps exactly its four DML privileges on both tables, RLS stays enabled with zero policies — verified on local and on remote. `src/types/database.ts` regenerated from the linked project is byte-identical, so it is not recommitted.
- **Decisions recorded:** ADR-0012, which supplies the representation record ADR-006 required and amends ADR-006 and `ARCHITECTURE.md` §2.2 on the range type only. It also documents three things the planning ADR could not have known: that the two tables reject an *identical* period with different SQLSTATEs (`23505` on `tax_schedules`, where T03's `unique (country_code, effective_from)` is checked first; `23P01` on `fee_schedules`, whose unique governs the version *label* — so T33 must map both codes to one message); that the T03 check constraint and the exclusion constraint are one mechanism rather than two; and that `btree_gist`'s support functions keep PostgreSQL's default `PUBLIC` execute grant, as every other extension here does, stated precisely rather than as the acceptance criterion's approximation.

---

## ✅ T06 — RLS policies (default deny) and append-only enforcement

> **Status: COMPLETE.**

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
  - `credit_packs`: policy + `GRANT SELECT`, active rows only.
  - **`credit_pack_prices`: the policy predicate is `active = true AND stripe_price_id IS NOT NULL`** (new in v2.3, ADR-0010). `stripe_price_id` is nullable until T34 populates it (T05, T08), and a price with no Stripe Price ID cannot be bought — surfacing one produces a pricing page whose button leads to a checkout that cannot be created. The database refuses to show an unbuyable price rather than trusting every future caller to filter for it.
  - **`marketplaces` is removed from the public-read set (new in v2.1, ADR-008).** It carries `adapter_key` and `capabilities`, which are integration internals. Nothing in the MVP client needs it: the feed is market-scoped server-side, and currency formatting needs `currencies` and `markets` only. Neither PRODUCT_SPEC nor ARCHITECTURE requires client access to it. If a client need emerges later, expose a view with the specific columns required — do not grant the table.

  **Service-role-only tables** — `deals`, `retailer_products`, `marketplace_products`, `product_matches`, `tax_schedules`, `fee_schedules`, `credit_purchases`, `stripe_webhook_events`, `api_usage_log`, `ingestion_runs`, `app_events`:
  - **No policies and no `anon`/`authenticated` grants of any kind.** Stated explicitly in the migration rather than left implicit, so a reviewer can see the decision was made.

  **Immutability — revised in v2.3 (ADR-0010), because the two tables need different rules:**
  - **`credit_ledger`: verify, do not re-create.** The append-only trigger and the `REVOKE UPDATE, DELETE … FROM service_role` are built in **T05**, with the table they protect. This task asserts both are still in place and does **not** add a second trigger — two triggers with the same purpose means one of them can be dropped without any test going red.
  - **`stripe_webhook_events`: add restricted UPDATE protection, not immutability.** A `BEFORE UPDATE` trigger permits changes to **`processed_at` and `error` only**; any change to `stripe_event_id`, `type`, `payload` or `received_at` raises. The row records event identity *and* processing outcome: the identity is evidence and must never move, the outcome is written after the fact by T35 and must be writable. A blanket immutability trigger here would break webhook fulfilment. `DELETE` is already revoked from `service_role` in T05; the trigger additionally rejects DELETE for any role that holds the privilege.
- **Testing requirements:** T09 covers this formally, but this task ships its own SQL smoke tests proving: (a) the T05 ledger protections are intact — `service_role` UPDATE/DELETE fails with a privilege error, and the trigger still rejects UPDATE/DELETE for a role that holds the privilege; (b) `stripe_webhook_events` accepts an UPDATE that sets `processed_at` and `error`, and rejects one that changes `payload`, `type`, `stripe_event_id` or `received_at`; (c) a `credit_pack_prices` row with `stripe_price_id IS NULL` is **not** visible to `anon`, while an active row with a Stripe Price ID is; (d) for one representative public-read table and one representative user-owned table, the `authenticated` role can actually read the rows it should — a policy that is inert for want of a grant must fail here, not at T09.
- **Priority:** P0
- **Completion note:** `20260810234030_rls_policies_and_grants.sql` applied locally from a clean `db:reset` and pushed to the linked development project; all seven migrations match local and remote, and `supabase db diff --linked --schema public` reports no schema changes. **19 policies and 16 table grants**, every pair written adjacent in one migration section. Public read (`anon` + `authenticated`, `SELECT` only): `countries` `USING (active)`, `currencies` `USING (true)`, `markets` `USING (active AND launch_status = 'live')`, `credit_packs` `USING (active)`, `credit_pack_prices` `USING (active AND stripe_price_id IS NOT NULL)`. User-owned (`authenticated` only): `profiles` SELECT/UPDATE on `id = auth.uid()`, `credit_ledger` SELECT own, `deal_unlocks` SELECT+INSERT, and `watchlist_items` / `purchase_records` / `barcode_lookups` SELECT+INSERT+DELETE, all on `user_id = auth.uid()`. **The thirteen service-role-only tables are named in the migration with a reason each and hold no policy and no grant at table or column level** — `marketplaces` included, per ADR-008. **`credit_balance` is protected by a column-level `GRANT UPDATE` over fourteen named settings columns rather than an update trigger:** it is declarative, it sits in `information_schema.column_privileges` beside every other grant, and it fails at privilege-check time (42501) before the row is read; there is no whole-table `UPDATE` to `anon` or `authenticated` anywhere in the schema. **`deal_unlocks` has neither a DELETE grant nor a DELETE policy**, because AC10.7 makes unlocks permanent — the absent half-pair is the point. **`credit_ledger` is verified, not re-created** (ADR-0010 decision 3): the migration asserts both T05 triggers and both T05 revokes in a `do` block and aborts if either regressed, and adds no second trigger. **T06's own object is `enforce_webhook_event_restricted_update()`** — `SECURITY INVOKER`, `search_path` pinned to `pg_catalog, pg_temp`, owner-only, revoked from `PUBLIC` in the same file — behind a `BEFORE UPDATE OR DELETE … FOR EACH ROW` trigger that permits `processed_at` and `error` (including clearing to `NULL`) and raises `0A000` on any change to `stripe_event_id`, `type`, `payload` or `received_at`, and on any DELETE. **162 new pgTAP assertions** in `rls_policies_and_grants.test.sql`, every negative one naming its mechanism — `42501` for the grant layer, zero rows for the policy layer, `0A000` for a trigger — so a "sees nothing" result can never pass for the wrong reason; they include the full 2×2 of the `credit_pack_prices` predicate, a four-row `markets` fixture (live / beta / planned / inactive), cross-user read, insert, update and delete attempts, an `authenticated` role carrying no JWT subject, and whole-schema catalogue checks that no policy is `FOR ALL`, targets `PUBLIC`, duplicates another policy's command, or exceeds its paired object privilege. Suite green: **612 pgTAP assertions** (162 new; 450 prior, of which twelve baseline assertions across five files were **rescoped rather than deleted** — each had asserted the pre-T06 state in so many words, and each now asserts the post-T06 truth as an exact allowlist) plus 88 application tests, with typecheck, lint and build clean. Verified read-only on remote from `supabase db dump --linked`: 24/24 tables with RLS, the 19 policies with identical predicates, the 16 grants, the fourteen `profiles` column grants with no whole-table UPDATE, `service_role` still `SELECT, INSERT` on `credit_ledger` and `SELECT, INSERT, UPDATE` on `stripe_webhook_events` with no DELETE, all three financial triggers, and `handle_new_user` still the only `SECURITY DEFINER` function in `public`. `src/types/database.ts` regenerated from the linked project is byte-identical — T06 adds no table, column or type — so it is not recommitted.
- **Decisions recorded:** ADR-0013, covering the three things T06 had to decide that no existing document settles: that `currencies` is fully public because the schema has no `active` column to filter on, contrary to the wording of ADR-008 and this task; that `markets` public visibility is `active AND launch_status = 'live'`, the narrowest of the three readings the documents offer; and that a `deal_unlocks` or `barcode_lookups` row is **not** evidence that credits were spent, which constrains T07.
- **Deferred to T09:** `stripe_webhook_events` has no `TRUNCATE` guard, while `credit_ledger` has one (ADR-0011 decision 5). T06 did not add one because T06 does not specify one and inventing a second protection here would have been exactly the "future-proof" object this task's own rules forbid — but the ledger's argument (a revoke says nothing about the migration owner, a support script or a dashboard session, and a row trigger never fires for `TRUNCATE`) applies unchanged to a table whose rows are the replay guard. T09 should decide it deliberately.

---

## ✅ T07 — Atomic credit RPCs (`spend_credits`, `grant_credits`)

> **Status: COMPLETE.**

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
- **Completion note:** `20260811004526_credit_rpcs.sql` applied locally from a clean `db:reset` and pushed to the linked development project; all eight migrations match local and remote, and `supabase db diff --linked --schema public` reports no schema changes. The migration creates **three functions and nothing else** — no table, column, constraint, index, trigger, policy or RLS setting is created or altered, and no row is written. Signatures are `spend_credits(p_user uuid, p_amount integer, p_reason public.credit_reason, p_ref_type text, p_ref_id uuid, p_idem text) → TABLE(new_balance integer, ledger_id uuid)` and `grant_credits` with an identical parameter list, both `SECURITY DEFINER` with `set search_path = public, pg_temp`. **`p_reason` is the `credit_reason` enum rather than §6.5's sketched `text`** (ADR-0014 decision 1): the column it writes is the enum, and a `text` parameter would accept more than its own storage. **ACLs verified against `pg_proc.proacl` on both local and remote** — `postgres=X/postgres,service_role=X/postgres` exactly for both RPCs, with no function anywhere in `public` carrying a NULL `proacl` (a NULL ACL *is* a `PUBLIC` execute grant) and no `anon` or `authenticated` execute grant on any function in the schema. The revoke and the grant sit in the same file as each body, per ADR-004. **`spend_credits` is consumption only** — `p_amount > 0` written as a negative delta, reasons `unlock_deal` and `barcode_lookup`, refusing to overdraw with `23514 INSUFFICIENT_CREDITS`. **`grant_credits` takes a SIGNED amount and is the only function that may end below zero** (ADR-0014 decision 2), because "permits a negative resulting balance (refunds *and chargebacks*)" is unsatisfiable with a positive-only amount; `chargeback` is deliberately not routable through `spend_credits`, where the balance guard would defeat AC17.5. Per-reason direction rules are enforced at the writer **without weakening `credit_ledger_reversal_direction`** — the suite asserts an owner's direct `INSERT` of a negative `refund` or a positive `chargeback` is still refused by the table. Serialisation is `SELECT credit_balance … FOR UPDATE` on the caller's `profiles` row; the ledger insert precedes the balance update so a `23505` on the unique idempotency key aborts a plpgsql sub-transaction with the balance untouched, and the handler resolves the key to the winner's row. Neither function commits — the transaction stays the caller's, which AC10.4 requires. Idempotent identity is `(user_id, delta, reason, ref_type, ref_id)`; an exact match replays the **recorded** `(balance_after, id)` so a replay is deterministic for the life of the row, and any mismatch raises `23505 IDEMPOTENCY_KEY_CONFLICT` (ADR-0014 decision 3). Error codes are distinguishable by design, following `enforce_deal_lifecycle`'s precedent: `23514` insufficient · `22023` validation · `23505` idempotency conflict · `23503` unknown user, each message leading with its stable token. A third function, `credit_ledger_idempotent_match`, holds the single definition of that identity rule; it is `SECURITY INVOKER`, `search_path` pinned, and granted to **nobody at all**, not even `service_role` (ADR-0014 decision 4). **172 new pgTAP assertions** across `credit_rpcs.test.sql` (132) and `credit_rpcs_concurrency.test.sql` (40). **The concurrency gate is real, not simulated:** `dblink` drives genuinely separate backends with every query sent before any result is collected, covering a blocking proof (session A holds an open transaction; B is observed still running 0.5s later, then refused once A commits), AC10.1 (10 concurrent unlocks at balance 1 → exactly one succeeds, balance 0), two concurrent spends of 2 against a balance of 3, and five concurrent retries of one idempotency key (5 successes, all returning the same balance, one ledger row). **It was mutation-checked:** deleting the `FOR UPDATE` makes that file fail fourteen assertions, with AC10.1 landing six successful unlocks and a balance of −5 — and the check corrected the file's own commentary, since B still *blocks* without the lock (the closing `UPDATE` takes the same row) and merely blocks too late. That file is the one place in the suite that commits fixtures rather than rolling back, because a second session cannot see an open transaction; it removes every row it wrote and then proves the append-only guard fires again against a freshly written probe row. Suite green: **784 pgTAP assertions** (172 new; 612 prior, with two catalogue-wide "these are exactly the functions in `public`" sweeps in `schema_b.test.sql` and `schema_c.test.sql` extended by the three new names rather than deleted) plus **106 application tests**, with typecheck, lint and build clean. **No credential appears in committed source.** `dblink` requires a password (`dblink_connect_u`, which would not, is owned by `supabase_admin` and grants `postgres` no EXECUTE), and `supabase test db` offers no channel to pass a session setting — it rebuilds the connection from parsed components inside its own container, so a URL `options=` parameter is discarded and `PGOPTIONS` does not cross the boundary. So `npm run db:test` now runs `scripts/db-test.mjs`, which resolves the password from `supabase status` using the **pinned** CLI in `node_modules`, publishes it as a database-level `t7.db_password` setting, runs `supabase test db` unchanged, and removes the setting in a `finally` that also covers a failing run and Ctrl-C. The password never reaches argv, disk, stdout or stderr: the `ALTER DATABASE` is fed to psql on stdin inside the database container over the socket the local stack trusts, and every diagnostic is redacted. The concurrency file **raises** if the setting is absent rather than falling back to any default, and its first assertion says so by name. A new vitest guard, `tests/unit/supabase/credit-rpcs-are-the-only-writer.test.ts`, asserts T07's "no check-then-deduct logic exists anywhere in application code" statically over `src/`, and pins `supabase/functions/*.sql` to appear **verbatim** inside the migration so the reference copy cannot rot into a confident wrong answer. Verified read-only on remote via `supabase db query --linked`: all three signatures, `prosecdef` true/true/false, `search_path=public, pg_temp` on all three, `has_function_privilege` false for `anon` and `authenticated` on all three and for `service_role` on the helper, zero `PUBLIC` execute grants schema-wide, `credit_ledger` still `INSERT, SELECT` for `service_role` with both append-only triggers enabled, 19 policies unchanged, no client write privilege on `profiles.credit_balance`, and the T06 grant surface unchanged at 5 tables for `anon` and 11 for `authenticated`. `src/types/database.ts` regenerated from the linked project: the only change is the three functions appearing under `Functions`.
- **Decisions recorded:** ADR-0014, covering the four things T07 had to decide that no existing document settles: that `p_reason` is the enum rather than `text`; that `grant_credits` takes a signed amount and owns the negative-balance path while `spend_credits` owns the balance guard; that an idempotency key identifies an *operation* rather than a request, so conflicting reuse is rejected rather than replayed; and that a private, ungranted helper holds the single definition of that identity.
- **The accounting rules this task fixes, restated because later tasks depend on them:**
  - **`credit_ledger` is the accounting source of truth.** `profiles.credit_balance` is a cache the RPCs write from one computed value, and AC10.8's invariant — `sum(delta) = credit_balance` — is asserted per fixture user after every scenario. A nightly reconciliation must use the **sum**, not an ordering: `created_at` defaults to the *transaction* timestamp, so rows written in one transaction share it and `order by created_at desc limit 1` picks arbitrarily.
  - **An activity row is not proof of spend** (ADR-0013 decision 3). No T07 function so much as names `deal_unlocks` or `barcode_lookups` — asserted over `prosrc` — and the suite writes an activity row claiming a credit was spent, then proves the ledger, the balance and the reconciliation invariant are all unmoved by it.
- **Left to T23:** **§6.5's "same transaction" is not expressible over PostgREST**, which gives one statement per request, so `spend_credits` + `insert deal_unlocks` cannot be two `supabase-js` calls and AC10.4 is not satisfiable that way. T23 must choose a wrapping RPC that does both or a direct Postgres connection. T07 deliberately does not pre-empt that choice: folding a `deal_id` and a `market_id` into a credit primitive would make every future consumer of credits an edit to `spend_credits`.
- **Left to T26 (security review #2: credits):** **the RPCs are the only *sanctioned* writer, not yet the only *possible* one.** `service_role` retains `INSERT` on `credit_ledger` and `UPDATE` on `profiles` from T05 and T06, so server code can still move credits without them. **T07 deliberately did not narrow those grants** — that is the documented later review item, and the blast radius belongs to T08's seed and T35's purchase bookkeeping, which are unwritten. The convention is enforced statically in the meantime by the vitest guard above. Narrowing is cheap when it comes: these functions are `SECURITY DEFINER` precisely so they survive it unchanged.

---

## ✅ T08 — Seed data: currencies, countries, launch market, Amazon locale, tax/fee schedules and credit packs

> **Status: COMPLETE.**

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
  - **Seed `stripe_price_id` as `NULL` on every pack price, and never a placeholder** (new in v2.3, ADR-0010). Stripe Prices do not exist until T34; a made-up value such as `price_TODO` or `price_test_123` is worse than a NULL in three ways — it passes any `IS NOT NULL` check, it is indistinguishable from a real ID on inspection, and it reaches Stripe as a 400 at checkout rather than failing at seed time. T06's public-read predicate (`active = true AND stripe_price_id IS NOT NULL`) means NULL-priced rows are simply invisible to clients until T34 fills them in, which is the correct behaviour for a pack that cannot yet be bought.
  - Seed 3–5 retailers in the chosen launch market with `source_type = 'curated'`.
  - Seed is idempotent.
  - **`fx_rates` is out of MVP scope (ADR-005).** The table is not created and not seeded. The MVP is single-currency per deal (§7.6, AC2.7) and there is no MVP consumer; it arrives in Phase 3 with the first genuine cross-border or multi-currency reporting requirement. Do not create it "for later".
  - **Seed operations are DML-only and execute as owner or `service_role`.** The seed performs no DDL, creates no privileges and alters no policies. If a seed appears to need DDL, that is a missing migration, not a seed change.
  - **Exactly one live market is seeding and operational discipline, not a database constraint.** `launch_status` is a lever the admin console legitimately flips (T33), so no uniqueness constraint is added on it. The rule lives in `docs/MARKET_PLAYBOOK.md` and in the T40 release checklist, and is verified there.
  - `docs/MARKET_PLAYBOOK.md` contains the checklist for opening a new market: provider coverage, tax verification, fee verification, Stripe support, retailer supply, legal review, seed rows, launch status.
  - **Demonstrate a synthetic second market can be seeded without a migration or business-logic code change.**
- **Testing requirements:** Run seed twice; counts remain stable. Resolve both the live launch market and the synthetic second market through the future `MarketContext` shape using fixtures. Verify fee-band coverage in the launch market has no gaps/overlaps.
- **Priority:** P0
- **Completion note:** Eight numbered files in `supabase/seed/`, loaded in dependency order by the existing `./seed/*.sql` glob — **no `config.toml` change, no migration, no DDL, no grant, no policy, and no row outside the nine reference tables**. 36 rows: 5 currencies · 4 countries · 4 marketplaces · 2 markets · 4 tax schedules · 3 fee schedules · 5 retailers · 3 credit packs · 6 pack prices. (Total corrected from "31" during T10: the nine per-table figures were always right and are unchanged; only their sum was mis-stated. Recounted from the seed files against a clean `db:reset`, and confirmed again on the hosted development project when the seed was applied there.) The launch market is `gb-amazon-uk` (GB + `amazon_uk`, GBP) at `active = true AND launch_status = 'live'` — **exactly one live market**, asserted rather than constrained, since `launch_status` is a lever T33 legitimately flips. **Fee and tax data are from primary sources, not memory:** the UK schedules were read from Amazon's own *Rate Card — Europe Fees, effective 1 July 2026* PDF and from `gov.uk/vat-rates`. A superseded 1 February 2026 rate card was found and discarded mid-task — seeding it as current would have been precisely the risk #2 defect. The current UK fee schedule carries **52 referral categories** ending in Amazon's own `everything_else` catch-all (so category coverage is total by construction), **42 fulfilment bands across all 13 UK size tiers**, and storage in **cubic feet** where DE is cubic metres. Referral rules store `mode` explicitly as `flat | threshold | marginal`, because on a £60 item under "15% up to £45, then 9%" the marginal reading gives £8.10 and the threshold reading £5.40. **GB has three real tax versions, not invented fixtures** — 17.5% → 20% on 2011-01-04, then a third version on 2024-08-01 where the rate is unchanged but `marketplace_fees_taxed` becomes true, because Amazon moved UK seller billing to a UK-established entity and referral/FBA fees became VAT-bearing; seeding `false` would have understated every launch-market fee by 20% of the fee for the non-registered seller who is our default. **`amazon_uk` has two adjacent fee versions** split at 2026-04-17 when the 1.5% fuel surcharge began, built from one shared CTE so the two cannot drift by a typo. **Every `stripe_price_id` is NULL** (ADR-0010) — asserted both as `count = 0` and as a regex, so a plausible fake such as `price_TODO` fails too — and `0008_credit_packs.sql` deliberately excludes that column from its `ON CONFLICT DO UPDATE`, verified by simulating a T34 backfill and re-running the seed without losing it. **Seeds are idempotent and deterministic:** re-running all eight files against a seeded database changes nothing, and two full `db:reset` runs from zero produce an identical md5 fingerprint over every seeded column including generated ids and jsonb payloads. **No fixture users, deals, purchases or ledger entries** — asserted, because a dashboard populated with invented deals misleads the person deciding whether the pipeline works. `docs/MARKET_PLAYBOOK.md` delivered with the full gate list. The synthetic second market (`de-amazon-de`, planned, inactive, with its own tax and fee schedules) was added with no DDL, no new column and no code change, which is the global-first proof. **T06 surface verified against the real seed:** `anon` sees 1 country, 5 currencies, 1 market, 3 credit packs and **0 pack prices**, is refused `marketplaces`/`tax_schedules`/`fee_schedules`/`retailers` with a **privilege error `42501`** rather than an empty set, and cannot see the planned market; `service_role` sees all 6 pack prices and both markets. **New suite:** `supabase/tests/database/seed_reference_data.test.sql`, **103 assertions**, asserting rates, exponents, flags and boundary dates **by value** rather than by row count. Suite green: **887 pgTAP assertions** across 9 files, **106 application tests**, typecheck, lint and build clean. The dev dashboard was confirmed to reflect the seed with **no UI change** (Markets 2, Retailers 5, Credit packs 3, five currencies at exponents 2/2/0/3/2) by running the dev server against the local stack via environment overrides; `.env.local`, which points at the hosted project, was not edited.
- **Remote data: deliberately NOT applied.** T08 seed data is the deterministic baseline for **local and ephemeral CI databases only**. The hosted development project was **not** seeded, and no remote mutation of any kind was performed. This is a decision, not an omission: T08's acceptance criteria concern the seed's existence, correctness and idempotency, and T09 runs against an ephemeral database in CI. It is also the tool's default rather than a convention anyone must remember — **`npm run db:push` carries migrations only**; seeding a remote requires an explicit `--include-seed`. If the hosted project is ever seeded, it is a separate, approved operation that must not touch migration history.
- **Decisions recorded:** ADR-0015, covering the five things T08 had to decide that no existing document settles: that the launch market is GB / `amazon_uk` / GBP and is now written down rather than inferred from examples; that the schema stays global-first despite a one-market seed, proved by a second market added with no DDL; that `surcharges.basis` is widened to `referral_fee | fulfilment_fee | selling_fees | sell_price | flat` with an optional `applies_to_categories`; that T14 must implement every basis and throw on an unknown one; and that pack prices are provisional planning values whose `stripe_price_id` stays NULL until T34.
- **Left to T14 / T15 (pricing engine):** **all five surcharge bases must be implemented, and an unrecognised basis must throw.** `ARCHITECTURE.md` §2.2 previously listed only `referral_fee | sell_price | flat`, which cannot express two of the launch market's three real surcharges — the Digital Services Fee applies to selling **and** fulfilment fees, the fuel surcharge to fulfilment fees alone. §2.2 is amended (ADR-0015 decision 3). A `default:` branch that skips or coerces an unknown basis reintroduces a silent, market-wide **understatement of cost**, which **overstates profit** — risk #5, in the one direction this product cannot afford. The seeded UK schedule is the day-one fixture: it contains a `selling_fees` and a `fulfilment_fee` entry, so an implementation that ignores either produces a visibly wrong figure against T15's hand-worked examples. The same obligation covers `min_fee_minor` and the `flat`/`threshold`/`marginal` referral mode, which is stored explicitly on every rule and must never be inferred.
- **Left to the founder before beta — rate-card ambiguities, all listed in `docs/MARKET_PLAYBOOK.md` §4.1.** None blocks T09; all block beta. (1) **`marketplace_fees_taxed = true` from 2024-08-01** is corroborated from accountancy sources describing Amazon's move to Amazon EU S.à r.l.'s UK branch — **confirm against a real Seller Central VAT invoice.** (2) **The Digital Services Fee at 2%** does not appear on Amazon's own rate card; the figure is from secondary sources, which also describe a separate 3% rate from 2026-03-20 for UK-established sellers selling into the FR/IT/ES stores (cross-border, out of MVP scope) — **confirm the amazon.co.uk rate on an invoice.** (3) **The minimum referral fee conflicts between sources**: the rate card states £0.25 for *all* categories, `sell.amazon.co.uk` states Books, Music, Video, DVD and Grocery are exempt. The rate card is seeded as primary — **resolve it.** (4) **Low-Price FBA is not seeded** — a separate programme with its own rates at or below £20, so items near that threshold price against standard FBA and look *worse* than they are. (5) **The Clothing Prime-selection referral ladder is not modelled**, because Prime selection is not knowable from catalogue data. `verified_at` is the mechanism that keeps these honest: it is non-NULL only where a human checked a primary source, DE's schedules carry NULL deliberately, and `MARKET_PLAYBOOK.md` gates a live market on it.
- **Left to T09:** the fixtures its acceptance criteria require now exist as seeded rows rather than assumptions — inactive countries (DE, US, JP), a non-live market (`de-amazon-de`) and inactive pack prices (the EUR rows), so "inactive rows are absent" can be asserted against something real.

---

## ✅ T09 — QA: anon-key and RLS access verification suite

> **Status: COMPLETE.**

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
- **Result: PASS WITH FINDINGS.** No P0. Two P1 findings, both fixed in T09; the rest classified and either fixed or deferred to the task that owns them.
- **P1 #1 — the database and security tests were missing from CI, and had been since T03.** `ci.yml` ran typecheck, lint, vitest and build. The **entire pgTAP suite ran only on a developer's machine**: RLS, the grant matrix, the append-only ledger, the temporal exclusion constraints and the T08 seed's integrity were verified nowhere that could block a merge, so a migration dropping a policy would have gone green. **Fixed:** a second CI job, `database`, starts the pinned Supabase stack, resets from zero (which is also the migration-reproducibility proof), then runs `npm run db:test` **and** `npm run test:integration`. It is a blocker. The two suites answer different questions and neither substitutes for the other — pgTAP reaches the database as the owner via `SET LOCAL ROLE` and proves the catalogue; the integration suite presents real JWTs to PostgREST and proves what a browser receives. `SET ROLE` is not a JWT: it does not populate `auth.uid()` and never traverses the token path.
- **P1 #2 — webhook event evidence lacked TRUNCATE protection.** T06 deferred this decision here explicitly. Measured before deciding: `DELETE` was refused for every caller (trigger `0A000` for the owner, `42501` for `service_role`), but **`TRUNCATE stripe_webhook_events` SUCCEEDED for the table owner**, while the same statement against `credit_ledger` was refused. T06's guard is a **row** trigger and a row trigger never fires for `TRUNCATE`, so a table whose rows are the Stripe replay guard and the evidence of what Stripe sent could be emptied in one statement by a migration, a support script or a dashboard session. Severity is bounded and that is stated rather than glossed: §9.2 rule 3 has two layers and this is the second, so `credit_ledger.idempotency_key` (`NOT NULL UNIQUE`, itself TRUNCATE-guarded) still refuses a replayed event — what was actually at risk is the evidence. **Fixed** by `20260811210126_webhook_events_truncate_guard.sql` (ADR-0016): one `SECURITY INVOKER` function with a pinned `search_path` and one `BEFORE TRUNCATE … FOR EACH STATEMENT` trigger. A separate function from the row trigger's, because that one must keep returning `NEW` — `UPDATE` of `processed_at` and `error` remains allowed and is asserted after the change. The migration creates no table, column, constraint, index, policy or grant, writes no row, and alters no existing object; its only privilege statement is a revoke.
- **Completion note:** Deliverables are `tests/integration/rls.test.ts` (**76 assertions**, the anon-key suite T09 names), `supabase/tests/database/security_baseline.test.sql` (**27 assertions**, the exhaustive privilege suite `rls_policies_and_grants.test.sql` said T09 owns), one migration, and the CI job above. **Catalogue state verified before writing a line of test:** 24 tables all with RLS enabled, 19 policies, 40 table grants, 14 column grants, 0 PUBLIC grants, 9 functions with **no NULL `proacl`** (a NULL ACL *is* a PUBLIC execute grant) and every one pinning a `search_path`. The three `SECURITY DEFINER` functions resolve `pg_temp` last, use no dynamic SQL, and are executable by neither `anon` nor `authenticated`; `public` is not `CREATE`-able by any client role, which is what makes a definer `search_path` of `public` safe in the first place. Grant/policy correspondence is exact in both directions — no policy without a grant (inert policy), no client grant without a policy (unguarded grant). **The suite is mutation-checked, as the testing requirements demand:** granting `SELECT` on `deals` to `anon` turned it red on **two independent assertions** — the behavioural check and the grant-catalogue sweep — and revoking returned it to 76/76. **A trap the task description did not name was found by reconnaissance and shapes the whole suite:** PostgREST returns **`42501` for both a missing grant and an RLS `WITH CHECK` violation**, distinguishable only by message (`permission denied for table X` versus `new row violates row-level security policy…`). A suite asserting `error.code === '42501'` therefore cannot tell the grant layer from the policy layer and would keep passing on the day someone adds a grant to a table that still has a restrictive policy. Every negative assertion classifies the outcome as `rows | privilege-denied | rls-refused | trigger-refused | constraint | other` and asserts the classification, never the raw code. The new pgTAP file is deliberately a different *kind* of test from every suite before it: T03–T08 assert that objects their authors knew about behave correctly, and **nothing failed when something new appeared**. It compares the whole catalogue against literals, so any added grant, policy, function or table turns it red — which is why adding this task's own function required updating the `schema_b`/`schema_c` sweeps and the `stripe_webhook_events` trigger assertions, those being the existing sweeps working exactly as designed. Both were made **more** specific rather than looser: the trigger assertion now names both triggers and asserts each one's level, because a row trigger cannot see `TRUNCATE` and a statement trigger cannot compare `OLD` with `NEW`, so neither is redundant. Suite green: **916 pgTAP assertions** across 10 files (up from 887/9), **76 integration assertions**, **106 application tests**, with typecheck, lint and build clean. **Migration applied remotely and verified read-only:** all nine migrations match local and remote, `supabase db diff --linked --schema public` reports no schema changes, and a `db dump` of the remote `public` schema is **byte-identical** to the local one. On the remote the new function carries no `SECURITY DEFINER` clause, is `SET search_path TO 'pg_catalog', 'pg_temp'`, and has `REVOKE ALL … FROM PUBLIC` with **zero** EXECUTE grants to `anon` or `authenticated`; both triggers are present with the intended levels; and `stripe_webhook_events` still grants `service_role` exactly `SELECT, INSERT, UPDATE` with no `DELETE`. No destructive statement was executed against the hosted project — the catalogue was proved by dump and diff. Generated types needed **no** regeneration: `gen types` does not emit trigger functions, confirmed by diffing a fresh generation against the committed file.
- **Decisions recorded:** ADR-0016, covering the three things T09 had to decide: that `stripe_webhook_events` gets the TRUNCATE guard T06 deferred here, with the hole measured rather than assumed; that the security baseline is asserted as an **allowlist** so the suite fails when something new appears rather than only when something known breaks; and that `42501` is ambiguous, so the integration suite classifies outcomes instead of codes.
- **Two smaller findings, recorded rather than silently fixed:** (1) **This task's own acceptance criteria are one table short** — the closed-table list names twelve and omits `retailers`, which carries no policy and no client grant exactly like the other twelve. The "every table appears in exactly one category" criterion is what surfaced it, which is that criterion working as intended; the suite covers thirteen. (2) **The integration suite cannot fully tear itself down, by design.** Asserting that user A sees only A's `credit_ledger` rows requires ledger rows for two users; those are undeletable at every layer and make the users undeletable too, so the suite asserts that retention behaviour instead of working around it and leaves 2 users and 2 ledger rows per run. **`npm run db:test` must therefore run BEFORE `npm run test:integration`** — CI sequences it correctly and `tests/integration/README.md` states it.
- **One test-infrastructure fix:** vitest's `testTimeout` was raised from its 5 s default to 15 s, with the cause **measured rather than guessed**. The first test in a React file pays a one-off ~350 ms jsdom + React + module-graph warm-up its siblings do not (they run in 11–130 ms), which is 13× inside the default budget on an idle machine and not on a contended CI runner — the two false reds observed during T08 were both a file's first test. The failure was never a hang, so the larger budget masks none.
- **Left to T26 (security review #2: credits) — unchanged and re-verified:** **`service_role` still holds direct `INSERT` on `credit_ledger` and `UPDATE` on `profiles`**, so server code can still move credits without the T07 RPCs. T09 confirmed this is still true and **deliberately did not narrow it**: ADR-0014 assigned the decision to T26, whose blast radius includes T35's purchase bookkeeping, and narrowing a privilege during a QA pass is exactly the "broaden or change permissions to make a test pass" move this task forbids in reverse. The convention is held meanwhile by `tests/unit/supabase/credit-rpcs-are-the-only-writer.test.ts`, and ADR-0013's rule was re-confirmed: `deal_unlocks` and `barcode_lookups` are activity records, never accounting proof.
- **Left to T10 — now demonstrated rather than predicted:** **a user holding financial records cannot be deleted.** `credit_ledger.user_id` and `credit_purchases.user_id` are `ON DELETE RESTRICT` (ADR-0010), so `auth.admin.deleteUser` fails with `23503` while any ledger row exists. T09 asserts this at the integration layer, which turns T10's account-deletion pseudonymisation from a documented intention into a blocking prerequisite with a failing-path test already in place.
- **Priority:** P0

---

## ⏳ T10 — Authentication, session middleware and onboarding profile

> **Status: IMPLEMENTED AND DEPLOYED — NOT CLOSED.** The code is written, merged and deployed, and ADR-0017 records the account-deletion mechanism it chose. **Two acceptance criteria below have not been verified**, and until both are, this task is open.
>
> **Outstanding verification — both required, neither optional:**
> 1. **The hosted end-to-end flow, on the hosted project, in one unbroken pass:** signup → email verification (a real verification email, `enable_confirmations = true`, not the local Mailpit path) → onboarding → feed → sign-out. The local stack runs with confirmations off (`RUNBOOK.md` §11.1), so a green local run does not evidence this.
> 2. **Onboarding completed in under 60 seconds on a mid-range Android device (AC2.4), with the timing recorded** in the PR or the completion note. A desktop or simulator timing does not substitute — the criterion names the device class because that is the constraint.
>
> **ADR-0017 is not evidence of completion.** It answers one design question T10 had to settle (how deletion works given `ON DELETE RESTRICT`); it says nothing about whether the flow above was walked or the timing taken. A recorded decision and a verified acceptance criterion are different artefacts, and one has repeatedly been read as the other.
>
> **T11 does not start until both pass.** T11 depends on T09 and T10, and a security review of an authentication flow nobody has walked end to end on the hosted project reviews the source rather than the system.

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
  - **Account deletion available in settings (AC1.5) — revised in v2.3 (ADR-0010).** Personal rows cascade as before. **Financial records do not.**
    - `credit_ledger` and `credit_purchases` are **retained** for audit and reconciliation, and their `user_id` foreign keys are `ON DELETE RESTRICT` (T05). They are not cascade-deleted, not soft-deleted, and not excluded from the nightly reconciliation (AC10.8, §11.4) afterwards.
    - **This makes a plain `delete from auth.users` fail** with `23503` for any user who ever held a credit — which is every user, since signup grants five. Account deletion in this product is therefore **pseudonymisation of the retained financial rows plus deletion of everything else**, not a cascade.
    - **The pseudonymisation mechanism is an explicit T10 decision and is deliberately not specified here.** Whether the retained rows point at a tombstone profile, a surrogate subject id, or a nulled actor column — and what happens to `auth.users` itself — changes the FK shape, the reconciliation query and the privacy claim in the same stroke, and choosing it in advance of the task that must live with it is how a wrong answer gets inherited. T10 chooses, records it as its own ADR, and writes the migration that implements it.
    - Whatever T10 chooses must satisfy three constraints simultaneously: the user's personal data is gone, the financial history still sums to the same totals per currency, and no retained row can be traced back to a person through this database.
- **Testing requirements:** Integration tests for redirect-and-return, profile update authorisation (user A cannot PATCH user B), and the signup grant landing in the ledger exactly once. A deletion test asserting that personal rows are gone, that the ledger and purchase rows survive with the same deltas and totals, and that nothing in the retained rows identifies the deleted user. Manual: complete onboarding in under 60 seconds on a mid-range Android phone (AC2.4) and record the timing in the PR.
- **Priority:** P0

---

## T10A — Signup abuse refusal and prep-cost onboarding defaults

- **Goal:** Two small additions to the T10 surface, raised in the ADR-0018 product review **after** T10 shipped. **This is a separate task, not a widening of T10.** T10 is verified and closed against the criteria it was built against; nothing here is retroactively a T10 acceptance criterion, and T10 must not be reopened to absorb it.
- **Agent:** Backend Engineer
- **Dependencies:** **T10 closed** (both outstanding verifications passed). Does **not** block T11 — a P1 follow-up cannot gate a P0 security review.
- **Files / areas:** `src/app/(auth)/*`, `src/lib/validation/profile.ts`, `src/services/profile/`, onboarding steps under `src/app/(app)/`
- **Acceptance criteria:**
  - **Disposable-email-domain refusal at signup.** Five credits × unlimited throwaway addresses is the cheapest attack this product has (AC10.6 grants on every signup). Signup is refused for a known disposable domain, with a clear message, **before** `grant_credits` is called — the grant must not be issued and then clawed back, because the ledger is append-only and a clawback is a `chargeback` row that means something else entirely (ADR-0010).
  - The domain list is **data, not a hardcoded array in a route handler**, and refusing a domain is a configuration change rather than a deploy.
  - **Do not add card-on-file at signup.** It would cost more honest conversions than it saves credits, from exactly the capital-constrained beginner this product exists for (ADR-0018 decision 8). If beta shows real abuse, the lever is to **reduce the grant to two or three credits**, not to add friction.
  - **Prep-cost defaults in onboarding.** Amazon ended FBA prep and labelling services in Europe on 1 July 2026, so most sellers now pay a third-party prep centre and most beginners do not know their per-unit rate. The prep-cost step offers a short list of typical prep-centre rates as tappable defaults instead of an empty number field. The user can still type their own figure, and the stored value remains integer minor units with an explicit currency.
  - **No integration, no partnership, no API.** The rates are seeded reference values with a recorded source and a verification date, in the same spirit as the T08 fee schedules — not scraped, and not invented.
  - The added onboarding option must not push onboarding past the AC2.4 60-second budget; re-time it on the same mid-range Android device and record the figure.
- **Testing requirements:** A test that a disposable domain is refused and **no ledger row is written**; a test that an ordinary domain still receives exactly one `signup_grant` row. A test that selecting a default prep rate stores the correct minor-unit value in the market currency. Re-run the AC2.4 timing and record it.
- **Priority:** **P1** — ship during beta only if the P0 loop is stable.

---

## T11 — Security review #1: authentication, RLS and secrets

- **Goal:** Independent verification that the foundation is sound before any money logic is built on it.
- **Agent:** Code Reviewer / Security Reviewer
- **Dependencies:** T09, **T10 closed** — both of T10's outstanding verifications (hosted signup → verification → onboarding → feed → sign-out, and the recorded sub-60-second onboarding timing on a mid-range Android) must have passed. **T11 does not start on a T10 that is merely deployed.** T10A is a P1 follow-up and is **not** a dependency.
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
- **Status: IN PROGRESS — findings produced, hardening pass landed, NOT COMPLETE.** The review produced eleven findings (F1–F11). A hardening pass on 2026-08-18 resolved the subset that must not be inherited by the deal engine; **ADR-0019** records it in full. **T11 does not close on this**: its acceptance criteria above are verification statements a reviewer must make, several are unmade, and T10 remains in verification, which T11's dependency line requires to have passed.
  - **F2 (dev dashboard served service-role queries to anonymous production callers) — RESOLVED.** `NODE_ENV` gate checked before a dynamic import; production never evaluates the admin snapshot layer. Proven by `tests/unit/dev-dashboard/production-gate.test.ts`.
  - **F3, F4, F7 (profile/onboarding integrity) — RESOLVED IN THE DATABASE**, migration `20260817231500_profile_onboarding_integrity.sql`, applied to the linked project with zero row impact. `onboarded_at` is derived and no longer in the authenticated column-UPDATE allowlist; country/market/currency coherence is a trigger, not application code. **T12/T13 may now rely on `profileStage() == 'ready'` implying a resolved market, currency and cost basis.**
  - **F6 (bundle scan reported a pass it had not earned) — RESOLVED.** Three-valued result; CI supplies the published local-stack key so the value assertion genuinely runs.
  - **F8, F9, F11 — RESOLVED** (no raw Postgres errors to users; no signup enumeration detail; explicit secure-cookie regression coverage).
  - **F1 (auth audit residue) — DOCUMENTATION CORRECTED, NO DATA TOUCHED.** `auth.audit_log_entries` was deliberately not purged or altered. The over-broad erasure claim is narrowed to `public` in ADR-0017/ADR-0019, `ARCHITECTURE.md` §11.5 and `RUNBOOK.md` §11.4. **Retention/purge policy is unresolved and belongs to T37; no period is stated anywhere.**
  - **Still open, and required before T11 can close:** F5 and F10 remain unaddressed by this pass, and every acceptance criterion above still needs an explicit reviewer verification recorded against it.
- **Out of scope, deliberately:** T39 security headers, and any narrowing of T26-owned `service_role` DML.

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
  - **Repeatability signal (ADR-0018).** A promotion that can be restocked next week is worth more than a one-off clearance pallet at the same margin — the case that prompted this product was someone re-buying **one** product for months rather than finding variety. Capture as a deal flag (`one_off | recurring_promo | standing_price`) and a **bounded modifier inside the existing weights config**. **Explicitly not a sixth weighted component:** the five weights and their justification are load-bearing, and a sixth is exactly what this becomes on the second pass if it is not ruled out in writing now.
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
  - A locked deal **does** contain: Deal Score, full score breakdown, named penalties, risk flags, profit band, ROI band, marketplace category, retailer *type*, assumption set, data freshness, and the unlock count (AC9.1–AC9.3, AC9.7).
  - **Every raw input in the breakdown is banded; exact values are withheld (ADR-0018).** Sales rank → within-category percentile band. Offer counts → a range. Buybox and 90-day average → the profit and ROI bands only, never the price itself. Price stability → a percentage band. Freshness → an age bucket, not a timestamp.
  - **Reason this is not optional.** Category + exact rank + exact offer count + exact buybox is a *fingerprint*: a £15/month Keepa subscription filters for that tuple and returns the external ID in about thirty seconds, and the `retailer type` field then narrows the shop — with no credit spent. Withholding the name does not protect the paid product if the numbers identify it. **A band persuades; an exact number identifies.**
  - The automated test asserts against the **serialised JSON string**, using a deny-list of substrings drawn from the fixture deal, and fails if any appears.
  - The test is a **CI blocker**.
  - **This module owns every band in the product** — profit, ROI and score inputs — so the feed, the card, the detail view and this test use identical boundaries. Bands defined in two places will disagree, and the disagreement is the leak.
- **Testing requirements:** Property-style test: for a fixture deal with distinctive sentinel values in every identity field, assert none of those sentinels appears anywhere in `JSON.stringify(redactDeal(deal, { unlocked: false }))`. Add a deliberately failing variant in review to prove the test actually catches a leak.
  - **Numeric fingerprint assertion (ADR-0018).** Distinctive non-round sentinel *numbers* in sales rank, offer count, buybox, 90-day average and price standard deviation, asserted absent from the serialised locked payload. The name-based deny-list is necessary and **not sufficient**: a payload containing no names and a perfect numeric fingerprint passes it cleanly. Both assertions are CI blockers.
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
  - **Filter granularity floor (ADR-0018).** Minimum profit snaps to whole units of 5 in the market currency, minimum ROI to 10 percentage points, minimum score to bands of 10. Values outside the floor are **rejected at validation, not silently rounded**. An unbounded filter is a binary search: profit between 4.20 and 4.30 with score between 73 and 74 identifies a single deal without unlocking it. This closes from the query side what T21's banding closes from the payload side, and it costs an honest user nothing — nobody sources on a 10p profit distinction.
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
  - `DealCard` shows: Deal Score, profit band, ROI band, marketplace category, retailer *type*, data freshness, and **how many users have already unlocked it** (AC8.1, AC9.7) — a competition signal the buyer genuinely needs, and one that makes a leaked deal self-limiting: a deal fifty people have bought is no longer a deal.
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
  - **Locked state** shows the complete score breakdown — all five components with scores, weights and **banded** inputs, never exact figures (AC9.1, ADR-0018) — every named penalty and risk flag in plain English (AC9.2, AC7.3), profit and ROI bands, the assumption set, and data freshness (AC9.3). It withholds only identity.
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
- **Pricing is settled for the MVP: flat 1 credit per unlock (ADR-0018).** Variable pricing by capital deployed was proposed and **rejected**: unlock is a one-time reveal, so a user declares one unit, pays for one unit, and buys fifty — invisibly and unstoppably, because the purchase happens at a retailer on their own card. The same argument disposes of a 2% search fee, an affiliate cut and a share of realised profit; a volume-based fee additionally **inverts the incentive the product rests on**, earning more when users buy more whether or not they profit. If pricing is revisited after beta, permissible inputs are **deal-intrinsic and known before the reveal** (profit band, score band, freshness); purchase quantity, transaction value and realised profit are not, in any framing.
- **Agent:** Integration Engineer
- **Dependencies:** T23, T28
- **Files / areas:** `src/services/billing/{checkout.ts,packs.ts}`, `src/app/api/v1/billing/checkout/route.ts`, `src/app/(app)/credits/*`
- **Acceptance criteria:**
  - **Stripe Checkout (hosted) only.** No Elements, no custom card form, no saved-card UI, no PCI surface.
  - Server resolves user/market currency, validates the pack and active currency price, creates a `credit_purchases` row with status `pending`, then creates the Checkout Session with `client_reference_id = userId` and metadata `{ userId, packId, purchaseId }`.
  - **Credit quantity is read from `credit_packs`; amount and Stripe Price ID are read server-side from `credit_pack_prices` for the user's resolved currency.** No client-supplied price or quantity is ever trusted (AC17.4).
  - **Stripe setup is part of this task: create the Stripe Prices and backfill `credit_pack_prices.stripe_price_id` for every pack price that is to be active** (new in v2.3, ADR-0010). T08 seeded these as `NULL` because no Stripe object existed yet, and placeholders were prohibited. Populating them is therefore a real step with a migration or a seed-update script behind it, not an assumption — and it is the step that makes the credits screen non-empty.
  - **Until `stripe_price_id` is non-null, a pack price is invisible to `anon` and `authenticated`.** T06's read policy is `active = true AND stripe_price_id IS NOT NULL`, so an unbackfilled price is not merely unbuyable, it is unreadable — the credits screen will render no purchasable pack at all. That is the intended behaviour and must not be "fixed" by relaxing the policy or by writing a placeholder ID: the correct fix is always to create the Stripe Price and backfill the real value.
  - Verify after backfill that each intended pack price is readable with the **anon key**, not only with the service role. A row that is correct in the database and filtered out by the policy looks identical to a missing row from the client's side.
  - Credits screen shows balance, packs, and full ledger history with reasons (F20).
  - Success page **polls the balance** rather than asserting success from the redirect (AC17.6).
  - Test mode throughout; live keys are a separate deployment step in T39.
- **Testing requirements:** Test that tampered client currency/price/credit count is ignored in favour of server-resolved market currency and database values. Test that an inactive pack is rejected. Test that a pack price with a NULL `stripe_price_id` is never offered for checkout and never appears in an anon-key read. Manual: complete a test-mode purchase end to end, and confirm the credits screen lists exactly the backfilled pack prices and no others.
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
  - **Competitor benchmark (ADR-0018):** rank 20 of the app's published deals against a paid arbitrage lead list covering the same period. The app's Deal Score must place the genuinely profitable ones higher. **If a $30/month spreadsheet ranks better, the Deal Score is wrong and beta waits** — better to learn that from a comparison than from a user.
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

- **Goal:** F18. Save, list, remove an unlocked deal — framed as **"the products I re-buy: are they still worth buying today?"** rather than as a bookmark (ADR-0018). Monitoring is what people pay for repeatedly, and it is the reason a user opens the app in week six. Same scope, sharper purpose.
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

**Completed:** T01 (repo, CI, deploy) · T02 (Supabase, clients, migrations) · T03 (11 core tables, 9 enums, RLS enabled, privileges normalised — ADR-004) · T04 (deals, user activity, cross-market consistency by composite FK — ADR-0008; deal lifecycle `draft | active | retired` — ADR-0009) · T05 (credit ledger, per-currency pack pricing, operational logs — ADR-0011) · T05A (temporal exclusion constraints on both schedule tables — ADR-0012) · T06 (19 RLS policies paired with 16 grants, 13 tables explicitly left closed, restricted-UPDATE protection on `stripe_webhook_events` — ADR-0013) · T07 (atomic `spend_credits` / `grant_credits`, `service_role`-only, idempotent on the ledger key, AC10.1 proved by a real `dblink` concurrency gate — ADR-0014) · T08 (36 reference rows across 8 idempotent, deterministic seed files; GB / `amazon_uk` / GBP as the one live market; UK tax and fee schedules from primary sources; `stripe_price_id` NULL throughout; `MARKET_PLAYBOOK.md`; **local/ephemeral only — the hosted project was deliberately not seeded** — ADR-0015) · T09 (anon-key RLS suite + exhaustive privilege allowlists; **the database tests were missing from CI and now block merges**; `stripe_webhook_events` TRUNCATE guard — ADR-0016).

**Current task: T10 — implemented and deployed, in verification, NOT closed.** Two acceptance criteria remain: the hosted signup → verification → onboarding → feed → sign-out pass, and a recorded sub-60-second onboarding timing on a mid-range Android (AC2.4). **T11 does not start until both pass.** Give tasks to coding agents in this exact order. Do not start one until the previous task's acceptance criteria are verified — ADR-0017 is a recorded decision, not a verification.

### 1. ✅ T05 — Credits, per-currency billing and operational logs — COMPLETE
**Agent:** Database Engineer · **Depends on:** T03  
Create the append-only ledger, currency-neutral packs, per-currency pack prices, webhook events and market/provider operational logs. Ledger immutability (trigger **and** revoked `service_role` privileges) and financial-record retention (`ON DELETE RESTRICT`) are built here, per ADR-0010.  
*Why first:* this makes credits global without making every unlock price country-specific — and the source of truth for money must never exist in a mutable state, not even for one migration.

### 2. ✅ T05A — Temporal integrity constraints on versioned schedules — COMPLETE
**Agent:** Database Engineer · **Depends on:** T03 · **Blocks:** T08  
Exclusion constraints preventing overlapping effective ranges on `tax_schedules` (per country) and `fee_schedules` (per marketplace), with `[)` semantics and correct open-ended handling.  
*Why second:* it must exist before T08 seeds a single schedule row, and it permanently removes a class of silent, market-wide wrongness (risks #2 and #3).

### 3. ✅ T06 — RLS policies, SQL grants and append-only enforcement — COMPLETE
**Agent:** Database Engineer · **Depends on:** T03, T04, T05, T05A  
Every policy paired with its minimum matching grant, every grant paired with its policy, service-role-only tables explicitly granted nothing. Verifies the T05 ledger protections rather than duplicating them, and adds restricted-UPDATE protection to `stripe_webhook_events` (ADR-0010).  
*Why third:* after T03's normalisation, a policy without a grant is inert and a grant without a policy is a leak. This is the task where that correspondence is established for the whole schema.

### 4. ✅ T07 — Atomic credit RPCs (`spend_credits`, `grant_credits`) — COMPLETE
**Agent:** Database Engineer · **Depends on:** T05, T06  
Race-free, idempotent, `SECURITY DEFINER`, with `EXECUTE` revoked from `PUBLIC`/`anon`/`authenticated` and granted only to `service_role`. `grant_credits` takes a signed amount and owns the negative-balance path; `spend_credits` owns the balance guard (ADR-0014).  
*Why fourth:* every later money path depends on this being the only way credits move.

### 5. ✅ T08 — Seed data: global reference data and one launch market — COMPLETE
**Agent:** Database Engineer · **Depends on:** T03, T04, T05, T05A  
Currencies, countries, Amazon locales, exactly one live market with verified tax and fee schedules, retailers, credit packs and per-currency pack prices — with `stripe_price_id` seeded `NULL` and no placeholders (ADR-0010). Plus `docs/MARKET_PLAYBOOK.md` and the synthetic-second-market proof. The launch market is GB / `amazon_uk` / GBP, named for the first time in ADR-0015; `surcharges.basis` widened there too, and **T14 owns implementing all five bases.** **Seed data is local/ephemeral only — the hosted development project was deliberately not seeded.**  
*Why fifth:* it is the first task that proves the global-first claim, and it cannot run before T05A without risking committing the exact overlap the constraint exists to prevent.

**Next up:** ✅ T09 (RLS/privilege QA) — **COMPLETE, PASS WITH FINDINGS**, two P1s fixed (database tests absent from CI; `stripe_webhook_events` TRUNCATE guard) → **T10 (auth/onboarding — implemented and deployed, account deletion resolved by ADR-0017, but IN VERIFICATION and not closed: hosted E2E and the AC2.4 Android timing are both outstanding)** → T11 (security review, gated on T10 closing). T10A is a P1 follow-up after T10 closes and gates nothing.  
Do not begin the deal engine until T11 has no open P0 findings. **T11's 2026-08-18 hardening pass (ADR-0019) resolved F2, F3, F4, F6, F7, F8, F9 and F11 and corrected F1's documentation; F5 and F10 are still open and T11's own acceptance criteria are still unverified, so T12 does not start.**
---

## Appendix — Task index

| Phase | Tasks | Priority |
|---|---|---|
| 1. Foundation | T01–T11 (incl. T05A) | P0 |
| 1a. Foundation follow-up | T10A | P1 |
| 2. Deal engine | T12–T20 | P0 |
| 3. Core APIs | T21–T27 | P0 |
| 4. Frontend | T28–T33 | P0 |
| 5. Payments | T34–T36 | P0 (late) |
| 6. Quality and launch | T37–T40 | P0 |
| 7. Deferred | T41–T44 | P1 |

**Security reviews:** T11 (auth, RLS, secrets) · T26 (credits, unlock, redaction) · T36 (payments).
**QA checkpoints:** T09 (RLS) · T15 (pricing) · T27 (pipeline) · T38 (mobile and errors) · T40 (release gates).

### Parked ideas — recorded so they are not lost, and not built (ADR-0018)

Raised and assessed during planning. **None affects the current build.** Each carries a trigger rather than a vague "later".

| Idea | Verdict | Trigger to revisit |
|---|---|---|
| **Community-submitted in-store deals** | The right diagnosis of the supply problem, and it reaches clearance stock no paid feed can see. Survives **only** if users share the *promotion*, never the *stock level* — a national price cut is non-rival and costs the reporter nothing, whereas "my store has twenty left" is rival and no rational user posts it. Pay 2–3 credits on **verification**, never on submission; contributor unlocks their own find free. Needs photo, timestamp, reputation and a "wasn't there" report. Converts the product from curator to platform, with the moderation duty that implies. | 50–100 active users **and** a Deal Score demonstrated against real outcomes. Cold start makes it impossible earlier. |
| **Retailer data feeds** (Pepesto, Actowiz, Apify) | Purchasable today — daily refresh, promotional prices, GTIN included, a few hundred a month, UK and much of Europe — and drops in as a third `IngestionSource` (§10.3) without touching anything downstream. But it is scraping wrapped in an API, so a feed can die with little notice; and volume is not deals — thousands of bad matches arrive with the good ones, increasing review load rather than reducing it. | 60 manually-curated deals proving the matching and the scoring first. **Never before.** |
| **2% transaction / search fee** | **Rejected structurally.** The purchase never passes through the product, so it cannot be metered; every variant depends on behaviour after the reveal, which is invisible. A volume fee also inverts the incentive the product rests on. | Not applicable. **Do not re-propose.** |
| **Buying or prepping on the user's behalf** | Rejected. Means holding customer money, owning stock, VAT liability and Seller Central access — a regulated logistics business, not a feature. Prep centres also do not buy; they forward goods already bought, so the flow does not close. | Not in this product. |
| **Subscription pricing** | Open, not decided. Credits are one-off purchases from a population that churns within months, while monitoring is inherently recurring. Countervailing point before switching: credits **ration deal exposure**, which is the structural flaw forcing subscription lead lists to cap membership at a few dozen. | Real repeat-purchase data from beta. |

---

**Not in this plan, by design:** automated scraping · affiliate feed adapters · SP-API · seller-specific gating checks · portfolio P&L · push notifications · local sourcing maps · AI assistant · fuzzy matching · subscriptions · CSV export · additional marketplace integrations · simultaneous multi-market launch · cross-border/FX arbitrage · native apps · Python services · 3PL workflow. See `PRODUCT_SPEC.md` §8 for the reason and the revisit condition for each.

---

*End of document. Any change to a task's scope, or to a P0 boundary, belongs in `docs/DECISIONS.md` as an ADR — and none of it changes silently.*
