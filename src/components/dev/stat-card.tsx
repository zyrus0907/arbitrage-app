import { formatCount } from '@/lib/dev-dashboard/format';
import type { RowCount } from '@/lib/dev-dashboard/types';

/**
 * One labelled figure.
 *
 * The value is formatted here, at the render boundary, from the raw count —
 * components format, they do not compute (ARCHITECTURE.md §1.2 rule 2). A count
 * the database did not answer renders as a placeholder rather than a zero, so
 * "empty" and "unreadable" never look alike.
 */
export function StatCard({ label, count }: { label: string; count: RowCount }) {
  return (
    <div className="rounded-xl border border-neutral-200 bg-white px-4 py-3.5 dark:border-neutral-800 dark:bg-neutral-900/40">
      <dt className="truncate text-[11px] font-medium tracking-wide text-neutral-500 dark:text-neutral-400">
        {label}
      </dt>
      <dd
        className={`mt-1.5 text-3xl leading-none font-semibold tracking-tight tabular-nums ${
          count === null ? 'text-neutral-300 dark:text-neutral-700' : ''
        }`}
      >
        {formatCount(count)}
      </dd>
    </div>
  );
}
