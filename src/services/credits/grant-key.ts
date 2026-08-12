/**
 * The signup grant's quantity and idempotency key — deliberately in their own
 * module, with no `import 'server-only'`.
 *
 * `signup-grant.ts` is server-only because it holds the service-role client.
 * These two values are pure data about the grant and nothing else, and keeping
 * them here means the property everything rests on — that the key is a pure
 * function of the user id — is unit-testable without a database or a server
 * runtime. See `tests/unit/credits/signup-grant-key.test.ts`.
 */

/** AC10.6. A quantity, not a price — no currency is involved in a credit. */
export const SIGNUP_GRANT_CREDITS = 5;

/**
 * Deterministic and versioned. Every call for a given user presents the same
 * key, so T07's idempotency check replays the recorded ledger row instead of
 * writing a second one — which is what makes the grant safe to retry from the
 * sign-up action, the app layout, or both at once.
 */
export function signupGrantIdempotencyKey(userId: string): string {
  return `signup_grant:v1:${userId}`;
}
