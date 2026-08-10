import 'server-only';

import { hasServiceRoleKey, publicEnv, serverEnv } from '@/lib/env';
import { createAdminClient } from '@/lib/supabase/admin';
import { Constants } from '@/types/database';

import { collectDevDashboardData, unavailableDevDashboardData } from './collect';
import type { DevDashboardSnapshot, SystemStatus } from './types';

/**
 * Development dashboard — the server boundary.
 *
 * `import 'server-only'` is the first line for the same reason it is in
 * `supabase/admin.ts`: this module reaches the service-role client, so a
 * `'use client'` module importing it must fail the build rather than ship.
 *
 * Nothing here returns a value read from the environment. `SystemStatus` is
 * three facts — which environment is running, whether the generated types are
 * present, whether credentials are configured — expressed as an enum and two
 * booleans, because the page renders whatever this function returns.
 */
function readSystemStatus(): SystemStatus {
  return {
    environment: serverEnv.NODE_ENV,
    // The generated types are a build artefact, so "available" means the
    // committed module actually carries the schema's enums rather than an empty
    // shell left behind by a failed `npm run db:types`.
    databaseTypesAvailable: Object.keys(Constants.public.Enums).length > 0,
    serverCredentialsConfigured:
      Boolean(publicEnv.NEXT_PUBLIC_SUPABASE_URL) &&
      Boolean(publicEnv.NEXT_PUBLIC_SUPABASE_ANON_KEY) &&
      hasServiceRoleKey(),
  };
}

export async function getDevDashboardSnapshot(): Promise<DevDashboardSnapshot> {
  const system = readSystemStatus();

  let client;
  try {
    client = createAdminClient();
  } catch {
    // Missing or malformed credentials. The dashboard reports an unavailable
    // backend and renders; it does not repeat what the environment said.
    return { ...unavailableDevDashboardData(), system };
  }

  return { ...(await collectDevDashboardData(client)), system };
}
