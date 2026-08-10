# DECISIONS.md

Architecture Decision Records. One entry per decision that a future reader would
otherwise have to reverse-engineer. Per `TASKS.md` §0 rule 4, any deviation from
`ARCHITECTURE.md` gets an ADR here **before** merge.

Format: context → decision → consequences. ADRs are append-only; a reversed
decision gets a new ADR that supersedes the old one rather than an edit.

---

## ADR-0001 — Next.js App Router, TypeScript strict, Tailwind, single deployable

**Status:** Accepted · T01 · 2026-08-09

**Context.** ARCHITECTURE.md §0.2 and §13 specify one repo, one deployable, App
Router with Server Components, and Tailwind. T01 is the skeleton that makes that
concrete.

**Decision.** Next.js (App Router) + React + TypeScript in `strict` mode +
Tailwind CSS v4, deployed to Vercel. The folder skeleton in §13 is created up
front, with a `README.md` in each directory stating the rule that governs it,
so the boundaries exist before there is code to put on the wrong side of them.

TypeScript is configured beyond bare `strict`: `noUncheckedIndexedAccess`,
`exactOptionalPropertyTypes`, `noImplicitOverride` and
`noFallthroughCasesInSwitch`. A codebase whose central concern is money
arithmetic should not have `array[i]` silently typed as defined.

`next.config.ts` explicitly sets `typescript.ignoreBuildErrors: false` and
`eslint.ignoreDuringBuilds: false`. Both are the framework defaults; stating
them prevents a future "just unblock the build" edit from passing unnoticed.

**Consequences.** One language, one build, one deploy target. Preview deploys per
PR. Stricter compiler settings will occasionally require an explicit
`undefined` check that a laxer configuration would not — that is the intent.

---

## ADR-0002 — Vitest as the test runner

**Status:** Accepted · T01 · 2026-08-09

**Context.** ARCHITECTURE.md names the CI stages (typecheck, lint, test, build)
but does not name a runner. Every task from T03 onward ships tests, several of
which are release gates: the redaction payload-leak test, the RLS access suite
and the unlock concurrency test.

**Decision.** Vitest, with `@testing-library/react` and a `jsdom` environment for
component tests. Tests live in `tests/unit` and `tests/integration`, with
colocated `*.test.ts` also picked up so a pure service can keep its tests beside
it as §13 shows.

**Rejected: Jest.** It needs additional transform configuration to run TypeScript
and ESM cleanly, and offers nothing this project needs in exchange.

**Rejected for now: Playwright.** The gates listed above are unit and integration
tests, not browser tests. The manual device checks that T28–T32 require are
explicitly manual and evidenced in the PR. Introducing a browser runner before
any UI exists would be tooling ahead of need.

**Consequences.** One runner covers pure functions, component rendering and
database-integration tests. `npm test` is the single CI test command.

---

## ADR-0003 — Environment variables validated at boot, in two separate schemas

**Status:** Accepted · T01 · 2026-08-09

**Context.** §1.2 rule 1: no third-party key may ever reach the browser. Next.js
enforces nothing here — it inlines any `NEXT_PUBLIC_*` variable into the client
bundle and leaves the rest as `undefined` at runtime if unset.

**Decision.** `src/lib/env.ts` is the only module that reads `process.env`. It
declares two Zod schemas — `publicEnvSchema` (`NEXT_PUBLIC_*` only) and
`serverEnvSchema` — and parses both at module load, throwing `EnvValidationError`
with the offending variable named. Public variables are read as static literals
because Next.js cannot inline a dynamic `process.env[name]` lookup.

Variables whose owning task has not landed yet (Supabase, Keepa, Stripe,
`CRON_SECRET`) are declared `.optional()` with a comment naming that task, and
are tightened to required by the task that first depends on them. They are
listed in `.env.example` now so the contract is visible; a present-but-empty
value is rejected rather than treated as unset.

