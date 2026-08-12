import Link from 'next/link';
import { redirect } from 'next/navigation';

import { signUpWithPassword } from '@/app/(auth)/actions';
import { CredentialsForm } from '@/components/auth/credentials-form';
import { safeRedirectPath } from '@/lib/auth/redirect';
import { APP_HOME_PATH, RETURN_TO_PARAM } from '@/lib/auth/routes';
import { currentUser } from '@/lib/auth/session';
import { messages } from '@/messages/en';

export const dynamic = 'force-dynamic';

export default async function SignUpPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  const rawNext = params[RETURN_TO_PARAM];
  const next = safeRedirectPath(Array.isArray(rawNext) ? rawNext[0] : rawNext, APP_HOME_PATH);

  if (await currentUser()) redirect(next);

  return (
    <>
      <h1 className="text-2xl font-semibold tracking-tight">{messages.auth.signUp.title}</h1>
      <p className="mt-1 mb-6 text-sm opacity-70">{messages.auth.signUp.subtitle}</p>

      <CredentialsForm
        action={signUpWithPassword}
        next={next}
        submitLabel={messages.auth.signUp.submit}
        submittingLabel={messages.auth.signUp.submitting}
        passwordAutoComplete="new-password"
        showPasswordHint
      />

      <p className="mt-6 text-sm opacity-70">
        {messages.auth.signUp.haveAccount}{' '}
        <Link className="underline" href={`/sign-in?${RETURN_TO_PARAM}=${encodeURIComponent(next)}`}>
          {messages.auth.signUp.signIn}
        </Link>
      </p>
    </>
  );
}
