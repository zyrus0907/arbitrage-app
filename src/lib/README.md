# `src/lib/`

Framework-level utilities with no business meaning.

## Rules

- `env.ts` is the only place `process.env` is read.
- `errors.ts` holds the single `AppError` type and its code taxonomy.
- `rate-limit.ts`, `logger.ts`, `config.ts` are cross-cutting, not domain logic.
