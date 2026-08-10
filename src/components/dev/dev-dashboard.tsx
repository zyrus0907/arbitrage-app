import { formatCount } from '@/lib/dev-dashboard/format';
import type {
  CurrencyReference,
  DevDashboardSnapshot,
  RowCount,
  SystemStatus,
} from '@/lib/dev-dashboard/types';
import { messages } from '@/messages/en';

import { Section } from './section';
import { StatCard } from './stat-card';
import { StatusDot, StatusPill, type StatusTone } from './status-pill';

/**
 * The development dashboard.
 *
 * A pure function of its snapshot: no data access, no client boundary, no
 * environment lookup. Whatever the server put in the snapshot is what the
 * browser receives, which is what makes the security assertion in
 * `tests/unit/dev-dashboard/` a statement about the whole page.
 */
export function DevDashboard({ snapshot }: { snapshot: DevDashboardSnapshot }) {
  const { backend, counts, dealLifecycle, currencies, system } = snapshot;
  const connected = backend === 'connected';
  const copy = messages.dev;

  return (
    <main className="min-h-dvh bg-neutral-50 text-neutral-900 dark:bg-neutral-950 dark:text-neutral-100">
      <div className="mx-auto w-full max-w-5xl px-5 py-8 sm:px-8 sm:py-12">
        <header className="flex flex-col gap-4 border-b border-neutral-200 pb-6 sm:flex-row sm:items-center sm:justify-between dark:border-neutral-800">
          <div>
            <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">{copy.title}</h1>
            <div className="mt-1.5 flex items-center gap-2">
              <span className="inline-flex items-center rounded bg-indigo-50 px-1.5 py-px text-[10px] font-semibold tracking-wider uppercase text-indigo-700 ring-1 ring-indigo-100 ring-inset dark:bg-indigo-500/10 dark:text-indigo-300 dark:ring-indigo-500/20">
                {copy.badge}
              </span>
              <p className="text-sm text-neutral-500 dark:text-neutral-400">{copy.subtitle}</p>
            </div>
          </div>
          <StatusPill
            tone={connected ? 'positive' : 'warning'}
            label={connected ? copy.backend.connected : copy.backend.unavailable}
          />
        </header>

        {connected ? null : (
          <div
            role="status"
            className="mt-6 rounded-xl border border-amber-200 bg-amber-50/70 px-4 py-3 dark:border-amber-500/20 dark:bg-amber-500/5"
          >
            <p className="text-sm font-medium text-amber-900 dark:text-amber-200">
              {copy.backendError.title}
            </p>
            <p className="mt-0.5 text-xs leading-relaxed text-amber-800/80 dark:text-amber-200/70">
              {copy.backendError.body}
            </p>
          </div>
        )}

        <Section title={copy.tables.heading} description={copy.tables.description}>
          <dl className="grid grid-cols-2 gap-3 lg:grid-cols-4">
            <StatCard label={copy.tables.markets} count={counts.markets} />
            <StatCard label={copy.tables.retailers} count={counts.retailers} />
            <StatCard label={copy.tables.retailerProducts} count={counts.retailerProducts} />
            <StatCard label={copy.tables.marketplaceProducts} count={counts.marketplaceProducts} />
            <StatCard label={copy.tables.deals} count={counts.deals} />
            <StatCard label={copy.tables.creditPacks} count={counts.creditPacks} />
            <StatCard label={copy.tables.creditPurchases} count={counts.creditPurchases} />
            <StatCard label={copy.tables.profiles} count={counts.profiles} />
          </dl>
        </Section>

        <Section title={copy.lifecycle.heading} description={copy.lifecycle.description}>
          <LifecycleStrip lifecycle={dealLifecycle} />
        </Section>

        <Section title={copy.currencies.heading} description={copy.currencies.description}>
          <CurrencyTable rows={currencies} connected={connected} />
        </Section>

        <Section title={copy.system.heading} subdued>
          <SystemPanel connected={connected} system={system} />
        </Section>

        <footer className="mt-10 border-t border-neutral-200 pt-5 sm:mt-12 dark:border-neutral-800">
          <p className="text-xs leading-relaxed text-neutral-500 dark:text-neutral-400">
            {copy.footer}
          </p>
        </footer>
      </div>
    </main>
  );
}

/**
 * The three deal states as one horizontal strip rather than three cards.
 *
 * Deliberately a different shape from the table counts above: those are eight
 * independent totals, this is one column of one table split three ways, and the
 * strip says so at a glance.
 */
