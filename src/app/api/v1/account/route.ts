import { NextResponse } from 'next/server';

import { currentAuthContext } from '@/lib/auth/session';
import { createAdminClient } from '@/lib/supabase/admin';
import { createClient } from '@/lib/supabase/server';
import { deleteAccount } from '@/services/account/delete-account';

/**
 * `DELETE /api/v1/account` (T10, AC1.5, AC1.6, ADR-0017).
 *
 * **This handler takes no input at all.** No body, no query parameter, no path
 * segment. The subject is the verified session's user, full stop. That is the
 * whole authorisation model, and it is deliberately not expressible any other
 * way: this route calls the service-role client, so an id read from the request
 * would be an unauthenticated delete-anyone endpoint one validation slip away.
 *
 * Idempotent. A second call against an already-deleted account cannot even
 * reach the service — the session is gone and `currentAuthContext` refuses a
 * tombstoned profile — and the service itself is retry-safe if it is reached
 * mid-way through a failed previous attempt.
 *
 * The response reports what was deleted and what was retained, because AC1.6's
 * promise ("financial records are retained, and they do not identify you") is
 * one a user is entitled to see evidence of at the moment they exercise it.
 */
export const dynamic = 'force-dynamic';

export async function DELETE() {
  const context = await currentAuthContext();
  if (!context) {
    return NextResponse.json(
      { ok: false, error: { code: 'UNAUTHENTICATED', message: 'Sign in to continue' }, meta: { version: 'v1' } },
      { status: 401 },
    );
  }

  const result = await deleteAccount(createAdminClient(), context.user.id);

  if (!result.ok) {
    return NextResponse.json(
      { ok: false, error: result.error, meta: { version: 'v1' } },
      { status: 500 },
    );
  }

  // Drop the browser's cookies for a session whose user no longer exists.
  const supabase = await createClient();
  await supabase.auth.signOut();

  return NextResponse.json(
    { ok: true, data: result.data, meta: { version: 'v1' } },
    { status: 200 },
  );
}
