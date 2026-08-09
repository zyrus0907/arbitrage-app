# `tests/`

Test suites outside the source tree.

## Rules

- `unit/` — pure functions: money, pricing, scoring, tax.
- `integration/` — RLS/anon-key access, API routes, the ingest→deal pipeline.
- `fixtures/` — hand-worked cases and provider payloads, per market.
- The redaction payload-leak test, the RLS suite and the unlock concurrency test are **CI blockers** and may never be skipped.
