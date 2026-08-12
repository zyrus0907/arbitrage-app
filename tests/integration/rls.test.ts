/**
 * T09 — anon-key and RLS access verification suite.
 *
 * This suite is a CI BLOCKER and may never be skipped (tests/README.md).
 *
 * ===========================================================================
 * WHAT MAKES THIS DIFFERENT FROM THE pgTAP SUITES
 * ===========================================================================
 *
 * `supabase/tests/database/*.test.sql` reach the database as the owner and use
 * `SET LOCAL ROLE` to impersonate. That proves the catalogue is correct. It does
 * NOT prove what a browser gets, because a browser does not `SET ROLE` — it
 * presents a JWT to PostgREST, which resolves the role, applies the grant layer,
 * then applies RLS with `auth.uid()` populated from the token.
 *
 * So this file holds real keys and real sessions: the anon key exactly as it is
 * shipped to the browser, and two users created through the Supabase admin auth
 * API who sign in and receive genuine tokens. Every assertion below is what an
 * attacker with that key would actually receive over HTTP.
 *
 * ===========================================================================
 * THE FAILURE-MODE RULE, AND THE TRAP THE TASK DESCRIPTION DID NOT NAME
 * ===========================================================================
 *
 * TASKS.md T09 warns that asserting "no rows" passes for the wrong reason: a
 * privilege error and an RLS-filtered empty set are different mechanisms and a
 * test must say which one it expects.
 *
 * Reconnaissance against the running stack found a second, sharper version of
 * the same trap, and it is the reason `classify()` exists:
 *
 *   PostgREST returns **42501 for BOTH** a missing grant AND an RLS WITH CHECK
 *   violation. They are only distinguishable by message:
 *
 *     no grant          → 42501 "permission denied for table X"
 *     policy refused it → 42501 "new row violates row-level security policy …"
 *
 * A suite asserting `error.code === '42501'` would therefore pass identically
 * whether the grant layer or the policy layer did the work — and would keep
 * passing on the day someone adds a grant to a table that still has a
 * restrictive policy, which is precisely the regression this file exists to
 * catch. Every negative assertion below asserts a CLASSIFIED outcome, never a
 * bare code.
 *
 * ===========================================================================
 * THIS SUITE REQUIRES A FRESHLY SEEDED DATABASE, AND CANNOT FULLY CLEAN UP
 * ===========================================================================
 *
 * Deliberately, and the reason is a feature rather than a defect. To assert that
 * user A sees only A's `credit_ledger` rows, the suite must write ledger rows
 * for A and B. `credit_ledger` is append-only at two layers (ADR-0011 decision
 * 5): the trigger refuses DELETE for **every** caller including the owner, and
 * `service_role` holds no DELETE privilege. `credit_ledger.user_id` is
 * additionally ON DELETE RESTRICT (ADR-0010), so the two test users cannot be
 * deleted either while those rows exist.
 *
 * That is exactly what those decisions promise, so the suite ASSERTS it rather
 * than working around it, and leaves the financial rows behind. Run against an
 * ephemeral database in CI, or after `npm run db:reset` locally.
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import { localStack } from './supabase-local';

// ---------------------------------------------------------------------------
// Outcome classification — the mechanism, not just the code
// ---------------------------------------------------------------------------

type Outcome =
  | { kind: 'rows'; count: number; data: Record<string, unknown>[] }
  | { kind: 'privilege-denied'; message: string }
  | { kind: 'rls-refused'; message: string }
  | { kind: 'trigger-refused'; message: string }
  | { kind: 'constraint'; code: string; message: string }
  | { kind: 'other'; code: string | null; message: string };

function classify(result: {
  data: unknown;
  error: { code?: string | null; message?: string } | null;
}): Outcome {
  const { data, error } = result;

  if (!error) {
    const rows = (Array.isArray(data) ? data : data == null ? [] : [data]) as Record<
      string,
      unknown
    >[];
    return { kind: 'rows', count: rows.length, data: rows };
  }

  const code = error.code ?? null;
  const message = error.message ?? '';

  // The grant layer refused: the query never reached RLS.
  if (code === '42501' && /permission denied/i.test(message)) {
    return { kind: 'privilege-denied', message };
  }
  // The policy layer refused a write. Same SQLSTATE, different mechanism.
  if (code === '42501' && /row-level security/i.test(message)) {
    return { kind: 'rls-refused', message };
  }
  // The repo's convention for "a trigger said no" (append-only, immutability).
  if (code === '0A000') {
    return { kind: 'trigger-refused', message };
  }
  if (code && /^23/.test(code)) {
    return { kind: 'constraint', code, message };
  }
  return { kind: 'other', code, message };
}

/** Reads as an assertion at the call site and prints the real outcome on failure. */
function expectKind(outcome: Outcome, kind: Outcome['kind']) {
  expect({ kind: outcome.kind, detail: describeOutcome(outcome) }).toEqual({
    kind,
    detail: describeOutcome(outcome),
  });
}

