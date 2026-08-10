-- T05A — Temporal integrity constraints on versioned schedules.
--
-- Source of truth: docs/TASKS.md v2.3 T05A, docs/DECISIONS.md ADR-006
-- (temporal exclusion constraints), docs/ARCHITECTURE.md §2.2 (the temporal
-- convention for versioned schedules) and §1.3 (MarketContext resolves exactly
-- one schedule per key per date).
--
-- WHAT THIS FIXES
--
-- tax_schedules and fee_schedules are versioned by an effective_from /
-- effective_to pair. T03 created both with a per-row sanity check and nothing
-- preventing two rows from covering the same instant. MarketContext (T13)
-- resolves "the schedule effective for this key on this date"; with two
-- overlapping rows PostgreSQL returns whichever row the plan reaches first —
-- stable enough to pass a test suite, unstable enough to change after an
-- unrelated VACUUM. Every profit figure in that market is then systematically
-- wrong, silently, which is risk #2 and risk #3 in ARCHITECTURE.md.
--
-- Seeding discipline cannot hold this. T08 is not the only writer: T33 gives
-- the admin console versioned fee-schedule editing (AC16.4), so a human
-- eventually creates the overlap by hand. This moves the failure from silent
-- and market-wide to a rejected write at the moment the mistake is made.
--
-- ===========================================================================
-- REPRESENTATION: daterange, not tstzrange (ADR-0012)
-- ===========================================================================
--
-- ADR-006 asked this task to record which representation it chose and to use
-- the same one on both tables. It offered `tstzrange(effective_from,
-- effective_to, '[)')` or a generated range column. Neither is taken, for two
-- reasons that only become visible when you look at the columns T03 actually
-- created:
--
--   * effective_from and effective_to are `date`, not `timestamptz`. A
--     tstzrange over them would have to cast, and a cast from date to
--     timestamptz invents a timezone — midnight in whose zone? A tax rate that
--     changes on the 1st changes on the 1st everywhere the schedule applies.
--     daterange keeps the column's own resolution and adds no hidden zone.
--   * A stored range column would duplicate state that already exists in two
--     columns, needing a generated column or a trigger to stay honest, and
--     would change the generated TypeScript types for no gain. The expression
--     is derived at index time from the two columns, so it cannot disagree
--     with them.
--
-- So: `daterange(effective_from, effective_to, '[)')`, inline, identically on
-- both tables.
--
--   [from, to)   — effective_from INCLUSIVE, effective_to EXCLUSIVE.
--                  A version ending on T and its successor starting on T are
--                  ADJACENT, not overlapping. Both are accepted: that is the
--                  normal shape of a version bump and rejecting it would make
--                  the constraint unusable.
--   to IS NULL   — open-ended / current indefinitely. daterange maps a NULL
--                  bound to an UNBOUNDED upper edge, so the current row
--                  participates in overlap detection as it must. Two
--                  open-ended rows for one key overlap on [max(from), ∞) and
--                  are rejected. A NULL that dropped out of the constraint
--                  would defeat the whole task, because the current row is
--                  precisely the one most likely to be NULL-terminated.
--
-- ===========================================================================
-- WHY THE T03 CHECK CONSTRAINTS ARE VERIFIED AND NOT RE-CREATED
-- ===========================================================================
--
-- T05A's acceptance criteria call for CHECK (effective_to IS NULL OR
-- effective_to > effective_from) on both tables. T03 already created exactly
-- that, as tax_schedules_effective_range and fee_schedules_effective_range.
-- Adding a second copy would leave two constraints with one purpose, either of
-- which could be dropped without a single test going red — the same trap T06
-- names for the ledger trigger. Section 1 therefore ASSERTS them and aborts if
-- either is missing.
--
-- That assertion is load-bearing rather than tidy-minded. daterange(d, d, '[)')
-- is not an error: it is the EMPTY range, and an empty range overlaps nothing.
-- If the check constraint were ever dropped, effective_to = effective_from
-- rows would be accepted and would sit outside the exclusion constraint
-- entirely — invisible to it, and invisible to any resolution query. The check
-- is what keeps the exclusion constraint total.
--
-- ===========================================================================
-- PRIVILEGE POSTURE (global rule 8 / ADR-004)
-- ===========================================================================
--
--   anon           → nothing granted, nothing revoked. Unchanged.
--   authenticated  → nothing granted, nothing revoked. Unchanged.
--   service_role   → nothing granted, nothing revoked. It keeps exactly the
--                    four DML privileges T03 gave it on these two tables.
--   RLS            → untouched. Both tables keep RLS enabled with zero
--                    policies; §6.3 lists them as service-role-only and T06
--                    adds no policy to either.
--   tables         → none created. No column, no sequence, no function, no
--                    trigger, no view.
--
-- This migration adds two constraints and one extension. It grants nothing and
-- revokes nothing.
--
-- The one honest caveat, stated rather than glossed: creating an extension
-- installs its objects with PostgreSQL's own defaults, which include EXECUTE to
-- PUBLIC on the extension's functions. btree_gist's are GiST support functions
-- — opclass internals invoked by the index machinery, not an API — and they
-- expose no row, no column and no table. This is the same posture the three
-- extensions already in this database carry (pgcrypto, uuid-ossp, pg_net), and
-- the ALTER DEFAULT PRIVILEGES in 20260810033236_normalise_privileges.sql
-- deliberately scope to schema public, not to extensions. Revoking here would
-- single out one extension for a treatment none of its neighbours receives,
-- and would diverge from what Supabase manages in that schema. What matters
-- for default-deny is unchanged and is asserted by the tests: anon and
-- authenticated hold no TABLE privilege of any kind, here or anywhere in
-- public.
--
-- ===========================================================================
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- ===========================================================================
--
--   * No data is inserted, updated or deleted. Both tables are empty at T05A
--     (seeding is T08, which this task blocks precisely so the seed is written
--     against enforced constraints). If either table ever holds a violating
--     row, ADD CONSTRAINT validates existing data and fails loudly — there is
--     no NOT VALID anywhere below, on purpose. The correct response to that
--     failure is to fix the data deliberately, never to weaken the constraint.
--   * No supporting index is added. An EXCLUDE constraint IS a GiST index on
--     (key, range), which is the index the resolution query wants; a second
--     btree would be dead weight.
--   * No RLS policy and no grant. T06 owns policies, and neither of these
--     tables gets one.
--   * No change to the T03 unique constraints. Their consequence is recorded
--     in section 3 rather than engineered away.

