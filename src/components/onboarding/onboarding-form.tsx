'use client';

import { useActionState, useMemo, useState } from 'react';

import { completeOnboarding } from '@/app/(app)/onboarding/actions';
import { toMinorUnits } from '@/components/onboarding/minor-units';
import { initialOnboardingState } from '@/lib/forms/state';
import { SubmitButton } from '@/components/auth/credentials-form';
import { messages } from '@/messages/en';
import type { SelectableCountry, SelectableMarket } from '@/services/profile';
import { Constants } from '@/types/database';

/**
 * Onboarding, in the order AC2.1 fixes: country/market → tax registration →
 * fulfilment → budget → prep cost per unit → inbound shipping per unit.
 *
 * ONE SCREEN, NOT SIX. AC2.5 gives the whole flow 60 seconds on a mid-range
 * Android phone for a user accepting defaults. A six-step wizard spends most of
 * that budget on navigation and re-render; a single form with sensible defaults
 * is one scroll and one tap. The *order* the criterion specifies is preserved
 * as the visual and tab order, which is what the ordering is for — the tax
 * answer changes how the money questions should be read.
 *
 * NO CURRENCY OR EXPONENT IS HARD-CODED (AC2.6). The money inputs convert what
 * the user types into integer minor units using `minor_unit_exponent` from the
 * resolved market's currency row. For GBP that is 2; for JPY it is 0 and the
 * input accepts no decimals at all. The conversion is here, in the one place
 * that has the exponent to hand, and the server re-validates the result as a
 * non-negative integer.
 */
export function OnboardingForm({
  countries,
  markets,
}: {
  countries: SelectableCountry[];
  markets: SelectableMarket[];
}) {
  const [state, formAction] = useActionState(completeOnboarding, initialOnboardingState);
  const [countryCode, setCountryCode] = useState(countries[0]?.code ?? '');
  const [taxRegistered, setTaxRegistered] = useState(false);

  const market = useMemo(
    () => markets.find((m) => m.countryCode === countryCode) ?? null,
    [markets, countryCode],
  );

  const exponent = market?.currencyMinorUnitExponent ?? 0;
  const currency = market?.currency ?? '';

  return (
    <form action={formAction} className="flex flex-col gap-8" noValidate>
      <fieldset className="flex flex-col gap-2">
        <legend className="text-sm font-semibold">
          {messages.onboarding.steps.market.legend}
        </legend>
        <p className="text-xs opacity-70">{messages.onboarding.steps.market.hint}</p>
        <label htmlFor="country_code" className="sr-only">
          {messages.onboarding.steps.market.countryLabel}
        </label>
        <select
          id="country_code"
          name="country_code"
          required
          value={countryCode}
          onChange={(event) => setCountryCode(event.target.value)}
          className="rounded-md border border-black/15 bg-transparent px-3 py-2 text-base dark:border-white/20"
        >
          {countries.map((country) => (
            <option key={country.code} value={country.code}>
              {country.name}
            </option>
          ))}
        </select>

        {market ? (
          <p className="text-xs opacity-70">
            {market.slug} · {market.currency}
          </p>
        ) : (
          // Not an error state. The submit path routes this to the waitlist.
          <p className="rounded-md border border-black/15 px-3 py-2 text-xs dark:border-white/20">
            {messages.onboarding.noMarket.body}
          </p>
        )}
      </fieldset>

      <fieldset className="flex flex-col gap-2">
        <legend className="text-sm font-semibold">{messages.onboarding.steps.tax.legend}</legend>
        <label className="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            name="tax_registered"
            checked={taxRegistered}
            onChange={(event) => setTaxRegistered(event.target.checked)}
          />
          {messages.onboarding.steps.tax.registeredLabel}
        </label>
        {/* AC2.3: the conservative default is stated, with its consequence. */}
        <p className="text-xs opacity-70">{messages.onboarding.steps.tax.hint}</p>

        <label htmlFor="tax_scheme" className="mt-2 text-sm font-medium">
          {messages.onboarding.steps.tax.schemeLabel}
        </label>
        <select
          id="tax_scheme"
          name="tax_scheme"
          defaultValue="standard"
          className="rounded-md border border-black/15 bg-transparent px-3 py-2 text-base dark:border-white/20"
        >
          {Constants.public.Enums.tax_scheme.map((scheme) => (
            <option key={scheme} value={scheme}>
              {messages.onboarding.taxSchemeOptions[scheme]}
            </option>
          ))}
        </select>
      </fieldset>

      <fieldset className="flex flex-col gap-2">
        <legend className="text-sm font-semibold">
          {messages.onboarding.steps.fulfilment.legend}
        </legend>
        <label htmlFor="default_fulfilment" className="sr-only">
          {messages.onboarding.steps.fulfilment.label}
        </label>
        <select
          id="default_fulfilment"
          name="default_fulfilment"
          defaultValue="marketplace_fulfilled"
          className="rounded-md border border-black/15 bg-transparent px-3 py-2 text-base dark:border-white/20"
        >
          {Constants.public.Enums.fulfilment_type.map((option) => (
            <option key={option} value={option}>
              {messages.onboarding.fulfilmentOptions[option]}
            </option>
          ))}
        </select>
      </fieldset>

      <MoneyField
        name="default_budget_minor"
        legend={messages.onboarding.steps.budget.legend}
        hint={messages.onboarding.steps.budget.hint}
        currency={currency}
        exponent={exponent}
      />
      <MoneyField
        name="prep_cost_per_unit_minor"
        legend={messages.onboarding.steps.prep.legend}
        hint={messages.onboarding.steps.prep.hint}
        currency={currency}
        exponent={exponent}
      />
      <MoneyField
        name="inbound_shipping_per_unit_minor"
        legend={messages.onboarding.steps.shipping.legend}
        hint={messages.onboarding.steps.shipping.hint}
        currency={currency}
        exponent={exponent}
      />

      {state.error ? (
        <p role="alert" className="rounded-md border border-red-500/40 bg-red-500/5 px-3 py-2 text-sm">
          {state.error}
        </p>
      ) : null}

      <SubmitButton
        label={market ? messages.onboarding.submit : messages.onboarding.noMarket.submit}
        submittingLabel={messages.onboarding.submitting}
      />
    </form>
  );
}

