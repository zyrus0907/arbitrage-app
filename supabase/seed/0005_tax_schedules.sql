-- T08 — tax_schedules.
--
-- Risk #2 lives in this file. An unverified or overlapping schedule makes every
-- profit figure in the market systematically wrong, silently, so `source_url`
-- and `verified_at` are first-class columns and are populated here rather than
-- left for later.
--
-- ===========================================================================
-- THE GB HISTORY IS REAL, AND THAT IS THE POINT
-- ===========================================================================
--
-- Three GB versions are seeded, not one. They are not fixture padding invented
-- to exercise the constraint — they are the actual sequence, and each boundary
-- is a change that moves money:
--
--   [2010-01-01, 2011-01-04)  17.5%, marketplace fees not taxed
--   [2011-01-04, 2024-08-01)  20.0%, marketplace fees not taxed
--   [2024-08-01, ∞)           20.0%, marketplace fees TAXED
--
-- The first boundary is the standard rate rising to 20% on 4 January 2011
-- (gov.uk). The second is not a rate change at all: on 1 August 2024 Amazon
-- moved UK seller billing from Amazon Services Europe S.à r.l. — which had no
-- UK establishment, so its fees fell under the VAT reverse charge — to Amazon
-- EU S.à r.l.'s UK branch, which must charge 20% UK VAT on referral and FBA
-- fees. `marketplace_fees_taxed` is a column on this table, so a change in it
-- is a new version exactly as a rate change would be.
--
-- That third row matters more than it looks. For a seller who is NOT
-- VAT-registered the VAT on Amazon's fees is a real, unreclaimable cost, and
-- §7.4's non-registered branch is the default assumption for our users
-- (profiles.tax_registered defaults to false, "the safer assumption to be wrong
-- about"). A schedule that said `false` here would understate every fee in the
-- launch market by 20% of the fee — an error in the dangerous direction.
--
-- ===========================================================================
-- HALF-OPEN PERIODS, AND WHY ADJACENCY IS DELIBERATE
-- ===========================================================================
--
-- T05A/ADR-0012 enforce `daterange(effective_from, effective_to, '[)')` with a
-- GiST exclusion constraint per country. [from, to) means a version ending on T
-- and its successor starting on T are ADJACENT, not overlapping, so the dates
-- below repeat on purpose: 2011-01-04 closes one row and opens the next, and
-- there is no one-day gap and no one-day overlap between them. Exactly one row
-- covers any given date, which is what MarketContext (T13) resolves against.
--
-- Only the current row is open-ended (`effective_to is null`). Two open-ended
-- rows for one country would overlap on [max(from), ∞) and be rejected by
-- tax_schedules_no_overlapping_periods — the constraint is doing real work
-- here, not sitting inert.
--
-- ===========================================================================
-- verified_at IS A CLAIM, SO IT IS NULL WHERE NO CLAIM CAN BE MADE
-- ===========================================================================
--
-- GB rows carry `verified_at` because the rate and its start date were read
-- from gov.uk's own VAT rates page. DE's row carries `verified_at = NULL`
-- deliberately: the 19%/7% figures are widely published but were not checked
-- against a primary Bundesfinanzministerium source when this seed was written,
-- and inventing a verification timestamp to fill the column would destroy the
-- only signal the column carries. NULL means "not verified", and
-- docs/MARKET_PLAYBOOK.md makes a non-NULL `verified_at` a gate for flipping a
-- market to `live`. DE is `planned`, so the gate is not yet due.
--
-- reduced_rates has no schema-imposed shape (jsonb, default '[]'). The shape
-- used here and in every future row is a list of
-- {code, label, rate_bps}, ordered high to low.

insert into public.tax_schedules (
  id, country_code, regime, standard_rate_bps, reduced_rates,
  registration_supported, input_reclaim_supported, marketplace_fees_taxed,
  effective_from, effective_to, source_url, verified_at, notes
) values
  -- GB, superseded: 17.5% standard rate.
  (
    '5eed0005-0000-4000-8000-000000000001', 'GB', 'vat', 1750,
    '[{"code": "reduced", "label": "Reduced rate", "rate_bps": 500},
      {"code": "zero",    "label": "Zero rate",    "rate_bps": 0}]'::jsonb,
    true, true, false,
    date '2010-01-01', date '2011-01-04',
    'https://www.gov.uk/vat-rates',
    timestamptz '2026-08-11T00:00:00Z',
    'Superseded. Standard rate rose to 20% on 2011-01-04. Retained so a deal or report dated before that boundary resolves to the rate that actually applied.'
  ),
  -- GB, superseded: 20% standard rate, Amazon fees still reverse-charged.
  (
    '5eed0005-0000-4000-8000-000000000002', 'GB', 'vat', 2000,
    '[{"code": "reduced", "label": "Reduced rate", "rate_bps": 500},
      {"code": "zero",    "label": "Zero rate",    "rate_bps": 0}]'::jsonb,
    true, true, false,
    date '2011-01-04', date '2024-08-01',
    'https://www.gov.uk/vat-rates',
    timestamptz '2026-08-11T00:00:00Z',
    'Superseded on 2024-08-01, not by a rate change but by Amazon moving UK seller billing to a UK-established entity, which made marketplace fees VAT-bearing.'
  ),
  -- GB, CURRENT.
  (
    '5eed0005-0000-4000-8000-000000000003', 'GB', 'vat', 2000,
    '[{"code": "reduced", "label": "Reduced rate", "rate_bps": 500},
      {"code": "zero",    "label": "Zero rate",    "rate_bps": 0}]'::jsonb,
    true, true, true,
    date '2024-08-01', null,
    'https://www.gov.uk/vat-rates',
    timestamptz '2026-08-11T00:00:00Z',
    'Current. Standard rate 20% (gov.uk, verified 2026-08-11). marketplace_fees_taxed = true from 2024-08-01: Amazon EU S.a r.l. UK branch charges 20% UK VAT on referral and FBA fees. That half is corroborated but was NOT verified against a primary Amazon or HMRC source; MARKET_PLAYBOOK.md requires confirmation against a real Seller Central VAT invoice before beta.'
  ),
  -- DE, current. Unverified on purpose — see the header note on verified_at.
  (
    '5eed0005-0000-4000-8000-000000000004', 'DE', 'vat', 1900,
    '[{"code": "reduced", "label": "Ermaessigter Steuersatz", "rate_bps": 700}]'::jsonb,
    true, true, false,
    date '2007-01-01', null,
    'https://www.gesetze-im-internet.de/ustg_1980/__12.html',
    null,
    'UNVERIFIED. Seeded so the synthetic second market resolves end to end. 19%/7% are widely published but were not checked against a primary source, and marketplace_fees_taxed = false assumes the Luxembourg reverse charge still applies to DE sellers. Both are MARKET_PLAYBOOK.md gate items before DE leaves planned.'
  )
on conflict (country_code, effective_from) do update set
  regime                  = excluded.regime,
  standard_rate_bps       = excluded.standard_rate_bps,
  reduced_rates           = excluded.reduced_rates,
  registration_supported  = excluded.registration_supported,
  input_reclaim_supported = excluded.input_reclaim_supported,
  marketplace_fees_taxed  = excluded.marketplace_fees_taxed,
  effective_to            = excluded.effective_to,
  source_url              = excluded.source_url,
  verified_at             = excluded.verified_at,
  notes                   = excluded.notes;
