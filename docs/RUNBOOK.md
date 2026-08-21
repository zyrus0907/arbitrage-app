# RUNBOOK.md

Operational procedures. This file is written for the person at the keyboard, so
every step is a command that can be copied, in the order it must be run.

**Current scope:** the Supabase database workflow (T02). Sections for deploys,
cron, incident response and provider quotas arrive with the tasks that create
them.

---

## 1. Prerequisites

| Requirement | Why | Check |
|---|---|---|
| Supabase CLI ≥ 2.22 | migrations, type generation, local stack | `supabase --version` |
| Logged in to the Supabase account that **owns the development project** | linking, pushing, generating types | `supabase projects list` |
| Docker Desktop running | **only** for the local stack (`supabase start`) | `docker info` |
| `.env.local` populated | app-side Supabase clients | see `.env.example` |

The CLI is also pinned as a dev dependency (`supabase` in `devDependencies`) so
CI and every developer use the same version. The `npm run db:*` scripts below
resolve that pinned binary; a globally installed CLI of a different version is
the usual cause of "works on my machine" migration drift.

Docker is required only for the local stack. Linking, pushing and generating
types against the hosted development project all work without it.

---

## 2. Environment variables

Four variables matter for the database, all defined in `.env.example` and
validated by `src/lib/env.ts`:

| Variable | Client-reachable | Used by |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | yes | all three clients |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | yes | browser + server clients |
| `SUPABASE_SERVICE_ROLE_KEY` | **no — never** | admin client only |
| `NEXT_PUBLIC_SITE_URL` | yes | auth redirect URLs |

Rules, enforced by tests in `tests/unit/supabase/`:

- **No privileged credential may carry a `NEXT_PUBLIC_` prefix.** A
  `NEXT_PUBLIC_*` variable is inlined into the browser bundle at build time; a
  service-role key placed there is published, permanently, to every visitor.
- `SUPABASE_SERVICE_ROLE_KEY` may be referenced in exactly two files:
  `src/lib/env.ts` and `src/lib/supabase/admin.ts`.
- `.env.local` is git-ignored (`.gitignore` ignores `.env.*` except
  `.env.example`). Verify at any time with `git check-ignore -v .env.local`.
- Never paste a key value into a migration, a comment, a test fixture, a log
  line, a commit message or an issue. If one is exposed, rotate it in the
  Supabase dashboard (Settings → API) before doing anything else.

---

## 3. Linking to the development Supabase project

Required once per machine, before any `db:push`, `db:pull` or `db:types`.

```bash
supabase login
```

Then link. The project reference is the subdomain of your
`NEXT_PUBLIC_SUPABASE_URL` — `https://<project-ref>.supabase.co`:

```bash
npx supabase link --project-ref <project-ref>
```

The CLI prompts for the database password (Supabase dashboard → Settings →
Database). The link is stored in `supabase/.temp/`, which is git-ignored — it is
per-machine state, not repository state.

Verify:

```bash
npx supabase projects list
```

The development project must show a check in the `LINKED` column. If the
command reports *"Your account does not have the necessary privileges"*, the CLI
is logged in as a different account from the one that owns the project — run
`supabase logout`, then `supabase login` with the owning account.

### Postgres major version

`supabase/config.toml` sets `[db].major_version`. It **must match the hosted
project**, or the local stack and the remote will disagree about what a
migration means. Check the remote with:

```sql
SHOW server_version;
```

Run it in the dashboard SQL editor and edit `config.toml` if it differs.

---

## 4. Creating a migration

Migrations are the only sanctioned way the schema changes. Never edit a running
database by hand in the dashboard — a dashboard edit is invisible to the next
developer and to production.

```bash
npm run db:new -- <descriptive_snake_case_name>
```

This creates `supabase/migrations/<timestamp>_<name>.sql`. Write the SQL by
hand. Naming follows `TASKS.md`, e.g. `schema_a`, `schema_b`, `schema_c`, `rls`,
`credit_rpcs`.

Two rules for the file itself:

- **Forward-only and idempotent where it can be.** Prefer `create table if not
  exists`, `create index if not exists`, `alter table ... add column if not
  exists`.
- **One logical change per migration.** A migration that both creates tables and
  backfills data cannot be reasoned about when it half-fails.

