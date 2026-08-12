import { requireOnboarded } from '@/lib/auth/guards';
import { messages } from '@/messages/en';

/**
 * Where an onboarded user lands (§4.3).
 *
 * **A placeholder on purpose.** The deal feed is T29's, the deal supply is
 * T19's and the redaction that makes a locked card safe to render is T21's.
 * T10 needs a destination for a completed sign-in and nothing more, so this
 * page states what it is. It shows no invented deal and no sample figure: a
 * dashboard populated with fabricated numbers is the fastest way to lose the
 * trust this product is entirely built on.
 */
export const dynamic = 'force-dynamic';

export default async function FeedPage() {
  await requireOnboarded();

  return (
    <>
      <h1 className="text-2xl font-semibold tracking-tight">
        {messages.feed.placeholderTitle}
      </h1>
      <p className="mt-2 max-w-prose text-sm opacity-70">{messages.feed.placeholderBody}</p>
    </>
  );
}
