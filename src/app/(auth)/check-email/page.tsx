import Link from 'next/link';

import { SIGN_IN_PATH } from '@/lib/auth/routes';
import { messages } from '@/messages/en';

/**
 * Shown after sign-up and after requesting a magic link.
 *
 * The copy says "if that address can be used" rather than "we have sent an
 * email", for the same non-enumeration reason the sign-in error is generic:
 * this page is reachable by anyone who can type an address, and it must not
 * confirm whether that address has an account.
 */
export default function CheckEmailPage() {
  return (
    <>
      <h1 className="text-2xl font-semibold tracking-tight">{messages.auth.checkEmail.title}</h1>
      <p className="mt-2 text-sm opacity-70">{messages.auth.checkEmail.body}</p>
      <Link className="mt-6 text-sm underline" href={SIGN_IN_PATH}>
        {messages.auth.checkEmail.back}
      </Link>
    </>
  );
}
