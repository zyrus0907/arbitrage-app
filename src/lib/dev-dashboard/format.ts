import type { RowCount } from './types';

/**
 * Development dashboard — count formatting.
 *
 * `Intl.NumberFormat`, never a hand-rolled separator (ARCHITECTURE.md §2.4).
 * The locale is pinned rather than resolved from a profile because this is
 * developer tooling with one reader; product surfaces format from the user's
 * locale and must not copy this shortcut.
 */
const countFormatter = new Intl.NumberFormat('en');

/**
 * Rendered in place of a count the database did not answer. A typographic
 * placeholder, not copy — it carries no meaning to translate.
 */
export const UNANSWERED = '—';

export function formatCount(count: RowCount): string {
  if (count === null || !Number.isFinite(count)) return UNANSWERED;
  return countFormatter.format(count);
}
