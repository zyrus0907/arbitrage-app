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
