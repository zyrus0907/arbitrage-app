# `supabase/seed/`

Reference and launch-market seed data. Created in T03, completed in T08.

Loaded by `npm run db:reset` via `[db.seed].sql_paths = ["./seed/*.sql"]` in
`supabase/config.toml`. The glob expands in lexicographic order, which is why
the files are numbered: the order below **is** the dependency order, and a file
cannot be renumbered without checking what references what.

| File | Rows | Depends on |
|---|---|---|
| `0001_currencies.sql` | GBP, USD, EUR, JPY, KWD | — |
| `0002_countries.sql` | GB (active), DE, US, JP | currencies |
| `0003_marketplaces.sql` | amazon_uk (active), amazon_de, amazon_us, amazon_jp | countries, currencies |
| `0004_markets.sql` | gb-amazon-uk (**live**), de-amazon-de (planned) | marketplaces, countries |
| `0005_tax_schedules.sql` | GB ×3 versions, DE ×1 | countries |
| `0006_fee_schedules.sql` | amazon_uk ×2 versions, amazon_de ×1 | marketplaces, currencies |
| `0007_retailers.sql` | 5 curated GB retailers | markets |
| `0008_credit_packs.sql` | 3 packs, 6 per-currency prices | currencies |

## Rules

- **Adding a country or a marketplace is seed rows and nothing else** — no
  migration, no code change (§0.3). `docs/MARKET_PLAYBOOK.md` is the checklist.
- **Seeds are idempotent.** Every statement is an upsert on a natural key, or on
  the primary key where the table has no natural key. Running the whole
  directory twice against a seeded database changes nothing.
- **Seeds are deterministic.** Ids are literal `5eed<file>-…` uuids rather than
  `gen_random_uuid()`, so two resets from zero produce identical state.
- **Seeds are DML only.** No DDL, no grants, no policies. A seed that appears to
  need DDL is a missing migration, not a seed change.
- **No fabricated identifiers.** `stripe_price_id` is NULL until T34 backfills
  real Stripe Prices (ADR-0010); affiliate tracking templates are NULL until a
  real affiliate relationship exists. A plausible-looking fake passes every
  `IS NOT NULL` check and fails at the point of use instead of at seed time.
- **No fixture users, deals, purchases or ledger entries.** A dashboard
  populated with invented deals misleads the person deciding whether the
  pipeline works. Asserted in `seed_reference_data.test.sql`.
- **`verified_at` is a claim.** It is non-NULL only where a human checked a
  primary source. NULL means unverified, and `MARKET_PLAYBOOK.md` gates a live
  market on it. Never fill it in to make something look finished.

## Tests

`supabase/tests/database/seed_reference_data.test.sql` (103 assertions) asserts
the content of these files by value — rates, exponents, flags and boundary dates
— rather than by row count, because a count assertion passes for the wrong
reason the moment someone edits a rate.
