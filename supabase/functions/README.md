# `supabase/functions/`

Postgres `SECURITY DEFINER` functions. Created in T07.

## Rules

- `search_path` is locked to `public, pg_temp`.
- Credits move only through `spend_credits` / `grant_credits`. No "check then deduct" in application code (§6.5).
