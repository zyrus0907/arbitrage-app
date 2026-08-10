/**
 * A label with a state dot. Used for the backend indicator in the header, the
 * deal lifecycle strip and each row of the system section.
 *
 * The dot is `aria-hidden` and the tone never carries meaning on its own — the
 * label always says the same thing in words.
 */
export type StatusTone = 'positive' | 'warning' | 'accent' | 'neutral';

const DOT: Record<StatusTone, string> = {
  positive: 'bg-emerald-500',
  warning: 'bg-amber-500',
  accent: 'bg-indigo-500 dark:bg-indigo-400',
  neutral: 'bg-neutral-300 dark:bg-neutral-600',
};

export function StatusDot({ tone }: { tone: StatusTone }) {
  return <span aria-hidden="true" className={`size-1.5 shrink-0 rounded-full ${DOT[tone]}`} />;
}

export function StatusPill({ tone, label }: { tone: StatusTone; label: string }) {
  return (
    <span className="inline-flex items-center gap-2 self-start rounded-full border border-neutral-200 bg-white px-2.5 py-1 text-xs font-medium whitespace-nowrap text-neutral-700 shadow-xs dark:border-neutral-800 dark:bg-neutral-900 dark:text-neutral-200">
      <StatusDot tone={tone} />
      {label}
    </span>
  );
}
