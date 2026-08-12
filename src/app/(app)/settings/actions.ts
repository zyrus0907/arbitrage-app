'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';

import { requireAuth } from '@/lib/auth/guards';
import { createAdminClient } from '@/lib/supabase/admin';
import type { SettingsFormState } from '@/lib/forms/state';
import { createClient } from '@/lib/supabase/server';
import { profilePatchSchema } from '@/lib/validation/profile';
import { messages } from '@/messages/en';
import { deleteAccount } from '@/services/account/delete-account';
import { updateProfile } from '@/services/profile';


function optionalInteger(formData: FormData, name: string): number | null | undefined {
  const raw = formData.get(name);
  if (raw === null) return undefined;
  if (raw === '') return null;
  const value = Number(raw);
  return Number.isFinite(value) ? value : Number.NaN;
}

/** Settings save (AC2.4). Writes through the caller's client, so RLS decides. */
export async function saveSettings(
  _state: SettingsFormState,
  formData: FormData,
): Promise<SettingsFormState> {
  const { user } = await requireAuth();

  const parsed = profilePatchSchema.safeParse({
    tax_registered: formData.get('tax_registered') === 'on',
    tax_scheme: formData.get('tax_scheme'),
    default_fulfilment: formData.get('default_fulfilment'),
    default_budget_minor: optionalInteger(formData, 'default_budget_minor'),
    prep_cost_per_unit_minor: optionalInteger(formData, 'prep_cost_per_unit_minor'),
    inbound_shipping_per_unit_minor: optionalInteger(formData, 'inbound_shipping_per_unit_minor'),
  });

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Check your answers', saved: false };
  }

  const supabase = await createClient();
  const result = await updateProfile(supabase, user.id, parsed.data);

  if (!result.ok) {
    return {
      error: 'message' in result.error ? result.error.message : 'Could not save',
      saved: false,
    };
  }

  revalidatePath('/settings');
  return { error: null, saved: true };
}

/**
 * Account deletion (AC1.5, AC1.6, ADR-0017).
 *
 * **The subject is the session's user and nothing else.** No user id is read
 * from the form. This function runs with the service-role key — it has to, both
 * because `pseudonymise_account` is granted to `service_role` alone and because
 * removing an `auth.users` row is an admin operation — so the id it acts on is
 * the single most security-critical value in T10. Taking it from the verified
 * session is what makes "user A cannot delete user B" a property of the code
 * rather than of a validation rule someone might relax.
 *
 * The typed confirmation is not security theatre standing in for that: it is
 * there because the operation is irreversible and a misclick should not be
 * enough. The authorisation is the session.
 */
export async function deleteOwnAccount(
  _state: SettingsFormState,
  formData: FormData,
): Promise<SettingsFormState> {
  const { user } = await requireAuth();

  if (formData.get('confirm') !== messages.settings.dangerZone.confirmWord) {
    return { error: messages.settings.dangerZone.confirmLabel, saved: false };
  }

  const result = await deleteAccount(createAdminClient(), user.id);
  if (!result.ok) {
    // Retry-safe: the scrub is idempotent and the auth deletion tolerates an
    // already-absent user, so "try again" is honest advice rather than a hope.
    return { error: messages.settings.dangerZone.error, saved: false };
  }

  // Clear the cookies for the session whose user no longer exists. The token
  // would already fail `getUser()`, but leaving a dead cookie in the browser
  // makes every subsequent request do a pointless round trip to discover that.
  const supabase = await createClient();
  await supabase.auth.signOut();

  redirect('/');
}
