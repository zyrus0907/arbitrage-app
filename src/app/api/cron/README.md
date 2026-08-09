# `src/app/api/cron/`

Vercel Cron entry points: ingest, refresh-listings, recompute-deals, reconcile.

## Rules

- Protected by `CRON_SECRET`.
- Every run is market-scoped, idempotent, batched, time-boxed and resumable via a cursor.