-- ---------------------------------------------------------------------------
-- 1. Preconditions
-- ---------------------------------------------------------------------------
-- The exclusion constraints below are only total while these two hold. Assert
-- rather than assume, and fail the whole migration if either has gone.

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.tax_schedules'::regclass
       and conname  = 'tax_schedules_effective_range'
       and contype  = 'c')
  then
    raise exception
      'T05A precondition failed: tax_schedules_effective_range is missing. '
      'Without it, effective_to = effective_from yields an EMPTY daterange, '
      'which overlaps nothing and escapes the exclusion constraint entirely.';
  end if;

  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.fee_schedules'::regclass
       and conname  = 'fee_schedules_effective_range'
       and contype  = 'c')
  then
    raise exception
      'T05A precondition failed: fee_schedules_effective_range is missing. '
      'Without it, effective_to = effective_from yields an EMPTY daterange, '
      'which overlaps nothing and escapes the exclusion constraint entirely.';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 2. btree_gist
-- ---------------------------------------------------------------------------
-- Required, and only because of the equality half of each constraint. GiST
-- indexes ranges natively (pg_catalog's range_ops), but not the scalar `=` on
-- text and uuid that scopes the overlap to one country or one marketplace.
-- btree_gist supplies gist_text_ops and gist_uuid_ops, which is what lets a
-- single index answer "same key AND overlapping period".
--
-- Idempotent, and placed in `extensions` to match every other extension in
-- this database — Supabase's convention, and it keeps `public` for application
-- objects only.

create extension if not exists btree_gist with schema extensions;

-- ---------------------------------------------------------------------------
-- 3. tax_schedules — no two versions of one country's tax may overlap
-- ---------------------------------------------------------------------------
-- Keyed by country_code. Overlaps across DIFFERENT countries are of course
-- valid and are exactly what a global-first schema is for (§0.3): every
-- country's schedule covers the same calendar.
--
-- Note for T33's schedule editor: this table already carries
-- tax_schedules_country_effective_from_key, unique on (country_code,
-- effective_from). Two rows starting on the same day for one country are
-- therefore rejected as 23505 by that older constraint before this one is
-- consulted, while every other kind of overlap raises 23P01 here. fee_schedules
-- has no equivalent unique, so the same user mistake surfaces there as 23P01.
-- The editor must treat both codes as "this period overlaps an existing
-- version" and say so in those words, not as a 500.

alter table public.tax_schedules
  add constraint tax_schedules_no_overlapping_periods
  exclude using gist (
    country_code                                        with =,
    daterange(effective_from, effective_to, '[)')       with &&
  );

comment on constraint tax_schedules_no_overlapping_periods on public.tax_schedules is
  'ADR-006/ADR-0012: at most one tax schedule per country per date. Half-open [effective_from, effective_to); NULL effective_to is unbounded, so two open-ended rows for one country conflict. Adjacent versions (one ending where the next begins) are accepted.';

-- ---------------------------------------------------------------------------
-- 4. fee_schedules — no two versions of one marketplace's fees may overlap
-- ---------------------------------------------------------------------------
-- Keyed by marketplace_id, per §2.2: fee schedules are per MARKETPLACE, not
-- per country. Two Amazon locales are two marketplaces and their schedules
-- overlap freely.
--
-- The existing unique on (marketplace_id, version) constrains the version
-- LABEL, which is a different question from the period it covers: '2026-01'
-- and '2026-01-revised' are distinct labels and could previously cover the
-- same dates. That is the gap this closes.

alter table public.fee_schedules
  add constraint fee_schedules_no_overlapping_periods
  exclude using gist (
    marketplace_id                                      with =,
    daterange(effective_from, effective_to, '[)')       with &&
  );

comment on constraint fee_schedules_no_overlapping_periods on public.fee_schedules is
  'ADR-006/ADR-0012: at most one fee schedule per marketplace per date. Half-open [effective_from, effective_to); NULL effective_to is unbounded, so two open-ended rows for one marketplace conflict. Adjacent versions (one ending where the next begins) are accepted.';
