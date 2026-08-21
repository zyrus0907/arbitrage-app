#!/usr/bin/env node
/**
 * T10 — prove no secret reached the browser bundle.
 *
 * WHY A SCRIPT AND NOT A VITEST TEST
 *
 * `tests/unit/supabase/no-privileged-key-in-client.test.ts` scans SOURCE and is
 * a real guard, but it can only prove that nobody wrote the variable name in
 * the wrong file. It cannot prove what the compiler emitted. `NEXT_PUBLIC_*`
 * inlining, a stray import that pulled a server module into a client chunk, or
 * a value that arrived through a Server Component's serialised props are all
 * invisible to it and all end up in `.next/static`.
 *
 * So this reads the built output. It needs a build to exist, which `npm test`
 * deliberately does not require — so it is its own command
 * (`npm run scan:bundle`) that CI runs after `npm run build`, rather than a
 * test that would either be skipped silently or make the unit suite depend on a
 * four-second compile.
 *
 * WHAT IT LOOKS FOR
 *
 *   1. Every server-only environment variable's NAME. A name in a client chunk
 *      means a server module was bundled into it.
 *   2. Every server-only environment variable's VALUE, when one is set. This is
 *      the assertion that actually matters, and it is why the script reads the
 *      environment rather than taking a list of patterns on trust.
 *   3. The `service_role` claim, which is what a Supabase service key decodes
 *      to — a leaked key would usually be spotted by (2), but not if it came
 *      from a different environment than the one running the scan.
 *
 * It never prints a secret. A hit is reported by variable name, file and
 * offset; the matched text is not echoed, because the output of this script is
 * exactly the sort of thing that ends up in a CI log.
 *
 * WHY IT REPORTS WHETHER (2) ACTUALLY RAN — T11 finding F6
 *
 * The value-level assertion is conditional on the value being present in the
 * scanning process's environment. In CI, which held no `SUPABASE_SERVICE_ROLE_KEY`,
 * it never ran — and the script still printed "No server-only variable name,
 * value or service-role claim appears in it." That sentence was true and the
 * impression it gave was false: the only check that can catch a key inlined
 * from a *different* environment had been silently skipped, in exactly the
 * environment the badge was being read from.
 *
 * So the outcome is now three-valued and the summary names which value
 * assertions executed:
 *
 *   PASS       — nothing found, and the required value assertion ran.
 *   INCOMPLETE — nothing found, but the required secret was absent. Exit 2 by
 *                default; exit 0 only with an explicit `--allow-incomplete`,
 *                and the word PASS is never printed either way.
 *   FAIL       — something was found. Exit 1.
 *
 * CI SUPPLIES A VALUE, AND IT IS NOT A SECRET. The local Supabase stack's
 * service-role key is a fixed, published development key signed with the
 * published local JWT secret — it authenticates nothing outside a developer's
 * own `supabase start`. Setting it for the build makes the value assertion
 * genuinely execute against a real, service-role-shaped JWT without putting a
 * production credential anywhere near a CI log. A real key is never required
 * here and must never be added.
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const buildDir = join(repoRoot, '.next');

/** Variables that must never appear in anything a browser downloads. */
const SERVER_ONLY_VARS = [
  'SUPABASE_SERVICE_ROLE_KEY',
  'KEEPA_API_KEY',
  'STRIPE_SECRET_KEY',
  'STRIPE_WEBHOOK_SECRET',
  'CRON_SECRET',
  // T10: Vercel system variables. Not secrets in the credential sense, but the
  // origin resolver must stay server-side — a client that resolved its own
  // origin would defeat the point of not trusting request-derived hosts, and
  // their presence here would mean a server module was bundled for the browser.
  'VERCEL_BRANCH_URL',
  'VERCEL_PROJECT_PRODUCTION_URL',
];

/** Literal strings that are a leak regardless of which environment set them. */
const FORBIDDEN_LITERALS = [
  // The role claim inside a Supabase service key's JWT payload, base64url-encoded.
  { label: 'a service_role JWT claim', needle: 'InNlcnZpY2Vfcm9sZSI' },
  { label: 'a Supabase secret key prefix', needle: 'sb_secret_' },
];

function walk(dir) {
  const out = [];
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return out;
  }
  for (const entry of entries) {
    const full = join(dir, entry);
    const stats = statSync(full);
    if (stats.isDirectory()) out.push(...walk(full));
    else out.push(full);
  }
  return out;
}