function describeOutcome(o: Outcome): string {
  switch (o.kind) {
    case 'rows':
      return `${o.count} row(s)`;
    case 'constraint':
      return `${o.code}: ${o.message}`;
    case 'other':
      return `${o.code ?? 'no-code'}: ${o.message}`;
    default:
      return o.message;
  }
}

// ---------------------------------------------------------------------------
// The category model — every table is in exactly one bucket
// ---------------------------------------------------------------------------
//
// The acceptance criterion is that no table escapes classification. These three
// lists are the assertion's input, and the catalogue sweep at the bottom fails
// if the live database holds a table none of them names.
//
// NOTE: TASKS.md T09's closed-table list names twelve tables and omits
// `retailers`, which is service-role-only exactly like the other twelve (no
// policy, no grant — verified in the catalogue sweep). It is included here
// because the coverage criterion, not the enumeration, is the real requirement;
// the discrepancy is reported in T09's completion note rather than papered over.

const CLOSED_TABLES = [
  'deals',
  'retailer_products',
  'marketplace_products',
  'product_matches',
  'fee_schedules',
  'tax_schedules',
  'marketplaces',
  'retailers',
  'credit_purchases',
  'api_usage_log',
  'ingestion_runs',
  'app_events',
  'stripe_webhook_events',
] as const;

const PUBLIC_REFERENCE_TABLES = [
  'countries',
  'currencies',
  'markets',
  'credit_packs',
  'credit_pack_prices',
] as const;

const USER_OWNED_TABLES = [
  'profiles',
  'credit_ledger',
  'deal_unlocks',
  'watchlist_items',
  'purchase_records',
  'barcode_lookups',
] as const;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const stack = localStack();
const RUN = Date.now();
const PASSWORD = `t9-${RUN}-not-a-real-secret`;

type Fixture = {
  id: string;
  email: string;
  client: SupabaseClient;
};

let service: SupabaseClient;
let anon: SupabaseClient;
let userA: Fixture;
let userB: Fixture;

/** Seeded ids the fixtures hang off. Resolved at runtime, never hardcoded. */
let marketId: string;
let marketplaceId: string;
let retailerId: string;
let feeScheduleId: string;
let taxScheduleId: string;
let retailerProductId: string;
let marketplaceProductId: string;
let dealId: string;

async function createUser(label: string): Promise<Fixture> {
  const email = `t09.${label}.${RUN}@example.test`;
  const { data, error } = await service.auth.admin.createUser({
    email,
    password: PASSWORD,
    email_confirm: true,
  });
  if (error) throw new Error(`could not create user ${label}: ${error.message}`);

  const client = createClient(stack.url, stack.anonKey, { auth: { persistSession: false } });
  const signIn = await client.auth.signInWithPassword({ email, password: PASSWORD });
  if (signIn.error) throw new Error(`could not sign in user ${label}: ${signIn.error.message}`);

  return { id: data.user!.id, email, client };
}

/**
 * One value from a `select … limit 1`, or a thrown error naming what was
 * missing. The column is a runtime string, so supabase-js cannot type the row —
 * the cast goes through `unknown` and the value is checked rather than asserted,
 * so a schema change surfaces here with a readable message instead of as
 * `undefined` in a foreign key three statements later.
 */
