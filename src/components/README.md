# `src/components/`

React components. Presentation only.

## Rules

- Components format money from `{ amountMinor, currency }` at the render boundary; they never do currency arithmetic (§4.2).
- User-facing strings come from `src/messages/en.ts`.
