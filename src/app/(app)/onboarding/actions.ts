'use server';

import { redirect } from 'next/navigation';

import { requireAuth } from '@/lib/auth/guards';
import { APP_HOME_PATH, WAITLIST_PATH } from '@/lib/auth/routes';
import type { OnboardingFormState } from '@/lib/forms/state';
import { createClient } from '@/lib/supabase/server';
import { onboardingSchema } from '@/lib/validation/profile';
import { applyOnboarding, applyWaitlist, resolveMarketForCountry } from '@/services/profile';


function integerField(formData: FormData, name: string): number {
  const raw = formData.get(name);
  if (raw === null || raw === '') return 0;
  const value = Number(raw);
  return Number.isFinite(value) ? value : Number.NaN;
}

/**
 * Completes onboarding (AC2.1, AC2.2).
 *
 * **The country is the only geographic input.** The market, the currency, the
 * locale and the timezone are all resolved from it server-side, against the
 * rows the caller is permitted to read — which T06 already restricts to
 * `active = true AND launch_status = 'live'`. A client cannot name a market it
 * cannot see, and nothing here needs to know that today's answer is GB /
 * `amazon_uk` / GBP: activating a second market is a seed change (ADR-0015).
 *
 * **No live market for that country is not an error.** It is the waitlist
 * (AC2.2, AC8.6): the honest answer is "we are not live here yet", never a
 * foreign market's prices, which would produce a confidently wrong profit
 * figure from the wrong fee and tax schedules.
 *
 * The money fields arrive as integer minor units, converted by the form from
 * `currencies.minor_unit_exponent` on the resolved market — the exponent is
 * data, and nothing here assumes hundredths (AC2.6). They are re-validated
 * server-side as non-negative integers.
 */
export async function completeOnboarding(
  _state: OnboardingFormState,
  formData: FormData,
): Promise<OnboardingFormState> {
  const { user } = await requireAuth();
  const supabase = await createClient();

  const countryCode = formData.get('country_code');
  if (typeof countryCode !== 'string' || !/^[A-Z]{2}$/.test(countryCode)) {
    return { error: 'Select where you are trading from', field: 'country_code' };
  }

  const market = await resolveMarketForCountry(supabase, countryCode);
  if (!market.ok) {
    return { error: 'We could not load the available markets. Try again.' };
  }

  if (!market.data) {
    const waitlisted = await applyWaitlist(supabase, user.id, countryCode);
    if (!waitlisted.ok) {
      return { error: 'message' in waitlisted.error ? waitlisted.error.message : 'Could not save' };
    }
    redirect(WAITLIST_PATH);
  }

  const parsed = onboardingSchema.safeParse({
    country_code: countryCode,
    default_market_id: market.data.id,
    tax_registered: formData.get('tax_registered') === 'on',
    tax_registration_country: formData.get('tax_registered') === 'on' ? countryCode : null,
    tax_scheme: formData.get('tax_scheme'),
    default_fulfilment: formData.get('default_fulfilment'),
    default_budget_minor: integerField(formData, 'default_budget_minor'),
    prep_cost_per_unit_minor: integerField(formData, 'prep_cost_per_unit_minor'),
    inbound_shipping_per_unit_minor: integerField(formData, 'inbound_shipping_per_unit_minor'),
  });

  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    return { error: issue?.message ?? 'Check your answers', field: issue?.path[0]?.toString() };
  }

  const result = await applyOnboarding(supabase, user.id, parsed.data);
  if (!result.ok) {
    return {
      error: 'message' in result.error ? result.error.message : 'Could not save your setup',
      field: 'field' in result.error ? result.error.field : undefined,
    };
  }

  redirect(APP_HOME_PATH);
}
