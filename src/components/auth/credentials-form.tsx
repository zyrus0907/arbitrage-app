'use client';

import { useActionState } from 'react';
import { useFormStatus } from 'react-dom';

import type { AuthFormState } from '@/lib/forms/state';
import { messages } from '@/messages/en';

/**
 * Email + password form, shared by sign-in and sign-up.
 *
 * The action is a Server Action passed in from the page, so this component
 * holds no Supabase client and no token: the credential goes straight to the
 * server in a form POST and the session comes back as an httpOnly cookie
 * (AC1.4). There is nothing here for a script on the page to read.
 *
 * The error is rendered into a `role="alert"` region tied to the fieldset by
 * `aria-describedby`, so a screen reader announces a failed sign-in rather than
 * leaving the user with a form that silently did nothing.
 */
export function CredentialsForm({
  action,
  next,
  submitLabel,
  submittingLabel,
  passwordAutoComplete,
  showPasswordHint = false,
  initialError = null,
}: {
  action: (state: AuthFormState, formData: FormData) => Promise<AuthFormState>;
  next: string;
  submitLabel: string;
  submittingLabel: string;
  passwordAutoComplete: 'current-password' | 'new-password';
  showPasswordHint?: boolean;
  initialError?: string | null;
}) {
  const [state, formAction] = useActionState(action, { error: initialError });

  return (
    <form action={formAction} className="flex flex-col gap-4" noValidate>
      <input type="hidden" name="next" value={next} />

      <div className="flex flex-col gap-1.5">
        <label htmlFor="email" className="text-sm font-medium">
          {messages.auth.fields.email}
        </label>
        <input
          id="email"
          name="email"
          type="email"
          required
          autoComplete="email"
          autoCapitalize="none"
          spellCheck={false}
          className="rounded-md border border-black/15 bg-transparent px-3 py-2 text-base outline-none focus-visible:ring-2 focus-visible:ring-current dark:border-white/20"
        />
      </div>

      <div className="flex flex-col gap-1.5">
        <label htmlFor="password" className="text-sm font-medium">
          {messages.auth.fields.password}
        </label>
        <input
          id="password"
          name="password"
          type="password"
          required
          minLength={8}
          autoComplete={passwordAutoComplete}
          aria-describedby={showPasswordHint ? 'password-hint' : undefined}
          className="rounded-md border border-black/15 bg-transparent px-3 py-2 text-base outline-none focus-visible:ring-2 focus-visible:ring-current dark:border-white/20"
        />
        {showPasswordHint ? (
          <p id="password-hint" className="text-xs opacity-70">
            {messages.auth.fields.passwordHint}
          </p>
        ) : null}
      </div>

      {state.error ? (
        <p role="alert" className="rounded-md border border-red-500/40 bg-red-500/5 px-3 py-2 text-sm">
          {state.error}
        </p>
      ) : null}

      <SubmitButton label={submitLabel} submittingLabel={submittingLabel} />
    </form>
  );
}

export function SubmitButton({
  label,
  submittingLabel,
}: {
  label: string;
  submittingLabel: string;
}) {
  // `useFormStatus` must be read by a child of the form, which is the only
  // reason this is a separate component.
  const { pending } = useFormStatus();
  return (
    <button
      type="submit"
      disabled={pending}
      className="rounded-md border border-black/20 px-3 py-2 text-sm font-medium disabled:opacity-60 dark:border-white/25"
    >
      {pending ? submittingLabel : label}
    </button>
  );
}
