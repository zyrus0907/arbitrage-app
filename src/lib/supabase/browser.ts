import { createBrowserClient } from '@supabase/ssr';

import { requirePublicSupabaseEnv } from '@/lib/env';
import type { Database } from '@/types/database';

/**
 * Browser Supabase client — ARCHITECTURE.md §6.2, row 1.
 *
 * Anon (publishable) credentials only. Subject to RLS; it can read exactly what
 * the policies in T06 permit and nothing else. Safe to import from a
 * `'use client'` module — that is the whole point of this file existing
 * separately from `server.ts` and `admin.ts`.
 *
 * Session tokens are held by `@supabase/ssr` in cookies that the server writes
 * as httpOnly, not in `localStorage` (AC1.4).
 */
export function createClient() {
  const { url, anonKey } = requirePublicSupabaseEnv();
  return createBrowserClient<Database>(url, anonKey);
}

export type BrowserClient = ReturnType<typeof createClient>;
