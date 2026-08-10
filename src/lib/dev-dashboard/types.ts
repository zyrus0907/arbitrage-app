/**
 * Development dashboard — shape of the server-rendered snapshot.
 *
 * This is developer tooling, not product UI. Everything under
 * `src/lib/dev-dashboard/` and `src/components/dev/` is deletable as a unit
 * (see the READMEs in both directories).
 *
 * The snapshot is the *only* thing the browser receives: aggregate row counts,
 * public reference data, and three booleans/enums describing the environment.
 * No credential, connection string, URL or provider error text belongs in any
 * field below, and `tests/unit/dev-dashboard/` asserts that.
 */

/** The eight table counts the dashboard reports. */
export type MetricKey =
  | 'markets'
  | 'retailers'
  | 'retailerProducts'
  | 'marketplaceProducts'
  | 'deals'
  | 'creditPacks'
  | 'creditPurchases'
  | 'profiles';

/** `deals.status` — ARCHITECTURE.md §2.3, ADR-0009. Retirement is terminal. */
export type DealLifecycleKey = 'draft' | 'active' | 'retired';

/**
 * A count the database answered, or `null` when that particular read failed.
 *
 * `null` is deliberately distinct from `0`: an empty table is a fact worth
 * rendering plainly, an unanswered query is not, and conflating them would let
 * a broken read look like a clean empty state.
 */
export type RowCount = number | null;

/** One row of `currencies`, the only reference data this page reads. */
export type CurrencyReference = {
  code: string;
  minorUnitExponent: number;
  name: string;
};

/** Healthy only when a real server-side query came back without an error. */
export type BackendStatus = 'connected' | 'unavailable';

/**
 * Facts about the running application that are safe to render.
 *
 * Booleans and enum labels only — never a value read from the environment.
 */
export type SystemStatus = {
  environment: 'development' | 'test' | 'production';
  databaseTypesAvailable: boolean;
  serverCredentialsConfigured: boolean;
};

/** Everything the dashboard reads from the database. */
export type DevDashboardData = {
  backend: BackendStatus;
  counts: Record<MetricKey, RowCount>;
  dealLifecycle: Record<DealLifecycleKey, RowCount>;
  currencies: CurrencyReference[];
};

/** What the page component renders. */
export type DevDashboardSnapshot = DevDashboardData & {
  system: SystemStatus;
};
