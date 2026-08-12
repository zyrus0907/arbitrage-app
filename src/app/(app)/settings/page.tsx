import { DeleteAccountForm, SettingsForm } from '@/components/settings/settings-form';
import { requireOnboarded } from '@/lib/auth/guards';
import { createClient } from '@/lib/supabase/server';
import { messages } from '@/messages/en';
import { listSelectableMarkets } from '@/services/profile';

export const dynamic = 'force-dynamic';

export default async function SettingsPage() {
  const { profile } = await requireOnboarded();

  // The currency and its exponent come from the user's market row, so the money
  // inputs render and parse against real data rather than an assumed hundredth
  // (AC2.6). A profile with no resolvable market falls back to exponent 0,
  // which shows whole units — wrong-looking rather than silently wrong.
  const supabase = await createClient();
  const markets = await listSelectableMarkets(supabase);
  const market = markets.ok
    ? markets.data.find((m) => m.id === profile.default_market_id)
    : undefined;

  return (
    <>
      <h1 className="text-2xl font-semibold tracking-tight">{messages.settings.title}</h1>
      <p className="mt-1 mb-8 text-sm opacity-70">{messages.settings.subtitle}</p>

      <SettingsForm
        profile={profile}
        currency={market?.currency ?? profile.assumption_currency ?? ''}
        exponent={market?.currencyMinorUnitExponent ?? 0}
      />

      <DeleteAccountForm />
    </>
  );
}
