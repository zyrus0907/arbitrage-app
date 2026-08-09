# `src/app/api/v1/`

Versioned REST-ish route handlers.

## Rules

- Every handler: authenticate → resolve `MarketContext` → rate-limit → Zod-validate → delegate to a service → typed envelope (§5.1).
- Handlers contain no business logic.
- Money in payloads is always `{ amountMinor, currency }` — never a bare number, never a preformatted string (§5.2).
