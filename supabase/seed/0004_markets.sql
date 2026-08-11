-- T08 — markets.
--
-- A market is the operating unit a deal belongs to: a source country plus a
-- marketplace. Two rows, and the second one is the acceptance criterion rather
-- than filler — T08 requires a demonstration that "a synthetic second market
-- can be seeded without a migration or business-logic code change". This file
-- is that demonstration: `de-amazon-de` needed no DDL, no new column and no
-- code, only a country row, a marketplace row and this insert.
--
-- EXACTLY ONE LIVE MARKET
--
-- `gb-amazon-uk` is the one, and it is the only row here with
-- `active = true AND launch_status = 'live'`. That pair is exactly T06's
-- public-read predicate for this table, so it is also the only market an anon
-- or authenticated client can see. `de-amazon-de` is `planned` and inactive and
-- is invisible to them — which is AC8.6 and risk #7's "all boxes ticked or the
-- market stays planned", not an oversight.
--
-- This is deliberately NOT a database constraint (T08 AC). `launch_status` is a
-- lever the admin console legitimately flips (T33, AC16.4), so a uniqueness
-- constraint on it would block a legitimate operation to prevent a mistake that
-- belongs to release discipline. The rule lives in docs/MARKET_PLAYBOOK.md and
-- the T40 checklist, and the seed test below asserts it holds for the seed.
--
-- CURRENCY IS NOT REPEATED, IT IS CONSTRAINED
--
-- markets_currency_matches_marketplace is a composite FK to
-- marketplaces (id, currency), so `currency` below cannot disagree with the
-- marketplace's own currency — the §1.3 MVP invariant is enforced in storage.
-- Writing GBP against amazon_de would be rejected, not merely wrong.

insert into public.markets (
  id, slug, source_country_code, marketplace_id, currency, active, launch_status
) values
  (
    '5eed0004-0000-4000-8000-000000000001', 'gb-amazon-uk', 'GB',
    '5eed0003-0000-4000-8000-000000000001', 'GBP', true, 'live'
  ),
  (
    '5eed0004-0000-4000-8000-000000000002', 'de-amazon-de', 'DE',
    '5eed0003-0000-4000-8000-000000000002', 'EUR', false, 'planned'
  )
on conflict (slug) do update set
  source_country_code = excluded.source_country_code,
  marketplace_id      = excluded.marketplace_id,
  currency            = excluded.currency,
  active              = excluded.active,
  launch_status       = excluded.launch_status;
