# MARKET_PLAYBOOK.md — opening a new market

Created in T08. Owned by whoever opens the market.

This document exists because of risk #7 in `ARCHITECTURE.md`: *market sprawl —
opening markets faster than supply or verification*. The mitigation recorded
there is a gate list, and **all boxes ticked or the market stays `planned`**.
This is that list.

---

## 0. The one-paragraph version

Opening a market is **seed rows plus supply work, not engineering**. If opening
a market requires a migration, a new column, or a branch in business logic, that
is a defect in the schema or the code, not a step in this checklist — stop and
fix it there. The only code a genuinely new *marketplace* should need is one
`MarketplaceAdapter` implementation (§10.1); a new *country* on an existing
marketplace should need none at all.

The seed in `supabase/seed/` proves this is achievable rather than aspirational:
`de-amazon-de` was added as a synthetic second market with no DDL, no new
column, and no code change.

---

## 1. What a market is made of

A live market is a chain of rows, each depending on the one above it. The seed
files are numbered in this order and must stay that way.

| # | Table | Seed file | Notes |
|---|---|---|---|
| 1 | `currencies` | `0001_currencies.sql` | ISO 4217. `minor_unit_exponent` is data — 2 for GBP/EUR/USD, 0 for JPY, 3 for KWD. Never assume ×100. |
| 2 | `countries` | `0002_countries.sql` | `tax_regime` selects the strategy module. `retail_price_display` says whether shelf prices include tax. |
| 3 | `marketplaces` | `0003_marketplaces.sql` | `provider` and `adapter_key` are text, never enums. `capabilities` drives §8.7 scoring. |
| 4 | `markets` | `0004_markets.sql` | Country + marketplace. Currency is enforced to equal the marketplace's by composite FK. |
| 5 | `tax_schedules` | `0005_tax_schedules.sql` | Per country, versioned, non-overlapping. |
| 6 | `fee_schedules` | `0006_fee_schedules.sql` | Per **marketplace**, versioned, non-overlapping. |
| 7 | `retailers` | `0007_retailers.sql` | Per market. Currency enforced to equal the market's. |
| 8 | `credit_pack_prices` | `0008_credit_packs.sql` | Per currency. Packs themselves are currency-neutral. |

---

## 2. The gate list

A market moves to `launch_status = 'live'` and `active = true` **only when every
box below is ticked.** Anything less and it stays `planned`, or `beta` with the
beta cohort explicitly told what is unverified.

### 2.1 Provider coverage

- [ ] The marketplace adapter supports this locale, **verified against the
      provider's own coverage list, not assumed**. Provider coverage varies by
      Amazon locale and is a market-selection input, not an afterthought
      (`ARCHITECTURE.md` §10.1).
- [ ] `marketplaces.capabilities` reflects what the adapter can *actually*
      supply for this locale. A capability claimed but absent produces a score
      component computed from nothing. A capability present but unclaimed
      silently drops a component and renormalises the weights.
- [ ] Rate limits and quota costs for this locale are known and budgeted.

### 2.2 Tax verification

- [ ] A `tax_schedules` row exists for the country, with `source_url` pointing at
      a **primary** source (the tax authority, not a summary site).
- [ ] `verified_at` is **non-NULL and set by a human who checked the primary
      source**. A NULL here is the schema's way of saying "nobody has verified
      this", and it is a hard blocker. Never fill it in to make a check pass.
- [ ] `standard_rate_bps` is in basis points (20% = 2000), never a float.
- [ ] `retail_price_display` on the country matches how prices are actually shown
      in that market. Getting this wrong shifts every profit figure in the market
      by the tax rate.
- [ ] `marketplace_fees_taxed` is confirmed **against a real settlement or VAT
      invoice from the marketplace**, not from a policy page. For a
      non-registered seller this tax is an unreclaimable cost, and
      `profiles.tax_registered` defaults to `false`.
- [ ] `input_reclaim_supported` and `registration_supported` match the regime.
- [ ] The period is half-open `[effective_from, effective_to)` and does not
      overlap any existing version for the country. The database enforces this
      (`tax_schedules_no_overlapping_periods`); a rejection with SQLSTATE
      `23P01` or `23505` means "this period overlaps an existing version".

