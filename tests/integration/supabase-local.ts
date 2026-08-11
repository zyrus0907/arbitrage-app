/**
 * T09 — resolving the local stack's connection details for the integration suite.
 *
 * WHY THIS EXISTS AT ALL
 *
 * The RLS suite has to hold three different credentials at once — the anon key,
 * the service-role key, and two real user sessions — because the whole point is
 * to prove they see different things. None of them may be committed, and none
 * of them may reach a terminal: `supabase status` prints the service-role key
 * next to everything else, and a CI log is not a private place.
 *
 * So this module is the one place that touches them, it returns them and never
 * prints them, and `scripts/db-test.mjs` sets the precedent it follows.
 *
 * RESOLUTION ORDER
 *
 * 1. Environment variables, if all three are present. This is the CI path and
 *    the escape hatch for running against a non-default local stack.
 * 2. The pinned Supabase CLI in `node_modules`, never a global install — a
 *    developer with an older `supabase` on their PATH must not get a different
 *    answer from the one `npm run db:reset` produced.
 *
 * There is deliberately NO third fallback to hardcoded demo keys. The local
 * stack's keys are well-known constants and it would be easy to inline them;
 * doing so would put a credential-shaped literal in committed source, which is
 * exactly what `tests/unit/supabase/no-privileged-key-in-client.test.ts` exists
 * to prevent, and it would silently pass against the wrong database the day
 * someone changes the local JWT secret.
 */
import { spawnSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

export type LocalStack = {
  url: string;
  anonKey: string;
  serviceRoleKey: string;
  /** Run one SQL statement as the container superuser and return raw stdout. */
  sql: (statement: string) => string;
};

/**
 * The database container, named from config.toml's project_id — the same
 * derivation `scripts/db-test.mjs` uses, with the same discovery fallback.
 */
function dbContainer(): string {
  const running = spawnSync(
    'docker',
    ['ps', '--filter', 'name=supabase_db_', '--format', '{{.Names}}'],
    { encoding: 'utf8' },
  );

  const names = (running.stdout ?? '')
    .split('\n')
    .map((n) => n.trim())
    .filter(Boolean);

  if (names.length === 0) {
    throw new Error(
      'No Supabase database container is running. Start the local stack with `npm run db:start` ' +
        'and seed it with `npm run db:reset` before running the integration suite.',
    );
  }

  const preferred = 'supabase_db_arbitrage-app';
  if (names.includes(preferred)) return preferred;

  // `names` is non-empty by the guard above, but the index signature is still
  // `string | undefined` under the repo's strict settings, so this is narrowed
  // rather than asserted with `!`.
  const [first] = names;
  if (!first) throw new Error('No Supabase database container is running.');
  return first;
}

/**
 * Catalogue access for the coverage assertion.
 *
 * PostgREST exposes only the `public` schema, so `information_schema` cannot be
 * reached through supabase-js at all — and the acceptance criterion requires the
 * suite to enumerate tables from the live catalogue rather than from a list
 * someone remembered to update. psql inside the container over the unix socket
 * the local stack trusts is the same channel `scripts/db-test.mjs` uses, and it
 * involves no password and no new dependency.
 */
function makeSql(container: string) {
  return (statement: string): string => {
    const result = spawnSync(
      'docker',
      ['exec', '-i', container, 'psql', '-U', 'postgres', '-d', 'postgres', '-tAc', statement],
      { encoding: 'utf8' },
    );

    if (result.status !== 0) {
      // The statement is echoed, the connection is not — nothing here carries a
      // credential, but the habit is worth keeping.
      throw new Error(`psql failed for statement: ${statement}\n${result.stderr ?? ''}`);
    }
    return result.stdout ?? '';
  };
}

let cached: LocalStack | null = null;

export function localStack(): LocalStack {
  if (cached) return cached;

  const container = dbContainer();
  const sql = makeSql(container);

  const fromEnv = {
    url: process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL,
    anonKey: process.env.SUPABASE_ANON_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    serviceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY,
  };

  if (fromEnv.url && fromEnv.anonKey && fromEnv.serviceRoleKey) {
    cached = {
      url: fromEnv.url,
      anonKey: fromEnv.anonKey,
      serviceRoleKey: fromEnv.serviceRoleKey,
      sql,
    };
    return cached;
  }

  const cli = join(repoRoot, 'node_modules', '.bin', 'supabase');
  const status = spawnSync(cli, ['status', '-o', 'json'], { cwd: repoRoot, encoding: 'utf8' });

  if (status.status !== 0) {
    // Deliberately does not echo stdout or stderr: on success this payload
    // carries every key the local stack has.
    throw new Error(
      'Could not read `supabase status`. Is the local stack running? Try `npm run db:start`.',
    );
  }

  let parsed: { API_URL?: string; ANON_KEY?: string; SERVICE_ROLE_KEY?: string };
  try {
    parsed = JSON.parse(status.stdout);
  } catch {
    throw new Error('Could not parse `supabase status -o json`.');
  }

  if (!parsed.API_URL || !parsed.ANON_KEY || !parsed.SERVICE_ROLE_KEY) {
    throw new Error('`supabase status` did not report the API URL and both keys.');
  }

  cached = {
    url: parsed.API_URL,
    anonKey: parsed.ANON_KEY,
    serviceRoleKey: parsed.SERVICE_ROLE_KEY,
    sql,
  };
  return cached;
}