If you have already changed the local database another way, capture the delta
instead of writing it by hand:

```bash
npm run db:diff -- -f <descriptive_snake_case_name>
```

---

## 5. Applying migrations locally

Requires Docker.

```bash
npm run db:start      # boots Postgres, Auth, Storage, Studio in containers
npm run db:reset      # drops, recreates, applies every migration, runs seeds
npm run db:status     # prints local URLs and keys
npm run db:stop       # frees the containers when done
```

`db:reset` is the workhorse: it rebuilds the local database from
`supabase/migrations/` in order, then applies `supabase/seed/*.sql`. Because it
runs **every** migration from empty every time, it is also the test that your
migrations still work as a set rather than only as a diff against your current
local state. Run it before every push.

Local Studio is at <http://localhost:54323>.

### Database tests

Schema properties that the application cannot assert — constraints, cascade and
restrict behaviour, indexes, triggers, RLS default deny — are pgTAP tests in
`supabase/tests/database/`:

```bash
npm run db:test
```

Run it **after** `db:reset`, because it tests whatever the local database
currently is. Each file opens a transaction, creates the `pgtap` extension
inside it and rolls back, so no migration ever installs a test extension into
the hosted project.

> Without Docker you cannot run the local stack. You can still push migrations
> to the development project (§6) and generate types (§7); you simply lose the
> ability to test a migration before it lands. In that situation, treat the
> development project as the test environment and never point `db:push` at
> production.

---

## 6. Pushing migrations to the development project

```bash
npm run db:list       # compares local migration files against the remote history
npm run db:push       # applies the pending ones
```

`db:list` first, always. It prints local-versus-remote status per migration and
is how you discover that someone applied a change in the dashboard, or that your
local history has diverged. Pushing on top of a divergence is how a schema
becomes irreproducible.

`db:push` prints the migrations it intends to apply and asks for confirmation.
Read that list. If it contains a migration you did not expect, stop.

After a successful push, regenerate types (§7) and commit the result in the same
commit as the migration. A migration and its types belong together; splitting
them leaves `main` in a state where the code does not describe the database.

---

## 7. Regenerating TypeScript database types

`src/types/database.ts` is generated. It is committed, and it is never edited by
hand.

```bash
npm run db:types          # from the linked development project (no Docker needed)
npm run db:types:local    # from the local stack (needs `npm run db:start`)
```

Both write `src/types/database.ts`, which all three Supabase clients are typed
against — so a schema change that the code has not caught up with shows up as a
typecheck failure rather than as a runtime surprise.

Regenerate **every time** a migration changes the schema, and commit the result.
Then:

```bash
npm run typecheck
```

At T02 the application schema is deliberately empty, so the committed file
describes an empty `public` schema plus the `Tables<>` / `TablesInsert<>` /
`TablesUpdate<>` / `Enums<>` helper types. T03 onward will fill it in.

> If `db:types` writes an empty or truncated file, it failed — the redirection
> still creates the file. Check the command's stderr and `git diff` before
> committing.

---

## 8. Rolling back safely

**Read this before you need it.**