async function scalarId(
  table: string,
  column: string,
  match: Record<string, unknown>,
): Promise<string> {
  const { data, error } = await service.from(table).select(column).match(match).limit(1).single();
  if (error || !data) {
    throw new Error(`fixture setup: no ${table} row matching ${JSON.stringify(match)}`);
  }

  const value = (data as unknown as Record<string, unknown>)[column];
  if (typeof value !== 'string') {
    throw new Error(`fixture setup: ${table}.${column} was not a string`);
  }
  return value;
}

beforeAll(async () => {
  service = createClient(stack.url, stack.serviceRoleKey, { auth: { persistSession: false } });
  anon = createClient(stack.url, stack.anonKey, { auth: { persistSession: false } });

  // Everything hangs off the T08 seed. If the seed is missing, these throw with
  // a message naming the missing row rather than failing later as a null FK.
  marketId = await scalarId('markets', 'id', { slug: 'gb-amazon-uk' });
  marketplaceId = await scalarId('marketplaces', 'id', { code: 'amazon_uk' });
  retailerId = await scalarId('retailers', 'id', { market_id: marketId, slug: 'argos' });
  taxScheduleId = await scalarId('tax_schedules', 'id', {
    country_code: 'GB',
    effective_from: '2024-08-01',
  });
  feeScheduleId = await scalarId('fee_schedules', 'id', {
    marketplace_id: marketplaceId,
    version: '2026-04-17',
  });

  const rp = await service
    .from('retailer_products')
    .insert({
      retailer_id: retailerId,
      retailer_sku: `t09-sku-${RUN}`,
      title: 'T09 fixture product',
      price_minor: 1299,
      currency: 'GBP',
      price_tax_treatment: 'inclusive',
    })
    .select('id')
    .single();
  if (rp.error) throw new Error(`fixture retailer_product: ${rp.error.message}`);
  retailerProductId = rp.data.id;

  const mp = await service
    .from('marketplace_products')
    .insert({
      marketplace_id: marketplaceId,
      external_id: `T09FIX${RUN}`,
      title: 'T09 fixture listing',
      currency: 'GBP',
      provider_key: 'keepa',
    })
    .select('id')
    .single();
  if (mp.error) throw new Error(`fixture marketplace_product: ${mp.error.message}`);
  marketplaceProductId = mp.data.id;

  const deal = await service
    .from('deals')
    .insert({
      market_id: marketId,
      retailer_id: retailerId,
      marketplace_id: marketplaceId,
      retailer_product_id: retailerProductId,
      marketplace_product_id: marketplaceProductId,
      match_confidence: 0.99,
      currency: 'GBP',
      buy_price_minor: 1299,
      buy_price_tax_treatment: 'inclusive',
      sell_price_minor: 2599,
      fee_schedule_id: feeScheduleId,
      tax_schedule_id: taxScheduleId,
      net_profit_minor: 640,
      roi_bps: 4200,
      margin_bps: 2461,
      deal_score: 70,
      demand_band: 'high',
      competition_band: 'medium',
      stability_band: 'high',
      confidence_band: 'high',
      score_breakdown: {},
      calc_version: 'calc.v1',
      score_version: 'score.v1',
      inputs_snapshot: {},
    })
    .select('id')
    .single();
  if (deal.error) throw new Error(`fixture deal: ${deal.error.message}`);
  dealId = deal.data.id;

  userA = await createUser('a');
  userB = await createUser('b');

  // One row per user in every user-owned table, so "A sees A's and not B's" is
  // asserted against a real B row rather than against an empty table.
  for (const u of [userA, userB]) {
    const writes = await Promise.all([
      service.from('credit_ledger').insert({
        user_id: u.id,
        delta: 10,
        reason: 'signup_grant',
        balance_after: 10,
        idempotency_key: `t09-${RUN}-${u.id}`,
      }),
      service.from('deal_unlocks').insert({ user_id: u.id, deal_id: dealId, credits_spent: 1 }),
      service.from('watchlist_items').insert({
        user_id: u.id,
        deal_id: dealId,
        marketplace_product_id: marketplaceProductId,
      }),
      service.from('purchase_records').insert({
        user_id: u.id,
        deal_id: dealId,
        market_id: marketId,
        units: 1,
        currency: 'GBP',
        expected_profit_minor: 640,
        inputs_snapshot: {},
      }),
      service.from('barcode_lookups').insert({
        user_id: u.id,
        market_id: marketId,
        barcode_raw: `t09-${RUN}`,
      }),
    ]);
    const failed = writes.find((w) => w.error);
    if (failed?.error) throw new Error(`fixture user rows: ${failed.error.message}`);
  }
}, 120_000);

