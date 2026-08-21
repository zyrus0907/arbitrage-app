/**
 * Profile and onboarding business logic (T10, F2, AC2.1–AC2.3, AC2.6).
 *
 * Follows the `services/` rules: no React, no `next/*`, IO at the edges. Every
 * function is handed a Supabase client rather than constructing one, which is
 * what lets the route handlers, the Server Actions and the integration tests
 * all drive the same code with different identities.
 *
 * **The writes here deliberately use the CALLER'S client, not the admin
 * client.** A profile update performed with the service-role key would bypass
 * RLS, and then "updates only the caller's own row" would be a property of this
 * file rather than of the database. Going through the anon+session client means
 * T06's `profiles_update_own` policy and its `with check (id = auth.uid())` are
 * the thing actually enforcing it, and the `credit_balance` column grant is the
 * thing actually refusing a balance edit — both tested at the integration layer
 * against a real JWT rather than asserted here.
 *
 * NOTHING IN THIS FILE HARD-CODES THE LAUNCH MARKET. GB / `amazon_uk` / GBP is
 * one row in `markets` (ADR-0015). Country, market, currency and tax regime are
 * resolved from data on every call, so opening a second market is a seed change
 * and not an edit here — which is the global-first claim in §0.3, kept honest.
 */
import type { SupabaseClient } from '@supabase/supabase-js';

import type { OnboardingInput, ProfilePatch } from '@/lib/validation/profile';
import type { Database, Tables } from '@/types/database';

export type Client = SupabaseClient<Database>;
export type Profile = Tables<'profiles'>;

/** A market the user may select, with everything the UI needs to render it. */
export type SelectableMarket = {
  id: string;
  slug: string;
  countryCode: string;
  currency: string;
  /** ISO 4217 exponent. The UI needs this to turn "12.50" into 1250 (AC2.6). */
  currencyMinorUnitExponent: number;
  countryName: string;
  countryLocale: string;
  countryTimezone: string;
  taxRegime: Database['public']['Enums']['tax_regime'];
};

export type ProfileServiceError =
  | { kind: 'not_found' }
  | { kind: 'forbidden'; message: string }
  | { kind: 'invalid'; message: string; field?: string }
  | { kind: 'io'; message: string };

export type Result<T> = { ok: true; data: T } | { ok: false; error: ProfileServiceError };

/**
 * The markets a user may actually choose.
 *
 * Read with the caller's own client on purpose: T06 already restricts the
 * `markets` public-read policy to `active = true AND launch_status = 'live'`
 * (ADR-0013), so the permitted set is defined once, in the database, and this
 * function cannot widen it by forgetting a filter. A market absent from this
 * list is a market the caller has no way to see and no way to select.
 */
export async function listSelectableMarkets(client: Client): Promise<Result<SelectableMarket[]>> {
  const { data, error } = await client
    .from('markets')
    .select(
      'id, slug, source_country_code, currency, countries!markets_source_country_code_fkey(name, default_locale, timezone_default, tax_regime), currencies!markets_currency_fkey(minor_unit_exponent)',
    )
    .order('slug');

  if (error) return { ok: false, error: { kind: 'io', message: error.message } };

  const markets: SelectableMarket[] = [];
  for (const row of data ?? []) {
    const country = row.countries;
    const currency = row.currencies;
    // A market whose joined reference rows are unreadable is not offered rather
    // than offered half-rendered: the currency exponent is what every money
    // input on the next screen depends on.
    if (!country || !currency) continue;
    markets.push({
      id: row.id,
      slug: row.slug,
      countryCode: row.source_country_code,
      currency: row.currency,
      currencyMinorUnitExponent: currency.minor_unit_exponent,
      countryName: country.name,
      countryLocale: country.default_locale,
      countryTimezone: country.timezone_default,
      taxRegime: country.tax_regime,
    });
  }
  return { ok: true, data: markets };
}

export type SelectableCountry = {
  code: string;
  name: string;
  taxRegime: Database['public']['Enums']['tax_regime'];
  defaultCurrency: string;
};

/**
 * The countries a user may say they trade from.
 *
 * Read with the caller's client, so the permitted set is T06's `countries`
 * policy (`active = true`) and not a list maintained here. A country being
 * selectable does NOT imply a live market — that is the point: a user in an
 * active country with no live market is the waitlist case (AC2.2).
 */
