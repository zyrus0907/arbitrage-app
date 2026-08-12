# `src/services/profile/`

Profile and onboarding logic (F2, AC2.1–AC2.6).

## Rules

- **Writes use the caller's client, never the admin client.** RLS and T06's column grants are what enforce "only your own row, and not `credit_balance`". Using the service-role key here would move that guarantee from the database into this file.
- **The country is the only geographic input.** Market, currency, locale, timezone and tax regime are resolved from it, server-side, against rows the caller is permitted to read. A client-supplied currency is exactly the case §11.3 forbids trusting.
- **No live market for a country is the waitlist, not an error** (AC2.2, AC8.6). Showing another market's deals would apply the wrong fee and tax schedules and produce a confidently wrong profit figure.
- Nothing here knows the launch market. GB / `amazon_uk` / GBP is one seeded row (ADR-0015).
