/**
 * Profile and onboarding input schemas (T10).
 *
 * THREE RULES THIS FILE EXISTS TO ENFORCE
 *
 * 1. **Enum values come from the generated database types, never from literals
 *    typed here.** `Constants.public.Enums` in `src/types/database.ts` is
 *    regenerated from the live catalogue, so a schema change that adds or
 *    removes a `tax_scheme` value turns this file into a type error rather than
 *    into a runtime rejection of a value the database would have accepted. A
 *    hand-copied `z.enum(['standard','simplified'])` drifts silently.
 *
 * 2. **Money is an integer count of minor units with an explicit currency, and
 *    the exponent is never assumed** (§2.4, AC2.6). The schema accepts an
 *    integer and nothing else. There is no `* 100` anywhere in this file, no
 *    float tolerance and no currency symbol: converting a person's "12.50" into
 *    1250 needs `currencies.minor_unit_exponent` for the market in question,
 *    which is data, and that conversion lives in the UI helper that has the
 *    exponent to hand — not in a validator that would have to guess.
 *
 * 3. **The server-owned columns are absent, not merely rejected.** The schemas
 *    below have no `credit_balance`, `id`, `created_at`, `updated_at` or
 *    `deleted_at` field, and `.strict()` means supplying one is an error rather
 *    than a silently ignored key. This mirrors T06's column-level UPDATE grant,
 *    which is the layer that actually enforces it — a Zod schema is the polite
 *    refusal, the grant is the wall.
 *
 * Country and market identifiers are validated for SHAPE here and for
 * PERMISSIBILITY in `src/services/profile/`, against the rows the user is
 * actually allowed to use. A uuid that parses is not a market the user may
 * select, and only the database knows the difference.
 */
import { z } from 'zod';

import { Constants } from '@/types/database';

const { fulfilment_type, tax_scheme } = Constants.public.Enums;

export const taxSchemeSchema = z.enum(tax_scheme);
export const fulfilmentTypeSchema = z.enum(fulfilment_type);

/** ISO 3166-1 alpha-2, matching `countries_code_iso3166` in the database. */
export const countryCodeSchema = z
  .string()
  .regex(/^[A-Z]{2}$/, 'Country code must be two upper-case letters (ISO 3166-1 alpha-2)');

/** ISO 4217, matching `currencies_code_iso4217`. */
export const currencyCodeSchema = z
  .string()
  .regex(/^[A-Z]{3}$/, 'Currency code must be three upper-case letters (ISO 4217)');

export const marketIdSchema = z.uuid('Market id must be a uuid');

/**
 * An amount of money as the database stores it: a whole number of minor units.
 *
 * Non-negative because every money column on `profiles` is a cost or a budget
 * and `profiles_assumptions_non_negative` rejects the alternative. The upper
 * bound is not arbitrary decoration — it keeps a fat-fingered or hostile value
 * inside the range where `bigint` arithmetic downstream in `lib/money` (T12)
 * cannot overflow, and it fails at the boundary rather than in a profit
 * calculation.
 */
export const minorUnitsSchema = z
  .number()
  .int('Amount must be a whole number of minor units — no decimal point')
  .min(0, 'Amount cannot be negative')
  .max(Number.MAX_SAFE_INTEGER, 'Amount is out of range');

/**
 * BCP 47-ish. Deliberately permissive on the subtags and strict on the shape:
 * the value is a display preference, and an over-tight pattern here would
 * reject legitimate locales for markets that do not exist yet.
 */
export const localeSchema = z
  .string()
  .regex(/^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$/, 'Locale must look like `en` or `en-GB`');

/** IANA zone name. Validated against the runtime's own database, not a list. */
export const timezoneSchema = z.string().min(1).refine(
  (value) => {
    try {
      new Intl.DateTimeFormat('en', { timeZone: value });
      return true;
    } catch {
      return false;
    }
  },
  { message: 'Unknown IANA time zone' },
);

export const displayNameSchema = z.string().trim().min(1).max(80);

/**
 * `PATCH /api/v1/profile` — every field optional, but at least one present.
 *
 * The money fields and `assumption_currency` are cross-checked below because
 * `profiles_assumptions_require_currency` rejects a money value with no
 * currency at the storage layer. Catching it here turns a 500-shaped constraint
 * violation into a 400 that names the field.
 */
export const profilePatchSchema = z
  .object({
    display_name: displayNameSchema.nullable(),
    country_code: countryCodeSchema,
    default_market_id: marketIdSchema.nullable(),
    locale: localeSchema.nullable(),
    timezone: timezoneSchema.nullable(),
    tax_registered: z.boolean(),
    tax_registration_country: countryCodeSchema.nullable(),
    tax_scheme: taxSchemeSchema,
    default_fulfilment: fulfilmentTypeSchema,
    default_budget_minor: minorUnitsSchema.nullable(),
    prep_cost_per_unit_minor: minorUnitsSchema.nullable(),
    inbound_shipping_per_unit_minor: minorUnitsSchema.nullable(),
    assumption_currency: currencyCodeSchema.nullable(),
  })
  .partial()
  .strict()
  .refine((value) => Object.keys(value).length > 0, {
    message: 'No updatable fields supplied',
  });

export type ProfilePatch = z.infer<typeof profilePatchSchema>;

/**
 * Onboarding submission — the six steps of AC2.1 in order:
 * country/market → tax-registration status → fulfilment → budget →
 * prep cost per unit → inbound shipping per unit.
 *
 * It cannot be skipped (AC2.1), so unlike the PATCH schema these fields are
 * required. The currency is NOT accepted from the client: it is resolved
 * server-side from the market the user selected, because a client-supplied
 * currency is exactly the "never trust client-supplied prices, currencies,
 * market ids" case in §11.3.
 */
export const onboardingSchema = z
  .object({
    country_code: countryCodeSchema,
    default_market_id: marketIdSchema,
    tax_registered: z.boolean(),
    tax_registration_country: countryCodeSchema.nullable().optional(),
    tax_scheme: taxSchemeSchema,
    default_fulfilment: fulfilmentTypeSchema,
    default_budget_minor: minorUnitsSchema,
    prep_cost_per_unit_minor: minorUnitsSchema,
    inbound_shipping_per_unit_minor: minorUnitsSchema,
    display_name: displayNameSchema.optional(),
    locale: localeSchema.optional(),
    timezone: timezoneSchema.optional(),
  })
  .strict()
  .refine(
    (value) => value.tax_registered === false || Boolean(value.tax_registration_country),
    {
      message: 'A registration country is required when the seller is tax-registered',
      path: ['tax_registration_country'],
    },
  );

export type OnboardingInput = z.infer<typeof onboardingSchema>;

export const credentialsSchema = z.object({
  email: z.email('Enter a valid email address').max(320),
  password: z
    .string()
    .min(8, 'Use at least 8 characters')
    .max(72, 'Passwords are limited to 72 characters'),
});

export const magicLinkSchema = z.object({
  email: z.email('Enter a valid email address').max(320),
});