### 2.3 Fee verification

- [ ] A `fee_schedules` row exists for the **marketplace**, with `source_url`
      pointing at the marketplace's own rate card or fee schedule.
- [ ] `verified_at` is non-NULL, set by a human, against that primary source.
- [ ] `referral_rules` **ends in a catch-all entry with `"default": true`**, so
      category coverage is total by construction rather than by hoping the
      category list is complete.
- [ ] Every referral rule declares `mode` explicitly as `flat`, `threshold` or
      `marginal`. The distinction is not cosmetic: on a £60 item with a
      "15% up to £45, then 9%" rule, `marginal` gives £8.10 and `threshold`
      gives £5.40.
- [ ] `fulfilment_bands` have **no gaps and no overlaps within each size tier**.
      Bands are `(from_weight_g, to_weight_g]` — exclusive lower, inclusive upper
      — matching how marketplaces print them. Asserted by
      `supabase/tests/database/seed_reference_data.test.sql`.
- [ ] `storage_rules.unit` is correct for the locale. The UK bills per **cubic
      foot** and the rest of Europe per **cubic metre**; assuming one gives a
      figure wrong by a factor of ~35.
- [ ] Every levy that is not a referral or fulfilment fee is an entry in
      `surcharges`, with the `basis` it actually applies to. There is no
      hardcoded digital-services-fee column and there must not be one.
- [ ] Currency-specific programmes that change the fee (low-price fulfilment
      tiers, regional storage programmes, pan-regional surcharges) are either
      modelled or **explicitly recorded as out of scope**. Silently omitting one
      understates cost, which overstates profit — the dangerous direction.

### 2.4 Stripe support

- [ ] Stripe supports the currency and the local payment methods sellers expect.
- [ ] `credit_pack_prices` rows exist for the currency, **priced deliberately for
      that market and not FX-converted** from another currency into an odd local
      number.
- [ ] Real Stripe Prices exist and `stripe_price_id` is backfilled (T34).
      **Until then the packs are correctly invisible** — T06 exposes a price only
      where `active = true AND stripe_price_id IS NOT NULL`. Never seed a
      placeholder such as `price_TODO` to make the page render: it passes every
      `IS NOT NULL` check, is indistinguishable from a real ID on inspection, and
      fails at the Checkout call rather than at seed time (ADR-0010 decision 4).

### 2.5 Retailer supply

- [ ] 3–5 retailers seeded for the market, each with a real `website_url`.
- [ ] `price_display` set **per retailer**, not inherited from the country. A
      trade or wholesale retailer displays ex-tax prices in a market whose shelf
      prices are otherwise inclusive.
- [ ] `affiliate_network` / `affiliate_tracking_template` are either real or
      NULL. A plausible-looking tracking template is worse than an empty column.
- [ ] Enough published deals to make the market worth visiting. `PRODUCT_SPEC.md`
      AC3.5 sets the beta bar at **60 published, admin-verified live deals,
      spanning ≥3 retailers and ≥4 marketplace categories**.

### 2.6 Legal review

- [ ] Consumer/trading disclaimers reviewed for the jurisdiction (T37).
- [ ] Privacy baseline covers the jurisdiction's regime.
- [ ] Any market-specific claim about tax treatment is reviewed. We state how a
      figure was derived; we do not give tax advice.

### 2.7 Seed rows and launch status

- [ ] All eight row types in §1 exist for the market.
- [ ] `npm run db:reset` from zero produces them, and a second reset produces
      **identical** state.
- [ ] `npm run db:test` passes, including
      `supabase/tests/database/seed_reference_data.test.sql`.
- [ ] The country is `active = true` — otherwise it is missing from the signup
      picker and users there cannot resolve to a market.
- [ ] The market is `active = true AND launch_status = 'live'` — **and this is
      the last step, taken only after every box above.**

---

## 3. Exactly one live market, and why the database does not enforce it

The MVP operates **exactly one live market** (`PRODUCT_SPEC.md` Gate A,
`TASKS.md` T08). This is *seeding and operational discipline, not a database
constraint*, and that is deliberate:

