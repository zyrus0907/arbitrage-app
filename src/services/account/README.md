# `src/services/account/`

Account deletion by pseudonymisation (AC1.5, AC1.6, ADR-0017).

## Rules

- **Scrub first, delete the auth user second.** The reverse order can lock a user out of an account that still holds their full profile, with no authenticated route left to finish the job.
- **Retry-safe end to end.** `pseudonymise_account` is idempotent and convergent; the auth deletion treats "no such user" as success, because that is what a completed previous attempt looks like.
- **The subject is always the verified session's user.** This module runs with the service-role key, so the caller — and only the caller — is responsible for that, and the API route accepts no user id from the request.
- `credit_ledger` and `credit_purchases` are never touched. Not deleted, not updated, not zeroed.
