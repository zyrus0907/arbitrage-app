-- ISO 4217 currency metadata.
--
-- T03 seeds only what T03's acceptance criteria require: proof that the schema
-- carries 0-, 2- and 3-decimal currencies as data rather than assuming x100
-- (ARCHITECTURE.md §2.2, §2.4). T08 extends this file with the remaining
-- currencies, countries, marketplaces, markets, schedules and retailers.
--
-- Idempotent: `npm run db:reset` and a re-run of the seed must leave identical
-- rows, so this is an upsert on the natural key, never a bare insert.

insert into public.currencies (code, minor_unit_exponent, symbol, name) values
  ('GBP', 2, '£',  'Pound Sterling'),
  ('USD', 2, '$',  'US Dollar'),
  ('JPY', 0, '¥',  'Yen')
on conflict (code) do update set
  minor_unit_exponent = excluded.minor_unit_exponent,
  symbol              = excluded.symbol,
  name                = excluded.name;
