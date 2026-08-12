import { OnboardingForm } from '@/components/onboarding/onboarding-form';
import { requireUnonboarded } from '@/lib/auth/guards';
import { createClient } from '@/lib/supabase/server';
import { messages } from '@/messages/en';
import { listSelectableCountries, listSelectableMarkets } from '@/services/profile';

export const dynamic = 'force-dynamic';

export default async function OnboardingPage() {
  await requireUnonboarded();

  // Both lists are read with the caller's own client, so what the form can
  // offer is exactly what T06's policies permit — active countries and live
  // markets. There is no server-side widening of either set.
  const supabase = await createClient();
  const [countries, markets] = await Promise.all([
    listSelectableCountries(supabase),
    listSelectableMarkets(supabase),
  ]);

  return (
    <>
      <h1 className="text-2xl font-semibold tracking-tight">{messages.onboarding.title}</h1>
      <p className="mt-1 mb-8 text-sm opacity-70">{messages.onboarding.subtitle}</p>

      <OnboardingForm
        countries={countries.ok ? countries.data : []}
        markets={markets.ok ? markets.data : []}
      />
    </>
  );
}
