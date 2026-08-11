# DECISIONS.md

Architecture Decision Records. One entry per decision that a future reader would
otherwise have to reverse-engineer. Per `TASKS.md` §0 rule 4, any deviation from
`ARCHITECTURE.md` gets an ADR here **before** merge.

Format: context → decision → consequences. ADRs are append-only; a reversed
decision gets a new ADR that supersedes the old one rather than an edit.

> **Two numbering series exist and they are not the same series.** The
> four-digit `ADR-0001…` records are *implementation* decisions, written by the
> task that made them (T01 → onward). The three-digit `ADR-004…008` records are
> *planning* decisions from the T03 post-completion review, written before the
> tasks that implement them. `ADR-007` (planning: deal market-consistency) and
> `ADR-0007` (implementation: functions are owner-only) are therefore different
> decisions. Noted rather than renumbered, because both sets are referenced by
> name from `TASKS.md`, `ARCHITECTURE.md` and existing migrations.
>
> **Going forward there is one series: the four-digit one.** The planning series
> ended at `ADR-008`; every new ADR — whatever its origin — continues from
> `ADR-0009`. That closes the collision rather than widening it.

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

## ADR-004 — Database privilege posture: default-deny at two layers
 
**Status:** Accepted · **Date:** 2026-08-10 · **Arose from:** T03 · **Supersedes:** nothing
 
### Context
 
T03 created 11 tables with RLS enabled and zero policies. During implementation we also normalised the underlying SQL privileges, which Supabase and Postgres would otherwise grant liberally by default. The resulting posture is:
 
- `anon` and `authenticated`: **no table privileges**
- `service_role`: **table DML only** (no DDL)
- Functions: **owner-only** by default
- Local and remote privilege state normalised and verified to match
This is a stronger posture than "RLS on, no policies," and it changes what a policy *means*. RLS filters rows **within privileges already held**. With no grant, a policy is inert — the query fails with a privilege error before RLS is ever consulted.
 
### Decision
 
Default-deny is enforced at **two independent layers — SQL privileges and RLS policies — and access requires both**.
 
1. Every migration creating a table, function, view or sequence **states its privilege posture explicitly** in a header comment. Silence is not a posture.
2. New objects receive **no** `anon` or `authenticated` privileges unless a later task grants them deliberately.
3. Any privilege Postgres or Supabase grants by default is **revoked in the same migration** that creates the object — including on sequences, which are easy to miss.
4. **Every policy has a matching minimum grant; every grant has a matching policy.** A mismatch in either direction is a defect: an inert policy, or an ungoverned privilege.
5. Grants are **minimum-necessary and per-operation**. Never `GRANT ALL`.
### Consequences
 
- **T06** must issue explicit `GRANT SELECT` (and per-operation grants) alongside every policy. Without this the policies are decoration and the app cannot read its own data.
- **T07** must `REVOKE ALL ON FUNCTION … FROM PUBLIC, anon, authenticated` and `GRANT EXECUTE … TO service_role`, in the same migration as the function body, and again after every `CREATE OR REPLACE`. A `SECURITY DEFINER` credit function with a default `PUBLIC` execute grant is a direct route to minting credits.
- **T04, T05, T05A** must state their posture and grant nothing to `anon`/`authenticated`.
- **T09's tests must distinguish failure modes.** A test asserting "zero rows" passes for the wrong reason when the real cause is a missing grant — and would keep passing until the day a grant is added, at which point it silently stops protecting anything. Assertions must specify whether a privilege error or RLS filtering is expected. See ADR-004 consequences in `TASKS.md` T09.
- Added as global rule 8 in `TASKS.md` and to the migration checklist in `docs/RUNBOOK.md`.
- Ongoing cost: roughly two extra lines per migration, and one review question per PR. Accepted.
### Alternatives considered
 
- *Rely on RLS alone with Supabase's default grants.* Rejected: it makes the anon key's reach depend on a default we do not control, and a policy authoring mistake becomes an immediate data leak rather than a caught error.
- *Grant broadly to `authenticated` and rely on policies to filter.* Rejected: one missing policy then exposes a whole table, and the paid product (`deals`) is exactly the thing that would leak.
---
 
## ADR-005 — `fx_rates` deferred to Phase 3
 
**Status:** Accepted · **Date:** 2026-08-10 · **Arose from:** T03 planning gap review
 
### Context
 
`ARCHITECTURE.md` §2.2 originally specified `fx_rates` as "Phase 3 use, **seeded now** for admin reporting only." No task in `TASKS.md` owned creating it — the gap that prompted this review.
 
On inspection the document contradicted itself. §2.2 said seed it now; risk #4 says "**no FX in MVP at all**"; §7.6 constrains deals to a single currency; §0.1 assumption 7 makes cross-border Phase 3; and `PRODUCT_SPEC.md` AC2.7 forbids the user from selecting a combination that would require conversion. "Admin reporting" is not a feature in `PRODUCT_SPEC.md`, and the admin console (T33) has no cross-currency view.
 
### Decision
 
**`fx_rates` is not created in the MVP.** It arrives in Phase 3, at the first genuine cross-border or multi-currency reporting requirement, and not before. `ARCHITECTURE.md` §2.2 is amended to match. `TASKS.md` T08 states it as explicitly out of scope.
 
### Consequences
 
- One extra migration in Phase 3. Trivial.
- Removes a live footgun: an empty table with no consumer is an invitation for a later service to join it and convert a currency, and **a silent FX error looks exactly like a great deal**. That is risk #4 in the architecture's own words.
- Until Phase 3, no table, no FK, no reference under `src/services/`.
### Revisit condition
 
The first of: cross-border sourcing (§7.7), multi-currency admin reporting becoming a stated requirement in `PRODUCT_SPEC.md`, or a second live market whose costs need consolidating into one reporting currency.
 
---
 
## ADR-006 — Temporal exclusion constraints on versioned schedules
 
**Status:** Accepted · **Date:** 2026-08-10 · **Arose from:** T03 planning gap review · **Implemented by:** T05A
 
### Context
 
`tax_schedules` and `fee_schedules` are versioned by an `effective_from`/`effective_to` pair. T03 created both without any constraint preventing overlapping ranges. The original plan left non-overlapping ranges as a T08 seeding discipline.
 
`MarketContext` (T13) resolves "the schedule effective for this key on this date." With two overlapping rows, Postgres returns whichever row the plan happens to reach first — stable enough to pass tests, unstable enough to change after an unrelated `VACUUM`.
 
Seeding discipline cannot hold this, because T08 is not the only writer: T33 gives the admin console versioned fee-schedule editing (AC16.4). A human will eventually create an overlap by hand, and the failure is silent.
 
### Decision
 
Enforce non-overlap **in the database**, on both tables, via `EXCLUDE` constraints (`btree_gist`, enabled only if not already present).
 
- **Half-open `[)` ranges.** A version ending at T and its successor starting at T are adjacent, not overlapping, and both are accepted — this is the normal shape of a version bump and must not be rejected.
- **`effective_to IS NULL` means open-ended/current and participates in overlap detection** as an unbounded upper edge. Two open-ended rows for the same key are rejected. A NULL that silently dropped out of the constraint would defeat the entire purpose, because the current row is precisely the one most likely to be NULL-terminated.
- Keyed by `country_code` for `tax_schedules`, `marketplace_id` for `fee_schedules`. Overlaps across different keys remain valid.
- `CHECK (effective_to IS NULL OR effective_to > effective_from)`.
**Representation choice:** record in the T05A PR whether `tstzrange(effective_from, effective_to, '[)')` is used inline or a generated range column is added. Both are acceptable; the choice must be consistent across the two tables.
 
### Consequences
 
