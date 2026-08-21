import { devDashboardEnabled } from '@/lib/dev-dashboard/enabled';
import { messages } from '@/messages/en';

/**
 * `/` — the development dashboard in development, a static holding page in
 * production (T11 finding F2).
 *
 * The dashboard is genuinely useful locally and stays exactly as it was. What
 * changed is that production no longer reaches it: `getDevDashboardSnapshot`
 * runs service-role aggregate queries, and this route is anonymous, so in
 * production every unauthenticated request to `/` was causing privileged reads.
 *
 * **The gate is checked before the import, and the import is dynamic for that
 * reason.** A top-level `import` would evaluate the snapshot module — and with
 * it `supabase/admin.ts` — on every production render regardless of the branch
 * taken. Gating the JSX instead of the query would have hidden the output while
 * leaving the reads in place, which is the finding rather than the fix.
 *
 * The production branch is a placeholder, not the T28 home/feed UI. It exists so
 * that `/` returns something honest while the marketing route group is unbuilt.
 *
 * A dashboard whose figures were captured at build time would be worse than no
 * dashboard, so this route is never prerendered — every request re-reads the
 * database.
 */
export const dynamic = 'force-dynamic';

export default async function HomePage() {
  if (!devDashboardEnabled()) {
    return (
      <main className="mx-auto flex min-h-screen max-w-xl flex-col justify-center gap-2 px-6">
        <h1 className="text-2xl font-semibold">{messages.app.name}</h1>
        <p className="text-sm text-neutral-500">{messages.app.tagline}</p>
      </main>
    );
  }

  const [{ DevDashboard }, { getDevDashboardSnapshot }] = await Promise.all([
    import('@/components/dev/dev-dashboard'),
    import('@/lib/dev-dashboard/snapshot'),
  ]);

  return <DevDashboard snapshot={await getDevDashboardSnapshot()} />;
}
