# `supabase/`

Database source of truth.

## Rules

- `migrations/` — versioned SQL. The schema is defined here, never by hand-editing a running database.
- `functions/` — `SECURITY DEFINER` RPCs, notably `spend_credits.sql` and `grant_credits.sql`.
- `seed/` — countries, currencies, marketplaces, markets, tax/fee schedules, retailers, credit packs. **The only place a country, currency or marketplace literal is allowed.**

## Workflow

Every migration, type-generation and rollback procedure lives in
`docs/RUNBOOK.md` §§3–9. The short version:

```bash
npm run db:new -- <name>   # create a migration
npm run db:reset           # apply from empty, locally (needs Docker)
npm run db:push            # apply to the linked development project
npm run db:types           # regenerate src/types/database.ts, then commit it
```

Migrations are **forward-only**. There is no `down` migration; a rollback is a
new migration that inverts the previous one (`docs/RUNBOOK.md` §8).

`config.toml` configures the **local** stack. `.temp/` is per-machine link state
and is git-ignored. No application tables exist yet — they land in T03–T05.
