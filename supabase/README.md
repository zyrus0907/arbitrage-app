# `supabase/`

Database source of truth.

## Rules

- `migrations/` — versioned SQL. The schema is defined here, never by hand-editing a running database.
- `functions/` — `SECURITY DEFINER` RPCs, notably `spend_credits.sql` and `grant_credits.sql`.
- `seed/` — countries, currencies, marketplaces, markets, tax/fee schedules, retailers, credit packs. **The only place a country, currency or marketplace literal is allowed.**
