import { z } from 'zod';

/**
 * Environment validation. Parsed once, at module load, so a missing or malformed
 * variable fails the boot rather than surfacing as `undefined` deep inside a
 * request path.
 *
 * Two schemas, deliberately separate (ARCHITECTURE.md §1.2 rule 1):
 *
 *  - `publicEnvSchema` — `NEXT_PUBLIC_*` only. Inlined into the client bundle.
 *  - `serverEnvSchema` — never referenced from a Client Component.
 *
 * Variables belonging to tasks that have not landed yet (Supabase, Keepa, Stripe)
 * are declared `.optional()` so the skeleton boots without them, and are made
 * required by the task that first depends on them.
 */

export const publicEnvSchema = z.object({
  NEXT_PUBLIC_SITE_URL: z.url(),

  // Required from T02, when the Supabase clients land.
  NEXT_PUBLIC_SUPABASE_URL: z.url().optional(),
  NEXT_PUBLIC_SUPABASE_ANON_KEY: z.string().min(1).optional(),
});

export const serverEnvSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),

  // Declared here so the contract is visible from day one; each becomes
  // required in the task that introduces its dependency.
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(1).optional(), // T02
  KEEPA_API_KEY: z.string().min(1).optional(), // T17
  STRIPE_SECRET_KEY: z.string().min(1).optional(), // T34
  STRIPE_WEBHOOK_SECRET: z.string().min(1).optional(), // T34
  CRON_SECRET: z.string().min(1).optional(), // T17
});

export type PublicEnv = z.infer<typeof publicEnvSchema>;
export type ServerEnv = z.infer<typeof serverEnvSchema>;

export class EnvValidationError extends Error {
  readonly issues: string[];

  constructor(scope: 'public' | 'server', issues: string[]) {
    super(`Invalid ${scope} environment configuration:\n${issues.map((i) => `  - ${i}`).join('\n')}`);
    this.name = 'EnvValidationError';
    this.issues = issues;
  }
}

function parse<T extends z.ZodType>(schema: T, scope: 'public' | 'server', raw: unknown): z.infer<T> {
  const result = schema.safeParse(raw);
  if (!result.success) {
    const issues = result.error.issues.map(
      (issue) => `${issue.path.join('.') || '(root)'}: ${issue.message}`,
    );
    throw new EnvValidationError(scope, issues);
  }
  return result.data;
}

export function parsePublicEnv(raw: unknown): PublicEnv {
  return parse(publicEnvSchema, 'public', raw);
}

export function parseServerEnv(raw: unknown): ServerEnv {
  return parse(serverEnvSchema, 'server', raw);
}

/**
 * `NEXT_PUBLIC_*` variables must be read as static literals — Next.js inlines
 * them at build time and cannot see a dynamic `process.env[name]` lookup.
 */
export const publicEnv: PublicEnv = parsePublicEnv({
  NEXT_PUBLIC_SITE_URL: process.env.NEXT_PUBLIC_SITE_URL,
  NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
  NEXT_PUBLIC_SUPABASE_ANON_KEY: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
});

/**
 * Required-at-use-site accessors (T02).
 *
 * The Supabase variables stay `.optional()` in the schemas above so the
 * repository can still be typechecked, tested and built without any Supabase
 * credentials — CI has none, and a build that demanded them would be a build
 * that could only run on a developer's machine. Instead, each Supabase client
 * asserts what *it* needs at the moment it constructs a connection, and fails
 * loudly with the variable name when it is absent.
 */

export type PublicSupabaseEnv = {
  url: string;
  anonKey: string;
};

export function requirePublicSupabaseEnv(env: PublicEnv = publicEnv): PublicSupabaseEnv {
  const missing: string[] = [];
  if (!env.NEXT_PUBLIC_SUPABASE_URL) missing.push('NEXT_PUBLIC_SUPABASE_URL');
  if (!env.NEXT_PUBLIC_SUPABASE_ANON_KEY) missing.push('NEXT_PUBLIC_SUPABASE_ANON_KEY');
  if (missing.length > 0) {
    throw new EnvValidationError(
      'public',
      missing.map((name) => `${name}: required to construct a Supabase client`),
    );
  }
  return {
    url: env.NEXT_PUBLIC_SUPABASE_URL as string,
    anonKey: env.NEXT_PUBLIC_SUPABASE_ANON_KEY as string,
  };
}

/**
 * The service-role key. Bypasses RLS, so this is only ever called from
 * `src/lib/supabase/admin.ts`, which is itself `server-only`.
 */
export function requireServiceRoleKey(env: ServerEnv = serverEnv): string {
  if (!env.SUPABASE_SERVICE_ROLE_KEY) {
    throw new EnvValidationError('server', [
      'SUPABASE_SERVICE_ROLE_KEY: required to construct the Supabase admin client',
    ]);
  }
  return env.SUPABASE_SERVICE_ROLE_KEY;
}

/**
 * Whether the service-role key is configured — a boolean, never the value.
 *
 * Diagnostics surfaces want to report "credentials present" without holding the
 * credential. This accessor exists so they can, and so the name of the variable
 * stays inside this module and `supabase/admin.ts`; the source-scanning test in
 * `tests/unit/supabase/` enforces exactly that boundary.
 */
export function hasServiceRoleKey(env: ServerEnv = serverEnv): boolean {
  return Boolean(env.SUPABASE_SERVICE_ROLE_KEY);
}

export const serverEnv: ServerEnv = parseServerEnv({
  NODE_ENV: process.env.NODE_ENV,
  SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
  KEEPA_API_KEY: process.env.KEEPA_API_KEY,
  STRIPE_SECRET_KEY: process.env.STRIPE_SECRET_KEY,
  STRIPE_WEBHOOK_SECRET: process.env.STRIPE_WEBHOOK_SECRET,
  CRON_SECRET: process.env.CRON_SECRET,
});
