# `tests/integration/`

Tests that touch a real database or a running route handler.

Run with `npm run test:integration` (its own vitest config: `node` environment,
sequential, longer timeouts). `npm test` deliberately **excludes** this
directory so the unit suite stays runnable with no Docker and no database.

## Rules

- Run against a seeded ephemeral database in CI.
- `rls.test.ts` is a **CI blocker** and may never be skipped.

## Ordering: run `db:test` BEFORE `test:integration`

`rls.test.ts` leaves rows behind and **cannot** clean up after itself. This is a
consequence of the design it is testing, not a defect in the test:

- To prove user A sees only A's `credit_ledger` rows, it must write ledger rows
  for two users.
- `credit_ledger` is append-only at two layers (ADR-0011 decision 5) — the
  trigger refuses `DELETE` for *every* caller including the owner, and
  `service_role` holds no `DELETE` privilege.
- `credit_ledger.user_id` is `ON DELETE RESTRICT` (ADR-0010), so those two test
  users cannot be deleted either.

The suite asserts that retention behaviour rather than working around it, and
leaves 2 users and 2 ledger rows per run.

**Consequence:** `npm run db:test` asserts that the T08 seed creates no users and
no ledger entries, so it fails if run *after* an integration run. The order is:

```bash
npm run db:reset && npm run db:test && npm run test:integration
```

CI's `database` job runs exactly that sequence. Locally, `npm run db:reset`
before `npm run db:test` is the fix if you have run the integration suite since.

## Credentials

`supabase-local.ts` is the only module that touches keys. It resolves them from
environment variables, falling back to the **pinned** CLI in `node_modules`, and
never prints them — `supabase status` emits the service-role key alongside
everything else, and CI logs are not private. No key is hardcoded, deliberately:
the local stack's keys are well-known constants and inlining them would put a
credential-shaped literal in committed source.
