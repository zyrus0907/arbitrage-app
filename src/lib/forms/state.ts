/**
 * Form-state shapes shared between Server Actions and the client components
 * that drive them with `useActionState`.
 *
 * These live here rather than beside their actions because a `'use server'`
 * module may export **only async functions** — Next rejects an exported object
 * at build time, since every export of such a module becomes a callable server
 * endpoint. Types are erased and would be fine; the initial-state constants are
 * not, so both move here and the actions import the types back.
 */

export type AuthFormState = { error: string | null };
export const initialAuthFormState: AuthFormState = { error: null };

export type OnboardingFormState = { error: string | null; field?: string | undefined };
export const initialOnboardingState: OnboardingFormState = { error: null };

export type SettingsFormState = { error: string | null; saved: boolean };
export const initialSettingsState: SettingsFormState = { error: null, saved: false };