afterAll(async () => {
  if (!service) return;
  // Reverse dependency order. credit_ledger is deliberately absent: it is
  // append-only and undeletable by design, which the retention test asserts.
  for (const u of [userA, userB]) {
    if (!u) continue;
    await service.from('barcode_lookups').delete().eq('user_id', u.id);
    await service.from('purchase_records').delete().eq('user_id', u.id);
    await service.from('watchlist_items').delete().eq('user_id', u.id);
    await service.from('deal_unlocks').delete().eq('user_id', u.id);
  }
  if (dealId) await service.from('deals').delete().eq('id', dealId);
  if (marketplaceProductId) {
    await service.from('marketplace_products').delete().eq('id', marketplaceProductId);
  }
  if (retailerProductId) {
    await service.from('retailer_products').delete().eq('id', retailerProductId);
  }
}, 120_000);

// ---------------------------------------------------------------------------
// 1. Closed tables — the GRANT layer must refuse, not the policy layer
// ---------------------------------------------------------------------------

describe('anon key against service-role-only tables', () => {
  it.each(CLOSED_TABLES)(
    '%s is refused by privilege, not returned empty',
    async (table) => {
      const outcome = classify(await anon.from(table).select('*'));
      // An empty result set here is a FAILURE: it would mean a SELECT grant
      // exists on a table that is supposed to be unreachable, and the only
      // thing hiding the rows would be a policy nobody wrote.
      expectKind(outcome, 'privilege-denied');
    },
  );

  it.each(CLOSED_TABLES)('%s cannot be written by anon either', async (table) => {
    const outcome = classify(await anon.from(table).insert({}));
    expect(['privilege-denied', 'rls-refused']).toContain(outcome.kind);
    expect(outcome.kind).toBe('privilege-denied');
  });
});

describe('authenticated users against service-role-only tables', () => {
  it.each(CLOSED_TABLES)('%s is refused to a signed-in user by privilege', async (table) => {
    const outcome = classify(await userA.client.from(table).select('*'));
    expectKind(outcome, 'privilege-denied');
  });
});

// ---------------------------------------------------------------------------
// 2. Public reference tables — the POLICY layer must do the filtering
// ---------------------------------------------------------------------------