export async function listSelectableCountries(client: Client): Promise<Result<SelectableCountry[]>> {
  const { data, error } = await client
    .from('countries')
    .select('code, name, tax_regime, default_currency')
    .order('name');

  if (error) return { ok: false, error: { kind: 'io', message: error.message } };

  return {
    ok: true,
    data: (data ?? []).map((row) => ({
      code: row.code,
      name: row.name,
      taxRegime: row.tax_regime,
      defaultCurrency: row.default_currency,
    })),
  };
}

/**
 * The live market for a country, or `null` when there is none.
 *
 * `null` is the waitlist signal (AC2.2, AC8.6): a user in a country we do not
 * operate in is told so, rather than shown another country's prices. That is a
 * product decision with a correctness edge — a GB fee schedule applied to a US
 * seller's costs produces a confidently wrong profit figure.
 */
export async function resolveMarketForCountry(
  client: Client,
  countryCode: string,
): Promise<Result<SelectableMarket | null>> {
  const markets = await listSelectableMarkets(client);
  if (!markets.ok) return markets;
  return { ok: true, data: markets.data.find((m) => m.countryCode === countryCode) ?? null };
}

export async function loadProfile(client: Client, userId: string): Promise<Result<Profile>> {
  const { data, error } = await client.from('profiles').select('*').eq('id', userId).maybeSingle();

  if (error) return { ok: false, error: { kind: 'io', message: error.message } };
  if (!data) return { ok: false, error: { kind: 'not_found' } };
  return { ok: true, data };
}

/** Where a signed-in user belongs right now. Drives every post-auth redirect. */
export type ProfileStage = 'deleted' | 'onboarding' | 'waitlisted' | 'ready';

export function profileStage(profile: Profile): ProfileStage {
  if (profile.deleted_at !== null) return 'deleted';
  if (profile.onboarded_at !== null) return 'ready';
  // A country chosen with no market resolved is the waitlist case: the user
  // finished the only step they can finish, and there is nothing more to ask.
  if (profile.country_code !== null && profile.default_market_id === null) return 'waitlisted';
  return 'onboarding';
}

/**
 * Persist onboarding (AC2.1).
 *
 * The market is re-resolved server-side from the list the caller may actually
 * see, and the currency is taken from that market row — never from the request
 * body. A client that posts `{ default_market_id: <some other market> }` is
 * rejected here, and would be rejected again by RLS if it tried to write
 * directly, because a market it cannot read is a market it cannot name.
 */
export async function applyOnboarding(
  client: Client,
  userId: string,
  input: OnboardingInput,
): Promise<Result<Profile>> {
  const markets = await listSelectableMarkets(client);
  if (!markets.ok) return markets;

  const market = markets.data.find((m) => m.id === input.default_market_id);
  if (!market) {
    return {
      ok: false,
      error: {
        kind: 'invalid',
        field: 'default_market_id',
        message: 'That market is not open for selection',
      },
    };
  }

  if (market.countryCode !== input.country_code) {
    return {
      ok: false,
      error: {
        kind: 'invalid',
        field: 'country_code',
        message: 'The selected market does not operate in that country',
      },
    };
  }

  const update: Database['public']['Tables']['profiles']['Update'] = {
    country_code: input.country_code,
    default_market_id: market.id,
    tax_registered: input.tax_registered,
    tax_registration_country: input.tax_registered
      ? (input.tax_registration_country ?? input.country_code)
      : null,
    tax_scheme: input.tax_scheme,
    default_fulfilment: input.default_fulfilment,
    default_budget_minor: input.default_budget_minor,
    prep_cost_per_unit_minor: input.prep_cost_per_unit_minor,
    inbound_shipping_per_unit_minor: input.inbound_shipping_per_unit_minor,
    // Resolved from the market, never accepted from the client (§11.3).
    assumption_currency: market.currency,
    locale: input.locale ?? market.countryLocale,
    timezone: input.timezone ?? market.countryTimezone,
    // `onboarded_at` is deliberately NOT written here (T11/F3,F4). It is derived
    // by `profiles_derive_onboarded_at` from the row this update produces, and
    // `authenticated` no longer holds the column-UPDATE grant — sending it would
    // be a 42501. "Onboarded" is now a fact about the row rather than a claim
    // made by whichever client happened to write it.
  };

  if (input.display_name !== undefined) update.display_name = input.display_name;

  return writeProfile(client, userId, update);
}

