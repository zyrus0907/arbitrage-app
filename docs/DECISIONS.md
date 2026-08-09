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
