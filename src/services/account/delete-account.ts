/**
 * Account deletion (T10, AC1.5, AC1.6, ADR-0017).
 *
 * THE TWO STEPS, IN THIS ORDER, FOR A REASON
 *
 *   1. `pseudonymise_account(user)` — deletes every personal row, scrubs the
 *      profile to a tombstone, stamps `deleted_at`. Retains `credit_ledger` and
 *      `credit_purchases` untouched.
 *   2. `auth.admin.deleteUser(user)` — removes the email, the identities, the
 *      sessions and the login itself.
 *
 * Scrub first. If the order were reversed and step 2 succeeded while step 1
 * failed, the user would be locked out of an account still holding their full
 * personal profile, with no authenticated route left to finish the job — the
 * worst possible failure, because it is both a privacy failure and unrecoverable
 * by the person affected. In this order the intermediate failure state is a
 * scrubbed profile with a live login, which the `(app)` layout's tombstone gate
 * already refuses to serve and which a retry completes.
 *
 * RETRY-SAFE END TO END. Step 1 is idempotent and convergent by construction
 * (see the migration). Step 2 treats "no such user" as success, because that is
 * exactly what a completed previous attempt looks like. Calling this function
 * twice produces the same end state and the same return value except for
 * `alreadyDeleted`.
 *
 * WHY THE ADMIN CLIENT. Both steps are privileged: `pseudonymise_account` is
 * granted to `service_role` alone, and the Auth admin API needs the service-role
 * key. **Authorisation is therefore this module's caller's job**, and the route
 * in `src/app/api/v1/account/route.ts` does it the only safe way — it deletes
 * the subject of the verified session and accepts no user id from the request.
 */
import 'server-only';

import type { AdminClient } from '@/lib/supabase/admin';

export type DeletionSummary = {
  /** True when a previous attempt had already tombstoned this subject. */
  alreadyDeleted: boolean;
  deletedAt: string;
  personalRowsDeleted: {
    dealUnlocks: number;
    watchlistItems: number;
    purchaseRecords: number;
    barcodeLookups: number;
  };
  /** `app_events` rows whose actor reference was nulled. The rows survive. */
  eventsDetached: number;
  /** Retained, never touched. Reported so the guarantee is observable. */
  financialRowsRetained: { ledgerEntries: number; creditPurchases: number };
  /** True when the auth.users row was already absent — a completed retry. */
  authUserAlreadyAbsent: boolean;
};

export type DeleteAccountResult =
  | { ok: true; data: DeletionSummary }
  | { ok: false; error: { code: string; message: string } };

export async function deleteAccount(
  admin: AdminClient,
  userId: string,
): Promise<DeleteAccountResult> {
  const { data, error } = await admin.rpc('pseudonymise_account', { p_user: userId });

  if (error) {
    return {
      ok: false,
      error: {
        code: error.code === '23503' ? 'UNKNOWN_SUBJECT' : 'PSEUDONYMISATION_FAILED',
        message: error.message,
      },
    };
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) {
    return {
      ok: false,
      error: {
        code: 'PSEUDONYMISATION_FAILED',
        message: 'pseudonymise_account returned no summary row',
      },
    };
  }

  const removal = await admin.auth.admin.deleteUser(userId);
  let authUserAlreadyAbsent = false;

  if (removal.error) {
    // A 404 means a previous attempt already removed the auth user. Anything
    // else leaves a live login attached to a scrubbed profile, and the caller
    // must know so it can be retried — reporting success there would leave a
    // usable credential on a "deleted" account, which is the one outcome this
    // whole mechanism exists to prevent.
    if (removal.error.status === 404) {
      authUserAlreadyAbsent = true;
    } else {
      return {
        ok: false,
        error: {
          code: 'AUTH_USER_DELETE_FAILED',
          message: removal.error.message,
        },
      };
    }
  }

  return {
    ok: true,
    data: {
      alreadyDeleted: row.already_deleted,
      deletedAt: row.deleted_at,
      personalRowsDeleted: {
        dealUnlocks: row.unlocks_deleted,
        watchlistItems: row.watchlist_deleted,
        purchaseRecords: row.purchases_deleted,
        barcodeLookups: row.lookups_deleted,
      },
      eventsDetached: row.events_detached,
      financialRowsRetained: {
        ledgerEntries: row.ledger_retained,
        creditPurchases: row.credit_purchases_retained,
      },
      authUserAlreadyAbsent,
    },
  };
}
