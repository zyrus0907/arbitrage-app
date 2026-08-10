# PRODUCT_SPEC.md

**Project:** Global Retail-to-Marketplace Arbitrage App
**Document owner:** Product Manager
**Status:** MVP definition. Scopes and conforms to ARCHITECTURE.md v2.0.
**Version:** 2.0 — global-first, marketplace-agnostic, Amazon-first MVP
**Companion document:** `ARCHITECTURE.md` v2.0 (technical contract)

> **Product scope rule:** The company vision is global retailer-to-marketplace arbitrage. The MVP launches in one chosen market and integrates Amazon only. Country, currency, tax regime, marketplace and product identifiers must remain configuration/data concepts so later markets and marketplaces do not require a product rewrite.

---

## Changelog: v1.0 → v2.0

- Reframed the product from UK retail-to-Amazon to a **global retailer-to-marketplace platform**.
- Kept the MVP deliberately narrow: **one launch market, Amazon only, domestic single-currency deals**.
- Replaced UK/GBP/VAT assumptions with `MarketContext`, explicit currency, and regime-driven tax treatment.
- Replaced EAN→ASIN as a core product concept with **GTIN-14 → marketplace listing**; ASIN remains Amazon adapter data.
- Added market-scoped onboarding, feed isolation, metrics, release gates and beta recruitment.
- Preserved the original trust hypothesis, feature priorities, credit model and 4–6 week beta objective.

---

## 0. Preamble: the hypothesis, and what follows from it

### 0.1 The hypothesis

> **Will users trust the app's recommendations enough to spend real money buying products?**

Note precisely what this does and does not say.

- It is about users spending money **at a retailer**, on stock, on our say-so. That is the behaviour we are testing.
- It is **not** primarily about users spending money on **credits**. That is a second, weaker hypothesis (willingness to pay for information), and at beta scale it is unmeasurable noise.
- It is **not** a data-volume hypothesis. Fifty deals a user believes beats five thousand a user doubts.

Everything in this spec is subordinate to that. A feature that does not either (a) produce a deal worth buying, (b) make a number believable, or (c) measure whether a purchase happened, is not in P0.

### 0.2 What "smallest commercially testable" means here

A build is commercially testable when it can answer, with real users and real money:

1. Does a user, shown a deal, **buy the stock**? (primary)
2. Did the prediction **hold up**? (primary — this is the product)
3. Would a user **pay for more deals** once the free grant runs out? (secondary)

Question 3 requires a live payment path. Questions 1 and 2 do not. So Stripe ships, but last, and its absence must never block the beta starting.

### 0.3 Assumptions

1. Solo founder, AI-assisted development, 4–6 calendar weeks to beta-ready.
2. **Global-first architecture, single-market beta.** The launch country/market is selected before beta; adding another country later must be primarily configuration + deal-supply work, not a schema rewrite.
3. **Amazon is the only marketplace integration in the MVP.** Product language and core models remain marketplace-agnostic so non-Amazon marketplaces can be added later through adapters.
4. Beta users are individuals doing retail arbitrage in the chosen launch market, generally using marketplace fulfilment or seller fulfilment from home. Their tax status is captured explicitly rather than assumed.
5. No marketplace seller-account integration is required for MVP use. This is a sourcing and decision-support tool.
6. Deal supply at beta is **manually curated** (admin CSV / URL paste), per ARCHITECTURE.md §10.4. Automated feeds are a post-beta concern.
7. Beta users are recruited from arbitrage communities in the chosen launch market — people who **already buy stock**. We are testing whether they switch their trust to us, not whether we can create the behaviour from scratch.
8. Beta runs 4 weeks with 20–50 users, seeded with free credits.
9. **Domestic, single-currency arbitrage only in MVP.** Retail purchase and resale marketplace must use the same currency. Cross-border arbitrage is deferred.

### 0.4 The central product tension (read this before anything else)

The paywall sits in front of the evidence.

A user cannot judge whether our maths is honest until they see a real product against a real marketplace listing with a real breakdown — and that is exactly what the credit buys. So the **first unlock is bought on faith**, and every subsequent one on evidence.

Two consequences, both non-negotiable:

- **The free signup grant is a product mechanic, not a promotion.** It must be large enough to survive one or two disappointing unlocks and still reach a good one. 5 credits minimum. If early beta data shows users churning at 2 unlocks, raise it — do not defend the number.
- **The locked card must prove the maths without revealing the identity.** It shows the full *shape* of the reasoning — score components, profit band, ROI band, the binding constraint, data freshness — and withholds only *which product it is*. A locked card that is merely a teaser fails the hypothesis before the user has spent anything.

---

## 1. Target User

### 1.1 Primary persona — "Second-year Sam"

| Attribute | Detail |
|---|---|
| Who | Individual reseller in the chosen launch market, 6–36 months into retail arbitrage |
| Fulfilment | Marketplace fulfilment primarily (Amazon FBA in MVP), with some seller fulfilment from home |
| Tax | Commonly not tax-registered at first; exact VAT/GST/sales-tax treatment depends on launch market |
| Capital | Moderate monthly working capital; beta screening threshold is set in local currency for the chosen market |
| Current method | Manual: retailer clearance pages, Amazon Seller App scanner in-store, a spreadsheet, and paid deal groups or sourcing communities |
| Sophistication | Understands ROI, featured offer/Buy Box, sales rank, gating and basic fees. Does **not** necessarily understand the local tax regime or every marketplace fee, and knows it. |
| Pain | Time. Sourcing eats evenings. Most "deals" they check are dead on arrival. |
| Why they'd trust us | They already pay for deal lists. They will switch if our numbers survive contact with reality. |

Sam is the beta cohort. Sam can evaluate us — which is what we need, because we need informed judgement, not enthusiasm.

### 1.2 Secondary persona — "Curious Chris" (aware, not P0-optimised)

Complete beginner, has watched YouTube videos, has not bought stock yet. Chris is a large future market but a **bad hypothesis test**: if Chris doesn't buy, we cannot tell whether he distrusted the number or simply lacked nerve, capital, or a seller account. Chris is welcome to sign up; Chris is not recruited into beta, and Chris's non-purchase is excluded from the primary metric.

### 1.3 Explicit non-users at MVP

Wholesale/private-label sellers · agencies and VAs sourcing at volume · users whose workflow requires a non-Amazon marketplace during MVP · cross-border arbitrage users · anyone needing bulk CSV export.

---

## 2. Core Problem

### 2.1 The problem statement

> A reseller can find discounted products easily. What they cannot do quickly is know, **with enough confidence to risk their own money**, whether a specific discounted product will actually sell on the target marketplace at a profit after all real costs. In the MVP, that target marketplace is Amazon in the chosen launch market.

### 2.2 Decomposition — the four jobs

