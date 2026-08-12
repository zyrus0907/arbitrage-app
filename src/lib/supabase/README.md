# `src/lib/supabase/`

The three scoped Supabase clients (ARCHITECTURE.md §6.2). Created in T02.

| File | Credential | Session | Bypasses RLS | Importable from a Client Component |
|---|---|---|---|---|
| `browser.ts` | anon (publishable) | **none — see below** | no | **yes** |
| `server.ts` | anon + user session | request cookie jar | no | no |
| `admin.ts` | **service role** | none | **yes** | **no — the build fails** |

## Rules

- `admin.ts` has **`import 'server-only'` as its first line**. Do not move it, do
  not remove it. A `'use client'` module importing this file fails `next build`.
- The service-role key is referenced in exactly two files: `src/lib/env.ts` and
  `admin.ts`. No privileged credential ever carries a `NEXT_PUBLIC_` prefix.
- `server.ts` must stay session-bound. If it ever needs elevated access, that is
  a call to `admin.ts` from a service — not a key swap here.
- All three are typed against `@/types/database`, which is generated. See
  `docs/RUNBOOK.md` §7.

## The session cookies are `httpOnly`, and that was not free (T10)

**`@supabase/ssr` does not set `httpOnly` by default.** Its defaults leave the
auth cookies readable by JavaScript so that `createBrowserClient` can pick the
session up on the client. §6.2 and T02's completion note both described these as
"httpOnly cookies" — that was an assumption about the library rather than a
property of it, and T10's integration suite is what turned it into a measured
fact by asserting the flag on a real `Set-Cookie` header.

`cookies.ts` now forces `httpOnly`, `sameSite=lax`, `path=/` and a `secure` flag
derived from the site URL's scheme, and `server.ts` and `src/proxy.ts` both route
every write through it.

**The consequence is deliberate: `browser.ts` cannot see the session.**
Authentication happens in Server Actions, and every authenticated surface is
server-rendered. `browser.ts` remains correct for anonymous reads of public
reference data. A future task wanting an authenticated Supabase call from the
client must route it through a server handler rather than relax this.

`tests/unit/supabase/` enforces every line above.
