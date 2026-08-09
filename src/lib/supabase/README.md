# `src/lib/supabase/`

The three scoped Supabase clients (§6.2). Created in T02.

## Rules

- `browser.ts` — anon key.
- `server.ts` — anon key + session via `@supabase/ssr`, httpOnly cookies.
- `admin.ts` — service role, **`import 'server-only'` as its first line**, bypasses RLS.
