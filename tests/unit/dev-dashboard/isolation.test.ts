import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, extname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { describe, expect, it } from 'vitest';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');

const SOURCE_EXTENSIONS = new Set(['.ts', '.tsx']);

function sourceFiles(dir: string): Array<{ path: string; source: string }> {
  return readdirSync(dir).flatMap((entry) => {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) return sourceFiles(full);
    if (!SOURCE_EXTENSIONS.has(extname(full))) return [];
    return [{ path: relative(repoRoot, full), source: readFileSync(full, 'utf8') }];
  });
}

const components = sourceFiles(resolve(repoRoot, 'src/components/dev'));
const dataLayer = sourceFiles(resolve(repoRoot, 'src/lib/dev-dashboard'));
const snapshotModule = readFileSync(resolve(repoRoot, 'src/lib/dev-dashboard/snapshot.ts'), 'utf8');
const homePage = readFileSync(resolve(repoRoot, 'src/app/page.tsx'), 'utf8');

/**
 * The dashboard's structural guarantees: all reads happen on the server, and the
 * privileged client stays behind the `server-only` boundary. These are static
 * assertions so they keep holding as the files change, rather than depending on
 * a reviewer noticing.
 */
describe('development dashboard isolation', () => {
  it('finds the files it is asserting about', () => {
    expect(components.length).toBeGreaterThan(2);
    expect(dataLayer.length).toBeGreaterThan(2);
  });

  it('has no client component anywhere in the dashboard', () => {
    const offenders = [...components, ...dataLayer, { path: 'src/app/page.tsx', source: homePage }]
      .filter(({ source }) => /^\s*(['"])use client\1/m.test(source))
      .map((file) => file.path);

    expect(offenders).toEqual([]);
  });

  it('keeps database access out of the presentation layer', () => {
    const offenders = components
      .filter(
        ({ source }) =>
          /from\s+['"][^'"]*supabase/.test(source) ||
          /from\s+['"][^'"]*dev-dashboard\/(snapshot|collect)['"]/.test(source) ||
          /from\s+['"]@\/lib\/env['"]/.test(source),
      )
      .map((file) => file.path);

    expect(offenders).toEqual([]);
  });

  it('confines the admin client and the environment to the server-only module', () => {
    const offenders = dataLayer
      .filter((file) => file.path !== 'src/lib/dev-dashboard/snapshot.ts')
      .filter(
        ({ source }) =>
          /from\s+['"][^'"]*supabase\/admin['"]/.test(source) ||
          /from\s+['"]@\/lib\/env['"]/.test(source),
      )
      .map((file) => file.path);

    expect(offenders).toEqual([]);
  });

  it("starts the server-only module with 'server-only'", () => {
    const firstCodeLine = snapshotModule
      .split('\n')
      .map((line) => line.trim())
      .find((line) => line.length > 0 && !line.startsWith('//') && !line.startsWith('*'));

    expect(firstCodeLine).toBe("import 'server-only';");
  });

  it('never prerenders the page, so counts are never baked in at build time', () => {
    expect(homePage).toMatch(/export const dynamic = 'force-dynamic';/);
  });

  it('names no privileged environment variable outside env.ts and the admin client', () => {
    const offenders = [...components, ...dataLayer]
      .filter(({ source }) => /SERVICE_ROLE|STRIPE_SECRET|KEEPA_API_KEY|CRON_SECRET/.test(source))
      .map((file) => file.path);

    expect(offenders).toEqual([]);
  });
});
