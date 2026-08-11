-- T08 — retailers.
--
-- Five curated retailers in the launch market (T08 AC: 3-5, source_type
-- 'curated'). These are real UK retailers that retail-arbitrage sourcing
-- actually uses; `website_url` is each one's public homepage and nothing more.
--
-- NO CREDENTIALS, NO AFFILIATE IDENTIFIERS, DELIBERATELY
--
-- `affiliate_network` and `affiliate_tracking_template` are NULL on every row.
-- No affiliate relationship exists yet, and a plausible-looking tracking
-- template is worse than an empty column: it would be indistinguishable from a
-- real one on inspection and would silently produce dead or mis-attributed
-- outbound links. This is the same reasoning ADR-0010 applies to
-- stripe_price_id. Automated feed ingestion is P2 (PRODUCT_SPEC §8) and the
-- MVP's supply is admin-curated, which is exactly what source_type = 'curated'
-- records.
--
-- price_display IS PER RETAILER, NOT INHERITED
--
-- All five are 'inclusive' because UK shelf prices include VAT, matching
-- countries.retail_price_display for GB. It is still stored per retailer rather
-- than read from the country at compute time: §7.4 notes the assumption is
-- systematically wrong when borrowed — a UK trade or wholesale retailer
-- displays ex-VAT prices, and adding one must be a row with 'exclusive' on it,
-- not an exception in code.
--
-- `market_id` scopes each row, and retailers_currency_matches_market is a
-- composite FK to markets (id, currency), so the currency below cannot disagree
-- with the market's. The unique key is (market_id, slug), so the same retailer
-- brand operating in a second market is legitimately a second row.
--
-- These rows are service-role-only: `retailers` gets no T06 policy and no anon
-- or authenticated grant. Nothing here is publicly readable.

insert into public.retailers (
  id, name, slug, market_id, country_code, currency,
  website_url, source_type, affiliate_network, affiliate_tracking_template,
  price_display, active
) values
  (
    '5eed0007-0000-4000-8000-000000000001', 'Argos', 'argos',
    '5eed0004-0000-4000-8000-000000000001', 'GB', 'GBP',
    'https://www.argos.co.uk', 'curated', null, null, 'inclusive', true
  ),
  (
    '5eed0007-0000-4000-8000-000000000002', 'B&M', 'bm',
    '5eed0004-0000-4000-8000-000000000001', 'GB', 'GBP',
    'https://www.bmstores.co.uk', 'curated', null, null, 'inclusive', true
  ),
  (
    '5eed0007-0000-4000-8000-000000000003', 'Boots', 'boots',
    '5eed0004-0000-4000-8000-000000000001', 'GB', 'GBP',
    'https://www.boots.com', 'curated', null, null, 'inclusive', true
  ),
  (
    '5eed0007-0000-4000-8000-000000000004', 'Superdrug', 'superdrug',
    '5eed0004-0000-4000-8000-000000000001', 'GB', 'GBP',
    'https://www.superdrug.com', 'curated', null, null, 'inclusive', true
  ),
  (
    '5eed0007-0000-4000-8000-000000000005', 'The Range', 'the-range',
    '5eed0004-0000-4000-8000-000000000001', 'GB', 'GBP',
    'https://www.therange.co.uk', 'curated', null, null, 'inclusive', true
  )
on conflict (market_id, slug) do update set
  name                        = excluded.name,
  country_code                = excluded.country_code,
  currency                    = excluded.currency,
  website_url                 = excluded.website_url,
  source_type                 = excluded.source_type,
  affiliate_network           = excluded.affiliate_network,
  affiliate_tracking_template = excluded.affiliate_tracking_template,
  price_display               = excluded.price_display,
  active                      = excluded.active;
