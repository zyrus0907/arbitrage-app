/**
 * A titled block of the development dashboard: small heading, optional line of
 * explanation, then content. Spacing is the only structure — no card wrapper,
 * so the cards and tables inside keep a single border weight.
 *
 * `subdued` demotes the heading for sections that are supporting detail rather
 * than the data the page exists to show.
 */
export function Section({
  title,
  description,
  subdued = false,
  children,
}: {
  title: string;
  description?: string;
  subdued?: boolean;
  children: React.ReactNode;
}) {
  return (
    <section className="mt-8 sm:mt-10">
      <div className="mb-3">
        <h2
          className={
            subdued
              ? 'text-[11px] font-medium tracking-wider uppercase text-neutral-500 dark:text-neutral-400'
              : 'text-sm font-semibold tracking-tight'
          }
        >
          {title}
        </h2>
        {description ? (
          <p className="mt-1 max-w-2xl text-xs leading-relaxed text-neutral-500 dark:text-neutral-400">
            {description}
          </p>
        ) : null}
      </div>
      {children}
    </section>
  );
}
