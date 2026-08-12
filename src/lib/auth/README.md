# `src/lib/auth/`

Session resolution, route classification and redirect safety (T10).

## Rules

- **`getUser()`, never `getSession()`.** `getSession()` believes the cookie; `getUser()` revalidates it with the Auth server. That difference is what makes a deleted account's still-unexpired JWT fail rather than pass.
- **Every user-supplied redirect target goes through `safeRedirectPath`.** Same-origin paths only — never an absolute URL, not even to our own host. Comparing origins is where open redirects live.
- **`routes.ts` is an allowlist of PUBLIC paths, not a list of protected ones.** Forgetting to register a new public page produces a visible redirect to sign-in; the inverse would ship a new route unprotected and silent.
- `session.ts` and `guards.ts` are `server-only`. `routes.ts` and `redirect.ts` are pure and are imported by the proxy and by tests.
