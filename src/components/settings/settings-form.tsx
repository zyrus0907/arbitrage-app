'use client';

import { useActionState, useState } from 'react';

import { deleteOwnAccount, saveSettings } from '@/app/(app)/settings/actions';
import { fromMinorUnits, toMinorUnitsOrNull } from '@/components/onboarding/minor-units';
import { initialSettingsState } from '@/lib/forms/state';
import { SubmitButton } from '@/components/auth/credentials-form';
import { messages } from '@/messages/en';
import type { Profile } from '@/services/profile';
import { Constants } from '@/types/database';

/**
 * Settings (AC2.4) and the account-deletion control (AC1.5).
 *
 * The form posts only the fields T06's column-level UPDATE grant permits. It
 * has no input for `credit_balance` — not disabled, absent — and the balance is
 * rendered as read-only text. A user who crafts the request by hand is refused
 * by the grant with `42501` before the row is even read; the absence here is
 * the honest interface, not the enforcement.
 */
export function SettingsForm({
  profile,
  currency,
  exponent,
}: {
  profile: Profile;
  currency: string;
  exponent: number;
}) {
  const [state, formAction] = useActionState(saveSettings, initialSettingsState);

  return (
    <form action={formAction} className="flex flex-col gap-6" noValidate>
      <p className="text-sm">
        <span className="opacity-70">{messages.settings.creditsLabel}: </span>
        <span className="font-medium">{profile.credit_balance}</span>
      </p>

      <label className="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          name="tax_registered"
          defaultChecked={profile.tax_registered}
        />
        {messages.onboarding.steps.tax.registeredLabel}
      </label>

      <div className="flex flex-col gap-1.5">
        <label htmlFor="tax_scheme" className="text-sm font-medium">
          {messages.onboarding.steps.tax.schemeLabel}
        </label>
        <select
          id="tax_scheme"
          name="tax_scheme"
          defaultValue={profile.tax_scheme}
          className="rounded-md border border-black/15 bg-transparent px-3 py-2 text-base dark:border-white/20"
        >
          {Constants.public.Enums.tax_scheme.map((scheme) => (
            <option key={scheme} value={scheme}>
              {messages.onboarding.taxSchemeOptions[scheme]}
            </option>
          ))}
        </select>
      </div>

      <div className="flex flex-col gap-1.5">
        <label htmlFor="default_fulfilment" className="text-sm font-medium">
          {messages.onboarding.steps.fulfilment.label}
        </label>
        <select
          id="default_fulfilment"
          name="default_fulfilment"
          defaultValue={profile.default_fulfilment}
          className="rounded-md border border-black/15 bg-transparent px-3 py-2 text-base dark:border-white/20"
        >
          {Constants.public.Enums.fulfilment_type.map((option) => (
            <option key={option} value={option}>
              {messages.onboarding.fulfilmentOptions[option]}
            </option>
          ))}
        </select>
      </div>

      <MoneyInput
        name="default_budget_minor"
        label={messages.onboarding.steps.budget.legend}
        minor={profile.default_budget_minor}
        currency={currency}
        exponent={exponent}
      />
      <MoneyInput
        name="prep_cost_per_unit_minor"
        label={messages.onboarding.steps.prep.legend}
        minor={profile.prep_cost_per_unit_minor}
        currency={currency}
        exponent={exponent}
      />
      <MoneyInput
        name="inbound_shipping_per_unit_minor"
        label={messages.onboarding.steps.shipping.legend}
        minor={profile.inbound_shipping_per_unit_minor}
        currency={currency}
        exponent={exponent}
      />

      {state.error ? (
        <p role="alert" className="rounded-md border border-red-500/40 bg-red-500/5 px-3 py-2 text-sm">
          {state.error}
        </p>
      ) : null}
      {state.saved ? (
        <p role="status" className="text-sm opacity-70">
          {messages.settings.saved}
        </p>
      ) : null}

      <SubmitButton label={messages.settings.save} submittingLabel={messages.settings.saving} />
    </form>
  );
}

/** Same exponent-driven conversion as onboarding — never an assumed ×100. */
function MoneyInput({
  name,
  label,
  minor,
  currency,
  exponent,
}: {
  name: string;
  label: string;
  minor: number | null;
  currency: string;
  exponent: number;
}) {
  const [display, setDisplay] = useState(fromMinorUnits(minor, exponent));
  const step = exponent === 0 ? '1' : `0.${'0'.repeat(Math.max(exponent - 1, 0))}1`;
  const parsed = toMinorUnitsOrNull(display, exponent);

  return (
    <div className="flex flex-col gap-1.5">
      <label htmlFor={name} className="text-sm font-medium">
        {label}
      </label>
      <div className="flex items-center gap-2">
        <input
          id={name}
          type="number"
          inputMode="decimal"
          min="0"
          step={step}
          value={display}
          onChange={(event) => setDisplay(event.target.value)}
          className="w-40 rounded-md border border-black/15 bg-transparent px-3 py-2 text-base dark:border-white/20"
        />
        <span className="text-sm opacity-70">{currency}</span>
      </div>
      <input
        type="hidden"
        name={name}
        value={parsed === null ? '' : Number.isFinite(parsed) ? String(parsed) : ''}
      />
    </div>
  );
}

/**
 * The deletion control, separated from the settings form because a nested form
 * is invalid HTML and because these two actions must never share a submit.
 */
export function DeleteAccountForm() {
  const [state, formAction] = useActionState(deleteOwnAccount, initialSettingsState);
  const [confirm, setConfirm] = useState('');
  const armed = confirm === messages.settings.dangerZone.confirmWord;

  return (
    <form
      action={formAction}
      className="mt-12 flex flex-col gap-3 rounded-md border border-red-500/30 p-4"
      noValidate
    >
      <h2 className="text-sm font-semibold">{messages.settings.dangerZone.title}</h2>
      <p className="text-sm opacity-70">{messages.settings.dangerZone.body}</p>
      {/* AC1.6 requires the retention to be stated plainly, in the place the
          user is deciding — not only in a privacy policy they will not open. */}
      <p className="text-xs opacity-70">{messages.settings.dangerZone.retained}</p>

      <label htmlFor="confirm" className="mt-2 text-sm font-medium">
        {messages.settings.dangerZone.confirmLabel}
      </label>
      <input
        id="confirm"
        name="confirm"
        value={confirm}
        onChange={(event) => setConfirm(event.target.value)}
        autoComplete="off"
        className="w-48 rounded-md border border-black/15 bg-transparent px-3 py-2 text-base dark:border-white/20"
      />

      {state.error ? (
        <p role="alert" className="text-sm">
          {state.error}
        </p>
      ) : null}

      <button
        type="submit"
        disabled={!armed}
        className="w-fit rounded-md border border-red-500/50 px-3 py-2 text-sm font-medium disabled:opacity-50"
      >
        {messages.settings.dangerZone.submit}
      </button>
    </form>
  );
}
