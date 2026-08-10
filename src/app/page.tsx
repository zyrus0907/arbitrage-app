import { DevDashboard } from '@/components/dev/dev-dashboard';
import { getDevDashboardSnapshot } from '@/lib/dev-dashboard/snapshot';

/**
 * Development dashboard (interim). Replaces the T01 placeholder home page and
 * is itself replaced by the marketing landing page when `(marketing)/` lands.
 *
 * A dashboard whose figures were captured at build time would be worse than no
 * dashboard, so this route is never prerendered — every request re-reads the
 * database.
 */
export const dynamic = 'force-dynamic';

export default async function HomePage() {
  const snapshot = await getDevDashboardSnapshot();
  return <DevDashboard snapshot={snapshot} />;
}
