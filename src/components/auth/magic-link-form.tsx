'use client';

import { useActionState } from 'react';

import { signInWithMagicLink } from '@/app/(auth)/actions';
import { messages } from '@/messages/en';

import { SubmitButton } from './credentials-form';

/** Passwordless sign-in (§6.1). Same server-only token handling as the password form. */
export function MagicLinkForm({ next }: { next: string }) {
  const [state, formAction] = useActionState(signInWithMagicLink, { error: null });

  return (
    <form action={formAction} className="flex flex-col gap-3" noValidate>
      <input type="hidden" name="next" value={next} />
      <div className="flex flex-col gap-1.5">
        <label htmlFor="magic-email" className="text-sm font-medium">
          {messages.auth.fields.email}
        </label>
        <input
          id="magic-email"
          name="email"
          type="email"
          required
          autoComplete="email"
          autoCapitalize="none"
          spellCheck={false}
          className="rounded-md border border-black/15 bg-transparent px-3 py-2 text-base outline-none focus-visible:ring-2 focus-visible:ring-current dark:border-white/20"
        />
      </div>
      {state.error ? (
        <p role="alert" className="rounded-md border border-red-500/40 bg-red-500/5 px-3 py-2 text-sm">
          {state.error}
        </p>
      ) : null}
      <SubmitButton
        label={messages.auth.signIn.magicLinkSubmit}
        submittingLabel={messages.auth.signIn.magicLinkSubmitting}
      />
    </form>
  );
}