| # | Job | Today's cost to the user | Where it fails |
|---|---|---|---|
| 1 | **Find** candidate discounts | 1–3 hrs/evening across retailer sites and deal groups | Volume without filtering |
| 2 | **Verify** it's the same product on the marketplace | 1–3 min per product | Multipacks, variations, bundles — silent, expensive errors |
| 3 | **Calculate** true net profit | 2–5 min per product, in a spreadsheet | Referral fee, fulfilment fee, local tax treatment, prep, inbound shipping, returns, storage. Tax and fee mistakes can invalidate the deal. |
| 4 | **Judge** whether it will actually sell | Gut feel + Keepa chart squinting | Demand, competition, Amazon on the listing, price volatility |

Existing deal groups solve job 1 and half of job 4. They routinely fail jobs 2 and 3, which is where the losses live.

### 2.3 The insight the product is built on

**Resellers do not lack deals. They lack defensible numbers.**

A profit figure with no visible derivation is worth nothing to someone about to spend £300. Therefore the product is not a number — it is an *auditable* number. This is why every P0 acceptance criterion below includes a transparency requirement, and why "show a figure without letting the user see how it was derived" is treated as a defect.

### 2.4 Why now / why us

Not a novel problem. The differentiator is narrow and defensible: **conservative, itemised, tax-regime-aware maths with the workings shown, and prediction-vs-actual accountability.** Competitors optimise for the impressiveness of the number. We optimise for its survival.

---

## 3. Main User Journey

### 3.1 The critical path (the only path that matters)

```
   Sign up
      ↓
   Onboarding: country/market, tax status, fulfilment, budget, prep + shipping costs
      ↓   [5 free credits granted]
   Feed of LOCKED deal cards
      │   score · profit band · ROI band · category · retailer type · freshness
      ↓
   Tap a card → LOCKED DETAIL
      │   full score breakdown, all five components, penalties,
      │   assumptions, binding constraint — everything except identity
      ↓
   "Unlock — 1 credit"
      ↓
   UNLOCKED DETAIL
      │   product · retailer link · marketplace listing link
      │   itemised profit breakdown, line by line
      │   editable assumptions with live recalculation
      │   "Buy 6 units — limited by estimated demand"
      ↓
   ─── user leaves the app, goes to the retailer, spends their own money ───
      ↓
   Returns → "I bought this" → units + actual price paid
      ↓   [T+14 to 30 days, email prompt]
   Outcome: sold / partial / unsold / returned + actual proceeds
      ↓
   ★ HYPOTHESIS ANSWERED ★
```

### 3.2 Journey annotations

**The gap between unlock and purchase is where the hypothesis lives.** The user leaves us. We cannot observe the retailer transaction. Therefore:

- The unlocked view must be usable *at the point of purchase* — one tap to the retailer product page, one tap to the marketplace listing, breakdown visible on a phone without scrolling past the fold twice.
- The "I bought this" prompt must be trivially cheap: one tap from the deal, one number (units), optional price. Any friction here destroys the primary metric.
- We must prompt for it. A returning-user banner and a T+2 email on any deal unlocked but not marked.

**Under-reporting is the primary measurement risk.** Users who buy but never tell us look identical to users who didn't trust us. Mitigations in §10.5 and §11.

### 3.3 Secondary journeys (P1)

- **In-store scan:** scan barcode → normalise GTIN → resolve marketplace listing → enter shelf price → profit estimate. Same trust machinery, different entry point.
- **Watchlist:** save an unlocked deal, revisit, see whether its numbers moved.

---

## 4. MVP Feature List

Full inventory. Priorities assigned in §5.

| # | Feature | One-line scope |
|---|---|---|
| F1 | Auth + account | Email/password + magic link, session, sign out |
| F2 | Onboarding profile | country/market, tax status, fulfilment, budget, prep cost, inbound shipping, locale |
| F3 | Curated deal supply | Admin ingestion of verified deals (CSV + single-URL paste) |
| F4 | GTIN→marketplace matching | Canonical GTIN-14 exact match only; Amazon ASIN is an adapter-level external ID |
| F5 | Marketplace enrichment (Amazon MVP) | Keepa adapter: rank, offers, featured-offer/Buy Box, 90-day history, dimensions |
| F6 | Profit engine | Itemised, regime-driven tax treatment, explicit currency, conservative defaults |
| F7 | Deal Score | 5 components, penalties, visible breakdown |
| F8 | Deal feed (locked) | Filtered, sorted, redacted cards |
| F9 | Locked deal detail | Full reasoning, no identity |
| F10 | Unlock + credits ledger | Atomic spend, permanent unlock, free grant |
| F11 | Unlocked deal detail | Identity + itemised breakdown + links |
| F12 | Editable assumptions | Live recalculation, no credit cost |
| F13 | Unit recommendation | Suggested units + stated binding constraint |
| F14 | "I bought this" | Purchase record + outcome follow-up |
| F15 | Report a deal | "This looks wrong" → refund path |
| F16 | Admin console | Ingestion, match review, credit adjust, deal publish/retire |
| F17 | Credit packs + Stripe | Checkout, webhook-granted credits |
| F18 | Watchlist | Save / list / remove |
| F19 | Barcode lookup | Scanner + manual entry → profit estimate |
| F20 | Credit history | Ledger view |
| F21 | Legal + disclaimers | ToS, privacy, "estimates not advice" |
| F22 | PWA shell | Manifest, icons, add-to-home-screen |
| F23 | Outcome email prompt | T+14 nudge for pending purchases |

---

## 5. Priorities: P0 / P1 / P2

### 5.1 P0 — beta cannot start without these

The test: *remove it, and can we still answer "did they trust it enough to buy?"* If no, it's P0.

| # | Feature | Why P0 |
|---|---|---|
| F1 | Auth + account | Identity for attribution |
| F2 | Onboarding profile | Country/market and tax status can materially change profit. A wrong assumption here invalidates the recommendation. |
| F3 | Curated deal supply | No deals, no test. Manual is sufficient and fastest. |
| F4 | GTIN→marketplace matching | One bad match ends a user relationship permanently |
| F5 | Amazon enrichment | Inputs to profit and score |
| F6 | Profit engine | **This is the product** |
| F7 | Deal Score | The compression that makes a feed scannable |
| F8 | Deal feed (locked) | The discovery surface |
| F9 | Locked deal detail | Where pre-purchase trust is earned (see §0.4) |
| F10 | Unlock + credits ledger | The scarcity that makes an unlock a signal of intent |
| F11 | Unlocked deal detail | The purchase decision surface |
| F12 | Editable assumptions | "I can check your working with my own costs" — the single strongest trust affordance we have |
| F13 | Unit recommendation | Converts a deal into an actionable capital decision |
| F14 | "I bought this" + outcome | **The measurement instrument. Without it there is no experiment.** |
| F15 | Report a deal | Both a trust signal and our match-quality feedback loop |
| F16 | Admin console | Operationally required to run curation |
| F21 | Legal + disclaimers | Non-negotiable before real money |

**P0-late (build last, must not block beta week 1):**

| # | Feature | Note |
|---|---|---|
| F17 | Credit packs + Stripe | Required for *commercial* testability. Ships week 5–6. If it slips, beta proceeds on manual grants and Stripe lands mid-beta. |
| F20 | Credit history | Trivial once the ledger exists; ships with F17 |

