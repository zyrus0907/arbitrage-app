import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, extname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { describe, expect, it } from 'vitest';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const srcDir = resolve(repoRoot, 'src');

const SOURCE_EXTENSIONS = new Set(['.ts', '.tsx', '.js', '.jsx', '.mjs']);

function sourceFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) return sourceFiles(full);
    return SOURCE_EXTENSIONS.has(extname(full)) ? [full] : [];
  });
}

const files = sourceFiles(srcDir).map((file) => ({
  path: relative(repoRoot, file),
  source: readFileSync(file, 'utf8'),
}));

/**
 * T02 acceptance: "No Supabase key other than NEXT_PUBLIC_SUPABASE_URL and
 * NEXT_PUBLIC_SUPABASE_ANON_KEY is referenced anywhere reachable from client
 * code", and ARCHITECTURE.md §1.2 rule 1.
 *
 * These are static assertions over the source tree, so they keep holding as
 * files are added in later tasks without anyone remembering to update a list.
 */
describe('privileged Supabase credentials are unreachable from client code', () => {
  it('finds source files to check (guards against a broken walker)', () => {
    expect(files.length).toBeGreaterThan(5);
  });

  it('never prefixes a privileged variable with NEXT_PUBLIC_', () => {
    const offenders = files.filter(({ source }) =>
      /NEXT_PUBLIC_[A-Z0-9_]*(SERVICE_ROLE|SECRET|PRIVATE)/.test(source),
    );
    expect(offenders.map((f) => f.path)).toEqual([]);
  });

  it('references SUPABASE_SERVICE_ROLE_KEY only in env.ts and the admin client', () => {
    const allowed = new Set(['src/lib/env.ts', 'src/lib/supabase/admin.ts']);
    const offenders = files
      .filter(({ source }) => source.includes('SUPABASE_SERVICE_ROLE_KEY'))
      .map((f) => f.path)
      .filter((path) => !allowed.has(path));
    expect(offenders).toEqual([]);
  });

  it("has no 'use client' module importing the admin client or the service-role accessor", () => {
    const offenders = files
      .filter(({ source }) => /^\s*(['"])use client\1/m.test(source))
      .filter(
        ({ source }) =>
          /from\s+['"][^'"]*supabase\/admin['"]/.test(source) ||
          source.includes('requireServiceRoleKey'),
      )
      .map((f) => f.path);
    expect(offenders).toEqual([]);
  });

  it("has no 'use client' module importing the server client (cookie/session-bound)", () => {
    const offenders = files
      .filter(({ source }) => /^\s*(['"])use client\1/m.test(source))
      .filter(({ source }) => /from\s+['"][^'"]*supabase\/server['"]/.test(source))
      .map((f) => f.path);
    expect(offenders).toEqual([]);
  });

  it('keeps the admin client out of the browser client module graph', () => {
    const browser = files.find((f) => f.path === 'src/lib/supabase/browser.ts');
    expect(browser).toBeDefined();
    expect(browser?.source).not.toMatch(/supabase\/admin/);
    expect(browser?.source).not.toMatch(/SERVICE_ROLE/);
  });
});
