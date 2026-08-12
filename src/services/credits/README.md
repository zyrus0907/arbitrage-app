# `src/services/credits/`

Credit movement. **The T07 RPCs are the only writer** — nothing here inserts into `credit_ledger` or updates `profiles.credit_balance` directly, and `tests/unit/supabase/credit-rpcs-are-the-only-writer.test.ts` enforces that statically.

## Rules

- Idempotency keys are **deterministic functions of their subject**, so a retry replays the recorded ledger row instead of writing a second one. `credit_ledger.idempotency_key UNIQUE` is what guarantees it; the key is what makes the guarantee reachable.
- `grant-key.ts` carries no `server-only` import so the key's purity is unit-testable; `signup-grant.ts` holds the admin client and does.
