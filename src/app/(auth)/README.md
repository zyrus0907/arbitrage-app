# `src/app/(auth)/`

Sign-in, sign-up and auth callback routes.

## Rules

- Sessions live in httpOnly cookies. Nothing auth-related is written to `localStorage` or `sessionStorage` (AC1.4).
