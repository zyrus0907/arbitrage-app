/**
 * The signup credit grant (T10, AC10.6).
 *
 * WHAT THE DOCUMENTS ACTUALLY SAY, CHECKED BEFORE WRITING THIS
 *
 * T03's `handle_new_user()` inserts nothing but the id. It does **not** set
 * `credit_balance`, and it writes **no** ledger row — so a fresh account has a
 * balance of 0 and an empty ledger, and AC10.8's invariant
 * `sum(credit_ledger.delta) = profiles.credit_balance` holds trivially at
 * signup. There is therefore no conflict between the trigger and T07's
 * accounting rules to resolve, and nothing in T07 is being rewritten here.
 *
 * WHY THIS IS NOT A SECOND CREDIT PATH
 *
 * `grant_credits` remains the only function that moves credits. This module
 * contributes one thing: a **deterministic idempotency key**. The key is
 * derived purely from the subject id, so every call for a given user — first
 * signup, a retried request, a later app boot — presents the same key, and T07
 * replays the recorded `(balance_after, ledger_id)` instead of writing a second
 * row (ADR-0014 decision 3). Exactly one `signup_grant` row can ever exist per
 * user, and it is the database that guarantees it via
 * `credit_ledger.idempotency_key UNIQUE`, not this code.
 *
 * That is also why it is safe to call this on every authenticated bootstrap
 * rather than only at signup. The grant is self-healing: if the call made
 * immediately after sign-up fails — a transient network error, a crashed
 * request — the next page load completes it, and a user does not silently lose
 * the five credits the product promised them. A non-deterministic key would
 * make that same retry a double-grant.
 *
 * The key is versioned (`v1`) so that a future deliberate re-grant is possible
 * without an UPDATE to an append-only table.
 */
import 'server-only';

import type { AdminClient } from '@/lib/supabase/admin';
import { SIGNUP_GRANT_CREDITS, signupGrantIdempotencyKey } from '@/services/credits/grant-key';

export { SIGNUP_GRANT_CREDITS, signupGrantIdempotencyKey };

export type SignupGrantResult =
  | { ok: true; balance: number; ledgerId: string }
  | { ok: false; code: string; message: string };

/**
 * Grants the signup credits, or returns the existing grant unchanged.
 *
 * Uses the admin client because `grant_credits` is granted to `service_role`
 * alone (T07) — an authenticated client calling it receives a privilege error,
 * which T07's and T09's suites both assert and which must stay true.
 */
export async function ensureSignupGrant(
  admin: AdminClient,
  userId: string,
): Promise<SignupGrantResult> {
  const { data, error } = await admin.rpc('grant_credits', {
    p_user: userId,
    p_amount: SIGNUP_GRANT_CREDITS,
    p_reason: 'signup_grant',
    // An unreferenced movement: T07 requires ref_type and ref_id to be supplied
    // together or not at all, and a signup grant refers to nothing.
    //
    // The cast is unavoidable and is narrow on purpose. `supabase gen types`
    // cannot read argument nullability out of `pg_proc` — every parameter comes
    // out non-nullable — while `grant_credits` explicitly accepts NULL for this
    // pair and raises `22023` if only one of them is supplied. Passing an empty
    // string instead would be worse: T07 rejects a blank `p_ref_type` by name.
    p_ref_type: null as unknown as string,
    p_ref_id: null as unknown as string,
    p_idem: signupGrantIdempotencyKey(userId),
  });

  if (error) {
    return { ok: false, code: error.code ?? 'GRANT_FAILED', message: error.message };
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return { ok: false, code: 'GRANT_FAILED', message: 'grant_credits returned no row' };

  return { ok: true, balance: row.new_balance, ledgerId: row.ledger_id };
}