/**
 * A money input that submits integer minor units.
 *
 * The visible input is `inputMode="decimal"` so a phone shows a numeric keypad;
 * the value posted is the hidden integer. `step` is derived from the exponent
 * rather than fixed at `0.01`, so a zero-exponent currency rejects a decimal
 * point at the browser layer as well as at the schema.
 */
function MoneyField({
  name,
  legend,
  hint,
  currency,
  exponent,
}: {
  name: string;
  legend: string;
  hint: string;
  currency: string;
  exponent: number;
}) {
  const [display, setDisplay] = useState('');

  const minor = toMinorUnits(display, exponent);
  const step = exponent === 0 ? '1' : `0.${'0'.repeat(exponent - 1)}1`;

  return (
    <fieldset className="flex flex-col gap-2">
      <legend className="text-sm font-semibold">{legend}</legend>
      <p className="text-xs opacity-70">{hint}</p>
      <div className="flex items-center gap-2">
        <input
          id={name}
          type="number"
          inputMode="decimal"
          min="0"
          step={step}
          value={display}
          onChange={(event) => setDisplay(event.target.value)}
          aria-label={legend}
          className="w-40 rounded-md border border-black/15 bg-transparent px-3 py-2 text-base dark:border-white/20"
        />
        {/* The code, not a symbol: a symbol is locale presentation and belongs
            to the formatter T12 brings, not to an input. */}
        <span className="text-sm opacity-70">{currency}</span>
      </div>
      <input type="hidden" name={name} value={Number.isFinite(minor) ? String(minor) : ''} />
    </fieldset>
  );
}
