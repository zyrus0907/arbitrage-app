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
    if (value && value.length >= 20 && content.includes(value)) {
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

if (findings.length > 0) {
  console.error('\nSECRET MATERIAL FOUND IN THE CLIENT BUNDLE:\n');
  for (const finding of findings) {
    console.error(`  ${finding.what}\n    in ${finding.file} at offset ${finding.at}`);
  }
  console.error(
    '\nA leaked service-role key is a total database compromise (§11.1). Rotate it in ' +
      'the Supabase dashboard before doing anything else.',
  );
  process.exit(1);
}

console.log('No server-only variable name, value or service-role claim appears in it.');