describe('anon key against public reference tables', () => {
  it.each(PUBLIC_REFERENCE_TABLES)('%s is readable — a privilege error is a failure', async (t) => {
    const outcome = classify(await anon.from(t).select('*'));
    expectKind(outcome, 'rows');
  });

  it('countries returns only the active country, and the inactive fixtures are absent', async () => {
    const outcome = classify(await anon.from('countries').select('code, active'));
    expectKind(outcome, 'rows');
    if (outcome.kind !== 'rows') return;

    expect(outcome.data.map((r) => r.code).sort()).toEqual(['GB']);
    expect(outcome.data.every((r) => r.active === true)).toBe(true);

    // Asserted against seeded inactive rows, not assumed: the seed really does
    // hold DE, US and JP, and the policy really is what hides them.
    const all = classify(await service.from('countries').select('code'));
    expect(all.kind).toBe('rows');
    if (all.kind === 'rows') {
      expect(all.data.map((r) => r.code).sort()).toEqual(['DE', 'GB', 'JP', 'US']);
    }
  });

  it('markets returns only the active, live market — planned markets stay hidden', async () => {
    const outcome = classify(await anon.from('markets').select('slug, active, launch_status'));
    expectKind(outcome, 'rows');
    if (outcome.kind !== 'rows') return;

    expect(outcome.data.map((r) => r.slug)).toEqual(['gb-amazon-uk']);
    expect(outcome.data.every((r) => r.active === true && r.launch_status === 'live')).toBe(true);

    const all = classify(await service.from('markets').select('slug'));
    if (all.kind === 'rows') {
      expect(all.data.map((r) => r.slug).sort()).toEqual(['de-amazon-de', 'gb-amazon-uk']);
    }
  });

  it('credit_packs returns the active packs', async () => {
    const outcome = classify(await anon.from('credit_packs').select('name, active'));
    expectKind(outcome, 'rows');
    if (outcome.kind !== 'rows') return;
    expect(outcome.data).toHaveLength(3);
    expect(outcome.data.every((r) => r.active === true)).toBe(true);
  });

  it('credit_pack_prices is readable but EMPTY — every seeded stripe_price_id is NULL', async () => {
    // This is the correct state until T34 backfills real Stripe Price IDs
    // (ADR-0010 decision 4). The grant exists, so this must NOT be a privilege
    // error; the policy predicate `active AND stripe_price_id IS NOT NULL` is
    // what empties it. Both halves are asserted.
    const outcome = classify(await anon.from('credit_pack_prices').select('*'));
    expectKind(outcome, 'rows');
    if (outcome.kind !== 'rows') return;
    expect(outcome.count).toBe(0);

    const all = classify(await service.from('credit_pack_prices').select('stripe_price_id, active'));
    if (all.kind === 'rows') {
      expect(all.count).toBe(6);
      expect(all.data.every((r) => r.stripe_price_id === null)).toBe(true);
      // And an inactive fixture really exists, so "inactive rows are absent" is
      // asserted against something rather than assumed.
      expect(all.data.some((r) => r.active === false)).toBe(true);
    }
  });

  it('currencies exposes every ISO row, including the 0- and 3-decimal ones', async () => {
    const outcome = classify(await anon.from('currencies').select('code, minor_unit_exponent'));
    expectKind(outcome, 'rows');
    if (outcome.kind !== 'rows') return;

    const byCode = Object.fromEntries(
      outcome.data.map((r) => [r.code as string, r.minor_unit_exponent]),
    );
    expect(byCode.JPY).toBe(0);
    expect(byCode.GBP).toBe(2);
    expect(byCode.KWD).toBe(3);
  });

  it('anon cannot write to a public reference table', async () => {
    const outcome = classify(
      await anon.from('countries').insert({
        code: 'ZZ',
        name: 'Nowhere',
        default_currency: 'GBP',
        default_locale: 'en-ZZ',
        tax_regime: 'none',
        retail_price_display: 'inclusive',
        timezone_default: 'UTC',
      }),
    );
    expectKind(outcome, 'privilege-denied');
  });
});

// ---------------------------------------------------------------------------
// 3. User-owned tables — the POLICY layer must scope rows to the caller
// ---------------------------------------------------------------------------

describe('authenticated user A against own rows', () => {
  it.each(USER_OWNED_TABLES)('%s is readable — a privilege error is a failure', async (t) => {
    const outcome = classify(await userA.client.from(t).select('*'));
    expectKind(outcome, 'rows');
  });

  it.each(USER_OWNED_TABLES)('%s returns only A rows, and B has a real row', async (table) => {
    const column = table === 'profiles' ? 'id' : 'user_id';

    const mine = classify(await userA.client.from(table).select(column));
    expectKind(mine, 'rows');
    if (mine.kind !== 'rows') return;

    expect(mine.count).toBeGreaterThan(0);
    expect(mine.data.every((r) => r[column] === userA.id)).toBe(true);
    expect(mine.data.some((r) => r[column] === userB.id)).toBe(false);

    // B's row exists — the isolation is the policy's doing, not an empty table.
    const asService = classify(await service.from(table).select(column).eq(column, userB.id));
    expect(asService.kind).toBe('rows');
    if (asService.kind === 'rows') expect(asService.count).toBeGreaterThan(0);
  });

  it('anon reaches none of the user-owned tables that hold rows', async () => {
    for (const table of USER_OWNED_TABLES) {
      const outcome = classify(await anon.from(table).select('*'));
      // profiles/credit_ledger etc. carry no anon grant at all.
      expectKind(outcome, 'privilege-denied');
    }
  });
});

// ---------------------------------------------------------------------------
// 4. The specific rejections T09 names
// ---------------------------------------------------------------------------

