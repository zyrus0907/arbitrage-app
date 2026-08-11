-- T08 — countries.
--
-- Four countries, one of them operated. Seeding more than one is the point:
-- §0.3 requires that opening a market is a row, and a table with a single row
-- proves nothing about that. The other three are real reference rows that a
-- future market needs, not decoration.
--
-- ACTIVE IS A VISIBILITY FLAG, NOT A "DO WE KNOW ABOUT IT" FLAG
--
-- T06's policy is `countries_select_public USING (active)`, and §6.1/AC2.2 use
-- this list to populate the signup country picker. An active country with no
-- live market produces a signup that resolves to nothing, so `active` is true
-- for exactly the country we operate in and false for the rest. DE, US and JP
-- are therefore deliberately invisible to anon and authenticated; they are
-- readable by service_role, which is what MarketContext and the admin console
-- use.
--
-- The inactive rows are also the fixture T09 needs: its criterion is that an
-- inactive row's absence from an anon query is asserted against a seeded
-- inactive row rather than assumed.
--
-- retail_price_display is not a detail (§2.2). Getting it wrong silently
-- inflates or deflates every profit figure in the country by the tax rate:
--   GB / DE / JP — shelf prices include tax  -> 'inclusive'
--   US           — sales tax is added at the till -> 'exclusive'
--
-- tax_regime selects the strategy module in services/tax/regimes/ (§7.4). JP's
-- consumption tax is an invoice-credit VAT (qualified invoice system, 2023), so
-- it maps to 'vat' rather than to a regime of its own.

insert into public.countries (
  code, name, default_currency, default_locale,
  tax_regime, retail_price_display, timezone_default, active
) values
  ('GB', 'United Kingdom', 'GBP', 'en-GB', 'vat',       'inclusive', 'Europe/London',    true),
  ('DE', 'Germany',        'EUR', 'de-DE', 'vat',       'inclusive', 'Europe/Berlin',    false),
  ('US', 'United States',  'USD', 'en-US', 'sales_tax', 'exclusive', 'America/New_York', false),
  ('JP', 'Japan',          'JPY', 'ja-JP', 'vat',       'inclusive', 'Asia/Tokyo',       false)
on conflict (code) do update set
  name                 = excluded.name,
  default_currency     = excluded.default_currency,
  default_locale       = excluded.default_locale,
  tax_regime           = excluded.tax_regime,
  retail_price_display = excluded.retail_price_display,
  timezone_default     = excluded.timezone_default,
  active               = excluded.active;
