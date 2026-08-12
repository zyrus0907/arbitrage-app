# `src/lib/forms/`

Form-state shapes shared between Server Actions and the client components that drive them.

## Rules

- These types and initial values live here because a `'use server'` module may export **only async functions** — every export of one becomes a callable server endpoint, so Next rejects an exported object at build time.
