import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { describe, expect, it } from 'vitest';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const adminPath = resolve(repoRoot, 'src/lib/supabase/admin.ts');

/**
 * T02 acceptance: importing `admin.ts` from a Client Component must fail the
 * build, not merely be discouraged by a comment.
 *
 * The mechanism is the `server-only` package. Its `exports` map resolves to an
 * empty module under the `react-server` condition (Server Components, Route
 * Handlers, `next build`'s server graph) and to a module that throws on
 * evaluation under every other condition — which is exactly the condition a
 * `'use client'` bundle is compiled under. Next.js surfaces that throw as a
 * build error.
 *
 * Vitest does not apply the `react-server` condition, so this test runs in the
 * same resolution mode a Client Component would, and can assert the failure
 * directly and in milliseconds — no `next build` of a fixture app required.
 */
describe('src/lib/supabase/admin.ts is server-only', () => {
  it("has `import 'server-only'` as its first line", () => {
    const source = readFileSync(adminPath, 'utf8');
    const firstLine = source.split('\n')[0]?.trim();
    expect(firstLine).toBe("import 'server-only';");
  });

  it('throws when imported under a client (non-react-server) resolution condition', async () => {
    await expect(import('@/lib/supabase/admin')).rejects.toThrow(/client component/i);
  });

  it('resolves `server-only` to the throwing entry, not the empty one', async () => {
    await expect(import('server-only')).rejects.toThrow(/client component/i);
  });
});
