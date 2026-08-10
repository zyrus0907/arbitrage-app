import 'server-only';

import { createClient as createSupabaseClient } from '@supabase/supabase-js';

import { requirePublicSupabaseEnv, requireServiceRoleKey } from '@/lib/env';
import type { Database } from '@/types/database';

/**
 * Admin Supabase client — ARCHITECTURE.md §6.2, row 3.
 *
 * Uses the **service-role key and therefore bypasses RLS entirely**. It is the
 * only client permitted to touch service-role-only tables (`deals`,
 * `retailer_products`, `marketplace_products`, `fee_schedules`, the logs) and
 * the only caller of the credit RPCs (T07).
 *
 * `import 'server-only'` is the **first line of this file** and must stay there
 * (T02 acceptance criterion). Under the `react-server` condition it resolves to
 * an empty module; under any other condition — which is what a Client Component
 * bundle gets — it throws, so an accidental `'use client'` import fails the
 * build rather than shipping the key to a browser. `tests/unit/supabase/`
 * asserts both the position of this line and the throwing behaviour.
 *
 * No session is ever attached: `persistSession` and `autoRefreshToken` are off
 * so this client can never be mistaken for one that carries a user identity.
 * Authorisation for anything this client does is the caller's responsibility,
 * enforced in the service layer.
 */
export function createAdminClient() {
  const { url } = requirePublicSupabaseEnv();
  const serviceRoleKey = requireServiceRoleKey();

  return createSupabaseClient<Database>(url, serviceRoleKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
}

export type AdminClient = ReturnType<typeof createAdminClient>;
