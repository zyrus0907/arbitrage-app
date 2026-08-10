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
