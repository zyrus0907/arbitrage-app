# `supabase/migrations/`

Versioned SQL migrations. Created from T03.

## Rules

- RLS is enabled on every table, default deny (§6.3).
- A migration is never edited after it has been applied to a shared environment.