describe('credit_balance is not writable by its owner', () => {
  it('A can update a profile column it is granted', async () => {
    const outcome = classify(
      await userA.client
        .from('profiles')
        .update({ display_name: 'A' })
        .eq('id', userA.id)
        .select('display_name'),
    );
    expectKind(outcome, 'rows');
    if (outcome.kind === 'rows') expect(outcome.data[0]?.display_name).toBe('A');
  });

  it('A cannot update credit_balance — refused by the COLUMN grant, and the balance is unmoved', async () => {
    const before = await service
      .from('profiles')
      .select('credit_balance')
      .eq('id', userA.id)
      .single();

    const outcome = classify(
      await userA.client.from('profiles').update({ credit_balance: 999_999 }).eq('id', userA.id),
    );

    // The pairing with the passing test above is what proves this is a
    // column-level denial rather than the row being unreachable: the same role,
    // the same row, a different column, a different answer.
    expectKind(outcome, 'privilege-denied');

    const after = await service
      .from('profiles')
      .select('credit_balance')
      .eq('id', userA.id)
      .single();
    expect(after.data?.credit_balance).toBe(before.data?.credit_balance);
  });

  it('A cannot INSERT into credit_ledger', async () => {
    const outcome = classify(
      await userA.client.from('credit_ledger').insert({
        user_id: userA.id,
        delta: 1_000,
        reason: 'promo',
        balance_after: 1_000,
        idempotency_key: `t09-forge-${RUN}`,
      }),
    );
    expectKind(outcome, 'privilege-denied');
  });

  it('A cannot UPDATE or DELETE a credit_ledger row it can read', async () => {
    const update = classify(
      await userA.client.from('credit_ledger').update({ delta: 1_000 }).eq('user_id', userA.id),
    );
    expectKind(update, 'privilege-denied');

    const del = classify(await userA.client.from('credit_ledger').delete().eq('user_id', userA.id));
    expectKind(del, 'privilege-denied');
  });
});

describe('the credit RPCs are unreachable from the client', () => {
  const args = (userId: string, reason: string) => ({
    p_user: userId,
    p_amount: 1,
    p_reason: reason,
    p_ref_type: 't09',
    p_ref_id: null,
    p_idem: `t09-rpc-${RUN}-${Math.random()}`,
  });

  it('anon cannot call spend_credits or grant_credits', async () => {
    for (const [fn, reason] of [
      ['spend_credits', 'unlock_deal'],
      ['grant_credits', 'promo'],
    ] as const) {
      const outcome = classify(await anon.rpc(fn, args(userA.id, reason)));
      expectKind(outcome, 'privilege-denied');
      expect(outcome.kind === 'privilege-denied' && outcome.message).toMatch(/function/i);
    }
  });

  it('an authenticated user cannot call them for anyone, including themselves', async () => {
    for (const [fn, reason] of [
      ['spend_credits', 'unlock_deal'],
      ['grant_credits', 'promo'],
    ] as const) {
      expectKind(classify(await userA.client.rpc(fn, args(userA.id, reason))), 'privilege-denied');
      expectKind(classify(await userA.client.rpc(fn, args(userB.id, reason))), 'privilege-denied');
    }
  });
});

// ---------------------------------------------------------------------------
// 5. Writes A is allowed to make must still be scoped to A
// ---------------------------------------------------------------------------