`launch_status` is a lever the admin console legitimately flips (T33, AC16.4). A
uniqueness constraint on it would block a legitimate operation in order to
prevent a mistake that belongs to release discipline. So the rule lives here, in
the T40 release checklist, and in an assertion over the seed:

```sql
select count(*) from markets where active and launch_status = 'live';  -- must be 1
```

`supabase/tests/database/seed_reference_data.test.sql` asserts it. If a second
market is ever legitimately opened, that assertion is the thing to update
deliberately — not to delete.

---

## 4. Current state

| Market | Country | Marketplace | Currency | Status | Tax verified | Fees verified |
|---|---|---|---|---|---|---|
| `gb-amazon-uk` | GB | `amazon_uk` | GBP | **live**, active | yes | yes |
| `de-amazon-de` | DE | `amazon_de` | EUR | `planned`, inactive | **no** | **no** |

`amazon_us` and `amazon_jp` exist as marketplace rows with no market. They are
reference data for a future market, not markets.

### 4.1 Open verification items for `gb-amazon-uk`

These were seeded from the sources named in the seed files and are recorded here
because §2 requires them to be confirmed by a human before beta, not because they
are believed wrong:

1. **`marketplace_fees_taxed = true` from 2024-08-01.** Corroborated from
   accountancy sources describing Amazon's move of UK seller billing to Amazon
   EU S.à r.l.'s UK branch. **Confirm against a real Seller Central VAT
   invoice.**
2. **Digital Services Fee at 2% (200 bps).** Amazon's own rate card does not
   state it; the figure comes from secondary sources, which also describe a
   separate 3% rate from 2026-03-20 for UK-established sellers selling into the
   FR/IT/ES stores. That cross-border case is out of MVP scope, but **confirm the
   amazon.co.uk rate on an invoice.**
3. **Minimum referral fee.** The rate card states £0.25 for *all* fee categories;
   `sell.amazon.co.uk` states Books, Music, Video, DVD and Grocery are exempt.
   The rate card is seeded as primary. **Resolve the conflict.**
4. **Low-Price FBA is not seeded.** It is a separate programme with its own rates
   for items at or below £20. Items near that threshold will price against
   standard FBA rates and therefore look *worse* than they are. Decide whether
   to model it before beta.
5. **Clothing Prime-selection referral variant is not modelled** (the
   £40/£45 ladder at 17%/7%), because Prime selection is not knowable from the
   catalogue data.

---

## 5. Adding a market: the actual procedure

1. Add the currency to `0001_currencies.sql` if it is not already there.
2. Add the country to `0002_countries.sql`. Leave `active = false`.
3. Add the marketplace to `0003_marketplaces.sql`. Leave `active = false`.
4. Add the market to `0004_markets.sql` as `planned`, inactive.
5. Add the tax schedule to `0005_tax_schedules.sql` with `verified_at = NULL`
   until a human has verified it.
6. Add the fee schedule to `0006_fee_schedules.sql`, likewise.
7. Add retailers to `0007_retailers.sql`.
8. Add per-currency pack prices to `0008_credit_packs.sql`, `active = false`,
   `stripe_price_id = NULL`.
9. Run `npm run db:reset && npm run db:test`. Run the reset twice and confirm the
   state is identical.
10. Work the gate list in §2.
11. Only then flip `countries.active`, `marketplaces.active`, `markets.active`
    and `markets.launch_status`.

Every one of those steps edits a seed file. **None of them edits a migration, a
type, or a line of business logic.** If one of them does, that is the finding —
report it rather than working around it.

---

## 6. Related

- `ARCHITECTURE.md` §0.3 (adding a market is a row), §2.2 (reference tables),
  §7.4 (tax regimes), §8.7 (capability-aware scoring), §10.1 (adapters), risk #7.
- `PRODUCT_SPEC.md` Gate A, AC3.5, AC8.6.
- `DECISIONS.md` ADR-005 (`fx_rates` deferred), ADR-006 / ADR-0012 (temporal
  exclusion constraints), ADR-008 / ADR-0013 (public reference exposure),
  ADR-0010 (`stripe_price_id` nullable, placeholders prohibited).
- `TASKS.md` T08, T33 (admin schedule editing), T34 (Stripe Prices), T40 (release
  gates).
