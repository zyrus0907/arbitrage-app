import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const read = (rel: string) => readFileSync(resolve(repoRoot, rel), 'utf8');

const FAKE_URL = 'https://example-project.supabase.co';
const FAKE_ANON_KEY = 'test-anon-key';

describe('browser client', () => {
  beforeEach(() => {
    vi.resetModules();
    vi.stubEnv('NEXT_PUBLIC_SUPABASE_URL', FAKE_URL);
    vi.stubEnv('NEXT_PUBLIC_SUPABASE_ANON_KEY', FAKE_ANON_KEY);
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.resetModules();
  });

  it('constructs from the public URL and anon key alone', async () => {
    const { createClient } = await import('@/lib/supabase/browser');
    const client = await Promise.resolve(createClient());
    expect(client).toBeDefined();
    expect(client.from).toBeTypeOf('function');
    expect(client.auth).toBeDefined();
  });

  it('throws a named error when a public variable is absent', async () => {
    vi.stubEnv('NEXT_PUBLIC_SUPABASE_ANON_KEY', undefined);
    vi.resetModules();
    const { createClient } = await import('@/lib/supabase/browser');
    expect(() => createClient()).toThrow(/NEXT_PUBLIC_SUPABASE_ANON_KEY/);
  });

  it('fails at module load — not mid-request — when a variable is malformed', async () => {
    vi.stubEnv('NEXT_PUBLIC_SUPABASE_ANON_KEY', '');
    vi.resetModules();
    await expect(import('@/lib/supabase/browser')).rejects.toThrow(
      /NEXT_PUBLIC_SUPABASE_ANON_KEY/,
    );
  });
});

describe('env accessors', () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.resetModules();
  });

  it('requireServiceRoleKey throws by name when the key is absent', async () => {
    const { requireServiceRoleKey } = await import('@/lib/env');
    expect(() =>
      requireServiceRoleKey({ NODE_ENV: 'test' } as Parameters<typeof requireServiceRoleKey>[0]),
    ).toThrow(/SUPABASE_SERVICE_ROLE_KEY/);
  });

  it('requirePublicSupabaseEnv returns both values when present', async () => {
    const { requirePublicSupabaseEnv } = await import('@/lib/env');
    expect(
      requirePublicSupabaseEnv({
        NEXT_PUBLIC_SITE_URL: 'http://localhost:3000',
        NEXT_PUBLIC_SUPABASE_URL: FAKE_URL,
        NEXT_PUBLIC_SUPABASE_ANON_KEY: FAKE_ANON_KEY,
      }),
    ).toEqual({ url: FAKE_URL, anonKey: FAKE_ANON_KEY });
  });
});

/**
 * `server.ts` imports `next/headers`, which only resolves inside a Next.js
 * request scope, so its contract is asserted statically. These assertions are
 * about the *shape of the contract* (§6.2), which is what future edits are
 * likely to break.
 */
describe('server client contract (static)', () => {
  const source = read('src/lib/supabase/server.ts');

  it('uses @supabase/ssr createServerClient, not the plain supabase-js client', () => {
    expect(source).toMatch(/createServerClient.*from '@supabase\/ssr'/s);
    expect(source).not.toMatch(/from '@supabase\/supabase-js'/);
  });

  it('is session-aware via the App Router cookie jar', () => {
    expect(source).toMatch(/from 'next\/headers'/);
    expect(source).toMatch(/await cookies\(\)/);
  });

  it('uses the getAll/setAll cookie interface required by @supabase/ssr', () => {
    expect(source).toMatch(/getAll\(\)/);
    expect(source).toMatch(/setAll\(/);
  });

  it('does not bypass RLS: anon key only, never the service-role key', () => {
    expect(source).toMatch(/anonKey/);
    expect(source).not.toMatch(/SERVICE_ROLE|requireServiceRoleKey/);
  });
});

describe('admin client contract (static)', () => {
  const source = read('src/lib/supabase/admin.ts');

  it('uses the service-role key and disables session persistence', () => {
    expect(source).toMatch(/requireServiceRoleKey\(\)/);
    expect(source).toMatch(/persistSession: false/);
    expect(source).toMatch(/autoRefreshToken: false/);
  });

  it('does not read cookies or otherwise carry a user session', () => {
    expect(source).not.toMatch(/next\/headers/);
    expect(source).not.toMatch(/@supabase\/ssr/);
  });
});

describe('all three clients are typed against the generated Database type', () => {
  for (const file of [
    'src/lib/supabase/browser.ts',
    'src/lib/supabase/server.ts',
    'src/lib/supabase/admin.ts',
  ]) {
    it(`${file} imports Database from @/types/database`, () => {
      expect(read(file)).toMatch(/import type \{ Database \} from '@\/types\/database'/);
    });
  }
});
