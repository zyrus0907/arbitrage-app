# `src/app/(app)/`

Authenticated product surface: feed, deal detail, scan, watchlist, credits, settings, purchases.

## Rules

- Every route here is protected by **`src/proxy.ts`** — Next.js 16 renamed Middleware to Proxy (ADR-0017 decision 8); the filename in T10 and in earlier drafts of this file is out of date, the behaviour is not.
- The proxy is an optimistic check, not the boundary. `layout.tsx` re-verifies the session with `getUser()` and applies the onboarding and tombstone gates, so a route here refuses to render for an unauthenticated caller even if the proxy never ran.
- Pages call `requireAuth` / `requireOnboarded` / `requireUnonboarded` from `src/lib/auth/guards.ts` rather than checking a session by hand.
- Every deal-bearing view renders only what `services/redaction` returned.
