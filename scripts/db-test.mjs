#!/usr/bin/env node
/**
 * `npm run db:test` — the repository's one command for the pgTAP suite.
 *
 * WHY THIS WRAPPER EXISTS
 *
 * T07's concurrency tests (supabase/tests/database/credit_rpcs_concurrency.test.sql)
 * drive genuinely separate backends through `dblink`, because a lock is only
 * observable between real sessions and two sequential calls in one transaction
 * would pass against a `spend_credits` with no `FOR UPDATE` in it.
 *
 * `dblink` refuses a passwordless connection for a non-superuser, and `postgres`
 * is not a superuser on the Supabase local stack. The unrestricted variant that
 * would sidestep that, `dblink_connect_u`, is owned by `supabase_admin` and
 * grants `postgres` no EXECUTE — so a password is genuinely required, and it
 * must not live in committed source.
 *
 * `supabase test db` offers no way to pass a session setting: it parses the
 * connection URL into components and rebuilds the connection inside its own
 * container, so a `?options=-c ...` parameter is discarded (the session reports
 * `application_name=psql`), and `PGOPTIONS` does not cross the container
 * boundary either. The one channel that does survive is the database itself.
 *
 * So this wrapper resolves the local password at run time, publishes it as a
 * database-level setting for the duration of the run, and removes it again in a
 * `finally` — including when the tests fail, and on Ctrl-C.
 *
 * WHAT IT IS CAREFUL ABOUT
 *
 * - The password never reaches argv. The `ALTER DATABASE` statement is fed to
 *   psql on stdin, inside the database container, over the unix socket that the
 *   local stack trusts. Nothing is written to disk.
 * - The password never reaches stdout or stderr. Everything that could carry it
 *   — including psql's own diagnostics and any thrown error — goes through
 *   `redact()` first.
 * - `supabase status` output is parsed but never printed: it also carries the
 *   service-role key.
 * - The CLI is the project's pinned binary from `node_modules`, never a global
 *   install, so the suite runs against the version in `package.json`.
 *
 * The setting is written to `pg_db_role_setting` for the length of the run. That
 * is a value the local database already authenticates with, on a stack that
 * listens on localhost and is destroyed by `npm run db:reset`; it is removed
 * before this process exits, and the T07 suite asserts nothing else about it.
 */

import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const cli = join(repoRoot, 'node_modules', '.bin', 'supabase');
const SETTING = 't7.db_password';

/** Replace every occurrence of the secret in text destined for a terminal. */
function redact(text, secret) {
  if (!text) return '';
  if (!secret) return text;
  return text.split(secret).join('«redacted»');
}

function fail(message) {
  console.error(`db:test: ${message}`);
  process.exit(1);
}

/**
 * The local stack's own connection string. Captured, never printed — the same
 * payload carries the anon and service-role keys.
 */
function localDbUrl() {
  const status = spawnSync(cli, ['status', '-o', 'json'], {
    cwd: repoRoot,
    encoding: 'utf8',
  });

  if (status.error) fail(`could not run the pinned Supabase CLI at ${cli} — is the dependency installed?`);
  if (status.status !== 0) {
    fail('`supabase status` failed. Is the local stack running? Try `npm run db:start`.');
  }

  let parsed;
  try {
    parsed = JSON.parse(status.stdout);
  } catch {
    // Deliberately does not echo stdout: it contains the project's keys.
    fail('could not parse `supabase status -o json`. Is the local stack running?');
  }

  if (!parsed?.DB_URL) fail('`supabase status` reported no DB_URL. Is the local stack running?');
  return parsed.DB_URL;
}

/**
 * The database container, so the ALTER can be issued over the socket the local
 * stack trusts rather than over TCP with a credential in argv. Named from
 * config.toml's project_id, which is what the CLI itself uses, with a discovery
 * fallback for a stack started under a different id.
 */
function dbContainer() {
  let projectId = null;
  try {
    const config = readFileSync(join(repoRoot, 'supabase', 'config.toml'), 'utf8');
    projectId = config.match(/^\s*project_id\s*=\s*"([^"]+)"/m)?.[1] ?? null;
  } catch {
    // fall through to discovery
  }

  const running = spawnSync('docker', ['ps', '--filter', 'name=supabase_db_', '--format', '{{.Names}}'], {
    encoding: 'utf8',
  });
  if (running.error) fail('could not run `docker`. The local stack needs Docker running.');

  const names = running.stdout.split('\n').map((n) => n.trim()).filter(Boolean);
  if (names.length === 0) fail('no Supabase database container is running. Try `npm run db:start`.');

  const preferred = projectId ? `supabase_db_${projectId}` : null;
  if (preferred && names.includes(preferred)) return preferred;
  if (names.length === 1) return names[0];
  fail(`several Supabase database containers are running (${names.join(', ')}) and none matches project_id.`);
}

/**
 * Run one statement as the container's superuser, with the SQL on stdin.
 *
 * `postgres` is not a superuser here and Postgres requires superuser to set a
 * customised parameter at database level, so this is the one step that needs
 * `supabase_admin`. It reaches it through the container's unix socket, which the
 * local pg_hba trusts — no password is involved in this call at all.
 */
function psqlAsSuperuser(container, database, sql, secret) {
  const result = spawnSync(
    'docker',
    ['exec', '-i', container, 'psql', '-U', 'supabase_admin', '-d', database, '-v', 'ON_ERROR_STOP=1', '-q'],
    { input: sql, encoding: 'utf8' },
  );

  if (result.error) fail('could not run psql inside the database container.');
  if (result.status !== 0) {
    const detail = redact(`${result.stderr ?? ''}${result.stdout ?? ''}`.trim(), secret);
    fail(`psql refused the setting statement.\n${detail}`);
  }
}

function sqlLiteral(value) {
  return `'${value.replace(/'/g, "''")}'`;
}

function main() {
  const dbUrl = localDbUrl();

  let password;
  let database;
  try {
    const url = new URL(dbUrl);
    password = decodeURIComponent(url.password);
    database = decodeURIComponent(url.pathname.replace(/^\//, '')) || 'postgres';
  } catch {
    fail('could not read the local database URL reported by `supabase status`.');
  }

  if (!password) {
    fail('the local database URL carries no password, so the dblink concurrency tests cannot run.');
  }

  const container = dbContainer();
  const ident = `"${SETTING}"`;
  let released = false;

  const release = () => {
    if (released) return;
    released = true;
    psqlAsSuperuser(container, database, `alter database ${database} reset ${ident};\n`, password);
  };

  // Ctrl-C and terminations must not leave the setting behind either.
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(signal, () => {
      release();
      process.exit(130);
    });
  }

  try {
    psqlAsSuperuser(
      container,
      database,
      `alter database ${database} set ${ident} = ${sqlLiteral(password)};\n`,
      password,
    );

    // Arguments are forwarded, so `npm run db:test -- <file>` still works.
    const args = ['test', 'db', ...process.argv.slice(2)];
    const run = spawnSync(cli, args, { cwd: repoRoot, stdio: 'inherit' });

    if (run.error) fail('could not run `supabase test db`.');
    process.exitCode = run.status ?? 1;
  } finally {
    release();
  }
}

main();
