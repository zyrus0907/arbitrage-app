/**
 * T10 — the `VERCEL_*` system variables stay on the server.
 *
 * Next.js inlines **only** `NEXT_PUBLIC_*` into the client bundle, so the way
 * these values would reach a browser is if someone mirrored one into a
 * `NEXT_PUBLIC_*` variable "so the client can use it too". This suite makes
 * that a red test rather than a code-review habit.
 *
 * The bundle itself is checked by `npm run scan:bundle`, which reads
 * `.next/static` after a build. This file checks the source, because a source
 * scan runs in milliseconds with no build and catches the mistake at the moment
 * it is made.
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { describe, expect, it } from 'vitest';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const srcRoot = join(repoRoot, 'src');

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const full = join(dir, entry);
    return statSync(full).isDirectory() ? walk(full) : [full];
  });
}

/**
 * Comments are stripped before matching. Without this, a doc comment that
 * *explains* the rule ("this module deliberately does not read `process.env`")
 * trips the assertion enforcing it — which is exactly what happened when this
 * suite was first written, and it would have pushed the explanation out of the
 * file to keep the test green.
 */
function stripComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
}

const sources = walk(srcRoot)
  .filter((f) => /\.(ts|tsx)$/.test(f))
  .map((f) => {
    const raw = readFileSync(f, 'utf8');
    return {
      path: relative(repoRoot, f).replaceAll('\\', '/'),
      source: raw,
      code: stripComments(raw),
    };
  });

/** The only modules permitted to read a `VERCEL_*` variable. */
const SERVER_ONLY_READERS = ['src/lib/auth/site-origin.ts', 'src/lib/supabase/cookies.ts'];

describe('VERCEL_* system variables', () => {
  it('finds source files to check (guards against a broken walker)', () => {
    expect(sources.length).toBeGreaterThan(10);
  });

  it('are never mirrored into a NEXT_PUBLIC_* variable', () => {
    const offenders = sources.filter(({ code }) => /NEXT_PUBLIC_VERCEL/.test(code));
    expect(offenders.map((f) => f.path)).toEqual([]);
  });

  it('are read only from the modules allowed to read them', () => {
    const readers = sources
      .filter(({ code }) => /process\.env\.VERCEL/.test(code))
      .map((f) => f.path)
      .sort();
    expect(readers).toEqual([...SERVER_ONLY_READERS].sort());
  });

  it('the origin resolver is behind the server-only boundary', () => {
    const file = sources.find((f) => f.path === 'src/lib/auth/site-origin.ts');
    expect(file).toBeDefined();
    // First statement in the file, exactly as `admin.ts` requires (T02).
    const firstLine = file!.source.split('\n').find((l) => l.trim() !== '');
    expect(firstLine?.trim()).toBe("import 'server-only';");
  });

  it('the pure resolver reads no environment at all, which is why it is testable', () => {
    const file = sources.find((f) => f.path === 'src/lib/auth/origin.ts');
    expect(file).toBeDefined();
    expect(/process\.env/.test(file!.code)).toBe(false);
  });

  it('no Client Component imports the server-only origin resolver', () => {
    const offenders = sources.filter(
      ({ code }) => /^['"]use client['"]/m.test(code) && /auth\/site-origin/.test(code),
    );
    expect(offenders.map((f) => f.path)).toEqual([]);
  });
});

describe('cookie security is not derived from a public URL', () => {
  it('sessionCookieOptions no longer reads NEXT_PUBLIC_SITE_URL', () => {
    const file = sources.find((f) => f.path === 'src/lib/supabase/cookies.ts');
    expect(file).toBeDefined();
    // A cookie SECURITY flag keyed off a client-inlined, freely-editable public
    // URL is the coupling this assertion exists to prevent returning.
    expect(/NEXT_PUBLIC_SITE_URL/.test(file!.code)).toBe(false);
  });

  it('still forces httpOnly and sameSite=lax (AC1.4 must not regress)', () => {
    const file = sources.find((f) => f.path === 'src/lib/supabase/cookies.ts');
    expect(file!.source).toMatch(/httpOnly:\s*true/);
    expect(file!.source).toMatch(/sameSite:\s*'lax'/);
  });
});
