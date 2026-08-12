import Link from 'next/link';
import { redirect } from 'next/navigation';

import { signInWithPassword } from '@/app/(auth)/actions';
import { CredentialsForm } from '@/components/auth/credentials-form';
import { MagicLinkForm } from '@/components/auth/magic-link-form';
import { safeRedirectPath } from '@/lib/auth/redirect';
import { APP_HOME_PATH, RETURN_TO_PARAM } from '@/lib/auth/routes';
import { currentUser } from '@/lib/auth/session';
import { messages } from '@/messages/en';

export const dynamic = 'force-dynamic';

export default async function SignInPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  const rawNext = params[RETURN_TO_PARAM];

  // Validated here, at the boundary, before it is rendered into a hidden input.
  // Re-validated again in the Server Action, because a hidden input is client
  // state and nothing rendered into the page may be trusted on the way back.
  const next = safeRedirectPath(
    Array.isArray(rawNext) ? rawNext[0] : rawNext,
    APP_HOME_PATH,
  );

  // Already signed in: there is nothing to do here.
  if (await currentUser()) redirect(next);

  const linkFailed = params.error === 'link';

  return (
    <>
      <h1 className="text-2xl font-semibold tracking-tight">{messages.auth.signIn.title}</h1>
      <p className="mt-1 mb-6 text-sm opacity-70">{messages.auth.signIn.subtitle}</p>

      <CredentialsForm
        action={signInWithPassword}
        next={next}
        submitLabel={messages.auth.signIn.submit}
        submittingLabel={messages.auth.signIn.submitting}
        passwordAutoComplete="current-password"
        initialError={linkFailed ? messages.auth.errors.linkFailed : null}
      />

      <div className="my-6 border-t border-black/10 pt-6 dark:border-white/15">
        <p className="mb-3 text-sm opacity-70">{messages.auth.signIn.orMagicLink}</p>
        <MagicLinkForm next={next} />
      </div>

      <p className="text-sm opacity-70">
        {messages.auth.signIn.noAccount}{' '}
        <Link className="underline" href={`/sign-up?${RETURN_TO_PARAM}=${encodeURIComponent(next)}`}>
          {messages.auth.signIn.createOne}
        </Link>
      </p>
    </>
  );
}