Supabase's migration tooling is **forward-only**. There is no `supabase
migration down`, no automatic inverse migration, and no built-in point-in-time
undo on the free tier. Any workflow that claims otherwise is inventing one.
Rollback is therefore a thing you *write*, not a thing you *run*.

### 8.1 The safe path: a forward "revert" migration

The correct rollback for a migration that has been pushed is a **new migration
that undoes it**:

```bash
npm run db:new -- revert_<original_name>
```

Write the inverse SQL (`drop table`, `drop column`, `drop policy`), push it, and
regenerate types. History stays linear and every environment reaches the same
state by replaying the same ordered list. Never delete or edit an already-pushed
migration file: the remote records which migrations it has applied by version,
so editing one makes local and remote silently disagree.

### 8.2 Rolling back destroys data

`drop column` and `drop table` are irreversible without a backup. Before pushing
any destructive revert:

1. Take a backup (§8.4).
2. Prefer a **non-destructive deprecation**: rename the column
   (`..._deprecated`), or stop reading it in code and drop it in a later,
   separate migration once you are certain nothing depends on it. An expand →
   migrate → contract sequence turns one risky step into three safe ones.

### 8.3 If a migration fails halfway

`db:push` applies each migration inside a transaction, so a failing migration
rolls itself back and the remote history does **not** record it. Fix the SQL in
the same file and push again. Do not create a second migration to patch a
migration that never applied.

### 8.4 Backups before anything destructive

```bash
npx supabase db dump --linked -f backup_$(date +%Y%m%d_%H%M).sql            # schema
npx supabase db dump --linked --data-only -f data_$(date +%Y%m%d_%H%M).sql  # data
```

Write dumps outside the repository, or to a git-ignored path. **A data dump from
a real environment contains user data and must never be committed.**

Paid Supabase plans add automated daily backups and point-in-time recovery. If
and when this project holds real user or payment data, that is the point at
which PITR stops being optional.

### 8.5 Last resort: reset the development project

Only for the development project, never production, and only when the migration
history is beyond repair:

```bash
npx supabase db reset --linked   # DESTROYS ALL DATA in the linked project
```

This drops everything and replays migrations from empty. Confirm the linked ref
is the development project first — `npx supabase projects list`.

---

## 9. Checklist for any schema change

```
[ ] npm run db:new -- <name>          write forward SQL
[ ] npm run db:reset                  applies cleanly from empty (Docker)
[ ] npm run db:test                   pgTAP schema tests pass
[ ] npm run db:list                   no unexpected divergence
[ ] npm run db:push                   applied to development
[ ] npm run db:types                  regenerate committed types
[ ] npm run typecheck && npm test     code still matches the schema
[ ] commit migration + types together
```

---

## 10. Verifying the Supabase client wiring

The three clients are `src/lib/supabase/{browser,server,admin}.ts`
(ARCHITECTURE.md §6.2). Their guarantees are asserted by
`tests/unit/supabase/`:

```bash
npm test
```

To reconfirm by hand that the admin client cannot reach a browser bundle,
temporarily add a page containing `'use client'` and an import of
`@/lib/supabase/admin`, then run `npm run build`. It must fail with:

```
Error: 'server-only' cannot be imported from a Client Component module
```

Delete the probe page afterwards. To confirm no privileged value reached the
built output:

```bash
grep -rl "SERVICE_ROLE" .next/static | wc -l   # must be 0
```

## Migration checklist — privilege posture
 
Established in T03 and binding on every migration from T04 onward (ADR-004). **Access requires both a SQL privilege and an RLS policy. Neither works alone:** RLS filters rows *within* privileges already held, so a policy without a grant is inert, and a grant without a policy is an ungoverned privilege.
 
Baseline established in T03:
 
- `anon`, `authenticated` → **no table privileges**
- `service_role` → **table DML only** (no DDL)
- functions → **owner-only**
### Before opening the PR, for every object the migration creates
 
**Tables**
- [ ] Header comment states the privilege posture explicitly — which roles get what, and why. Silence is not a posture.
- [ ] No `GRANT` to `anon` or `authenticated` unless this migration is the task that deliberately opens access (T06 for the schema's public-read and user-owned tables).
- [ ] Any Postgres or Supabase **default grant is revoked in this same migration**.
- [ ] `ALTER TABLE … ENABLE ROW LEVEL SECURITY` is present.
- [ ] If a policy is added, a matching **minimum, per-operation** grant is added with it — `SELECT` where only reads are needed, never `GRANT ALL`.
- [ ] If a grant is added, a matching policy is added with it.
- [ ] Service-role-only tables state "no anon/authenticated grants" explicitly rather than leaving it implicit.
**Sequences**
- [ ] Default grants on sequences created alongside tables are revoked. Easy to miss; `GRANT INSERT` without sequence access fails confusingly, and sequence access without `INSERT` is a needless privilege.
**Functions**
- [ ] `REVOKE ALL ON FUNCTION … FROM PUBLIC, anon, authenticated;`
- [ ] `GRANT EXECUTE ON FUNCTION … TO <specific role>;` — for the credit RPCs this is `service_role` and nothing else.
- [ ] Both statements live in the **same migration file as the function body**, and are repeated after **every** `CREATE OR REPLACE`. Postgres grants `EXECUTE` to `PUBLIC` on creation by default, and a later "fix the RPC" migration that replaces the body without re-revoking silently reopens it.
- [ ] `SECURITY DEFINER` functions also set `search_path` explicitly.
**Views**
- [ ] Posture stated. Note that a view runs with the privileges of its owner unless `security_invoker` is set — decide which is intended and say so.
**Extensions**
- [ ] If the migration creates an extension, note that its objects are not granted to `anon` or `authenticated`.
### After applying remotely
 
- [ ] Regenerate `src/types/database.ts` against the **remote** database and commit it. Local-only generation does not satisfy this.
- [ ] Re-run the T09 RLS/privilege verification suite. It enumerates tables from the live catalogue and fails on any table no assertion covers, so a new table will turn it red until an assertion is added — that is intended, not a nuisance.
- [ ] Confirm local and remote migration history match.
### Verifying the posture by hand
 
Useful when a PR's claims need checking rather than trusting:
 
```sql
-- Table and column privileges held by the client-facing roles
select table_name, privilege_type, grantee
from information_schema.role_table_grants
where grantee in ('anon','authenticated')
order by table_name, grantee, privilege_type;
 