### 5.2 P1 — ship during beta if the core loop is stable

| # | Feature | Why not P0 |
|---|---|---|
| F18 | Watchlist | Retention feature. A 4-week beta cannot measure retention, and a watchlist without alerts is a bookmark. Cheap (~half a day) — ship it if week 5 is calm. |
| F19 | Barcode lookup | Tests a *different* hypothesis (in-store sourcing) with a *different* failure mode. Costs 4–6 days for camera permissions, device fragility, iOS Safari `BarcodeDetector` gaps, and a manual fallback. The feed already answers the question we're asking. |
| F22 | PWA shell | Manifest + icons is half a day; genuinely nice-to-have. Mobile web works without it. |
| F23 | Outcome email prompt | Manual emails to 30 beta users are fine for four weeks. Automate only if manual chasing proves unsustainable. |

### 5.3 P2 — post-beta, explicitly deferred

Price-drop alerts · push notifications · automated affiliate-feed ingestion · SP-API / seller integration · gating and restriction checks · portfolio P&L · in-store and local sourcing maps · AI sourcing assistant · fuzzy/title matching · multipack detection · subscriptions · referrals · CSV export · multi-marketplace · native apps · Python services · 3PL and shipment workflow.

### 5.4 Challenges to the brief — stated plainly

Four items from the original MVP framing that I am moving:

1. **Barcode lookup → P1.** Not because it's bad, but because it's a second product surface competing for the same six weeks. It answers "would they use us in Aldi?" — a good question, and the wrong one to ask first.
2. **Watchlist → P1.** Retention has no signal in a 4-week window.
3. **Automated ingestion → P2.** ARCHITECTURE.md §10.3 already makes this case. Fifty verified deals beats five thousand unverified ones, and a scraper that dies in week 3 kills the beta.
4. **Stripe → P0-late.** Real money for stock is the hypothesis. Real money for credits is the business model, and it can be validated two weeks later without loss.

One thing I am **adding** to P0 that wasn't in the brief: **F15, report a deal.** It costs half a day, it is the fastest bad-match detector we will ever have, and a visible refund policy is disproportionately powerful as a trust signal at exactly the moment a user is deciding whether to believe us.

---

## 6. User Stories

Grouped by feature. `[P0]` / `[P1]` marked.

### Onboarding
- `[P0]` As a new user, I want to state my country/market and tax-registration status during signup, so profit figures reflect the applicable local regime rather than a global average.
- `[P0]` As a new user, I want to enter my own prep and inbound shipping costs, so the numbers match my operation instead of a generic assumption.
- `[P0]` As a new user, I want free credits on signup, so I can evaluate a full deal before deciding whether the product is worth paying for.
- `[P0]` As a user, I want to change my tax-registration status later, so my figures stay correct when my circumstances change.

### Discovery
- `[P0]` As a reseller, I want a feed of pre-vetted opportunities ranked by quality, so I stop spending evenings checking dead ends.
- `[P0]` As a reseller with a fixed local-currency budget to deploy, I want to filter by minimum profit, minimum ROI, and my budget, so I only see deals I can actually act on.
- `[P0]` As a sceptical user, I want to see *why* a locked deal scored what it scored before I spend a credit, so unlocking is an informed choice rather than a gamble.
- `[P0]` As a user, I want to see how fresh the Amazon data is, so I know whether I'm looking at a live opportunity or a stale one.

### Analysis
- `[P0]` As a reseller, I want every cost broken out line by line — buy price, referral fee, fulfilment fee, applicable tax treatment, prep, shipping, storage, returns — so I can verify the maths myself.
- `[P0]` As a reseller, I want to change the assumed sell price and my costs and see the profit update immediately, so I can stress-test the deal against my own judgement.
- `[P0]` As a reseller, I want to understand the demand, competition, and price-stability judgements separately, so I can weigh the risks I personally care about.
- `[P0]` As a cautious buyer, I want to know when the app is uncertain — weak match, missing data, stale figures — so I can discount its advice accordingly.
- `[P0]` As a user, I want a direct link to both the retailer page and the marketplace listing, so I can verify the product with my own eyes before buying.

### Decision
- `[P0]` As a reseller with a fixed budget, I want a recommended number of units **and the reason for that number**, so I don't over-commit capital to a slow seller.
- `[P0]` As a reseller, I want to know how much cash the recommendation ties up, so I can plan across several deals.

### Purchase and outcome
- `[P0]` As a user who acted on a deal, I want to record that I bought it in one tap, so I can later compare what was predicted with what happened.
- `[P0]` As a user, I want to record the outcome when the stock sells, so I can judge whether this app is actually worth paying for.
- `[P0]` As a user who spotted an error, I want to report a deal and get my credit back, so a mistake costs me nothing but time.

### Credits and payment
- `[P0]` As a user, I want unlocks to be permanent, so I never pay twice for the same information.
- `[P0]` As a user, I want to see my balance and what I spent it on, so I trust the accounting.
- `[P0-late]` As a user who has used the free credits, I want to buy more in a few taps, so I can keep sourcing.

### Admin (founder-facing)
- `[P0]` As the operator, I want to upload candidate products and see the computed deal before publishing, so nothing reaches a user unverified.
- `[P0]` As the operator, I want to retire a deal instantly, so a discovered error stops spreading.
- `[P0]` As the operator, I want to refund credits, so I can honour the refund policy.
- `[P0]` As the operator, I want to compare predicted profit against reported actuals, so I can calibrate the score.

### Deferred
- `[P1]` As a user, I want to save a deal to a watchlist, so I can revisit it when I have capital.
- `[P1]` As a user standing in a shop, I want to scan a barcode and get a profit estimate, so I can decide at the shelf.

---

## 7. Acceptance Criteria for P0 Features

Written as verifiable conditions. Given / When / Then where behavioural.

---

### F1 — Auth + account

- **AC1.1** Given a valid email and password, when a user signs up, then an account and profile are created and a verification email is sent.
- **AC1.2** Given an unverified account, when the user attempts to spend a credit, then the spend is refused with a clear "verify your email" message and **no credit is deducted**.
- **AC1.3** Given a logged-out visitor, when they request any `/(app)/*` route, then they are redirected to sign-in and returned to the intended route afterwards.
- **AC1.4** Session tokens are never present in `localStorage` or any client-readable storage. Verified by inspection as a release gate.
- **AC1.5** A user can delete their account; all **personal** rows cascade and the deletion completes within 30 days per the applicable privacy regime and the product's GDPR-grade baseline.
- **AC1.6** **Financial records are retained, not deleted.** Credit ledger entries and credit purchase records survive account deletion for audit and reconciliation — they are never cascade-deleted with the account, and the retained rows must not identify the deleted user. A chargeback can arrive after an account closes, and a reconciliation a user can empty by closing their account proves nothing. The privacy policy states this retention plainly, and the mechanism that de-identifies the retained rows is decided and implemented in T10.

---

### F2 — Onboarding profile

