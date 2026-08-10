# `supabase/tests/`

pgTAP tests, run with `npm run db:test` against the local stack.

## Rules

- These assert schema properties the application cannot: constraints, cascade and restrict behaviour, indexes, triggers, and RLS default deny (§6.3).
- Each file runs inside a transaction that is rolled back, and creates `pgtap` itself. **No migration installs a test extension.**
- `npm run db:reset` first — these run against whatever the local database currently is.
