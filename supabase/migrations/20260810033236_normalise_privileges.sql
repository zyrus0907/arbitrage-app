-- T03 — Normalise table, function and default privileges.
--
-- Why this migration exists.
--
-- RLS is the authorisation boundary (§6.3), but RLS is only the *second* gate:
-- a role must first hold the table privilege before a policy is ever consulted.
-- After 20260810025815_schema_a.sql, that first gate differed between the local
-- stack and the hosted development project:
--
--                        local                        hosted dev
--   anon                 REFERENCES,TRIGGER,TRUNCATE  ALL
--   authenticated        REFERENCES,TRIGGER,TRUNCATE  ALL
--   service_role         REFERENCES,TRIGGER,TRUNCATE  ALL
--
-- Both environments denied anon today, but for different reasons — locally the
-- grant was absent, remotely RLS was doing the work. A test that passes for the
-- wrong reason is worse than no test, and T09's whole purpose is to prove the
-- anon key reads nothing. It has to prove it against production's privilege
-- shape, not the local stack's.
--
-- The local gap was also breaking the architecture's main data path: the
-- service role held no DML at all locally, so the admin client (§6.2) could not
-- read the tables that §6.3 designates service-role-only.
--
-- This migration makes the first gate explicit and identical in both places. It
-- changes no table, column, constraint, index or trigger, enables no policy,
-- and does not weaken RLS.

-- ---------------------------------------------------------------------------
-- 1. The eleven Schema A tables
-- ---------------------------------------------------------------------------
--
-- REVOKE ALL clears both the local residue (REFERENCES/TRIGGER/TRUNCATE/
-- MAINTAIN) and the hosted project's GRANT ALL, so the two environments land on
-- the same state rather than on the same behaviour by coincidence. It names
-- service_role too, because that role inherits the same residue from the
-- default ACL and would otherwise keep TRUNCATE, TRIGGER and REFERENCES it has
-- no use for; the GRANT below then gives it back exactly what it needs.
--
-- Nothing is granted to anon or authenticated at T03. The public-read tables
-- (countries, currencies, markets, marketplaces per §6.3) get their SELECT in
-- T06, in the same migration as the policy that governs it — a grant and its
-- policy belong together, or one of them gets forgotten.

revoke all on table
  public.currencies,
  public.countries,
  public.marketplaces,
  public.markets,
  public.tax_schedules,
  public.fee_schedules,
  public.profiles,
  public.retailers,
  public.retailer_products,
  public.marketplace_products,
  public.product_matches
from anon, authenticated, service_role;

-- The service role is the sanctioned server-side path (§6.2, §6.3). It gets the
-- four DML privileges and nothing else — no TRUNCATE, no TRIGGER, no
-- REFERENCES, which is stricter than the ALL the hosted project had.
grant select, insert, update, delete on table
  public.currencies,
  public.countries,
  public.marketplaces,
  public.markets,
  public.tax_schedules,
  public.fee_schedules,
  public.profiles,
  public.retailers,
  public.retailer_products,
  public.marketplace_products,
  public.product_matches
to service_role;

-- ---------------------------------------------------------------------------
-- 2. Trigger functions
-- ---------------------------------------------------------------------------
--
-- Neither is reachable today — calling a trigger function directly raises
-- "trigger functions can only be called as triggers" — but the hosted project
-- had granted both to anon and authenticated, and PostgreSQL's built-in default
-- grants EXECUTE to PUBLIC. Owner-only is the honest state.
--
-- This is safe for the triggers themselves: EXECUTE on a trigger function is
-- checked when the trigger is CREATED, not when it fires. Verified empirically
-- against a probe table before this migration was written. The signup trigger
-- and the eleven updated_at triggers are unaffected.

revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.set_updated_at()  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Default privileges for future objects
-- ---------------------------------------------------------------------------
--
-- Without this, the divergence returns with every new table. The hosted project
-- carries ALTER DEFAULT PRIVILEGES FOR ROLE postgres ... GRANT ALL ON TABLES TO
-- anon, so T04's `deals` and T05's `credit_ledger` would each arrive granting
-- everything to the anon role — exactly the tables §6.3 says are service-role
-- only, and the ones risk #10 (locked-deal leakage) is about.
--
-- The same applies to FUNCTIONS, and there it is sharper: T07 requires
-- spend_credits and grant_credits to be "callable only by the service role".
-- With the inherited default plus PostgreSQL's built-in PUBLIC EXECUTE, they
-- would be callable by anon unless someone remembered to revoke. After this,
-- the safe state is the default and the grant is the deliberate act.
--
-- Migrations run as `postgres` in both environments, so that is the role whose
-- defaults matter. supabase_admin's defaults are Supabase's own and are left
-- alone.

-- service_role is revoked first for the same reason as above: it inherits
-- TRUNCATE/TRIGGER/REFERENCES from the existing default, and a future table
-- should give it the same four privileges the eleven current tables do, not a
-- wider set that nothing asked for.

alter default privileges for role postgres in schema public
  revoke all on tables from public, anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  grant select, insert, update, delete on tables to service_role;

alter default privileges for role postgres in schema public
  revoke all on functions from public, anon, authenticated;

alter default privileges for role postgres in schema public
  revoke all on sequences from public, anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  grant usage, select on sequences to service_role;