-- Function execute privileges
select p.proname, p.prosecdef as security_definer, a.grantee, a.privilege_type
from information_schema.role_routine_grants a
join pg_proc p on p.proname = a.routine_name
where a.grantee in ('public','anon','authenticated');
 
-- Tables with RLS enabled but no policies (expected: service-role-only tables)
select c.relname
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relrowsecurity
  and not exists (select 1 from pg_policy p where p.polrelid = c.oid);
 
-- Policies with no corresponding grant, and grants with no policy: cross-check
-- the two queries above against the policy list in the PR description.
```
 
### The failure modes this prevents
 
| Symptom | Cause | Where it bites |
|---|---|---|
| Policy written, app still cannot read | Grant missing — policy is inert | T06, and any later feature task |
| Table readable by anon that should not be | Grant present, policy missing or permissive | Redaction bypass — the paid product given away |
| RLS test passes but protects nothing | Test asserted "zero rows" when the real cause was a privilege error | T09 — assertions must name the expected mechanism |
| Credits mintable from the client | `CREATE OR REPLACE` on a `SECURITY DEFINER` function without re-revoking `PUBLIC` | T07, and any later RPC change |

---

## Migration checklist — financial tables

**Applies to any migration that creates or alters `credit_ledger`, `credit_purchases`, `credit_packs`, `credit_pack_prices`, `stripe_webhook_events`, or any future table holding money, credits or payment identity.** This checklist is *in addition to* the privilege-posture checklist above, not instead of it. Established by ADR-0010 (T05 planning) and binding from T05 onward.

The failure mode this exists to prevent is specific: financial defects are silent. A wrong fee is visible to the user; a mutable ledger row, a missing idempotency constraint or a cascade that deletes a purchase record shows up as nothing at all until a reconciliation disagrees months later, and by then the evidence needed to work out what happened is the evidence that was destroyed.

### 1. Append-only and immutability

- [ ] For every append-only table, **both** layers are present: a `BEFORE UPDATE OR DELETE` trigger that raises, **and** the corresponding privilege revoked from `service_role`. One without the other is half a guarantee (ADR-0010).
- [ ] The trigger is created in the **same migration as the table**, not a later hardening pass. A money table must never exist in a mutable state, not even between two migrations.
- [ ] For a table that is *restricted* rather than immutable (`stripe_webhook_events`), the migration names **which columns may change** and rejects changes to all others. Identity and payload frozen; processing outcome writable.
- [ ] No second trigger duplicating a guarantee an earlier migration already makes. Two triggers with one purpose means either can be dropped with no test going red.
- [ ] The tests distinguish the **mechanism**: a privilege error and a trigger exception are different failures. Exercise the trigger as a role that *holds* the privilege (the migration owner), or the test only re-proves the revoke.

### 2. Foreign key delete behaviour

- [ ] Every FK on the table states its delete behaviour explicitly. `CASCADE` by default is a decision made by omission.
- [ ] Financial rows use **`ON DELETE RESTRICT`** — ledger entries and purchase records outlive the account (ADR-0010, `ARCHITECTURE.md` §11.4).
- [ ] The **cascade chain is traced end to end**, not just one hop. `profiles` cascades from `auth.users`, so a `RESTRICT` two levels down blocks the auth-user delete — verify what the whole chain does, and write the test that proves it.
- [ ] Actor/audit columns that reference a user for provenance rather than ownership use `ON DELETE SET NULL` (ADR-0009's `published_by`/`retired_by` is the precedent), so deleting a person does not delete a record of what happened.

### 3. Privilege narrowing

- [ ] `service_role` holds **only the operations the table's write path actually performs**. The blanket `SELECT, INSERT, UPDATE, DELETE` of ADR-0006 is a starting point, not an entitlement.
- [ ] Every narrowing is named in the migration header **with its reason**, so a later "restore the standard grants" migration cannot undo it while looking like tidying.
- [ ] The privileges pgTAP test asserts the **narrowed, per-table** posture. A test that asserts a uniform grant across all tables will pass on the day someone re-grants.
- [ ] Nothing is granted to `anon` or `authenticated` on a financial table beyond a user's own read, and that read arrives with its policy in the same migration.

### 4. Money and currency constraints

- [ ] Every money column is `bigint` **minor units** with a `NOT NULL` `currency` column beside it, FK-validated against `currencies` (§2.4, §11.2). A currency-free amount must be unrepresentable.
- [ ] Sign constraints match the semantics: prices and amounts `> 0`; ledger `delta <> 0`; a balance that is *allowed* to go negative (`balance_after`) carries **no** non-negative check, and the migration says why.
- [ ] No `numeric`/`float` money column, no `×100` assumption, no currency inferred from a market or a locale at write time.
- [ ] Purchase **snapshots are immutable in intent and documented as such** — what was bought and paid is frozen; only the status of the process may change.

### 5. Idempotency

- [ ] Every idempotency key column is **`NOT NULL` and `UNIQUE`**. A nullable key defeats the constraint entirely — multiple NULLs do not conflict in a unique index, so every unkeyed write passes.
- [ ] External event identifiers (`stripe_event_id`, `stripe_payment_intent_id`, `stripe_checkout_session_id`) are unique, and the migration states which is the primary replay guard.
- [ ] The duplicate-write path is **tested**, not assumed: the same key twice must be rejected or resolved to the prior result, and never applied twice.
- [ ] Nothing deletes a row whose existence *is* the idempotency guarantee. `DELETE` on the webhook event table is revoked for exactly this reason.

### 6. Before pushing

- [ ] `npm run db:reset && npm run db:test` — the financial tests run from empty, as a set.
- [ ] The reconciliation invariant still holds after the change: `sum(credit_ledger.delta) == profiles.credit_balance` per user (§11.4, AC10.8).
- [ ] Types regenerated against the **remote** database and committed with the migration.

---

## 11. Authentication, sessions and account deletion (T10)

### 11.1 Local auth configuration

`supabase/config.toml` `[auth]` drives the local stack. Two settings matter and
one of them **differs from what production requires**:

| Setting | Local value | What production needs |
|---|---|---|
| `site_url` | `http://localhost:3000` | the deployed origin |
| `additional_redirect_urls` | localhost | the deployed origin + Vercel preview pattern |
| `auth.email.enable_confirmations` | `false` | **`true`** — AC1.1 requires a verification email |
| `minimum_password_length` | `6` | 8, to match the Zod schema the forms enforce |