describe('an authenticated user cannot write rows owned by someone else', () => {
  it('inserting a watchlist row as B is refused by the POLICY, not the grant', async () => {
    const outcome = classify(
      await userA.client.from('watchlist_items').insert({
        user_id: userB.id,
        deal_id: dealId,
        marketplace_product_id: marketplaceProductId,
      }),
    );
    // The distinction that matters: A *does* hold INSERT on this table, so a
    // privilege denial here would mean the grant is missing and the policy is
    // untested. The WITH CHECK predicate is what must refuse this.
    expectKind(outcome, 'rls-refused');
  });

  it('updating B\'s profile row is filtered to zero rows rather than erroring', async () => {
    const outcome = classify(
      await userA.client
        .from('profiles')
        .update({ display_name: 'taken over' })
        .eq('id', userB.id)
        .select(),
    );
    expectKind(outcome, 'rows');
    if (outcome.kind === 'rows') expect(outcome.count).toBe(0);

    const b = await service.from('profiles').select('display_name').eq('id', userB.id).single();
    expect(b.data?.display_name).not.toBe('taken over');
  });

  it('deleting B\'s watchlist row is filtered to zero rows', async () => {
    const outcome = classify(
      await userA.client.from('watchlist_items').delete().eq('user_id', userB.id).select(),
    );
    expectKind(outcome, 'rows');
    if (outcome.kind === 'rows') expect(outcome.count).toBe(0);

    const remaining = await service
      .from('watchlist_items')
      .select('id')
      .eq('user_id', userB.id);
    expect(remaining.data?.length).toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------------------
// 6. Financial retention, asserted rather than worked around
// ---------------------------------------------------------------------------

describe('financial records survive account deletion attempts (ADR-0010)', () => {
  it('a user holding credit_ledger rows cannot be deleted', async () => {
    const { error } = await service.auth.admin.deleteUser(userA.id);

    // RESCOPED IN T10 (ADR-0017), NOT DELETED — the outcome is unchanged and
    // the MECHANISM has moved, which is worth saying because this suite's whole
    // discipline is that a test must know why it passes.
    //
    // Before T10: `profiles` cascaded from `auth.users`, and credit_ledger's
    // ON DELETE RESTRICT held the profile back, so the delete failed with
    // 23503 two levels down.
    //
    // After T10: that cascade is gone, because retaining financial history
    // requires retaining the profile row the FKs point at. The refusal now
    // comes from an explicit BEFORE DELETE guard on `auth.users` that rejects
    // any account whose profile still holds personal data — which is the rule
    // the FK was always a proxy for. Without it, dropping the FK would have
    // turned this loud failure into a silent orphaned profile full of PII.
    //
    // Either way, this suite still cannot fully tear itself down, and that is
    // still the correct behaviour rather than a defect.
    expect(error).not.toBeNull();
    expect(error?.message).toMatch(/ACCOUNT_NOT_PSEUDONYMISED|not pseudonymised|Database error/i);

    const still = await service.from('credit_ledger').select('id').eq('user_id', userA.id);
    expect(still.data?.length).toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------------------
// 7. Coverage — no table may escape classification
// ---------------------------------------------------------------------------

describe('the catalogue sweep', () => {
  it('every table in public is in exactly one category', () => {
    const live = stack
      .sql(
        `select table_name from information_schema.tables
          where table_schema = 'public' and table_type = 'BASE TABLE'
          order by table_name`,
      )
      .split('\n')
      .map((s) => s.trim())
      .filter(Boolean);

    const classified = [...CLOSED_TABLES, ...PUBLIC_REFERENCE_TABLES, ...USER_OWNED_TABLES];

    // A table added between here and T44 that nobody classified is the failure
    // this assertion exists to produce. Without it the suite would silently
    // stop protecting each new table.
    expect([...live].sort()).toEqual([...classified].sort());
    expect(new Set(classified).size).toBe(classified.length);
    expect(live).toHaveLength(24);
  });

  it('RLS is enabled on every table in public', () => {
    const without = stack
      .sql(
        `select c.relname from pg_class c
           join pg_namespace n on n.oid = c.relnamespace
          where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity`,
      )
      .trim();
    expect(without).toBe('');
  });

  it('exactly the classified-open tables carry a grant to anon or authenticated', () => {
    const granted = stack
      .sql(
        `select distinct table_name from information_schema.role_table_grants
          where table_schema = 'public' and grantee in ('anon','authenticated')
          order by table_name`,
      )
      .split('\n')
      .map((s) => s.trim())
      .filter(Boolean);

    // Open tables are exactly the reference + user-owned sets. Every closed
    // table must appear nowhere in the grant catalogue — that is what makes
    // their 42501 a privilege denial rather than an accident of policy.
    expect(granted.sort()).toEqual(
      [...PUBLIC_REFERENCE_TABLES, ...USER_OWNED_TABLES].sort(),
    );
    for (const closed of CLOSED_TABLES) expect(granted).not.toContain(closed);
  });
});