- **T05A blocks T08.** The constraint must exist before any schedule row is seeded, or the seed can create the defect and commit it as fixture data.
- Failure mode moves from silent and market-wide (risks #2 and #3, "trust gone market-wide") to a loud write rejection at the moment a human makes the mistake.
- The admin console's schedule editor (T33) will surface constraint violations as user-facing errors. It must handle them with a clear message rather than a 500.
- Recorded in `ARCHITECTURE.md` §2.2 as a stated convention, not only here, because T13 and T33 both depend on the semantics.
---
 
## ADR-007 — Deal market-consistency enforced declaratively
 
**Status:** Accepted · **Date:** 2026-08-10 · **Arose from:** T03 planning gap review · **Implemented by:** T04
 
### Context
 
`deals` carries `market_id`, `retailer_product_id` and `marketplace_product_id`. Nothing prevented a row where these disagree — a deal in market A referencing a retailer product belonging to market B, or a marketplace product from a marketplace other than the one market A resolves to.
 
`ARCHITECTURE.md` §15 step 11 anticipates this ("cross-market deal id is rejected") but no constraint existed. §2.3 states the consequence plainly: a query that forgets market scoping surfaces as "a user in Germany seeing a Tesco price in pounds."
 
The T04 test criterion that was supposed to cover this — "two markets can hold independent deals for the same canonical product pair where the marketplace differs" — was incoherent: if the marketplace differs, `marketplace_product_id` differs, so it is not the same pair; and a retailer product cannot belong to two markets because its retailer has exactly one `market_id`. It tested nothing.
 
### Decision
 
Enforce in the database, on insert **and** update:
 
1. `deals.market_id` equals the market of `retailer_product_id`'s retailer.
2. `deals.marketplace_product_id`'s `marketplace_id` equals the `marketplace_id` that `deals.market_id` resolves to.
**Preferred mechanism: denormalise the parent keys onto `deals` and enforce with composite foreign keys.** A `CONSTRAINT TRIGGER` is acceptable if the engineer judges it cleaner, and the choice is recorded in the T04 PR — but declarative constraints cannot be bypassed by `COPY` or a service-role bulk upsert, and the T19 ingestion pipeline does bulk upserts.
 
A violation must **fail the write**. A cross-market deal that merely fails to appear in a feed is not acceptable.
 
### Consequences
 
- Small denormalisation on `deals` if option (a) is taken — accepted, since the columns are immutable for the row's lifetime.
- T04's test criterion replaced with genuine cross-market rejection tests covering insert, update and bulk write.
- T19's pipeline gets a hard failure rather than a silent bad row, consistent with the "partial failure is normal, silent wrongness is not" principle in §12.2.
---
 
## ADR-008 — Public reference-data exposure surface
 
**Status:** Accepted · **Date:** 2026-08-10 · **Arose from:** T03 privilege review · **Implemented by:** T06
 
### Context
 
`ARCHITECTURE.md` §6.3 originally listed `markets`, `marketplaces`, `countries` and `currencies` as public-read, with the rationale "the client needs to render a currency and a market name."
 
`marketplaces` carries `adapter_key` and `capabilities` — integration internals that describe which provider serves a marketplace and what data it can supply. The stated rationale does not require it: the feed is market-scoped server-side, and rendering a currency and a market name is served by `currencies` and `markets` alone. No MVP client surface reads it.
 
### Decision
 
The public-read surface for `anon`/`authenticated` is exactly:
 
| Table | Exposure |
|---|---|
| `countries` | `SELECT`, active rows only |
| `currencies` | `SELECT`, active rows only |
| `markets` | `SELECT`, active/live rows only |
| `credit_packs` | `SELECT`, active rows only |
| `credit_pack_prices` | `SELECT`, active rows only |
 
**`marketplaces` is removed from public read** and becomes service-role only. Everything not in this table is service-role only.
 
If a client need for marketplace data emerges, expose a **view** with the specific columns required — do not grant the table.
 
### Consequences
 
- `ARCHITECTURE.md` §6.3 amended; this is the one place where v2.1 planning **narrows** a previously documented decision, and it is recorded here rather than changed silently.
- T06 grants and T09 assertions both updated: `marketplaces` moves to the "privilege error expected" category.
- If a later frontend task needs `capabilities` client-side, that is a design smell — capability-aware scoring (§8.7) happens server-side and ships its results in the redacted deal payload.

---

## ADR-0008 — Schema B: cross-market consistency by composite foreign key

**Status:** Accepted · T04 · 2026-08-10 · implements ADR-007

**Context.** ADR-007 requires that a `deals` row cannot reference a retailer
product and a marketplace product that do not both belong to its market, that
the rule hold on insert *and* update, and that it hold for bulk writes — T19's
pipeline upserts in batches as the service role. It offers two mechanisms and
prefers (a) denormalised parent keys plus composite foreign keys over (b) a
`CONSTRAINT TRIGGER`, and asks that the choice be recorded.

**Decision. Option (a).** `deals` carries two denormalised, `NOT NULL` scope
keys — `retailer_id` and `marketplace_id` — and five foreign keys compose the
two rules out of one-hop relationships that do exist:

| Constraint | References | Asserts |
|---|---|---|
| `deals_retailer_product_fkey` | `retailer_products (id, retailer_id)` | the product belongs to that retailer |
| `deals_retailer_market_fkey` | `retailers (id, market_id)` | the retailer belongs to the deal's market |
| `deals_marketplace_product_fkey` | `marketplace_products (id, marketplace_id)` | the listing belongs to that marketplace |
| `deals_market_marketplace_fkey` | `markets (id, marketplace_id)` | the market resolves to that marketplace |
| `deals_market_currency_fkey` | `markets (id, currency)` | the deal is priced in its market's currency (§7.6) |

Rows 1–2 compose ADR-007's rule 1; rows 3–4 compose rule 2. Row 5 extends the
same technique Schema A already uses for `markets`, `retailers` and
`marketplace_products` (ADR-0005 decision 4) to the table where a currency error
would actually reach a user.

Four composite `UNIQUE` constraints were added to Schema A tables to be
referenceable: `retailers (id, market_id)`, `retailer_products (id,
retailer_id)`, `markets (id, marketplace_id)`, `marketplace_products (id,
marketplace_id)`. Each is *(primary key, one parent key)* and so is already
implied by the primary key — it restricts nothing about what those tables may
hold, and it needs **no new column on any T03 table**. The denormalisation lands
on `deals`, which is where ADR-007 puts it.

**Why not the trigger.** A foreign key is enforced by the same referential
machinery on `INSERT`, `UPDATE`, `INSERT … ON CONFLICT DO UPDATE` and `COPY`,
and cannot be turned off by `ALTER TABLE … DISABLE TRIGGER` or by
`session_replication_role = replica` — both of which bulk-load and restore
tooling uses. The failure is a plain `23503` that a pipeline already handles as
a row-level error rather than a bespoke exception to parse. `COPY FROM STDIN` of
a cross-market row was verified rejected by hand, because pgTAP cannot trap it:
a failing `COPY` aborts the surrounding transaction, and `COPY FROM
PROGRAM`/`FILE` needs a superuser, which neither the local stack nor a hosted
Supabase project grants. The suite covers the paths that *can* be trapped —
single insert, update, multi-row insert, `INSERT … SELECT` from a staging table,
and both branches of an upsert — and additionally asserts the exact set of
non-internal triggers on `deals` — `set_updated_at` and, after ADR-0009,
`enforce_deal_lifecycle` — so the cross-market enforcement cannot quietly
migrate into a trigger, and a third one cannot appear unannounced.

**The load-bearing detail.** A composite foreign key is `MATCH SIMPLE`: if any
referencing column is `NULL`, PostgreSQL skips the check entirely. `retailer_id`
and `marketplace_id` being `NOT NULL` is therefore not tidiness — it is the
constraint. `supabase/tests/database/schema_b.test.sql` asserts it directly.

**Two further judgement calls, recorded so they are not mistaken for accidents.**

1. **The same technique is applied to `watchlist_items` and `purchase_records`,
   with no columns beyond the ones T04 enumerates.** `deals` gained three more
   *(id, column)* unique keys so that a watchlist item cannot point at a listing
   its deal is not about, and a purchase record cannot be attributed to a market
   or a currency its deal does not use. Predicted-versus-actual is reported per
   market and never pooled (§14.4), so a misattributed purchase row corrupts the
   one number the MVP exists to measure.
2. **The same technique is *not* applied to `fee_schedule_id`/`tax_schedule_id`,
   nor to `barcode_lookups`.** Tying a deal's fee schedule to its marketplace is
   the same class of correctness and is cheap, but T04's scope names exactly two
   cross-market rules; the tax-schedule half would additionally need a
   denormalised country code, so doing only the fee half would be an asymmetric
   half-measure. `barcode_lookups` would need a denormalised `marketplace_id`
   beyond T04's enumerated column set. Both are noted for T05A/T13 rather than
   smuggled in here.

**Consequences.** A cross-market or cross-currency deal is unrepresentable
rather than merely rejected downstream, on every write path, including the bulk
ones T19 has not been written yet. The cost is two denormalised columns that
T19's writer must populate — it will fail loudly with `23502` if it does not —
seven extra unique indexes across six tables, and the standing rule that the
scope keys are immutable for a row's lifetime. A wholesale, internally
consistent move of every scope key at once is still permitted, and is tested:
the constraints forbid *disagreement*, not change.

---

## ADR-0009 — Deal lifecycle: draft → active → retired, with retirement terminal

**Status:** Accepted · T04 · 2026-08-10 · product decision by the Product Manager · amends `ARCHITECTURE.md` §2.3

**Context.** `ARCHITECTURE.md` §2.3 typed `deals.status` as `active | stale | retired`. T04 implemented that enum and immediately surfaced a contradiction it could not resolve on its own: `TASKS.md` T19 requires that "deals default to a non-published state" and `PRODUCT_SPEC.md` AC3.3 requires that "no ingested product becomes a user-visible deal without an explicit publish action by an admin" — and there was no unpublished state to default to. `stale`, meanwhile, was a state for something that is not a state: freshness is a function of `deals.expires_at` and `marketplace_products.refreshed_at`, both of which already exist.

Raised at the T04 pre-push stop rather than patched around. The Product Manager resolved it.

**Decision.**

1. **`deal_status` is `draft | active | retired`.** `stale` is removed entirely.
2. **`deals.status` is `NOT NULL DEFAULT 'draft'`**, and an INSERT in any other state is rejected. A newly computed deal is therefore invisible to users whatever the pipeline intends, and publication is always a later UPDATE.
3. **Legal transitions:** `draft → draft`, `draft → active`, `draft → retired`, `active → active`, `active → retired`. **Retired is terminal** — `retired → active`, `retired → draft` and `active → draft` are rejected. A retired row's other columns may still be corrected; its state may not change.
4. **Enforced by a `BEFORE INSERT OR UPDATE` row trigger** (`public.enforce_deal_lifecycle`), which also stamps `published_at`/`retired_at` when the caller leaves them absent and never touches the actor columns.
5. **Audit columns on `deals`:** `published_at`, `published_by`, `retired_at`, `retired_by`, `retire_reason`. The actor columns reference `auth.users` with `ON DELETE SET NULL`.
6. **Staleness is derived at read time**, never stored — no `stale` value, no boolean, no freshness column.
7. **The pair unique index predicate becomes `status <> 'retired'`.** One *live* deal per pair; retired rows leave the index so history is kept and a replacement draft is always possible.

**Why a trigger, when ADR-0008 argued for declarative constraints.** A transition rule compares OLD to NEW, and PostgreSQL has no declarative form for that — no assertions, no temporal constraints, and a CHECK cannot see the previous row. The choice was not "trigger versus foreign key" but "trigger versus nothing". The cross-market invariants remain declarative and unaffected; `deals` now carries exactly two user triggers, and a test asserts that so the cross-market rules cannot quietly migrate into one.

**Why an INSERT must be `draft` rather than merely defaulting to it.** A default protects against forgetting; it does not protect against a service deciding it knows better, and AC3.3 is a promise to users that nothing unreviewed reaches them. With the insert restricted, the guarantee holds for the pipeline, for admin CSV loads, for a bulk `COPY`, and for anything written later by someone who has not read T19. The cost is that publication is always an UPDATE — which is what T20A does anyway.

**Why `ON DELETE SET NULL` on the actor columns.** `CASCADE` would delete a deal because an admin closed their account, which is absurd. `RESTRICT` would block the account deletion AC1.5 promises. `SET NULL` keeps the fact and the timestamp, drops the personal linkage, and is the privacy-preserving answer as well as the operationally correct one.

**What this decision deliberately does not do.** It does not enforce *who* may publish or retire. The database rejects transitions that are invalid for everyone; authorization belongs to **T20A**, added by this decision as the single sanctioned API for the two acts, and to **T33**, which calls it. A trigger that tried to read the current actor's role would put authorization in the one place it cannot be tested or reasoned about per request.

**Consequences.**

- **T19** inserts drafts, never publishes, retires an active deal that becomes hard-suppressed on recompute (`retire_reason = 'suppressed_on_recompute'`), and skips rejected matches.
- **T20A** is new and blocks **T33**.
- **T22/T29** filter on exactly `status = 'active'`; a retired deal remains reachable by a user who unlocked it (AC10.7).
- **T24** must mark the underlying `product_matches` row rejected on a confirmed bad match (AC15.6), adding that marker in its own migration — otherwise the next recompute republishes the same error. `product_matches` has no rejection concept today, and T04 deliberately did not invent one for a workflow that does not exist yet.
- **T27** asserts a pipeline run produces zero active deals.
- One state transition per deal is now an auditable event rather than an inferred one, which is what makes AC3.9 measurable at all.

---

## ADR-0010 — Financial records: reversal semantics, retention, and double-enforced ledger immutability

**Status:** Accepted · T05 planning · 2026-08-10 · taken **before** T05 begins · amends `ARCHITECTURE.md` §2.3, §6.3, §9.2, §9.3, §11.2, §11.4, §11.5 · does not touch ADR-0009 or any T01–T04 outcome

**Context.** T05 creates every table that money passes through — `credit_ledger`, `credit_purchases`, `credit_packs`, `credit_pack_prices`, `stripe_webhook_events` — and six questions were left open by `ARCHITECTURE.md` v2.0 in ways that only become expensive later:

1. §9.2 rule 4 says a Stripe reversal "deducts credits", and §9.3 says a bad deal is refunded with `reason='refund'`. The reason enum has one value for both, so the ledger cannot distinguish "we were wrong" from "the payment was reversed" after the fact — and the sign cannot either, since `admin_adjust` may also be negative.
2. §2.3 says "No UPDATE, no DELETE, ever", and §11.2 says a trigger enforces it — but the `service_role` our own server code runs as holds blanket table DML from ADR-0006, so the strongest statement in the schema was one `DROP TRIGGER` away from untrue.
3. §11.5 specifies account deletion as a cascade from `auth.users`, which, applied to the ledger, would let a user delete the record of their own purchases and refunds.
4. T08 seeds pack prices in week 2; T34 creates Stripe Prices in week 5. Nothing said what `stripe_price_id` holds in between.
5. `stripe_webhook_events` was listed with `processed_at` and `error` — fields written *after* the row is inserted — while T06 was told to make the table reject UPDATE, which would break T35's fulfilment path.
6. T06 was to create the ledger immutability trigger, one task after T05 creates the ledger, leaving a window where the source of truth for money is mutable.

**Decisions.**

**1. `refund` and `chargeback` are separate ledger reasons with opposite signs.** The enum becomes `signup_grant | purchase | unlock_deal | barcode_lookup | refund | chargeback | admin_adjust | promo`.

- **`refund` — positive.** A credit restored to the user because the product was wrong (AC15.4). It is a quality event, counted by the "credit refunds issued" trust-damage signal (`PRODUCT_SPEC.md` §9.4).
- **`chargeback` — negative.** Credits removed because Stripe reversed the payment that created them (`charge.refunded`, `charge.dispute.created`, AC17.5). It is a payment event, reconciled against Stripe, and it may drive the balance negative.

Two reasons cost one enum value. One reason costs the ability to answer "are we shipping bad deals?" without joining to Stripe.

**2. Financial records are `ON DELETE RESTRICT` and survive account deletion.** `credit_ledger.user_id` and `credit_purchases.user_id` restrict; the user-activity tables T04 built keep their cascades. Audit and reconciliation evidence that a user can delete by closing their account is not evidence, and a chargeback can arrive months later against an account that no longer exists.

**3. `credit_ledger` immutability is enforced twice, and both layers are built in T05.** A `BEFORE UPDATE OR DELETE` trigger that raises unconditionally, **and** `REVOKE UPDATE, DELETE ON credit_ledger FROM service_role` so the role holds only `SELECT, INSERT`. The trigger is created in the same migration as the table, not in T06 — a table that holds money should never exist in a mutable state, not even for one migration. T06's job becomes verification.

**4. `stripe_price_id` is nullable until T34, and placeholders are prohibited.** T08 seeds `NULL`. The safety is a read predicate, not a column constraint: `credit_pack_prices` is publicly readable only where `active = true AND stripe_price_id IS NOT NULL` (T06). A fake id like `price_TODO` would satisfy every not-null check and then fail at the Checkout call, which is the worst place to discover it.

**5. Webhook event identity is immutable; its processing outcome is not.** `stripe_event_id`, `type`, `payload` and `received_at` are frozen by a restricted-UPDATE trigger (T06); `processed_at` and `error` are writable. `DELETE` is revoked from `service_role` in T05 — the row *is* the replay guard, and deleting one re-opens the duplicate-grant window.

**6. `service_role`'s blanket table DML is narrowed per table where the table's own invariant requires it.** This is the first deviation from ADR-0006's uniform posture, and it is deliberate: `service_role` is not a trusted actor, it is the identity every server-side bug runs as.

**Why not enforce immutability with the trigger alone.** A trigger is a schema object like any other: `DROP TRIGGER` is one line in a migration written by someone who found it inconvenient at 2am, and nothing else in the schema would notice. Revoking the privilege means the *default* posture of the role that runs all our code is "cannot do this", so the trigger becomes the backstop for privileged roles rather than the only wall.

**Why not enforce it with the revoke alone.** A revoke says nothing about the migration owner, a support script connected as `postgres`, or a dashboard SQL session — exactly the contexts in which someone "just fixes one row". AC10.5 promises the *database* rejects it, not that our application happens not to try.

**Why account deletion is not solved here.** Retention is a schema decision and belongs to T05, which creates the foreign keys. **De-identification is a product and privacy decision and belongs to T10**, which owns account deletion and must test the result. The two are not the same choice, and picking the second one now — a tombstone profile, a surrogate subject id, a nulled actor column — would fix the FK shape, the reconciliation query and the privacy claim from the task least able to evaluate them. T10 records its choice as its own ADR.

**Consequences.**

- **T05** creates the ledger trigger, applies both revokes, and adds the constraints (`idempotency_key NOT NULL UNIQUE`, `delta <> 0`, `balance_after NOT NULL` and signed, `credits > 0`, `amount_minor > 0`, currency FKs) and the eight required indexes. Its tests must distinguish a privilege failure from a trigger failure, which means exercising the trigger as a role that holds the privilege.
- **T06** verifies the ledger protections instead of creating them, and adds the restricted-UPDATE trigger to `stripe_webhook_events`. Its `credit_pack_prices` policy predicate gains `AND stripe_price_id IS NOT NULL`.
- **T07**'s `grant_credits` writes `chargeback` rows as well as `refund` rows; both are inserts, so the revoke does not constrain it. The RPCs are `SECURITY DEFINER` and run as owner, so the ledger revoke on `service_role` does not affect them — that is the intended shape, not a loophole: the only sanctioned write path stays open and every unsanctioned one closes. **One implementation constraint follows for T07:** the idempotency check in §6.5's sketch must resolve as `ON CONFLICT DO NOTHING` plus a read of the existing row, never `ON CONFLICT DO UPDATE` — an upsert on `credit_ledger` is an UPDATE and the append-only trigger will raise on it, correctly.
- **T08** seeds `stripe_price_id` as `NULL`. **No pack price is publicly readable until T34 populates it** — the credits page will show no purchasable pack before then, which is correct and should not be "fixed" with a placeholder.
- **T09**'s privilege suite must assert the narrowed per-table posture, not a blanket `service_role` DML grant, or the revokes regress silently.
- **T10** owns account-deletion pseudonymisation and must record it as its own ADR. Until it lands, deleting a user with ledger rows fails with `23503` — including via `auth.users`, because `profiles` cascades from it.
- **T35** deducts with reason `chargeback`, and its per-currency reconciliation can now separate payment reversals from product refunds without leaving the database.
- **`PRODUCT_SPEC.md`** gains AC1.6 (financial retention) and sharpened AC15.4 / AC17.5 / AC21.4.

---

## ADR-0011 — Schema C: four storage-level invariants, and four ambiguities resolved

**Status:** Accepted · T05 · 2026-08-10 · implements ADR-0010 · refines `ARCHITECTURE.md` §2.3 in four places where the document was silent or self-contradictory · touches no T01–T04 outcome

**Context.** ADR-0010 settled T05's six open questions before the task began, and T05 implemented them as written: the split `refund`/`chargeback` reasons, `ON DELETE RESTRICT` on both financial tables, the double-enforced ledger immutability, the nullable `stripe_price_id`, the restricted-not-immutable webhook table, and the two `service_role` narrowings. Writing the SQL surfaced two further classes of thing that ADR-0010 could not have covered, because both only appear once the columns are being typed:

1. **Four invariants the documents state in prose but no constraint would have enforced.** Each is a financial defect of the silent kind `RUNBOOK.md`'s financial checklist exists to prevent — nothing fails at write time, and the disagreement surfaces in a reconciliation months later.
2. **Four points where `ARCHITECTURE.md` §2.3's column list and another section of the same document could not both be satisfied.** Each needed a decision rather than a reading.

**Decisions — part 1: four invariants enforced at the storage layer.**

**1. `refund` must be positive and `chargeback` must be negative** — `CHECK ((reason <> 'refund' OR delta > 0) AND (reason <> 'chargeback' OR delta < 0))`.

ADR-0010 decision 1, `ARCHITECTURE.md` §2.3's reason table, AC15.4 and AC17.5 all fix these two directions. Without the constraint the direction is a convention held by whichever service writes the row, and a reversed sign produces a `refund` row that means the opposite of what every reader of the "credit refunds issued" trust metric (`PRODUCT_SPEC.md` §9.4) will assume. The remaining six reasons are deliberately unconstrained: `admin_adjust` is signed by definition — which is exactly why the sign alone cannot identify a reversal after the fact — and a grant or promo that later needs reversing is an `admin_adjust`, not a backwards `refund`.

**2. `credit_pack_prices.stripe_price_id` is `UNIQUE`.** Two price rows pointing at one Stripe Price means one Stripe object sells two different credit quantities, and T35's per-currency reconciliation cannot say which sale it is looking at. Multiple NULLs do not conflict in a unique index, so this constrains nothing until T34 populates the column — which is precisely the window (T08 onward) in which it must not get in the way.

**3. A purchase's currency must agree with its price row's currency** — composite foreign key `(credit_pack_price_id, currency) → credit_pack_prices (id, currency)`, requiring the referenceable `UNIQUE (id, currency)` on the price table.

This is ADR-0008's technique applied to money rather than to markets, for the same reason: §11.4 reconciles `credit_purchases` against Stripe **per currency**, and a USD sale recorded against the GBP price row is a currency-blind error that a currency-blind total would hide. `MATCH SIMPLE` means a NULL `credit_pack_price_id` skips the check entirely, which is correct — an admin grant or a retired price has nothing to agree with. The composite key also carries the plain reference, so no second single-column FK exists to drift from it.

**4. `credit_ledger` rejects `TRUNCATE`** — a `BEFORE TRUNCATE ... FOR EACH STATEMENT` trigger sharing the row trigger's function.

`TRUNCATE` is neither `UPDATE` nor `DELETE`, and a row-level trigger never fires for it. ADR-0010's argument for the trigger layer is that a revoke says nothing about the migration owner, a support script or a dashboard session; that argument applies unchanged to `truncate credit_ledger`, which would empty the source of truth for money without firing anything. `service_role` cannot reach it — it holds no `TRUNCATE` anywhere — so this closes the gap for exactly the privileged roles the row trigger already exists to catch. The function raises unconditionally and never references `OLD` or `NEW`, so one function serves both triggers.

**Decisions — part 2: four ambiguities resolved.**

**5. `credit_purchases.stripe_checkout_session_id` is nullable and `UNIQUE`.** §2.3 lists it `UNIQUE` with no nullability marker, while §9.2's purchase flow creates the `credit_purchases(pending)` row **before** the Checkout Session exists. `NOT NULL` would make the documented flow impossible. Unique still does the work that matters — one session can never fulfil two purchases — and the same shape already applies to `stripe_payment_intent_id`, which §2.3 does mark nullable for the same reason one step later in the flow.

**6. `app_events.user_id` is nullable with `ON DELETE SET NULL`.** §11.5 enumerates what cascades from `auth.users` — profile, unlocks, watchlist, purchase records, barcode lookups — and `app_events` is not on that list, so the behaviour had to be chosen rather than inherited. The funnel question (§9.3) is a **count**, not a person: nulling the actor de-identifies the row completely while preserving the count, and it can never block the deletion AC1.5 requires. This is ADR-0009's `published_by`/`retired_by` precedent applied to analytics. Nullable also because an event can precede any account at all — signup is itself an event.

**7. `updated_at` goes only on the three tables that are genuinely edited** — `credit_packs`, `credit_pack_prices`, `credit_purchases`. ADR-0005 decision 5 put `updated_at` on every Schema A table because reference data is edited and catalogue rows are re-upserted. Applied literally to Schema C it contradicts two of this task's guarantees: an append-only table cannot carry a "when was this last changed" column, and on `stripe_webhook_events` it would become a fourth column T06's restricted-UPDATE trigger had to carve an exception for, weakening the rule to "identity frozen, plus whatever else we added". The ledger, the webhook table and the three operational logs therefore carry exactly §2.3's column sets; their own timestamp — `created_at`, `received_at`, `started_at` — is the record of when they happened.

**8. `api_usage_log.marketplace_id` is nullable, `ON DELETE RESTRICT`.** §2.3 does not say. Not every provider call is marketplace-scoped — a retailer feed fetch or a payment-processor call has none — and `NOT NULL` would mean those calls simply go unlogged, which is the opposite of what a cost log is for (§10.2, risk #6). `RESTRICT` rather than `SET NULL` because a marketplace is configuration that is effectively never deleted, and cost history that silently loses its attribution stops answering the question it exists to answer.

**Why these are constraints rather than conventions.** Every one of the four in part 1 is already written down somewhere. The reason to spend a constraint on a documented rule is the failure mode: financial defects are silent. A wrong fee is visible to the user and reported within a day; a `refund` row with the wrong sign, a duplicated Stripe Price or a currency-mismatched purchase produces no error, no alert and no symptom until a reconciliation disagrees months later — by which point the evidence needed to work out what happened is the evidence that is wrong. `RUNBOOK.md`'s financial checklist exists because of that asymmetry, and these four are its items 1, 4 and 5 applied to the specific columns T05 creates.

**Alternatives considered.**

- **Enforcing the purchase snapshot columns (`credits`, `amount_minor`, `currency`) with a restricted-UPDATE trigger.** Rejected. `RUNBOOK.md` financial checklist §4 sets the standard as "immutable in intent and **documented as such**", T05's acceptance criteria ask for no trigger, and checklist §1 warns that two mechanisms with one purpose means either can be dropped with no test going red. The three columns carry explicit `Immutable snapshot` comments and `schema_c.test.sql` asserts all three comments exist, so the intent is machine-checked even though the value is not.
- **Constraining the sign of all eight ledger reasons.** Rejected. Only `refund` and `chargeback` have a direction fixed by the documents; inventing one for `promo` or `signup_grant` would be this task deciding a product question it has no basis to decide, and the first legitimate reversal would need a migration.
- **`ON DELETE CASCADE` for `app_events.user_id`.** Rejected: it destroys funnel history as a side effect of an unrelated privacy operation, when nulling one column satisfies the same privacy requirement.

**Consequences.**

- **T07** is unaffected by decisions 1–4 in one direction and constrained in another: `grant_credits` writes `refund` rows positive and `chargeback` rows negative or the insert fails, which is the intended shape. ADR-0010's existing constraint stands — the idempotency check must be `ON CONFLICT DO NOTHING` plus a read, never `DO UPDATE`, and `schema_c.test.sql` now proves the trigger raises on the upsert path rather than leaving it as prose.
- **T08** is unaffected. Seeding `stripe_price_id` as `NULL` on every pack price remains valid and now has two coexisting NULL rows asserted as a test, so the unique constraint cannot be mistaken for a reason to invent a placeholder.
- **T34** must create one Stripe Price per pack price row. Reusing a Stripe Price id across two rows now fails at write time rather than at reconciliation.
- **T35** may write `processed_at` and `error` on `stripe_webhook_events` exactly as designed — T05 added no trigger there, and the test suite asserts the table has zero triggers so T06's restricted-UPDATE trigger arrives as the only one.
- **T10** inherits the retention consequence unchanged from ADR-0010, plus one clarification: `app_events` does **not** block account deletion and de-identifies itself, so the pseudonymisation mechanism T10 designs has to cover `credit_ledger` and `credit_purchases` only.
- **`ARCHITECTURE.md` §2.3** should be read with decisions 5–8 alongside it; the column lists there are otherwise silent on all four points.

---

## ADR-0012 — Temporal exclusion constraints use `daterange`, and the two tables reject the same mistake with different SQLSTATEs

**Status:** Accepted · T05A · 2026-08-11 · implements ADR-006 · records the representation ADR-006 required to be recorded · amends ADR-006 and `ARCHITECTURE.md` §2.2 on one point · touches no T01–T05 outcome

**Context.** ADR-006 decided that `tax_schedules` and `fee_schedules` must reject overlapping effective periods in the database, and left one thing open for the implementing task: *"record in the T05A PR whether `tstzrange(effective_from, effective_to, '[)')` is used inline or a generated range column is added. Both are acceptable; the choice must be consistent across the two tables."* This ADR is that record. It also documents one behaviour of the finished constraints that neither ADR-006 nor `ARCHITECTURE.md` §2.2 anticipated, and that T33 has to handle.

**Decision 1 — the range is `daterange(effective_from, effective_to, '[)')`, inline, identical on both tables.**

Neither option ADR-006 named is taken as written, for reasons only visible once T03's actual columns are read.

**Not `tstzrange`, because the columns are `date`.** `ARCHITECTURE.md` §2.2 and ADR-006 both describe these ranges in the language of instants — "a version ending at time T" — but T03 created `effective_from` and `effective_to` as `date` on both tables. Building a `tstzrange` over them requires a cast, and casting `date` to `timestamptz` invents a timezone: midnight in whose zone? For a rate that changes on the 1st, the answer would have to be the same in every locale the schedule applies to, and a `timestamptz` boundary derived from a `date` silently is not — it resolves against whatever `TimeZone` the writing session happened to carry. `daterange` keeps the column's own resolution and adds no hidden zone. **ADR-006 and §2.2 are amended on this point:** the semantics they specify are unchanged, only the range type is.

**Not a generated or stored range column, because it would duplicate live state.** A stored range restates what two columns already say, needs a generated column or a trigger to stay honest with them, and changes the generated TypeScript surface for no gain. The inline expression is derived at index time and cannot disagree with its source columns. It also kept `src/types/database.ts` byte-identical, which is what T05A's acceptance criteria ask for.

The interval semantics ADR-006 specified are implemented exactly and are asserted in both directions on both tables:

- **`[from, to)`** — `effective_from` inclusive, `effective_to` exclusive. A version ending on T and its successor starting on T are **adjacent, not overlapping**, and both are accepted. This is the normal shape of a version bump; a constraint that rejected it would be dropped by the first person who had to bump a rate.
- **`effective_to IS NULL` is an unbounded upper edge**, not an exemption. Two open-ended rows for one key overlap on `[max(from), ∞)` and are rejected. This is the case worth spending a constraint on: the current row is precisely the row most likely to be NULL-terminated and the row every resolution query reads, so a NULL that dropped out of overlap detection would leave the constraint protecting everything except the thing it exists to protect.

**Decision 2 — T03's existing `CHECK (effective_to IS NULL OR effective_to > effective_from)` is verified, not re-created.**

T05A's acceptance criteria call for that check on both tables. T03 had already created it, as `tax_schedules_effective_range` and `fee_schedules_effective_range`. A second copy would leave two constraints with one purpose, either droppable without a test going red — the trap `RUNBOOK.md`'s financial checklist §1 names and that ADR-0010 applied to the ledger trigger. The migration instead **asserts** both in a `do` block and aborts if either is absent.

That assertion is load-bearing rather than defensive housekeeping, and the reason is specific to the range representation chosen above: `daterange(d, d, '[)')` is not an error, it is the **empty** range, and an empty range overlaps nothing. If the check constraint were ever dropped, `effective_to = effective_from` rows would be accepted and would sit outside the exclusion index entirely — invisible to the constraint, and invisible to any resolution query. **The check is what makes the exclusion constraint total**, and the two must now be understood as one mechanism rather than two independent ones.

**Decision 3 — the same user mistake surfaces as a different SQLSTATE on each table, and that is accepted rather than normalised.**

An identical effective period for the same key is rejected on both tables, but not by the same constraint:

| Table | Identical period, same key | Why |
|---|---|---|
| `tax_schedules` | **`23505`** unique_violation | T03's `unique (country_code, effective_from)` is an older index and is checked first |
| `fee_schedules` | **`23P01`** exclusion_violation | its T03 unique is on `(marketplace_id, version)` — a *label*, not a period — so nothing older catches it |

Every other kind of overlap raises `23P01` on both tables. The asymmetry is not introduced here and is not worth engineering away: dropping T03's unique to make the codes uniform would remove a working constraint to improve an error message.

It does, however, make `fee_schedules` the table this task actually changes the reachable behaviour of. Its unique constrained the version *label*, so `v2024` and `v2024-revised` could previously cover identical dates — exactly the overlap AC16.4's versioned editing invites, and exactly what ADR-006 predicted a human would eventually do by hand.

**Decision 4 — `btree_gist` is created in `extensions`, and its default `PUBLIC` execute grant is left alone.**

The equality half of each constraint (`country_code with =`, `marketplace_id with =`) needs `gist_text_ops` / `gist_uuid_ops`; GiST indexes ranges natively via `pg_catalog.range_ops` but not scalars. The extension is created idempotently in `extensions`, matching `pgcrypto`, `uuid-ossp` and `pg_net`.

T05A's acceptance criteria ask the migration to note that extension objects are not granted to `anon` or `authenticated`. Stated precisely: **that is not what happens for any extension**, here or elsewhere. PostgreSQL grants `EXECUTE` to `PUBLIC` on extension functions at creation, and ADR-004's `ALTER DEFAULT PRIVILEGES` in `20260810033236_normalise_privileges.sql` deliberately scope to schema `public`, not `extensions`. The grant is left in place: btree_gist's functions are GiST opclass internals invoked by the index machinery, they expose no row, column or table, and revoking would single out one extension for treatment none of its neighbours in a Supabase-managed schema receives. What default-deny actually promises is unchanged and is asserted rather than assumed — `anon` and `authenticated` hold no table privilege of any kind in `public`, and btree_gist creates no table, view or sequence and installs nothing into `public`.

**Consequences.**

- **T08 is unblocked.** The seed is now written against enforced constraints, so it cannot commit an overlap as fixture data — the reason ADR-006 made T05A block it.
- **T13's `MarketContext` resolver** may rely on `effective_from <= d AND (effective_to IS NULL OR effective_to > d)` returning at most one row per key, and must treat **zero** rows as a legitimate answer. A date before any version, or in a deliberate gap, resolves to nothing; that is a missing schedule and the caller must fail visibly rather than fall back to an arbitrary row. The constraint guarantees "never two", not "always one".
- **T33's schedule editor must map `23P01` *and* `23505` to the same user-facing message** — "this period overlaps an existing version" — per the table above. ADR-006 already required violations to surface as clear errors rather than a 500; this names the two codes it will actually see.
- **The constraints govern `UPDATE` as well as `INSERT`**, which is the path T33 takes. Both directions are tested.
- **No supporting index was added.** Each `EXCLUDE` *is* a GiST index on `(key, range)` — the index the resolution query wants — so a second btree would be dead weight.
- **`ARCHITECTURE.md` §2.2's temporal convention** is unchanged in substance; only its implied range type is amended, above.

---

## ADR-0013 — The first public surface: what "public reference data" actually means, and what an activity row proves

**Status:** Accepted · T06 · 2026-08-11 · implements ADR-004 and ADR-008 · amends ADR-008 and `TASKS.md` T06 on one point, narrows another · touches no T01–T05A outcome

**Context.** T06 opened the schema's first `anon`/`authenticated` surface: 19 policies, 16 grants, 13 tables deliberately left closed. Almost all of it was already specified — ADR-004 fixed the pairing rule, ADR-008 fixed the exposure set, ADR-0010 fixed the `credit_pack_prices` predicate and the webhook rule. Three things were not, and each only becomes visible once the policies are being written against the columns that actually exist.

**Decision 1 — `currencies` is public in full, because there is nothing to filter on.**

ADR-008's table and `TASKS.md` T06 both say `currencies` is readable "active rows only". The table has no `active` column: `ARCHITECTURE.md` §2.2 defines it as `code, minor_unit_exponent, symbol, name`, and T03 built exactly that. The predicate is therefore `USING (true)` — the only unqualified predicate anywhere in the schema, and the one place a reviewer should expect to find one.

This is a correction to the wording of ADR-008 rather than a widening of its intent. The intent was "the client may read the reference rows it needs to render a price"; `currencies` is the ISO 4217 list, every column of it is public knowledge, and the grant is `SELECT` alone. What makes the exception safe is that it is *checkable*: the suite asserts both that `currencies` is the only table with a `true` predicate and that the table genuinely has no `active` column, so the day someone adds one, the second assertion fails and the policy must be narrowed in the same migration. An unqualified predicate that no test distinguishes from a forgotten one is the actual hazard, and that is what is closed here.

Rejected: inventing an `active` column to satisfy the sentence. A flag with one possible value is not a security boundary, it is a column that future code will branch on for no reason.

**Decision 2 — `markets` is public only where `active = true AND launch_status = 'live'`.**

Three documents describe this predicate three ways. `ARCHITECTURE.md` §6.3 says `active = true`. ADR-008 and `TASKS.md` T06 say "active/live rows only". §5.3 documents the endpoint the policy backs as "Live markets (public — drives signup)". The narrowest reading is taken, on the principle that a security boundary resolves ambiguity downward: a predicate that is too narrow produces a visible absence, and a predicate that is too wide produces a market a user can select before it can serve them.

The consequence is intended and is the reason the narrow reading is also the *correct* one, not merely the safe one. A `beta` or `planned` market is invisible to `anon` and `authenticated`, so a user in that country is waitlisted — which is precisely AC2.2 and AC8.6, and precisely what risk #7's "all boxes ticked or the market stays `planned`" is for. `active` alone would have let a market that is configured but not launched appear in the signup picker, and "an empty feed is worse than an honest not-live-here-yet" (§6.1) is the whole argument against that. Server-side reads run as `service_role` and are unaffected, so the admin console and the ingestion pipeline still see every market.

**Decision 3 — A `deal_unlocks` or `barcode_lookups` row is not evidence that credits were spent. The ledger is.**

T06 requires `authenticated` to hold `INSERT` on both tables, governed by `WITH CHECK (user_id = auth.uid())`. That predicate constrains *whose* row it is and nothing else on it, so a client holding the grant can insert an unlock row with `credits_spent = 0`. This is not a defect in the policy — the policy is exactly what T06 specifies, and a narrower one would have to encode a payment rule in a row filter — but it is a fact about what these tables mean, and it has to be written down before T07 reads them.

**These tables are activity records, not financial records.** The financial record is `credit_ledger`, which no client can write at either layer: `authenticated` holds `SELECT` alone, there is no write policy of any kind, and the only sanctioned writer is T07's `SECURITY DEFINER` RPC running as owner.

It leaks nothing today. `deals` is unreadable by `authenticated` at the grant layer, so a self-inserted unlock row unlocks nothing; entitlement is resolved server-side by the unlock route, which is where redaction lives (§6.3).

**Consequences.**

- **T07 must derive entitlement and balance from `credit_ledger` and `profiles.credit_balance`, never from the presence of a `deal_unlocks` row.** `spend_credits` + `insert deal_unlocks` in one transaction (§6.5) remains correct: the ledger row is what makes the unlock real, and the unlock row is the index into it. A future "have they already unlocked this?" check that reads `deal_unlocks` alone is answering a cheaper question than it thinks — acceptable for AC10.2's no-double-charge path, which is idempotency rather than authorisation, and not acceptable for anything that grants access.
- **T09 inherits three assertions** it would otherwise have to infer: that `currencies` is the only unqualified predicate, that a `beta` market is invisible to both client roles, and that `deal_unlocks.credits_spent` is unconstrained by RLS.
- **T10** may not assume a user can delete their own unlock history. `deal_unlocks` has neither a DELETE grant nor a DELETE policy (AC10.7), so account deletion reaches it only by cascade from `auth.users`.
- **`ARCHITECTURE.md` §6.3's policy table** is accurate for `markets` as amended here; its `currencies` row is amended by decision 1.
- **If a client need for an inactive currency or a non-live market emerges**, it is a view with named columns, not a widened policy — the same rule ADR-008 set for `marketplaces`.

---

## ADR-0014 — The credit RPCs: which function may take a balance negative, and what an idempotency key identifies

**Status:** Accepted · T07 · 2026-08-11 · implements ADR-004, ADR-0010 and ADR-0013 · amends `ARCHITECTURE.md` §6.5 on one point · changes no T05 or T06 outcome

**Context.** T07 specifies `spend_credits` and `grant_credits` down to their ordering, their `SECURITY DEFINER` posture and their privilege statements, so most of this task had its decisions made for it. Four things were not decided anywhere, and each is the kind of thing that is invisible until the function is being written against the columns that actually exist.

**Decision 1 — `p_reason` is `public.credit_reason`, not `text`.**

`ARCHITECTURE.md` §6.5 sketches the signature with `p_reason text`. The column it is written to is the `credit_reason` enum, and a `text` parameter would make the function's accepted input wider than its own storage — the cast would fail eventually, but one statement later, inside the insert, with an error about a column rather than about an argument. The enum is taken instead: PostgREST resolves a JSON string to it without ceremony, an unknown reason fails at the call boundary with `22P02`, and the function's contract and the table's contract are the same set of values by construction rather than by agreement.

This is a correction to a sketch rather than a change of intent. §6.5's block is explicitly a comment-annotated outline, and every other element of it — the parameter order, the return shape, the `FOR UPDATE`, the raise — is implemented exactly as written.

**Decision 2 — `grant_credits` takes a SIGNED amount, and it is the only function that may end below zero.**

T07 says `grant_credits` "permits a negative resulting balance (refunds and chargebacks, §9.2)". Read literally against a positive-only amount, that sentence cannot be satisfied: adding a positive number to a non-negative balance never produces a negative one. The sentence is only meaningful if `grant_credits` accepts a negative amount, and §9.2 rule 4 names exactly what that case is — a Stripe reversal clawing credits back under reason `chargeback`, with AC17.5 requiring the balance to go negative rather than the operation to fail.

So the split is by DIRECTION OF AUTHORITY, not by sign of intent:

| | `spend_credits` | `grant_credits` |
|---|---|---|
| `p_amount` | `> 0`, written as `delta = -p_amount` | signed, non-zero, written as `delta = p_amount` |
| reasons | `unlock_deal`, `barcode_lookup` | `signup_grant`, `purchase`, `refund`, `promo` (positive); `chargeback` (negative); `admin_adjust` (either) |
| may end negative | **no** — `23514 INSUFFICIENT_CREDITS` | **yes** |

`chargeback` is deliberately not routable through `spend_credits`. There it would meet the balance guard, and a payment reversal that fails because the user already spent the money is precisely the outcome AC17.5 forbids. Equally, no consumption reason is routable through `grant_credits`, because that function does not check the balance at all — accepting `unlock_deal` there would be a documented way to unlock a deal with no credits.

The per-reason direction rules restate at the writer what `credit_ledger_reversal_direction` already enforces for `refund` and `chargeback`, and extend it to the four reasons ADR-0010 decision 1 deliberately left unconstrained at the storage layer so that `admin_adjust` could stay signed. **The table constraint is not weakened and is not now redundant:** the suite asserts that a negative `refund` and a positive `chargeback` are still refused by an owner's direct `INSERT`, so T07 did not become the only thing standing between a reversed sign and the ledger.

Rejected: one function with a signed amount and a `p_allow_negative` flag. A boolean that decides whether the balance guard applies is the guard, and it would be supplied by the caller.

**Decision 3 — An idempotency key identifies an OPERATION, not a request. Conflicting reuse is rejected.**

T07 requires that an existing key returns the prior result and does not double-charge. It does not say what happens when a key is reused for a *different* operation, and the unique constraint alone cannot tell the difference.

Identity is `(user_id, delta, reason, ref_type, ref_id)`. An exact match replays the recorded `(balance_after, id)`; anything else raises `23505 IDEMPOTENCY_KEY_CONFLICT`. Two properties follow, and both are asserted:

- **A replay returns the RECORDED result, not the live balance.** If the account has moved on since, the answer to "what did this operation do" has not. A replay is therefore deterministic for the life of the row, which is what makes it safe for a client to retry indefinitely.
- **Silently returning success for an operation that never happened is the failure mode being closed.** A webhook redelivered with a mutated amount, or a client that reuses a key across two different unlocks, gets an error rather than a fabricated receipt.

`created_at` and `balance_after` are excluded from the comparison: they are outcomes of the first call, not inputs to it.

**Decision 4 — A private helper exists, and it is granted to nobody.**

`public.credit_ledger_idempotent_match` holds the single definition of decision 3's identity rule, which both RPCs need in two places each. Four inline copies of the predicate the whole no-double-charge guarantee rests on is four chances for it to drift. The helper is `SECURITY INVOKER` — it is only ever reached from inside a definer function already running as the owner, so definer rights it does not need are rights it does not get — and its ACL is `postgres=X/postgres` alone, not even `service_role`, since an execute grant on it would be a way to probe which idempotency keys exist.

It is a third function in a task whose file list names two. Flagged rather than hidden: it appears in `supabase/functions/` alongside the two RPCs, in the T07 function inventory assertions, and in the generated `Functions` type (harmlessly — `gen types` introspects the catalogue, not privileges, so it advertises a function no role can call).

**Consequences.**

- **The RPCs are the only *sanctioned* writer, not yet the only *possible* one.** `service_role` retains `INSERT` on `credit_ledger` and `UPDATE` on `profiles` from T05 and T06, so server code can still move credits without them. T07's answer is the acceptance criterion "no check-then-deduct logic exists in application code", asserted statically in `tests/unit/supabase/credit-rpcs-are-the-only-writer.test.ts`. Turning the convention into a privilege means revoking those two grants — which these `SECURITY DEFINER` functions would survive unchanged, and which is the main reason they are `SECURITY DEFINER` at all, given that `service_role` needs no help from a definer function today. **Raised for T26**, not done here, because T08's seed and T35's purchase bookkeeping are unwritten and the blast radius is theirs to measure.
- **§6.5's "same transaction" is not expressible over PostgREST.** `spend_credits` + `insert deal_unlocks` in one transaction (AC10.4) cannot be two `supabase-js` calls; PostgREST gives one statement per request. **T23 must choose** a wrapping RPC that does both, or a direct Postgres connection. T07 deliberately does not pre-empt that choice: folding a `deal_id` and a `market_id` into a credit primitive would make every future consumer of credits an edit to `spend_credits`.
- **T08's signup grant and T35's webhook fulfilment both call `grant_credits`**, with `stripe_webhook_events.stripe_event_id` as the natural idempotency key for the latter — the second of §9.2 rule 3's two layers, now with a defined conflict behaviour.
- **T09 inherits the privilege matrix as an assertion**: `spend_credits` and `grant_credits` are `postgres=X/postgres,service_role=X/postgres` exactly, and a NULL `proacl` on either is a `PUBLIC` execute grant on a credit-minting function.
- **The concurrency gate is automated and is mutation-checked.** `supabase/tests/database/credit_rpcs_concurrency.test.sql` drives real concurrent sessions through `dblink`, because two sequential calls in one transaction prove arithmetic and would pass against a `spend_credits` with no `FOR UPDATE` in it. Deleting the `FOR UPDATE` was tried: the file fails fourteen assertions, with AC10.1 landing six successful unlocks and a balance of `-5` against a starting balance of `1`. That file commits its fixtures and removes them again, which is the one place in the suite where a test is not purely a rolled-back transaction, and it is documented in the file header.
- **`npm run db:test` is now a wrapper, and that is a consequence of the concurrency gate rather than a preference.** `dblink` refuses a passwordless connection for a non-superuser; `dblink_connect_u`, which would not, is owned by `supabase_admin` and grants `postgres` no EXECUTE even when a migration creates the extension. A password is therefore unavoidable, and it must not be committed. `supabase test db` provides no way to pass one: it parses the connection URL into components and rebuilds the connection inside its own container, so `?options=-c …` is discarded (the session reports `application_name=psql`) and `PGOPTIONS` does not cross the container boundary. The only channel that survives is the database itself, so `scripts/db-test.mjs` publishes the local password as a database-level `t7.db_password` setting for the length of the run and removes it in a `finally`. The password never reaches argv, disk or any stream — the `ALTER DATABASE` goes to psql on stdin inside the container, over the socket the local stack trusts, and the one step needing superuser is the only reason `supabase_admin` is used at all. **The test file has no fallback:** an absent setting raises, because a test that substituted a default would pass only where the default happened to be right.

---

## ADR-0015 — The launch market is GB / `amazon_uk` / GBP, the surcharge basis vocabulary is wider than §2.2 says, and pack prices are provisional

**Status:** Accepted · T08 · 2026-08-11 · amends `ARCHITECTURE.md` §2.2 on one point · implements ADR-005, ADR-006/ADR-0012, ADR-008 and ADR-0010 · changes no T03–T07 outcome · **no migration, no remote data**

**Context.** T08 seeds reference data, and reference data is where an architecture stops being a claim. Four of the things this task had to settle were settled nowhere: which market we actually launch in, whether a one-market seed compromises the global-first schema, how to express fees that the documented surcharge vocabulary cannot represent, and what a pack price means before anyone has decided what a credit costs. Each is invisible until you are writing rows against the columns that exist.

**Decision 1 — The initial MVP launch market is GB / `amazon_uk` / GBP, and this ADR is the first place that is written down.**

Every document assumes it and none records it. `ARCHITECTURE.md` §2.2 uses `'amazon_uk'` as its worked example of a marketplace `code`, §1.3's `MarketContext` sketch carries `id: 'amazon_uk'`, §13's greppable-literal ban names `'GB'` as the literal that must not appear in a service, and `PRODUCT_SPEC.md` prices its motivating example in pounds. `PRODUCT_SPEC.md` otherwise says "the chosen launch market" throughout, deliberately, so that the product spec stays market-neutral — which is right, and which is also why the choice has to be recorded somewhere else rather than inferred from an example.

So: `countries.GB` active, `marketplaces.amazon_uk` active, `markets.gb-amazon-uk` with `active = true AND launch_status = 'live'`. That pair is exactly T06's public-read predicate, so the launch market is also the only market a browser can see.

The choice is recorded as a *decision*, not a discovery, because the alternative — leaving it implicit — has a specific failure mode. `'GB'` and `'amazon_uk'` would keep appearing in examples, then in a fixture, then in a default, and §13's literal ban would be enforced against a value nobody had ever formally chosen.

**Decision 2 — One live market is a seeding fact. The schema stays global-first, and the proof is a second market rather than an assertion.**

The risk in seeding a single market is not that the seed is small; it is that "the launch market" quietly becomes a synonym for "the market", and the second one then costs a migration. T08's acceptance criterion asks for a demonstration, so the seed contains one: `de-amazon-de` — country DE, marketplace `amazon_de`, currency EUR, its own tax schedule, its own fee schedule with its own storage unit — added with **no DDL, no new column, no code change, and no new enum value**. It is `planned` and inactive, so it is invisible to `anon` and `authenticated` and consumes nothing.

Three specific things are held global rather than collapsed to the launch market, and each is asserted:

- **`currencies` spans three minor-unit exponents.** T03's own comment on `minor_unit_exponent` cited "2 for GBP/USD/EUR, 0 for JPY, 3 for KWD" as the reason the exponent is data — but only 0 and 2 had ever been seeded, so code dividing by 100 would have passed every test in the repository. KWD is seeded to close that, and `amazon_jp` exists as a marketplace whose money columns are JPY, because a zero-decimal *currency row* proves less than a zero-decimal *marketplace*.
- **Storage is billed in different units in different markets.** UK FBA storage is per cubic **foot**; the rest of Europe is per cubic **metre**. `storage_rules.unit` is therefore data on every row, and a pricing engine that assumed m³ would be wrong by a factor of about thirty-five. This is the cleanest available demonstration that a per-market constant cannot be hoisted into code.
- **`retailers.price_display` is stored per retailer even though all five seeded retailers agree with their country.** §7.4 warns the assumption is systematically wrong when borrowed; a UK trade or wholesale retailer displays ex-VAT prices, and adding one must be a row rather than an exception.

**Exactly one live market remains seeding and release discipline, not a constraint.** No uniqueness index is added on `launch_status`, because it is a lever T33's admin console legitimately flips (AC16.4), and a constraint there would block a legitimate operation to prevent a mistake that belongs to a checklist. The rule lives in `docs/MARKET_PLAYBOOK.md`, in the T40 gate list, and as an assertion over the seed.

**Decision 3 — `surcharges.basis` gains `selling_fees` and `fulfilment_fee`, and entries gain `applies_to_categories`. This is the one deviation from `ARCHITECTURE.md` in T08.**

§2.2 defines a surcharge entry as `{code, label, basis: 'referral_fee'|'sell_price'|'flat', rate_bps|amount_minor, applies_to_countries?}`. The launch market has three real surcharges and that vocabulary can express exactly one of them:

| Surcharge | What it actually applies to | Expressible in §2.2? |
|---|---|---|
| Digital Services Fee, 2% | Selling on Amazon fees **and** FBA fees | No — `referral_fee` covers half |
| Fuel and logistics surcharge, 1.5% | Fulfilment fees only | No — no such basis |
| Media closing fee, £0.50 | Flat, but only on media categories | Partly — `flat` fits, category scoping does not |

The vocabulary is widened rather than the data being bent to fit, because bending it has a direction. Forcing the DSF onto `referral_fee` drops the FBA half of its base; forcing the fuel surcharge onto `referral_fee` charges it against the wrong number entirely. Both **understate cost**, which **overstates profit** — risk #5, and the one direction of error this product cannot afford, since a user acts on the figure by spending their own money.

`basis` therefore takes five values: `referral_fee`, `fulfilment_fee`, `selling_fees` (referral + fulfilment), `sell_price`, `flat`. `applies_to_categories?` joins `applies_to_countries?` as an optional scope. `ARCHITECTURE.md` §2.2 is amended to match; this is the only edit T08 makes to that document.

This costs nothing today and would have cost a data migration later: nothing reads `surcharges` yet, because the pricing engine is T14. That is precisely the window in which to get the vocabulary right. It also does not touch the schema — `surcharges` is `jsonb` and `schema_a.sql`'s column comment names the keys without enumerating the basis values, so no migration is implied and none is added.

**Decision 4 — T14 must implement every basis in the seeded data, and a missing one must fail loudly.**

The corollary of decision 3, stated separately because it is a commitment against a future task rather than a description of this one. When `services/pricing/surcharges.ts` is written it must handle all five bases. A `default:` branch that skips an unrecognised basis, or treats it as `flat`, or applies it to `sell_price`, reintroduces exactly the understatement decision 3 exists to prevent — and it would do so silently, on every deal in the market, which is risk #2's shape. **An unknown basis must throw.** The seeded UK schedule is the fixture that makes this testable on day one: it contains a `selling_fees` and a `fulfilment_fee` entry, so an implementation that quietly ignores either produces a visibly wrong fee against a hand-worked example in T15.

**Decision 5 — Pack prices are provisional planning values, and `stripe_price_id` stays NULL until T34.**

`PRODUCT_SPEC.md` open question 3 leaves credit pricing undecided: it needs a number before Gate C, anchored against what comparable deal groups charge in the launch market. T08 nevertheless has to seed pack prices. The seeded GBP figures — £5.00 / £12.00 / £30.00 for 10 / 30 / 100 credits — are therefore **deliberate placeholders for a commercial decision, not the outcome of one**. The only property committed to is structural: the per-credit rate falls as the pack grows (50p, 40p, 30p).

Being wrong here is unusually cheap, and the reason is ADR-0010 decision 4 rather than luck. `stripe_price_id` is NULL on all six rows — no Stripe object exists, and a placeholder such as `price_TODO` is prohibited because it satisfies every `IS NOT NULL` check, is indistinguishable from a real id on inspection, and fails at the Checkout call rather than at seed time. T06 exposes a price only where `active = true AND stripe_price_id IS NOT NULL`, so **no client can read any of these rows**. A repricing before T34 changes a number in one seed file and nothing else.

The EUR rows are set independently rather than FX-converted, per §2.3: a price converted from a base currency lands on an odd local number and reads as an afterthought.

**Consequences.**

- **`ARCHITECTURE.md` §2.2's surcharge line is amended and nothing else in that document changes.** The `deals.surcharges` row in §2.4 describes the *itemised output* on a computed deal (`[{code,label,amount_minor}]`), which is a different shape from a schedule's *rules*, and it is correct as written.
- **T14 and T15 inherit decision 4 as a hard requirement.** All five bases, and an unknown basis throws. `min_fee_minor` and the `flat`/`threshold`/`marginal` distinction on referral rules are the same class of obligation: on a £60 item under a "15% up to £45, then 9%" rule, `marginal` gives £8.10 and `threshold` gives £5.40, so the mode is stored explicitly on every rule and must never be inferred.
- **T34 owns `stripe_price_id` from the moment it backfills.** `0008_credit_packs.sql` deliberately excludes that column from its `ON CONFLICT ... DO UPDATE`, so re-running the seed after a backfill cannot reset a live price to NULL and silently un-buy every pack. Verified by simulating a backfill and re-running.
- **The credits page shows no purchasable pack until T34, and that is correct.** It must not be "fixed" with a placeholder.
- **`verified_at` is load-bearing and is NULL where no claim can be made.** GB's tax and fee schedules carry it because the rates were read from `gov.uk` and Amazon's own rate card; DE's carry NULL because they were not verified against a primary source. `MARKET_PLAYBOOK.md` gates a live market on a non-NULL `verified_at`, which makes the column a check rather than a note — and makes fabricating one a way to defeat the gate.
- **Five founder-verification items remain open on the launch market** and are listed in `MARKET_PLAYBOOK.md` §4.1: the 2024-08-01 `marketplace_fees_taxed` boundary and the 2% DSF rate are corroborated from secondary sources and need confirming against a real Seller Central invoice; the rate card and `sell.amazon.co.uk` disagree on whether the £0.25 minimum referral fee has category exemptions; Low-Price FBA and the Clothing Prime-selection referral ladder are not modelled. None blocks T09; all block beta.
- **T09 gets the fixtures its criteria require.** Inactive countries (DE, US, JP), a non-live market (`de-amazon-de`) and inactive pack prices (the EUR rows) all exist as seeded rows, so "inactive rows are absent" can be asserted against something real rather than assumed.
- **T08 seed data was deliberately NOT applied to the hosted development project.** It is the deterministic baseline for local and ephemeral CI databases. `supabase db push` does not carry seeds — it requires an explicit `--include-seed` — so the separation is the tool's default rather than a convention to remember.
- **Two pre-existing test assertions were whole-table counts that assumed empty reference tables**, and T08's seed is the first thing that ever put rows in them. Both were rescoped to their own fixtures rather than relaxed: the claims being made were about fixture rows resolving independently, never about how many rows the database happens to hold.