The application handles both confirmation settings without a code change: with
confirmations on, `signUp` returns a user and no session and the user is sent to
`/check-email`; with them off, the session is live immediately. Do not "fix" one
by hardcoding the other.

Emails on the local stack go to **Mailpit**, not to a real inbox:

```bash
npx supabase status
```

Open the `MAILPIT_URL` it prints to read a verification or magic link.

### 11.2 Where the session lives

- **httpOnly cookies, written by the server** (AC1.4). Authentication runs in
  Server Actions rather than in the browser client precisely so the cookie
  carries `httpOnly` — `@supabase/ssr`'s browser client uses cookies too, but
  JavaScript-written ones that any injected script can read.
- `sameSite` is **`lax`**, and must stay so: the magic-link and verification
  flows return the user from their mail client as a cross-site top-level
  navigation, and `strict` withholds the cookie on exactly that request.
- Verify the flags without a browser:

```bash
curl -sD - -o /dev/null "http://localhost:3000/feed" | grep -i '^location'
```

### 11.3 Route protection

`src/proxy.ts` — **not `middleware.ts`**; Next.js 16 renamed Middleware to Proxy
(ADR-0017 decision 8). It refreshes the session and redirects a request with no
session to `/sign-in?next=…`. It is **default-deny**: everything needs a session
unless it appears in `PUBLIC_PATHS` in `src/lib/auth/routes.ts`.

