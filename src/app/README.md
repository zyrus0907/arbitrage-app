# `src/app/`

Routing, rendering and HTTP only.

## Rules

- `app/` **never contains business logic**. A route handler authenticates, resolves `MarketContext`, rate-limits, validates with Zod, delegates to a service and returns a typed envelope (ARCHITECTURE.md §5.1).
- Server Components by default. Client Components only where interaction requires it (§4.1).
- Route groups: `(marketing)`, `(auth)`, `(app)`, plus `admin/` and `api/`.
