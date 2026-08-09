# `src/app/(app)/`

Authenticated product surface: feed, deal detail, scan, watchlist, credits, settings, purchases.

## Rules

- Every route here is protected by `src/middleware.ts`.
- Every deal-bearing view renders only what `services/redaction` returned.
