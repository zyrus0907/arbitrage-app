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

---

## T10 — `auth.test.ts`

Starts the **real Next.js application** (via `next dev`, on a free port,
pointed at the local Supabase stack) and drives it with `fetch` and a cookie
jar. Almost every T10 auth criterion is a statement about HTTP — redirected and
returned to the intended route, httpOnly cookies, sign-out clears access, an old
session cannot continue — and none of those can be proved by calling a function
with a hand-built request, because the hand-built request is where the mistake
would be.

**`next dev`, not `next build && next start`, and this matters.** `NEXT_PUBLIC_*`
variables are inlined into the client bundle at *build* time, and the committed
`.env.local` points at the hosted development project. A production build would
bake the hosted URL in and the suite would silently test against the wrong
database. `next dev` resolves the environment per request, so the overrides in
`app-server.ts` actually take effect.

Sessions are established by minting a real magic-link token with the admin API
and driving `/auth/callback` with it. Establishing a session and testing the
callback are therefore the same act — a helper that set cookies some other way
would prove nothing about the code that ships.

**Like `rls.test.ts`, this suite cannot fully tear itself down.** Its users
acquire signup-grant ledger rows, which are append-only and `ON DELETE
RESTRICT`, so they can only be removed through the T10 pseudonymisation
mechanism — which is itself one of the things under test. Run against a freshly
reset database.

The database-level proof of account deletion lives in
`supabase/tests/database/account_deletion.test.sql` (63 assertions): the scrub,
the retention, the tombstone check constraint, idempotency and the `auth.users`
guard are catalogue and constraint facts. This file proves the HTTP route drives
that mechanism and that the session dies with it.
