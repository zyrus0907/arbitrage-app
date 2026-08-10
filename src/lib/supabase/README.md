# `src/lib/supabase/`

The three scoped Supabase clients (ARCHITECTURE.md §6.2). Created in T02.

| File | Credential | Session | Bypasses RLS | Importable from a Client Component |
|---|---|---|---|---|
| `browser.ts` | anon (publishable) | via cookies | no | **yes** |
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

`tests/unit/supabase/` enforces every line above.
