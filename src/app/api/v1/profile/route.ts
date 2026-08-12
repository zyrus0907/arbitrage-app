import { NextResponse, type NextRequest } from 'next/server';

import { currentAuthContext } from '@/lib/auth/session';
import { createClient } from '@/lib/supabase/server';
import { profilePatchSchema } from '@/lib/validation/profile';
import { updateProfile } from '@/services/profile';

/**
 * `GET/PATCH /api/v1/profile` (T10, §5.3).
 *
 * Follows §5.1's handler shape as far as T10's dependencies allow:
 * authenticate → validate (Zod, parse don't validate) → delegate to a service →
 * typed envelope. Rate limiting is T25's and market resolution is T13's; both
 * are deliberately absent rather than stubbed, because a stub here would be
 * indistinguishable from the real thing at review time.
 *
 * **The caller can only ever affect their own row, at three layers.** The
 * subject is taken from the verified session and never from the request; the
 * service filters on it; and RLS's `with check (id = auth.uid())` refuses the
 * write regardless of what the first two do. There is no `user_id` parameter to
 * this endpoint, which is why "user A cannot PATCH user B" has no code path to
 * get wrong.
 *
 * `credit_balance` is not in the schema, so sending it is a 400 — and would be
 * a `42501` from the column grant even if it were.
 */
export const dynamic = 'force-dynamic';

type Envelope<T> =
  | { ok: true; data: T; meta: { version: 'v1' } }
  | { ok: false; error: { code: string; message: string; details?: unknown }; meta: { version: 'v1' } };

function ok<T>(data: T, status = 200) {
  return NextResponse.json<Envelope<T>>({ ok: true, data, meta: { version: 'v1' } }, { status });
}

function fail(code: string, message: string, status: number, details?: unknown) {
  return NextResponse.json<Envelope<never>>(
    { ok: false, error: { code, message, ...(details ? { details } : {}) }, meta: { version: 'v1' } },
    { status },
  );
}

export async function GET() {
  const context = await currentAuthContext();
  if (!context) return fail('UNAUTHENTICATED', 'Sign in to continue', 401);

  return ok({ profile: context.profile, stage: context.stage });
}

export async function PATCH(request: NextRequest) {
  const context = await currentAuthContext();
  if (!context) return fail('UNAUTHENTICATED', 'Sign in to continue', 401);

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return fail('INVALID_BODY', 'Request body must be JSON', 400);
  }

  const parsed = profilePatchSchema.safeParse(body);
  if (!parsed.success) {
    // The issue list is safe to return: it describes the caller's own input.
    return fail('VALIDATION_FAILED', 'Some fields were rejected', 400, parsed.error.issues);
  }

  const supabase = await createClient();
  const result = await updateProfile(supabase, context.user.id, parsed.data);

  if (!result.ok) {
    switch (result.error.kind) {
      case 'invalid':
        return fail('VALIDATION_FAILED', result.error.message, 400, {
          field: result.error.field,
        });
      case 'forbidden':
        return fail('FORBIDDEN', result.error.message, 403);
      case 'not_found':
        return fail('NOT_FOUND', 'No profile for this account', 404);
      default:
        // The database message is not echoed: it can name columns, constraints
        // and policies, which is reconnaissance for anyone probing the API.
        return fail('PROFILE_UPDATE_FAILED', 'Could not update the profile', 500);
    }
  }

  return ok({ profile: result.data });
}
