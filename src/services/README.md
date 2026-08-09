# `src/services/`

★ Business logic lives here, and only here.

## Rules

- **`services/` never imports React.** No JSX, no hooks, no `next/*` rendering APIs.
- Pure functions where possible; IO at the edges.
- Nothing here knows what country or marketplace it is in — it receives a resolved `MarketContext` (§1.2 rule 7).
- No country code, currency code, tax rate or marketplace name appears as a literal outside `supabase/seed/`, `services/tax/regimes/` and test fixtures (§13).

Planned modules: `market/`, `ingestion/`, `matching/`, `marketplace/`, `tax/`, `pricing/`, `scoring/`, `recommendation/`, `credits/`, `billing/`, `redaction/`.
