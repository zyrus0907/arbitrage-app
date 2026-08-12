import Link from 'next/link';

import { requireUnonboarded } from '@/lib/auth/guards';
import { ONBOARDING_PATH } from '@/lib/auth/routes';
import { messages } from '@/messages/en';

/**
 * The waitlist state (AC2.2, AC8.6).
 *
 * A user whose country has no live market sees this instead of a feed. Showing
 * them another market's deals would apply the wrong tax schedule and the wrong
 * marketplace fee schedule to their costs and produce a confidently wrong
 * profit figure — the market-wide trust failure in risk #2. An honest "not here
 * yet" is the better product and the only correct one.
 */
export const dynamic = 'force-dynamic';

export default async function WaitlistPage() {
  await requireUnonboarded();

  return (
    <>
      <h1 className="text-2xl font-semibold tracking-tight">{messages.waitlist.title}</h1>
      <p className="mt-2 max-w-prose text-sm opacity-70">{messages.waitlist.body}</p>
      <Link className="mt-6 inline-block text-sm underline" href={ONBOARDING_PATH}>
        {messages.waitlist.changeCountry}
      </Link>
    </>
  );
}
