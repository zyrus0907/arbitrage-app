/**
 * T10 — the signup grant's idempotency key (AC10.6).
 *
 * The whole "exactly one signup grant per user, no matter how many times the
 * path runs" guarantee rests on this key being a pure function of the user id.
 * If it ever picks up a timestamp, a random value or a request id, the
 * self-healing retry in `(app)/layout.tsx` silently becomes a double-grant —
 * and the ledger is append-only, so it could not be corrected by an UPDATE.
 *
 * The behavioural proof (one ledger row after repeated calls) is in the
 * integration suite; this is the property that makes it possible.
 */
import { describe, expect, it } from 'vitest';

import {
  SIGNUP_GRANT_CREDITS,
  signupGrantIdempotencyKey,
} from '@/services/credits/grant-key';

const USER_A = '11111111-1111-4111-8111-111111111111';
const USER_B = '22222222-2222-4222-8222-222222222222';

describe('signupGrantIdempotencyKey', () => {
  it('is deterministic for the same user', () => {
    expect(signupGrantIdempotencyKey(USER_A)).toBe(signupGrantIdempotencyKey(USER_A));
  });

  it('is stable across time', async () => {
    const first = signupGrantIdempotencyKey(USER_A);
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(signupGrantIdempotencyKey(USER_A)).toBe(first);
  });

  it('differs between users', () => {
    expect(signupGrantIdempotencyKey(USER_A)).not.toBe(signupGrantIdempotencyKey(USER_B));
  });

  it('contains the user id, so a collision between two users is impossible', () => {
    expect(signupGrantIdempotencyKey(USER_A)).toContain(USER_A);
  });

  it('is versioned, leaving room for a deliberate future re-grant', () => {
    expect(signupGrantIdempotencyKey(USER_A)).toMatch(/^signup_grant:v\d+:/);
  });
});

describe('SIGNUP_GRANT_CREDITS', () => {
  it('is the five credits AC10.6 promises', () => {
    expect(SIGNUP_GRANT_CREDITS).toBe(5);
  });
});