- **AC2.1** Onboarding collects, in order: country/market → tax-registration status → fulfilment method → budget → prep cost per unit → inbound shipping per unit. It cannot be skipped, but fields after market/tax selection may have clear market-specific defaults.
- **AC2.2** Country selection resolves an active `market_id`, currency, locale and tax regime. If the user's country has no live market, they are waitlisted rather than shown a foreign or empty feed.
- **AC2.3** Tax-registration status defaults to the conservative non-registered treatment where applicable, with a plain-language explanation appropriate to the market's tax regime.
- **AC2.4** Given a user changes tax-registration status or cost assumptions in settings, when they next view a deal detail, personalised figures reflect the new status without mutating the canonical stored deal.
- **AC2.5** Onboarding completes in under 60 seconds for a user accepting defaults. Measured on a mid-range Android phone.
- **AC2.6** All money inputs use the active market currency in the UI and are stored as integer minor units with an explicit currency code. No currency symbol or decimal exponent is hard-coded.
- **AC2.7** MVP permits only domestic single-currency deal analysis. A user cannot select a source market and resale marketplace that would require FX.

---

### F3 — Curated deal supply

- **AC3.1** An admin can upload a CSV of candidate products (market, retailer, SKU, title, GTIN/EAN/UPC, price, currency, URL) and receives a per-row result: matched / unmatched / failed, with reasons.
- **AC3.2** An admin can paste a single retailer product URL plus a GTIN and price/currency, and produce one candidate within a selected market.
- **AC3.3** No ingested product becomes a user-visible deal without an explicit **publish** action by an admin.
- **AC3.4** Every ingestion run records rows in, rows upserted, rows failed, and per-row errors.
- **AC3.5** At beta launch, at least **60 published, admin-verified live deals** exist in the chosen launch market, spanning at least 3 retailers and 4 marketplace categories.
- **AC3.6** An admin can retire a live deal, and it disappears from all user feeds within 60 seconds. Users who already unlocked it retain access, with a "this deal has been retired" banner.
- **AC3.7** **A newly computed deal is created in `draft` and is invisible to users.** No user-facing surface returns a deal that is not `active`. The computation pipeline never publishes: publication is a separate, explicit admin act. This is AC3.3 made structural rather than procedural — "nothing reaches a user unverified" must not depend on a service remembering.
- **AC3.8** **Retirement is permanent.** A retired deal never returns to `draft` or `active`. Correcting a retired deal means computing a new one; the retired row remains as the record of what was shown and when. A user who unlocked it keeps access under AC3.6 and AC10.7.
- **AC3.9** **Hard suppression on recompute retires the deal.** Where a recompute of an `active` deal newly trips a hard suppression rule (net profit ≤ 0, match confidence < 0.6, required inputs missing — AC7.5), the deal is retired with reason `suppressed_on_recompute` rather than left live or silently downgraded. A deal that no longer passes its own publication bar must stop being shown, and the reason must be recorded.
- **AC3.10** Only one non-retired deal exists per retailer-product/marketplace-product pair at a time, so an admin reviewing the queue is never choosing between duplicate candidates for the same product.

---

### F4 — GTIN→marketplace matching

- **AC4.1** Matching uses exact canonical GTIN-14 derived from EAN/UPC/other supported GTIN forms. Title/fuzzy matching is not enabled.
- **AC4.2** Given a match confidence below 0.6, when the pipeline runs, then no deal is created and the row is queued for admin review.
- **AC4.3** Given a match confidence between 0.6 and 0.8, when a deal is created, then a score penalty is applied and the deal is flagged for admin review before publish.
- **AC4.4** Every published deal displays its match confidence to the user in plain language, not as a raw decimal.
- **AC4.5** Where the retailer product is a multipack and the marketplace listing is a single unit (or vice versa), the admin review UI surfaces the pack-size discrepancy from title and weight before publish. **Multipack mismatch is the single highest-frequency catastrophic error in this category and must not be caught by users.**

---

### F5 — Marketplace enrichment (Amazon/Keepa in MVP)

- **AC5.1** Every published MVP deal has the Amazon/Keepa inputs required by the active scoring configuration: demand/rank data, featured-offer/Buy Box price, offer counts, and 90-day price statistics. Future marketplaces may expose different capabilities; unavailable components must be disclosed and handled per ARCHITECTURE.md §8.7.
- **AC5.2** Given missing weight or dimensions for a marketplace-fulfilled deal, when the pipeline runs, then **no profit figure is produced** and the deal is suppressed. No estimated dimensions are ever substituted.
- **AC5.3** Every deal displays the age of its marketplace data. Data older than 48 hours is visually marked as stale.
- **AC5.4** Keepa token consumption per run is logged and a daily cap is enforced; exceeding the cap halts refresh and logs, rather than degrading silently.

---

### F6 — Profit engine