const clientDirs = [join(buildDir, 'static')];

const files = clientDirs
  .flatMap(walk)
  .filter((f) => /\.(js|mjs|css|json|map|txt|html)$/.test(f));

if (files.length === 0) {
  console.error(
    'No build output found under .next/static. Run `npm run build` first — this scan ' +
      'is meaningless without something to scan, and passing vacuously would be worse ' +
      'than failing.',
  );
  process.exit(1);
}

const findings = [];

/**
 * The value assertion is only meaningful for a value long enough not to collide
 * with minified output, so "set" is not the same question as "usable". Both are
 * tracked, and reported, per variable.
 */
const MIN_SCANNABLE_VALUE_LENGTH = 20;

/** Without this one, the scan cannot answer the question it exists to answer. */
const VALUE_ASSERTION_REQUIRED_FOR = 'SUPABASE_SERVICE_ROLE_KEY';

const allowIncomplete = process.argv.includes('--allow-incomplete');

const valueAssertions = new Map(
  SERVER_ONLY_VARS.map((name) => {
    const value = process.env[name];
    if (!value) return [name, 'not set'];
    if (value.length < MIN_SCANNABLE_VALUE_LENGTH) return [name, 'too short to scan'];
    return [name, 'executed'];
  }),
);

for (const file of files) {
  let content;
  try {
    content = readFileSync(file, 'utf8');
  } catch {
    continue; // Binary or unreadable; nothing text-shaped to leak.
  }

  for (const name of SERVER_ONLY_VARS) {
    const at = content.indexOf(name);
    if (at !== -1) {
      findings.push({ what: `the name ${name}`, file: relative(repoRoot, file), at });
    }

    const value = process.env[name];
    // A short value would produce false positives against minified output; a
    // real key is far longer than this.
    if (valueAssertions.get(name) === 'executed' && content.includes(value)) {
      findings.push({
        what: `the VALUE of ${name}`,
        file: relative(repoRoot, file),
        at: content.indexOf(value),
      });
    }
  }

  for (const { label, needle } of FORBIDDEN_LITERALS) {
    const at = content.indexOf(needle);
    if (at !== -1) {
      findings.push({ what: label, file: relative(repoRoot, file), at });
    }
  }
}

console.log(`Scanned ${files.length} client bundle files under .next/static.`);

console.log('\nChecks performed:');
console.log(`  variable NAMES        executed for all ${SERVER_ONLY_VARS.length} server-only variables`);
console.log(`  forbidden LITERALS    executed for all ${FORBIDDEN_LITERALS.length} literals`);
console.log('  variable VALUES:');
for (const [name, state] of valueAssertions) {
  // The state, never the value.
  console.log(`    ${name.padEnd(30)} ${state}`);
}

if (findings.length > 0) {
  console.error('\nRESULT: FAIL — SECRET MATERIAL FOUND IN THE CLIENT BUNDLE:\n');
  for (const finding of findings) {
    console.error(`  ${finding.what}\n    in ${finding.file} at offset ${finding.at}`);
  }
  console.error(
    '\nA leaked service-role key is a total database compromise (§11.1). Rotate it in ' +
      'the Supabase dashboard before doing anything else.',
  );
  process.exit(1);
}

if (valueAssertions.get(VALUE_ASSERTION_REQUIRED_FOR) !== 'executed') {
  // Not a pass. The name scan and the literal scan found nothing, and the one
  // check that would catch a key inlined from another environment did not run.
  console.error(
    `\nRESULT: INCOMPLETE — no name, and no forbidden literal, appears in the bundle, but the ` +
      `value-level assertion for ${VALUE_ASSERTION_REQUIRED_FOR} did not run ` +
      `(${valueAssertions.get(VALUE_ASSERTION_REQUIRED_FOR)}).\n\n` +
      'Set it for the build and the scan and re-run. It does NOT have to be a real key: the ' +
      'local Supabase stack publishes a fixed service-role key (`npx supabase status`) which ' +
      'authenticates nothing outside your own machine and exercises this assertion fully. ' +
      'Never put a production service-role key in a CI environment to satisfy this.',
  );
  process.exit(allowIncomplete ? 0 : 2);
}

console.log('\nRESULT: PASS — no server-only variable name, value or service-role claim appears in it.');