/**
 * Record a waitlist choice for a country with no live market (AC2.2).
 *
 * Stores the country and leaves `default_market_id` and `onboarded_at` null,
 * which `profileStage` reads back as `waitlisted`. No new table: a waitlist
 * with no notification mechanism behind it is a state, not an entity, and
 * inventing a table here would be the "future-proof object" the project's own
 * rules forbid.
 */
export async function applyWaitlist(
  client: Client,
  userId: string,
  countryCode: string,
): Promise<Result<Profile>> {
  const market = await resolveMarketForCountry(client, countryCode);
  if (!market.ok) return market;
  if (market.data) {
    return {
      ok: false,
      error: {
        kind: 'invalid',
        field: 'country_code',
        message: 'That country has a live market — complete onboarding instead',
      },
    };
  }
  return writeProfile(client, userId, { country_code: countryCode, default_market_id: null });
}

/**
 * `PATCH /api/v1/profile`.
 *
 * The schema already excludes every server-owned column, so this function's job
 * is the cross-field rule the database states as a check constraint: a money
 * value requires a currency (`profiles_assumptions_require_currency`). Checking
 * it against the MERGED row rather than the patch matters — clearing the
 * currency while leaving a stored budget in place violates the constraint even
 * though the patch mentions only one of the two.
 */
export async function updateProfile(
  client: Client,
  userId: string,
  patch: ProfilePatch,
): Promise<Result<Profile>> {
  const current = await loadProfile(client, userId);
  if (!current.ok) return current;

  const merged = { ...current.data, ...patch };
  const hasMoney =
    merged.default_budget_minor !== null ||
    merged.prep_cost_per_unit_minor !== null ||
    merged.inbound_shipping_per_unit_minor !== null;

  if (hasMoney && merged.assumption_currency === null) {
    return {
      ok: false,
      error: {
        kind: 'invalid',
        field: 'assumption_currency',
        message: 'Cost assumptions need an explicit currency',
      },
    };
  }

  if (patch.default_market_id) {
    const markets = await listSelectableMarkets(client);
    if (!markets.ok) return markets;
    if (!markets.data.some((m) => m.id === patch.default_market_id)) {
      return {
        ok: false,
        error: {
          kind: 'invalid',
          field: 'default_market_id',
          message: 'That market is not open for selection',
        },
      };
    }
  }

  // `exactOptionalPropertyTypes` distinguishes "absent" from "present and
  // undefined", and a Zod `.partial()` produces the latter. Dropping the
  // undefined keys is not a type workaround: sending `{ locale: undefined }` to
  // PostgREST would serialise as `null` and clear a column the caller never
  // mentioned.
  const update: Database['public']['Tables']['profiles']['Update'] = {};
  for (const [key, value] of Object.entries(patch)) {
    if (value !== undefined) {
      (update as Record<string, unknown>)[key] = value;
    }
  }

  return writeProfile(client, userId, update);
}

/**
 * The single write path. Every caller funnels through here so the `eq('id')`
 * filter, the RLS reliance and the error mapping exist once.
 *
 * The `.eq('id', userId)` is belt to RLS's braces. RLS is what makes a
 * cross-user write impossible; this filter is what makes it obvious to a reader
 * that no code path here was ever intended to update someone else's row.
 */
async function writeProfile(
  client: Client,
  userId: string,
  update: Database['public']['Tables']['profiles']['Update'],
): Promise<Result<Profile>> {
  const { data, error } = await client
    .from('profiles')
    .update(update)
    .eq('id', userId)
    .select('*')
    .maybeSingle();

  if (error) {
    // 42501 is PostgREST's code for both a missing privilege and an RLS
    // WITH CHECK violation (ADR-0016 decision 3), so it is reported as
    // forbidden either way rather than guessed at.
    if (error.code === '42501') {
      return { ok: false, error: { kind: 'forbidden', message: 'Not permitted' } };
    }
    return { ok: false, error: { kind: 'io', message: error.message } };
  }

  // No row came back: either the row does not exist, or the policy filtered it
  // out. Both are "not yours to write" from here.
  if (!data) return { ok: false, error: { kind: 'not_found' } };
  return { ok: true, data };
}
