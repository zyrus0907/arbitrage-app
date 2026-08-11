-- ISO 4217 currency metadata.
--
-- T03 seeded the three currencies its own acceptance criteria needed. T08
-- extends the list to the four its criteria name (GBP, USD, EUR, JPY) plus KWD.
--
-- WHY KWD IS HERE AND NOT "EXTRA"
--
-- schema_a.sql's own comment on minor_unit_exponent cites "2 for GBP/USD/EUR,
-- 0 for JPY, 3 for KWD" as the reason the exponent is data rather than an
-- assumed x100. Until now no 3-decimal row existed, so the claim was asserted
-- in a comment and proved nowhere: every seeded currency was 0 or 2, and code
-- that divided by 100 would have passed every test in the repository. KWD makes
-- the third case real, and the seed tests assert all three exponents.
--
-- Idempotent: `npm run db:reset` and a re-run of the seed must leave identical
-- rows, so this is an upsert on the natural key, never a bare insert.

insert into public.currencies (code, minor_unit_exponent, symbol, name) values
  ('GBP', 2, '£',  'Pound Sterling'),
  ('USD', 2, '$',  'US Dollar'),
  ('EUR', 2, '€',  'Euro'),
  ('JPY', 0, '¥',  'Yen'),
  ('KWD', 3, 'د.ك', 'Kuwaiti Dinar')
on conflict (code) do update set
  minor_unit_exponent = excluded.minor_unit_exponent,
  symbol              = excluded.symbol,
  name                = excluded.name;