- **AC6.1** The output is an itemised breakdown, never a single figure. Minimum lines: buy price, tax treatment (labelled per the resolved market's regime — VAT, GST, sales tax or none), referral fee, fulfilment fee, storage, prep, inbound shipping, returns allowance, net profit, ROI, margin.
- **AC6.2** The pricing engine supports the tax regime selected by the resolved MarketContext (VAT, GST, sales tax or none). It must distinguish registered vs non-registered treatment where the regime supports it, and must not hard-code country-specific rates.
- **AC6.3** Where the applicable tax regime permits input-tax recovery, the UI displays any evidence/invoice caveat required for that treatment. Where tax treatment is uncertain, the deal is flagged rather than guessed.
- **AC6.4** Assumed sell price is the **lower** of the current featured-offer/Buy Box price and its 90-day average where price-history capability is available. Never the peak, never the maximum.
- **AC6.5** A returns allowance and at least one month of storage are included by default.
- **AC6.6** Profit rounds **down**; ROI rounds **down**. Rounding occurs only at the final step.
- **AC6.7** ROI is calculated on **cash deployed** (buy price + prep + inbound shipping) and the denominator is labelled in the UI.
- **AC6.8** All money is integer minor units throughout and always carries an ISO 4217 currency code. Currency exponent comes from configuration, never an assumed ×100. Fee rates come from a versioned fee schedule in the database, never from constants in code.
- **AC6.9** At least **15 hand-worked test cases** pass, covering: registered and non-registered tax cases where applicable, tax-inclusive and tax-exclusive retail pricing, marketplace-fulfilled and seller-fulfilled flows, minimum referral fee, fulfilment-band boundaries, zero and negative profit, and a heavy/oversize item. Tests cover at least two currencies, including one non-2-decimal currency.
- **AC6.10** Every deal stores a full snapshot of its inputs and a calculation version stamp, such that any historical figure can be reproduced exactly.

---

### F7 — Deal Score

- **AC7.1** Score is 0–100. The default Amazon-MVP configuration uses five components: profitability 35%, demand 25%, competition 20%, price stability 10%, confidence 10%.
- **AC7.2** The breakdown — each component's score, weight, and the raw inputs behind it — is persisted and displayed to the user.
- **AC7.3** Every applied penalty is named in the UI in plain English (e.g. "the marketplace operator is selling on this listing").
- **AC7.4** Sales rank is normalised **within category** before scoring.
- **AC7.5** Hard suppression: no deal is published where net profit ≤ 0, match confidence < 0.6, or required inputs are missing.
- **AC7.6** Given identical inputs, the scorer returns an identical score. Verified by table-driven tests.
- **AC7.7** All weights, penalty factors and market-specific thresholds live in controlled configuration. No magic constants elsewhere in scoring code.
- **AC7.8** If a future marketplace lacks a scoring capability, the unavailable component is dropped, remaining weights are renormalised, confidence is reduced, and the missing capability is visibly disclosed. No synthetic default score is substituted.

---

### F8 — Deal feed (locked)

- **AC8.1** A locked card shows: Deal Score, profit band, ROI band, marketplace category, retailer *type* (e.g. "supermarket"), and data freshness.
- **AC8.2** A locked card's server response contains **no** product title, image, marketplace external ID, retailer name, retailer URL, or raw/canonical GTIN. This is enforced by an automated test asserting the serialised payload, and that test is a CI blocker.
- **AC8.3** Filters available: minimum profit, minimum ROI, minimum score, category, budget ceiling. Filters are applied server-side and every query is scoped to the user's active market.
- **AC8.4** Default sort is Deal Score descending. Deals scoring under 50 are excluded from the default feed.
- **AC8.5** The feed renders in under 2 seconds on a mid-range Android phone over 4G.
- **AC8.6** An empty or over-filtered feed shows an explanatory state, never a blank screen. A user in a country without a live market sees a waitlist/not-live state rather than deals from another market.

---

### F9 — Locked deal detail

- **AC9.1** Shows the complete score breakdown: all five components with scores, weights, and inputs.
- **AC9.2** Shows all named penalties and all risk flags.
- **AC9.3** Shows the profit and ROI **bands**, the assumption set used, and the data freshness — but not the exact figures tied to an identifiable product.
- **AC9.4** Contains no identifying information, per AC8.2, verified by the same test.
- **AC9.5** Displays the credit cost of unlocking and the user's current balance before the user commits.
- **AC9.6** Displays the refund policy link adjacent to the unlock button.

---

### F10 — Unlock + credits ledger

- **AC10.1** Given a balance of 1 credit, when 10 unlock requests arrive concurrently, then exactly one succeeds and the balance is 0. Verified by an automated concurrency test.
- **AC10.2** Given an already-unlocked deal, when unlock is called again, then the full deal is returned and **no credit is charged**.
- **AC10.3** Given insufficient credits, when unlock is called, then a `INSUFFICIENT_CREDITS` error is returned with a route to obtain more, and no partial state is written.
- **AC10.4** The credit spend and the unlock record are written in the same transaction. Neither can exist without the other.
- **AC10.5** The ledger is append-only. `UPDATE` and `DELETE` are rejected at the database level.
- **AC10.6** New users receive 5 credits on signup, recorded in the ledger with reason `signup_grant`.
- **AC10.7** Unlocks are permanent and survive any subsequent deal retirement.
- **AC10.8** A nightly reconciliation confirms that for every user, the sum of ledger deltas equals the cached balance. Any mismatch raises an alert.

---

### F11 — Unlocked deal detail

- **AC11.1** Shows product title, image, brand, exact retailer name, and pack size.
- **AC11.2** Provides one-tap links to both the retailer product page and the marketplace listing (Amazon in MVP). Both open in a new tab and are verified live at publish time.
- **AC11.3** Shows the full itemised profit breakdown per AC6.1, personalised to the user's tax status, market context and cost assumptions.
- **AC11.4** Shows the score breakdown, all penalties, and all risk flags.
- **AC11.5** Displays a gating warning: the user is responsible for checking their own selling eligibility for the brand and category.
- **AC11.6** Displays the "estimates, not guarantees; not financial or tax advice" disclaimer within the same screen as the profit figure — not in a footer, not behind a link.
- **AC11.7** The entire breakdown is legible on a 375px-wide viewport without horizontal scrolling.

---

### F12 — Editable assumptions

- **AC12.1** The user can override: assumed sell price, prep cost, inbound shipping, expected storage months, and number of units.
- **AC12.2** Recalculation is immediate and costs no credits.
- **AC12.3** Overrides are session-scoped by default, with an explicit "save as my defaults" action that updates the profile.
- **AC12.4** The canonical stored deal is never mutated by a user's override.
- **AC12.5** When a user's overrides push net profit to zero or below, this is stated plainly rather than hidden or floored at zero.

---

### F13 — Unit recommendation

- **AC13.1** Recommends a unit count constrained by the minimum of: budget capacity, estimated demand share, score-band risk cap, and a per-deal capital-at-risk cap (default 20% of stated budget).
- **AC13.2** The **binding constraint is named in plain English** — e.g. "Limited to 6 units by estimated demand: 8 sellers are already sharing roughly 90 sales a month."
- **AC13.3** Displays total cash required and total expected profit for the recommended quantity.
- **AC13.4** Never recommends fewer than 1 unit for a published deal.
- **AC13.5** Recommendation updates live when the user changes their budget in the assumptions panel.

---

### F14 — "I bought this" + outcome

- **AC14.1** Reachable in one tap from any unlocked deal.
- **AC14.2** Requires only unit count. Actual price paid is optional and pre-filled with the deal's buy price.
- **AC14.3** On save, the deal's predicted per-unit profit and full inputs snapshot are frozen onto the purchase record.
- **AC14.4** The user can later record an outcome: sold / partial / unsold / returned, with optional actual proceeds.
- **AC14.5** The user can view their own purchase list showing predicted versus actual where both exist.
- **AC14.6** An admin can export or view predicted-versus-actual across all users, grouped by score band.
- **AC14.7** A purchase can be recorded up to 90 days after unlock.
- **AC14.8** Recording a purchase takes under 10 seconds end to end on a phone.

---

### F15 — Report a deal

- **AC15.1** A report control is available on every unlocked deal.
- **AC15.2** Reasons offered: wrong product matched · wrong pack size · price is wrong · out of stock · other (free text).
- **AC15.3** Reports appear in an admin queue with the deal, the reporter, and the reason.
- **AC15.4** An admin can confirm a report, which retires the deal and refunds the credit to every user who unlocked it, recorded in the ledger with reason **`refund`** and a **positive** delta — the credit is restored, one ledger row per affected user. This reason is reserved for restoring credits after our own error; a Stripe payment reversal is `chargeback` (AC17.5) and moves in the opposite direction.
- **AC15.5** The refund policy is published and linked from the unlock button and the credits page.
- **AC15.6** **A confirmed bad-match report marks the underlying product match rejected**, not just the deal retired. Retiring the deal alone is not enough: the match is what was wrong, and the next pipeline run would recompute the same deal from the same match and republish the same error. A rejected match is never used to create a deal again, and reversing that judgement is a deliberate admin act.

---

### F16 — Admin console

- **AC16.1** Access is gated by a server-side role check. No client-side hiding.
- **AC16.2** Provides: ingestion upload and run history · match review queue with approve/override/reject · deal preview before publish · publish/retire · report queue · credit adjustment · predicted-vs-actual view.
- **AC16.3** Every admin credit adjustment writes a ledger row with reason `admin_adjust` and an actor reference.
- **AC16.4** Fee schedules are editable through the console and versioned; editing creates a new version rather than mutating the current one.

---

### F17 — Credit packs + Stripe *(P0-late)*

- **AC17.1** Credits are granted **only** by the verified Stripe webhook, never by the success redirect.
- **AC17.2** Webhook signature is verified against the raw request body.
- **AC17.3** A replayed webhook event grants credits exactly once. Verified by Stripe CLI replay as a release gate.
- **AC17.4** Pack price and credit quantity are read server-side from the database. No client-supplied price or quantity is ever trusted.
- **AC17.5** A **Stripe refund or chargeback** — the payment being reversed — deducts credits with a **negative** delta recorded under reason **`chargeback`**, permitting a negative balance; history is never erased and no ledger row is edited or removed. This is distinct from a bad-deal credit refund (AC15.4, reason `refund`, positive): one is a payment failure, the other a product failure, and they are reported and reconciled separately.
- **AC17.6** The success page polls the balance rather than asserting success from the redirect.

---

### F21 — Legal + disclaimers

- **AC21.1** Terms of service, privacy policy, and refund policy are published and linked from the footer and from signup. Market-specific notices are added before a market goes live.
- **AC21.2** "Estimates, not guarantees. Not financial or tax advice." appears on every screen displaying a profit figure.
- **AC21.3** A gating and eligibility warning appears on every unlocked deal.
- **AC21.4** the applicable privacy regime and the product's GDPR-grade baseline: users can export their data and delete their account from settings under the product's GDPR-grade baseline; additional jurisdiction-specific rights are handled as market requirements. The privacy policy states which records are **retained after deletion** and why — credit ledger and purchase history are kept as financial and audit records, de-identified rather than deleted (AC1.6).

---

## 8. Explicitly Excluded from MVP

Each exclusion carries its reason, so it can be revisited on evidence rather than mood.

| Excluded | Reason | Revisit when |
|---|---|---|
| **Automated retailer scraping** | Highest-effort, highest-fragility, ToS-hostile component in the system. The single fastest way to spend three months and ship nothing. | Hypothesis validated and deal supply is the binding constraint |
| **Automated affiliate feed ingestion** | Curation gives higher-quality deals faster. Feeds are a scaling tool, not a validation tool. | Post-beta, as the first scaling investment |
| **Amazon SP-API / seller account integration** | Requires seller account, developer registration, OAuth and regional setup. Keepa is sufficient for the first MVP data path. | Phase 3, alongside real fee previews and eligibility checks |
| **Marketplace selling-eligibility / restriction checks** | Genuinely valuable, but Amazon MVP requires SP-API for seller-specific checks. Mitigated by explicit warnings. | With seller-account integration |
| **Portfolio / inventory P&L** | Not the hypothesis. "I bought this" measures prediction accuracy; a P&L system does not, and costs 2+ weeks. | Once users have enough recorded purchases to want a ledger |
| **Push notifications and price alerts** | Retention mechanics for a product with no proven core value. Permissions, infra, and delivery reliability are their own project. | Phase 2 |
| **Local / in-store sourcing maps** | Geolocation, store-level inventory, a different data problem entirely | Phase 4 |
| **AI sourcing assistant** | A chat wrapper over unvalidated data is theatre. This only becomes real when grounded in our own structured, calibrated data. | Phase 4, after score v2 calibration |
| **3PL / marketplace-fulfilment shipment workflow** | Post-purchase operations. Entirely outside the hypothesis. | Phase 5 |
| **Subscriptions** | Churn, dunning, proration, failed-payment recovery — none of which test trust. Credits also price the underlying data cost naturally. | When credit repurchase rate proves demand is recurring |
| **Fuzzy / title matching** | Directly increases catastrophic-mismatch risk, which is risk #1. Exact GTIN-14 only until match quality is proven. | With a human review queue at volume |
| **Additional marketplace integrations / simultaneous multi-market launch** | Each adds distinct fees, capabilities, tax verification and deal-supply work. Architecture supports them, but beta should not. | After the first market validates the core loop |
| **Native mobile apps** | Mobile web is sufficient. App store review is a release-cadence tax. | If device APIs become essential |
| **Team accounts, referrals, CSV export** | No user has asked. No hypothesis needs them. | On request, with evidence |
| **Python data services** | Nothing in the MVP requires a second language or runtime | Phase 4, for vector matching or statistical modelling |
| **Real-time updates** | Prices refresh hourly at best. Nobody needs a websocket. | Never, probably |
| **Advanced/local tax schemes and cross-border tax** | Long tail of jurisdiction-specific complexity | On demand from paying users and before each affected market opens |

---

## 9. Key Product Metrics

### 9.1 North Star

> **Purchase Conviction Rate** — of users who unlock at least one deal, the percentage who record at least one purchase within 14 days.

This is the hypothesis expressed as a number. Nothing else on this page outranks it. It is measured **per market**, never pooled across countries.

**Beta target: ≥ 30%.** Rationale: the cohort already buys stock, so the question is switching trust rather than creating behaviour. Below 20% and the product's core premise is in doubt. Above 40% and we should be moving quickly to scale deal supply.

### 9.2 The quality metric (co-primary)

> **Prediction Accuracy** — of purchases with a recorded outcome, the percentage achieving at least 70% of predicted net profit.

**Beta target: ≥ 60%.**

This is the metric that determines whether the business has a future. A high Conviction Rate with poor Accuracy means we have persuaded people to lose money, which is worse than failing.

### 9.3 Funnel metrics

| Stage | Metric | Beta target |
|---|---|---|
| Activation | Signup → onboarding complete | ≥ 85% |
| Engagement | Onboarding → first deal detail viewed | ≥ 80% |
| **Trust point 1** | Deal detail viewed → first unlock | ≥ 50% |
| Depth | Median unlocks per active user per week | ≥ 3 |
| **Trust point 2** | Unlock → purchase recorded | ≥ 30% |
| Follow-through | Purchase → outcome recorded | ≥ 60% |
| Retention | Week 1 → week 3 active | ≥ 40% |
| **Monetisation** | Users exhausting free credits → buy a pack | ≥ 25% |

The two "trust points" are where the hypothesis actually gets tested. Everything else is plumbing.

### 9.4 Trust-damage signals (watch daily)

| Signal | Meaning | Alarm threshold |
|---|---|---|
| Deal report rate | Users catching our errors | > 3% of unlocks |
| Confirmed bad matches | Errors that were real | > 1% of unlocks — **stop and fix** |
| Assumptions-panel edit rate | Users disagreeing with our defaults | > 50% suggests our defaults are wrong |
| Unlock-then-immediate-exit rate | Deal disappointed on reveal | > 40% |
| Credit refunds issued | Direct cost of error — ledger reason `refund` **only**; Stripe reversals (`chargeback`) are a payment signal, not a trust signal, and must not be counted here | Any spike |

### 9.5 Health and cost

Provider cost per published deal · provider cost per unlock (must stay well below credit price) · deals published per week per market · deal freshness distribution · error rate · p95 feed latency. For the MVP provider, track Keepa token usage explicitly.

### 9.6 Qualitative — mandatory, not optional

At 20–50 users, quantitative signal is thin. **Ten user interviews are worth more than the entire dashboard.** Specifically: watch three users unlock a deal while narrating their thinking. The question "what would make you doubt this number?" will teach more in twenty minutes than a week of funnel analysis.

---

## 10. Beta Test Plan (20–50 users)

### 10.1 Objectives

1. Measure Purchase Conviction Rate and Prediction Accuracy.
2. Discover what specifically causes users to distrust a number.
3. Detect calculation, matching, and fee errors before public launch.
4. Establish whether curated supply at ~60 deals/week is sufficient to sustain engagement.

### 10.2 Recruitment

- **Target: 35 users.** Below 20 the data is anecdote; above 50 the founder cannot run curation and support simultaneously.
- **Source:** arbitrage communities in the chosen launch market: relevant Facebook/Reddit/Discord/Telegram groups and direct outreach to existing paid-deal-group members.
- **Screening (required):** based in the chosen launch market · has an active Amazon seller account for that marketplace · has bought stock for resale in the last 90 days · meets the market-local working-capital threshold · willing to record purchases and outcomes.
- **Excluded:** complete beginners (see §1.2), users outside the chosen launch market for this beta, users requiring cross-border or non-Amazon flows, and anyone unwilling to report outcomes.
- **Incentive:** 40 free credits (≈8 weeks of typical use) plus lifetime founder pricing. Deliberately **not** cash — cash buys compliance, not honest judgement.

### 10.3 Structure — 4 weeks

| Week | Focus | Activity | Gate |
|---|---|---|---|
| **0** | Dry run | Founder + 3 friendly users. 5 deals bought with founder's own money. | Predictions survive contact with reality; no P0 defects |
| **1** | Onboarding cohort | 15 users. Daily deal refresh. Daily error monitoring. 5 onboarding interviews. | Activation ≥ 80%; zero confirmed bad matches |
| **2** | Full cohort | +20 users. Stripe live. First purchase data lands. 5 unlock-observation sessions. | Trust point 1 ≥ 40% |
| **3** | Depth | No new users. Push outcome recording. Ship P1 items if stable. Mid-beta survey. | Purchases recorded ≥ 15 across cohort |
| **4** | Outcomes and readout | Chase outcomes. 10 exit interviews. Score v1 calibration analysis. | Both primary metrics measured |

### 10.4 Deal supply commitment

The beta lives or dies on this: **15 new verified deals per week, minimum, every week.** This is roughly 6–8 hours of founder curation weekly and must be calendared as a non-negotiable operational commitment, not fitted around development. A beta with a stale feed measures nothing.

### 10.5 Measurement integrity

The primary risk is **silent purchasing** — users who buy but never tell us, making trust look like distrust.

Mitigations:
1. Screening includes an explicit commitment to report.
2. In-app banner on any deal unlocked >48h ago and unmarked.
3. Personal email from the founder at T+3 on unmarked unlocks. At 35 users this is genuinely feasible and doubles as qualitative research.
4. Exit interviews ask directly: "did you buy anything you didn't record?" — and the answer adjusts the reported metric with the adjustment disclosed.

### 10.6 Feedback channels

In-app "report this deal" (structured) · a shared beta Discord or WhatsApp group (fast, honest, high-signal) · scheduled 1:1 calls (10 minimum across the beta) · mid-beta and exit surveys.

### 10.7 Exit criteria

**Proceed to public launch:** Conviction ≥ 30% · Accuracy ≥ 60% · confirmed bad matches < 1% · at least 25 recorded purchases · at least 15 recorded outcomes · ≥ 25% of credit-exhausted users bought a pack.

**Iterate, don't launch:** Conviction 15–30%, or Accuracy 40–60%. The loop works but something specific is broken — interviews will say what.

**Reconsider the product:** Conviction < 15% *with* Accuracy ≥ 60%. This is the informative failure: our numbers were right and users still didn't act. The problem is not the maths, and no amount of engineering fixes it.

---

## 11. Main Product Risks

Product risks. Technical risks are covered in ARCHITECTURE.md §16 and not repeated.

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| **1** | **Deal supply is too thin or too weak.** Curation yields few genuinely good deals; users open the feed and find nothing worth buying. **This is the most likely reason the beta fails, and it will look like a trust failure.** | High | Fatal | 15 verified deals/week as a calendared commitment; measure "deals meeting a user's filters" per user, not deals published; if supply is the binding constraint, say so in the readout rather than mislabelling it as distrust |
| **2** | **Users buy but don't report.** Conviction Rate under-reads; we draw the wrong conclusion. | High | High | §10.5 in full; adjust the reported metric using exit-interview disclosure |
| **3** | **The paywall blocks the trust it depends on.** Users won't spend a credit on an unproven product, so they never see the evidence that would convince them. | Medium | High | Generous free grant (5, raise on evidence); locked detail carries full reasoning minus identity; visible refund policy; raise the grant immediately if trust point 1 falls below 40% |
| **4** | **One bad match destroys a user permanently.** Multipack/variation mismatch is the classic killer. | Medium | Severe | GTIN-14 exact only; admin pack-size check before publish (AC4.5); confidence surfaced; report-and-refund; treat any confirmed bad match as a stop-the-line event |
| **5** | **Prediction accuracy fails on contact with reality.** Fees, tax treatment, or demand estimates prove wrong once real stock is bought. | Medium | Severe | Founder buys 5 deals in week 0 with own money; conservative defaults throughout; validate fees against real Amazon settlement reports in the chosen launch market during beta; treat accuracy as co-primary, not secondary |
| **6** | **Users trust the number and still don't buy** — capital constraints, gating fear, storage limits, other priorities. | Medium | High | Exit interviews specifically probe non-purchase reasons; gating warning in-product; this outcome is *informative*, not merely negative, and changes the roadmap toward gating checks |
| **7** | **Scope creep.** Barcode, watchlist, feeds, alerts all feel small individually. | High | High | This document is the contract; P1 items ship only after the P0 loop is stable; anything unlisted goes to backlog untouched |
| **8** | **Founder capacity collapse.** Curation (6–8h/wk) + support + interviews + development is more than one person's week. | High | High | Cap the cohort at 35; freeze development in beta weeks 3–4; batch curation into two fixed sessions per week |
| **9** | **Marketplace eligibility/gating causes a user loss we predicted nothing about.** User buys stock they cannot sell. | Medium | High | Prominent eligibility warning; brand risk-flag list; suppress known-problem brands; SP-API restriction checks prioritised in Phase 3 |
| **10** | **Seasonality distorts the read.** Beta timing lands in a quiet or abnormal retail period. | Medium | Medium | Note the calendar window in the readout; avoid Q4 and the immediate post-Christmas clearance distortion for the primary read |
| **11** | **Free credits produce tourist behaviour.** Users unlock casually because it costs nothing, inflating unlock rate and depressing Conviction. | Medium | Medium | Segment the metric by pre- and post-grant-exhaustion; treat post-exhaustion behaviour as the higher-quality signal |
| **12** | **Perceived-as-advice liability.** An app telling people what to buy with their money. | Low | High | "Estimate" and "opportunity" language only, never "guaranteed"; disclaimers adjacent to figures, not in footers; ToS before any real user |

---

## 12. Recommended Release Criteria

Three gates. Each is a hard stop.

### 12.1 Gate A — Internal (before any external user)

**Correctness**
- [ ] All 15+ hand-worked pricing test cases pass (AC6.9)
- [ ] Launch-market tax-regime paths verified against worked examples by someone other than the author
- [ ] Redaction payload-leak test passes and is a CI blocker (AC8.2)
- [ ] Concurrency test passes: 10 parallel unlocks at balance 1 → exactly one succeeds (AC10.1)
- [ ] Ledger append-only enforcement verified at the database level
- [ ] Scoring determinism verified by table-driven tests

**Security**
- [ ] RLS enabled on every table, default deny; anon key verified to read nothing it shouldn't
- [ ] No secret reachable from the client bundle; service-role module is `server-only`
- [ ] Rate limits live on auth, unlock, and checkout
- [ ] Security headers configured

**Data**
- [ ] 60+ published deals in the chosen launch market, ≥3 retailers, ≥4 categories
- [ ] 100% of published deals manually spot-verified: correct marketplace listing, correct pack size, live retailer link, live price
- [ ] Fee schedule and tax schedule verified for the chosen launch market, with source and verification dates recorded

**Market readiness**
- [ ] Exactly one launch market is marked `live` for beta; all others remain `planned` or `beta-disabled`
- [ ] Launch market has verified currency, tax schedule, fee schedule, Amazon/Keepa coverage, Stripe support, and sufficient retailer deal supply
- [ ] Seeding a synthetic second market has been demonstrated without changing core business logic

**Reality check — the one that matters most**
- [ ] **The founder has personally bought at least 5 deals from the app with their own money, and the actual outcome is recorded.** Do not put this product in front of a user until you have taken your own advice and it worked.

### 12.2 Gate B — Beta launch

- [ ] Gate A fully passed
- [ ] Legal pages live: ToS, privacy, refund policy
- [ ] Disclaimers present on every profit-displaying screen
- [ ] Sentry live; founder alerted on error spikes
- [ ] Admin console operational: publish, retire, review, refund
- [ ] Runbook written for: bad deal published, Keepa outage, Stripe webhook failure, credit reconciliation mismatch
- [ ] Feed loads in under 2s on a mid-range Android phone over 4G
- [ ] Full flow completed on a real phone by someone other than the founder
- [ ] Support channel live with a stated response commitment
- [ ] 15 deals/week curation capacity confirmed and calendared
- [ ] Stripe verified in test mode; live mode may follow in beta week 2

### 12.3 Gate C — Public launch

- [ ] Beta exit criteria met (§10.7)
- [ ] Purchase Conviction Rate ≥ 30%
- [ ] Prediction Accuracy ≥ 60%
- [ ] Confirmed bad-match rate < 1% of unlocks
- [ ] Stripe live, reconciled daily, replay-tested with the Stripe CLI
- [ ] Credit pricing confirmed above blended Keepa cost per unlock with margin
- [ ] A sustainable answer exists to "where do next month's deals come from" — automated feed work scoped and started
- [ ] Score v2 calibration analysis complete against recorded outcomes
- [ ] No P0 defect open

### 12.4 Non-criteria — deliberately not required

Test coverage percentage · design polish beyond legibility and clarity · load capacity beyond 100 concurrent users · SEO · marketing site beyond a single explanatory page · analytics beyond the events named in §9.

---

## Appendix A — Six-week build plan

Mapped onto ARCHITECTURE.md §15, compressed to the P0 scope in this document.

| Week | Build | Architecture steps | Done when |
|---|---|---|---|
| **1** | Foundation, schema, RLS, reference data, `MarketContext`, auth, onboarding | 1–5 | Protected routes work; active market resolves correctly; anon key reads nothing it shouldn't |
| **2** | Money/currency module, tax engine, pricing engine, scoring engine | 5–8 | Multi-currency unit tests pass; launch-market tax cases pass; scores are sensible on known deals |
| **3** | Marketplace adapter, Keepa provider, admin ingestion, GTIN matching, deal computation | 9–10 | 20 real products in the launch market go end-to-end and produce believable deals |
| **4** | Market-scoped feed, locked detail, redaction, unlocked detail, assumptions panel, unit recommendation | 11, 14 | Payload-leak and cross-market-isolation tests green; full breakdown legible on a phone |
| **5** | Credits, unlock, purchase tracking, report-a-deal, admin console completion | 12, 16 | Concurrency test green; predicted-vs-actual visible per market |
| **6** | Multi-currency Stripe setup for the launch currency, legal, hardening, deal curation, dry run | 13, 18 | Gate A passed; founder has bought 5 deals |

Deliberate ordering: the pricing and scoring engines come **before** any data plumbing, because they are pure, testable, and are the actual product. Credits are proven **before** Stripe touches them. Curation runs in parallel from week 3 — deal supply cannot start in week 6.

**Slip protocol.** If week 4 ends late, cut in this order: (1) Stripe to beta week 2, (2) filters reduced to profit and ROI only, (3) outcome recording to a founder-run spreadsheet. Do **not** cut: the itemised breakdown, editable assumptions, the score breakdown, or "I bought this." Cutting any of those means running a beta that cannot answer the question.

---

## Appendix B — Open questions for the founder

1. **Launch market.** Which country/Amazon locale will host the first beta? This must be chosen before real fee/tax verification, retailer selection and recruitment.
2. **Free grant size.** 5 credits is my recommendation. What is the real Keepa cost per unlock? If it's material, the grant becomes a genuine cost decision rather than a rounding error.
3. **Credit pricing.** Needs a number before Gate C. Anchor against what comparable deal groups charge in the chosen launch market and price credit packs deliberately in local currency.
4. **Beta recruitment access.** Do you already have standing in arbitrage communities in the chosen launch market? If not, recruitment is a two-week task that must start in build week 2, not week 5.
5. **Curation capacity.** Is 6–8 hours a week genuinely available alongside development? If not, the cohort drops to 20 and the deal commitment to 10/week.
6. **Founder capital for the week-0 dry run.** A market-local budget sufficient to buy five representative deals. This is the single highest-value spend in the whole project.
7. **Retailer selection.** Which 3–5 retailers in the launch market? Affiliate-feed availability and GTIN quality should influence this now, even though automated feeds are P2.

---

*End of document. This spec scopes ARCHITECTURE.md; it does not amend it. Any change to a P0 boundary is a product decision and belongs in `docs/DECISIONS.md` as an ADR alongside the technical ones.*
