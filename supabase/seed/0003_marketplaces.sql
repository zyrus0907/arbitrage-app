-- T08 — marketplaces (Amazon locales).
--
-- Four Amazon locales. `provider` and `adapter_key` are text, not enums,
-- precisely so that eBay costs one adapter class and one row (§0.3, §10.1) —
-- nothing below assumes Amazon, and no column here is Amazon-specific. The
-- Amazon vocabulary that does exist (ASIN, FBA, FBM) appears only as values
-- inside `fulfilment_programs`, which is what that column is for.
--
-- DETERMINISTIC IDs
--
-- Every T08 seed row carries a literal uuid rather than letting
-- gen_random_uuid() pick one. Two reasons:
--
--   * The seed must be rerunnable (T08 AC "seed is idempotent"). Cross-file
--     references — markets -> marketplaces, fee_schedules -> marketplaces —
--     then need no subquery and cannot drift between runs.
--   * `credit_packs` has no natural unique key at all (T05 gave it none), so
--     `on conflict (id)` is the only idempotent form available there. Using one
--     scheme everywhere is better than one exception nobody can explain.
--
-- Layout, so the values are greppable and obviously synthetic:
--   5eed<file-number>-0000-4000-8000-0000000000<row>
-- '5eed' reads as "seed"; the file number matches the seed file that owns the
-- row. These are fixture identifiers and are never treated as secrets.
--
-- WHY THE OTHER THREE ARE INACTIVE
--
-- `marketplaces` is service-role-only (§6.3, ADR-008 — it carries adapter_key
-- and capabilities, which are integration internals), so `active` here is not a
-- visibility flag; it is the flag that says an adapter is wired up and verified
-- for this locale. Only amazon_uk is. Provider coverage varies by Amazon locale
-- and is a market-selection input rather than an afterthought (§10.1), so
-- activating one of the others is a MARKET_PLAYBOOK.md step, not a flag flip.
--
-- `capabilities` drives §8.7: a component whose inputs are unavailable is
-- dropped and the remaining weights are renormalised, never defaulted. The
-- values below describe the Keepa adapter (T17):
--   priceHistory       true  — 90-day price series
--   rankOrDemandProxy  true  — sales rank and rank history
--   offerCounts        true  — FBA/FBM offer counts
--   feePreview         false — Keepa does not call getMyFeesEstimate; real fee
--                              previews need SP-API, which is out of MVP scope
--   categoryTaxonomy   true  — category tree
--
-- feePreview = false is the load-bearing one: it is why fee_schedules exists
-- and is verified by hand rather than fetched per product.

insert into public.marketplaces (
  id, provider, code, country_code, currency, domain, adapter_key,
  capabilities, fulfilment_programs, active
) values
  (
    '5eed0003-0000-4000-8000-000000000001', 'amazon', 'amazon_uk', 'GB', 'GBP',
    'www.amazon.co.uk', 'keepa',
    '{"priceHistory": true, "rankOrDemandProxy": true, "offerCounts": true, "feePreview": false, "categoryTaxonomy": true}'::jsonb,
    '{"marketplace_fulfilled": "FBA", "seller_fulfilled": "FBM"}'::jsonb,
    true
  ),
  (
    '5eed0003-0000-4000-8000-000000000002', 'amazon', 'amazon_de', 'DE', 'EUR',
    'www.amazon.de', 'keepa',
    '{"priceHistory": true, "rankOrDemandProxy": true, "offerCounts": true, "feePreview": false, "categoryTaxonomy": true}'::jsonb,
    '{"marketplace_fulfilled": "FBA", "seller_fulfilled": "FBM"}'::jsonb,
    false
  ),
  (
    '5eed0003-0000-4000-8000-000000000003', 'amazon', 'amazon_us', 'US', 'USD',
    'www.amazon.com', 'keepa',
    '{"priceHistory": true, "rankOrDemandProxy": true, "offerCounts": true, "feePreview": false, "categoryTaxonomy": true}'::jsonb,
    '{"marketplace_fulfilled": "FBA", "seller_fulfilled": "FBM"}'::jsonb,
    false
  ),
  (
    -- Seeded mainly to keep a zero-decimal currency reachable end to end: a
    -- marketplace whose money columns are JPY is the thing that would break
    -- code assuming x100, and currencies alone cannot demonstrate that.
    '5eed0003-0000-4000-8000-000000000004', 'amazon', 'amazon_jp', 'JP', 'JPY',
    'www.amazon.co.jp', 'keepa',
    '{"priceHistory": true, "rankOrDemandProxy": true, "offerCounts": true, "feePreview": false, "categoryTaxonomy": true}'::jsonb,
    '{"marketplace_fulfilled": "FBA", "seller_fulfilled": "FBM"}'::jsonb,
    false
  )
on conflict (code) do update set
  provider            = excluded.provider,
  country_code        = excluded.country_code,
  currency            = excluded.currency,
  domain              = excluded.domain,
  adapter_key         = excluded.adapter_key,
  capabilities        = excluded.capabilities,
  fulfilment_programs = excluded.fulfilment_programs,
  active              = excluded.active;