function LifecycleStrip({
  lifecycle,
}: {
  lifecycle: Record<'draft' | 'active' | 'retired', RowCount>;
}) {
  const copy = messages.dev.lifecycle;

  const stages: Array<{ label: string; count: RowCount; tone: StatusTone; accent: boolean }> = [
    { label: copy.draft, count: lifecycle.draft, tone: 'neutral', accent: false },
    { label: copy.active, count: lifecycle.active, tone: 'accent', accent: true },
    { label: copy.retired, count: lifecycle.retired, tone: 'neutral', accent: false },
  ];

  return (
    <dl className="flex flex-col divide-y divide-neutral-200 overflow-hidden rounded-xl border border-neutral-200 bg-white sm:flex-row sm:divide-x sm:divide-y-0 dark:divide-neutral-800 dark:border-neutral-800 dark:bg-neutral-900/40">
      {stages.map((stage) => (
        <div key={stage.label} className="flex flex-1 items-center gap-2.5 px-4 py-3">
          <StatusDot tone={stage.tone} />
          <dt className="text-xs text-neutral-500 dark:text-neutral-400">{stage.label}</dt>
          <dd
            className={`ml-auto text-base font-semibold tabular-nums ${
              stage.count === null
                ? 'text-neutral-300 dark:text-neutral-700'
                : stage.accent
                  ? 'text-indigo-600 dark:text-indigo-400'
                  : ''
            }`}
          >
            {formatCount(stage.count)}
          </dd>
        </div>
      ))}
    </dl>
  );
}

function CurrencyTable({ rows, connected }: { rows: CurrencyReference[]; connected: boolean }) {
  const copy = messages.dev.currencies;

  if (rows.length === 0) {
    // An empty result and an unread one are different facts, and the empty
    // state must not assert the first when it only knows the second.
    return (
      <div className="rounded-xl border border-dashed border-neutral-200 px-4 py-3 dark:border-neutral-800">
        <p className="text-xs text-neutral-500 dark:text-neutral-400">
          {connected ? copy.empty : copy.unavailable}
        </p>
      </div>
    );
  }

  return (
    <div className="overflow-hidden rounded-xl border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-900/40">
      <table className="w-full table-auto text-sm">
        <thead>
          <tr className="border-b border-neutral-200 bg-neutral-50/80 dark:border-neutral-800 dark:bg-neutral-900/60">
            <th
              scope="col"
              className="px-3 py-2 text-left text-[11px] font-medium tracking-wide text-neutral-500 sm:px-4 dark:text-neutral-400"
            >
              {copy.code}
            </th>
            <th
              scope="col"
              className="px-3 py-2 text-left text-[11px] font-medium tracking-wide text-neutral-500 sm:px-4 dark:text-neutral-400"
            >
              {copy.name}
            </th>
            <th
              scope="col"
              className="px-3 py-2 text-right text-[11px] font-medium tracking-wide text-neutral-500 sm:px-4 dark:text-neutral-400"
            >
              {copy.exponent}
            </th>
          </tr>
        </thead>
        <tbody className="divide-y divide-neutral-200 dark:divide-neutral-800">
          {rows.map((row) => (
            <tr key={row.code}>
              <th
                scope="row"
                className="px-3 py-2 text-left font-mono text-[13px] font-medium sm:px-4"
              >
                {row.code}
              </th>
              <td className="px-3 py-2 text-neutral-600 sm:px-4 dark:text-neutral-400">
                {row.name}
              </td>
              <td className="px-3 py-2 text-right tabular-nums sm:px-4">{row.minorUnitExponent}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function SystemPanel({ connected, system }: { connected: boolean; system: SystemStatus }) {
  const copy = messages.dev.system;

  const rows: Array<{ label: string; value: string; tone: StatusTone }> = [
    {
      label: copy.database,
      value: connected ? copy.databaseConnected : copy.databaseUnavailable,
      tone: connected ? 'positive' : 'warning',
    },
    {
      label: copy.environment,
      value: copy.environments[system.environment],
      tone: 'neutral',
    },
    {
      label: copy.types,
      value: system.databaseTypesAvailable ? copy.typesAvailable : copy.typesUnavailable,
      tone: system.databaseTypesAvailable ? 'positive' : 'warning',
    },
    {
      label: copy.credentials,
      value: system.serverCredentialsConfigured
        ? copy.credentialsConfigured
        : copy.credentialsMissing,
      tone: system.serverCredentialsConfigured ? 'positive' : 'warning',
    },
  ];

  return (
    // A hairline grid: the gap shows the container's colour, so each cell is
    // separated by exactly one pixel and no cell needs its own border.
    <dl className="grid grid-cols-2 gap-px overflow-hidden rounded-xl border border-neutral-200 bg-neutral-200 sm:grid-cols-4 dark:border-neutral-800 dark:bg-neutral-800">
      {rows.map((row) => (
        <div key={row.label} className="bg-neutral-50 px-3.5 py-2.5 dark:bg-neutral-950">
          <dt className="truncate text-[11px] text-neutral-500 dark:text-neutral-400">
            {row.label}
          </dt>
          <dd className="mt-1 flex items-center gap-1.5 text-xs font-medium text-neutral-700 dark:text-neutral-300">
            <StatusDot tone={row.tone} />
            {row.value}
          </dd>
        </div>
      ))}
    </dl>
  );
}