**Consequences.** A misconfigured deployment fails at boot with a precise message
instead of failing later as an `undefined` inside a request path. The separation
makes "is this secret client-reachable?" answerable by reading one file — which
is what the T11 security review will check.

---

## ADR-0004 — Supabase clients, the `server-only` boundary, and forward-only migrations

**Status:** Accepted · T02 · 2026-08-10

**Context.** ARCHITECTURE.md §6.2 specifies three Supabase clients with three
different privilege levels. The dangerous one is the admin client: it holds the
service-role key and bypasses RLS entirely, so a single accidental import from a
Client Component publishes a key that can read and write every table. §6.3 makes
RLS the real authorisation boundary, which only holds if the session-bound
server client never quietly acquires service-role privileges.

**Decision.**

1. **Three files, three privileges, no shared factory.** `browser.ts` (anon),
   `server.ts` (anon + session via `@supabase/ssr`, `getAll`/`setAll` against the
   App Router cookie jar), `admin.ts` (service role). A shared factory
   parameterised by key would put the decision "which key" at a call site, which
   is exactly where it must not be.

2. **`import 'server-only'` is the first line of `admin.ts`.** The package
   resolves to an empty module under the `react-server` condition and to a
   throwing module under every other, so a `'use client'` import fails
   `next build` rather than shipping the key. This was verified empirically, not
   assumed: a probe page importing the admin client was built and the build
   failed with *"'server-only' cannot be imported from a Client Component
   module"*. `tests/unit/supabase/` locks in both the position of the line and
   the throwing behaviour, the latter by importing under Vitest's non-
   `react-server` resolution — the same condition a client bundle uses.

3. **The Supabase environment variables stay `.optional()` in `src/lib/env.ts`;
   each client asserts what it needs at construction.** Making them required at
   boot would mean the repository could not be typechecked, tested or built
   without live credentials, which breaks CI and every clean checkout. The
   trade-off is that a missing variable surfaces on first client construction
   rather than at boot; it surfaces *named*, via `requirePublicSupabaseEnv` /
   `requireServiceRoleKey`, which is the property that mattered in ADR-0003.

4. **Rollback is a forward migration, not a `down` command.** Supabase's
   migration tooling is forward-only. Rather than inventing a `down`-migration
   convention the tooling would not honour, `docs/RUNBOOK.md` §8 documents the
   supported path: a new migration that inverts the previous one, an
   expand → migrate → contract sequence for destructive changes, and `db dump`
   before anything irreversible.

5. **`src/types/database.ts` is generated and committed**, even while the
   application schema is empty. Committing the empty-schema shape now means every
   later schema change arrives as a reviewable diff of one file, and all three
   clients are already parameterised by `Database`.

**Consequences.** The privilege boundary is enforced by the build rather than by
review discipline. Adding a fourth client, or importing the admin client into a
Client Component, cannot pass CI silently. Migration history is linear and
replayable in every environment; the cost is that undoing a destructive change
requires a backup taken beforehand, which §8.4 makes an explicit step.

---

## ADR-0005 — Schema A: key types, enum policy, and currency consistency by construction

**Status:** Accepted · T03 · 2026-08-10

**Context.** `ARCHITECTURE.md` v2.0 §2 is the schema contract, but it carries
three residues of v1.0 that Schema A had to resolve before any SQL could be
written, plus two questions the document leaves to the implementer.

**Decisions.**

1. **`marketplaces` and `markets` use `uuid` primary keys with a separate
   natural key.** §2 states that PKs are `uuid`, and §2.2 gives `marketplaces`
   both an `id PK` and a `code` (`'amazon_uk'`) — but §2.3 then types
   `marketplace_products.marketplace_id` as `text`. The `text` is v1.0 residue
   from when the marketplace *was* the code. `marketplaces.id uuid` with
   `code text unique` is taken as the intent, and `markets` follows the same
   shape with `slug`. `'amazon_uk'` remains the value that seeds, logs and
   `MarketContext` carry; it is simply not the storage key.

