-- T08 — credit_packs and credit_pack_prices.
--
-- Three packs, six prices: GBP (the launch currency, active) and EUR (the
-- planned second market, inactive). The split between the two tables is what
-- makes selling into a second country a seeding exercise rather than a refactor
-- (§9.1): a pack's VALUE is credits and is currency-neutral, a pack's PRICE is
-- per currency. One credit buys one unlock in Manchester and in Munich; only
-- the price list differs.
--
-- ===========================================================================
-- stripe_price_id IS NULL ON EVERY ROW. THAT IS THE ACCEPTANCE CRITERION.
-- ===========================================================================
--
-- No Stripe object exists until T34, and ADR-0010 decision 4 prohibits a
-- placeholder. A value like 'price_TODO' or 'price_test_123' would be worse
-- than NULL in three ways: it satisfies every IS NOT NULL check, it is
-- indistinguishable from a real id on inspection, and it fails at the Checkout
-- call instead of at seed time.
--
-- The consequence is intended and must not be "fixed": T06's public-read
-- predicate for credit_pack_prices is
--   active = true AND stripe_price_id IS NOT NULL
-- so between now and T34 NO pack price is visible to anon or authenticated,
-- and the credits page shows nothing purchasable. That is correct behaviour for
-- a pack that cannot be bought. `credit_packs` itself IS publicly readable
-- where active, so the pricing page can still render what a pack contains.
--
-- The GBP rows are `active = true` even though nothing can see them: `active`
-- records commercial intent, `stripe_price_id` records buyability, and T34's
-- job is to fill in the second without having to reason about the first.
--
-- The EUR rows are `active = false` — the DE market is `planned`, so those
-- prices are not merely unbuyable, they are not offered. They also give T09 the
-- seeded inactive fixture its criteria require, so "inactive rows are absent"
-- can be asserted against a real row rather than assumed. Two NULL
-- stripe_price_id values coexist here, which is deliberate coverage for
-- credit_pack_prices_stripe_price_key: NULLs do not conflict in a unique index,
-- and the constraint must not be mistaken for a reason to invent a placeholder.
--
-- ===========================================================================
-- THE AMOUNTS ARE PROVISIONAL, AND THAT IS RECORDED RATHER THAN HIDDEN
-- ===========================================================================
--
-- PRODUCT_SPEC.md §open-questions item 3 leaves credit pricing undecided: it
-- needs a number before Gate C, anchored against what comparable deal groups
-- charge in the launch market. T08 requires pack prices to be seeded now, so
-- these are deliberate provisional figures, not researched ones. The per-credit
-- rate falls as the pack grows (50p, 40p, 30p), which is the only structural
-- property worth committing to before the anchoring work is done.
--
-- Being wrong here is unusually cheap: no client can read these rows until T34
-- backfills stripe_price_id, so a repricing before then changes a number in
-- this file and nothing else. The EUR figures are set independently rather than
-- FX-converted from GBP — §2.3 requires prices to be chosen per market, never
-- converted into an odd local number.
--
-- ===========================================================================
-- WHY THESE ROWS CARRY EXPLICIT IDs
-- ===========================================================================
--
-- credit_packs has NO natural unique key — T05 gave it an id, a name, credits,
-- active and sort_order, and no unique constraint on any of them. `on conflict
-- (id)` is therefore the only idempotent upsert available, which is why the
-- deterministic ids described in 0003_marketplaces.sql are not merely a
-- convention here but a requirement. Adding a unique constraint on `name` would
-- be DDL, and T08 forbids DDL in seeds: a seed that appears to need DDL is a
-- missing migration, not a seed change.

insert into public.credit_packs (id, name, credits, active, sort_order) values
  ('5eed0008-0000-4000-8000-000000000001', 'Starter',  10,  true, 1),
  ('5eed0008-0000-4000-8000-000000000002', 'Standard', 30,  true, 2),
  ('5eed0008-0000-4000-8000-000000000003', 'Pro',      100, true, 3)
on conflict (id) do update set
  name       = excluded.name,
  credits    = excluded.credits,
  active     = excluded.active,
  sort_order = excluded.sort_order;

insert into public.credit_pack_prices (
  id, credit_pack_id, currency, amount_minor, stripe_price_id, active
) values
  -- GBP — the launch currency. Offered, not yet buyable.
  ('5eed0009-0000-4000-8000-000000000001', '5eed0008-0000-4000-8000-000000000001', 'GBP',  500, null, true),
  ('5eed0009-0000-4000-8000-000000000002', '5eed0008-0000-4000-8000-000000000002', 'GBP', 1200, null, true),
  ('5eed0009-0000-4000-8000-000000000003', '5eed0008-0000-4000-8000-000000000003', 'GBP', 3000, null, true),
  -- EUR — priced for the planned DE market, not offered until it opens.
  ('5eed0009-0000-4000-8000-000000000004', '5eed0008-0000-4000-8000-000000000001', 'EUR',  600, null, false),
  ('5eed0009-0000-4000-8000-000000000005', '5eed0008-0000-4000-8000-000000000002', 'EUR', 1400, null, false),
  ('5eed0009-0000-4000-8000-000000000006', '5eed0008-0000-4000-8000-000000000003', 'EUR', 3500, null, false)
on conflict (credit_pack_id, currency) do update set
  amount_minor = excluded.amount_minor,
  -- stripe_price_id is deliberately NOT updated from `excluded`. Once T34
  -- backfills a real Stripe Price ID, re-running this seed must not wipe it
  -- back to NULL and silently un-buy every pack. T34 owns this column from
  -- that point on; the seed only ever establishes the row.
  active       = excluded.active;