**Adding a public page means adding it to that list.** Forgetting produces a
redirect to sign-in — visible and reported. The inverse arrangement would ship
the page unprotected and silent, which is why the list is inverted.

The proxy is not the authorization boundary. `src/app/(app)/layout.tsx`
re-verifies with `getUser()` and applies the onboarding and tombstone gates, and
RLS governs every row underneath.

### 11.4 Deleting an account

Two steps, in this order, both idempotent:

```sql
-- 1. Scrub. Deletes personal rows, tombstones the profile, retains the ledger.
select * from public.pseudonymise_account('<user uuid>');
```

```sql
-- 2. Remove the login. Refused by the guard trigger unless step 1 has run.
-- In practice, do this through the Auth admin API, not SQL.
```

From the application, both steps are `DELETE /api/v1/account`, which acts on the
verified session's user and accepts no user id.

**What survives, and why:** `credit_ledger` and `credit_purchases` rows are
retained untouched (ADR-0010, AC1.6) — a chargeback can arrive after an account
closes, and a reconciliation a user can empty by closing their account proves
nothing. `profiles.credit_balance` is **not** zeroed, because that would break
AC10.8's invariant `sum(delta) = credit_balance` for exactly the rows §11.4
requires reconciliation to keep covering.

**What is NOT removed, and must not be described as removed (ADR-0019 decision 1,
T11/F1):** Supabase Auth's audit history. `auth.audit_log_entries` retains
authentication events — sign-in, token refresh, logout, the deletion itself —
keyed by the subject UUID and carrying request metadata, and deleting the
`auth.users` row does not purge them. `pseudonymise_account` neither touches nor
was designed to touch them.

The guarantee the mechanism actually provides is about `public`: **no row this
application can reach — through `anon`, `authenticated` or `service_role` — ties
the UUID back to a person.** `auth` is not in PostgREST's exposed schemas, so the
audit history has no API surface at all here; it is reachable only by a database
superuser or through the Supabase dashboard. When answering a user or a
regulator, say *pseudonymised in the application's data* — not *erased
everywhere*. **Do not purge `auth.audit_log_entries` to make a sentence true:**
destroying authentication audit history is its own incident, and the retention
question belongs to T37.

**What is deliberately unresolved:** the legal retention *duration* — for the
financial rows **and** for the auth audit history. The
mechanism retains indefinitely. Settle the period with advice before beta and
record it in the privacy policy (T37) — do not invent one in a column comment.

**If a deletion half-completed** (the scrub ran, the auth deletion failed): the
account is already unusable — the layout refuses a tombstoned profile — and
re-running the same request finishes the job. Do not attempt to reverse it; the
tombstone constraint refuses to accept personal data back onto the row.

### 11.5 Checking for leaked secrets in the browser bundle

```bash
npm run build && npm run scan:bundle
```

Reads `.next/static` and fails on any server-only variable **name** or **value**,
or on a `service_role` JWT claim. The source scan in `tests/unit/supabase/` is
not a substitute: it cannot see what the compiler emitted.

**Three outcomes, not two** (T11 finding F6):

| Result | Exit | Meaning |
| --- | --- | --- |
| `PASS` | 0 | Nothing found, **and** the value-level assertion for `SUPABASE_SERVICE_ROLE_KEY` actually ran. |
| `INCOMPLETE` | 2 | Nothing found, but that assertion was skipped because no value was in the environment. `--allow-incomplete` exits 0 instead; it still never prints `PASS`. |
| `FAIL` | 1 | Something was found. Rotate the key before anything else (§11.1). |

The value assertion is the only one that can catch a key inlined from a
*different* environment, so a run without it is not a clean bill of health. It
does **not** need a real key: export the local stack's published service-role
key (`npx supabase status`) before the build and the scan. CI does exactly that.
Never put a production service-role key in CI to satisfy this.

The script prints which value assertions executed and which did not. It never
prints a value.