2. **`TASKS.md` T03's "No table named `marketplace_products` exists" is read as
   `amazon_products`.** The same task requires `marketplace_products` to be
   created, and §2.3 titles that table "replaces `amazon_products`". The
   acceptance criterion is honoured against the table it was clearly written
   about, and `supabase/tests/database/schema_a.test.sql` asserts
   `hasnt_table('public','amazon_products')` permanently.

3. **Enums only for closed domains; `provider` and `adapter_key` stay `text`.**
   Postgres enum types give the generated `Database` type real unions, which is
   worth having for `tax_regime`, `price_tax_treatment`, `market_launch_status`,
   `tax_scheme`, `fulfilment_type`, `gtin_format`, `retailer_source_type`,
   `match_method` and `match_verified_by`. They are the wrong choice for
   `marketplaces.provider` and `marketplaces.adapter_key`: an enum there would
   mean adding eBay required a migration, which §0.3 forbids in as many words.

4. **The single-currency invariant is enforced by composite foreign key, not by
   convention.** §1.3 states the MVP invariant `retailer.currency ==
   marketplace.currency` and §7.6 asks for it at three layers. The storage layer
   is the first: `marketplaces UNIQUE(id, currency)` is referenced by
   `markets(marketplace_id, currency)` and by
   `marketplace_products(marketplace_id, currency)`, and `markets UNIQUE(id,
   currency)` is referenced by `retailers(market_id, currency)`. A row that
   would require an FX conversion cannot be written at all. The pricing-engine
   assertion and the matching validation (§7.6's other two layers) remain to be
   built in T13–T18.

5. **`updated_at` on every Schema A table, via one shared trigger.**
   `ARCHITECTURE.md` specifies `created_at` but is silent on `updated_at`.
   Reference data is edited by an admin and catalogue rows are re-upserted by
   ingestion; knowing when a row last changed is worth one trigger function.
   `public.set_updated_at()` pins its `search_path` even though it is not
   `SECURITY DEFINER`.

**Deliberately not built in T03.** `fx_rates` (§2.2) appears in no task's create
list — T03, T04 and T05 all omit it — and §7.7 forbids its use in MVP deal
maths, so it is not created here and needs a task before Phase 3.
`tax_schedules` has a unique `(country_code, effective_from)` but **no exclusion
constraint preventing overlapping effective ranges**: that needs `btree_gist`,
and an extension is not worth adding before T08 seeds a schedule that could
overlap. Overlap remains a seeding discipline until then.

**Consequences.** A cross-currency deal is unrepresentable rather than merely
discouraged — the failure mode §7.6 calls out (a silent FX error looking exactly
like a great deal) cannot originate in the data. The cost is that changing a
marketplace's currency is a multi-row operation rather than one `update`, which
is the correct level of friction for a change that would invalidate every deal
beneath it.

---

## ADR-0006 — Table, function and default privileges are declared in migrations

**Status:** Accepted · T03 · 2026-08-10

**Context.** RLS is the authorisation boundary (§6.3), but it is the *second*
gate. PostgreSQL consults a policy only after the role already holds the table
privilege. After Schema A was pushed, that first gate differed between
environments: the local stack granted `anon`, `authenticated` and `service_role`
only `REFERENCES/TRIGGER/TRUNCATE/MAINTAIN`, while the hosted development
project granted all three `ALL` — because Supabase's hosted projects carry
`ALTER DEFAULT PRIVILEGES ... GRANT ALL ON TABLES TO anon` for the `postgres`
role and the current CLI image does not.

Both environments denied `anon` at T03, but for different reasons — locally
because the grant was missing, remotely because RLS caught it. T09 exists to
prove the anon key can read nothing; run against the local stack it would have
passed without exercising what production does. The same gap left the
`service_role` with no DML locally, so the admin client could not read the very
tables §6.3 designates service-role-only.

**Decision.** Privileges are declared in migrations, like everything else about
the schema, in `20260810033236_normalise_privileges.sql`:

1. `REVOKE ALL` on the eleven Schema A tables from `anon`, `authenticated` and
   `service_role`, then `GRANT SELECT, INSERT, UPDATE, DELETE` to
   `service_role` alone. Nothing is granted to `anon` or `authenticated` at
   T03; the public-read tables get their `SELECT` in T06, **in the same
   migration as the policy that governs it**. A grant and its policy belong
   together or one of them gets forgotten.

2. The two trigger functions become owner-only. This is safe: `EXECUTE` on a
   trigger function is checked when the trigger is created, not when it fires,
   which was verified against a probe table before the migration was written.

3. `ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public` is normalised
   for tables, functions and sequences, so future objects inherit this posture
   instead of re-importing the divergence. This matters most for functions:
   with the inherited default plus PostgreSQL's built-in `PUBLIC EXECUTE`,
   T07's `spend_credits` would be callable by `anon` unless someone remembered
   to revoke — against that task's own acceptance criteria and against risk #9.

`supabase/tests/database/privileges.test.sql` asserts the resulting state, so
drift fails a test rather than surviving as a difference nobody looks at.

**Consequences.** T04, T05 and T06 must grant explicitly: a new table is
readable by nobody but the service role until a migration says otherwise, and a
new function is executable only by its owner. That is more typing and it is the
point — the safe state is now the default and access is the deliberate act.
T09's suite will exercise the same privilege shape in both environments, so a
pass there means what it claims to mean.

---

## ADR-0007 — Functions in `public` are owner-only by default

**Status:** Accepted · T03 · 2026-08-10 · refines ADR-0006

**Context.** ADR-0006 normalised table, function and sequence privileges, but
`20260810033236_normalise_privileges.sql` revoked function privileges from
`PUBLIC`, `anon` and `authenticated` only. The hosted development project had
also granted `EXECUTE` to `service_role` on both trigger functions and by
default on future ones; the local stack had not. Nothing was reachable by an
untrusted role in either place, so this was never an exposure — it was the same
reproducibility defect ADR-0006 set out to remove, surviving in a smaller form:
T07's credit RPCs would have been executable by the service role automatically
on the hosted project and not locally.

**Decision.** `20260810042445_functions_owner_only.sql` revokes `EXECUTE` from
`service_role` on `handle_new_user()` and `set_updated_at()`, and revokes it in
the default privileges for `PUBLIC`, `anon`, `authenticated` **and**
`service_role`. A function created in `public` is now executable by its owner
and nobody else until a migration says otherwise.

This deliberately differs from the table rule in ADR-0006, where `service_role`
does inherit DML by default. Tables are the service role's ordinary working
surface — §6.3 routes every server-side read and write through it, and making
each new table need a grant would be friction without a corresponding risk.
Functions are the opposite: the ones this project will add are `SECURITY
DEFINER` RPCs that move credits, and §6.5 and risk #9 make their reachability a
financial-integrity property. T07's own acceptance criterion already says
`spend_credits` and `grant_credits` must be "callable only by the service role",
so that task writes the grant next to the function it belongs to.

**Trigger safety.** `EXECUTE` on a trigger function is checked when the trigger
is created, not when it fires. This is asserted permanently rather than
trusted: `supabase/tests/database/privileges.test.sql` builds a
`SECURITY DEFINER` probe shaped like the signup trigger, revokes `EXECUTE` from
every role after the trigger exists, fires it as `anon`, and asserts both that
the trigger ran and that `anon` genuinely held no `EXECUTE` at the time. The
`updated_at` trigger is fired by `service_role` under the same condition.

**Consequences.** T07 must grant `EXECUTE` explicitly on each credit RPC, and
any later function follows the same rule. Forgetting produces a loud
`permission denied for function` on first call, locally and remotely alike,
rather than a difference between environments discovered in production.
