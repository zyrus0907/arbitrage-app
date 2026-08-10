-- T03 — Functions in `public` are owner-only by default.
--
-- Closes the last local↔remote privilege divergence.
-- 20260810033236_normalise_privileges.sql revoked function privileges from
-- PUBLIC, anon and authenticated but not from service_role, and the two
-- environments had started from different places:
--
--                                     local                  hosted dev
--   handle_new_user / set_updated_at  {postgres=X}           + GRANT ALL to service_role
--   default privs on FUNCTIONS        {postgres=X}           + GRANT ALL to service_role
--
-- Nothing was reachable by anon or authenticated in either place, so this was
-- never an exposure. It was a reproducibility defect: a function created in T07
-- would be executable by the service role automatically on the hosted project
-- and not locally, which is the same "passes in one environment" failure mode
-- that migration was written to remove.
--
-- The direction chosen is owner-only. A function in `public` grants EXECUTE to
-- nobody but its owner until a migration says otherwise. T07's spend_credits
-- and grant_credits then carry their own explicit
-- `grant execute ... to service_role`, which is what that task's acceptance
-- criteria ask for in any case ("callable only by the service role"). The safe
-- state is the default; access is the deliberate act, written next to the
-- function that needs it.
--
-- This migration alters no table, column, constraint, index, trigger, policy,
-- RLS setting or row. It changes function privileges only.

-- ---------------------------------------------------------------------------
-- 1. The two existing trigger functions
-- ---------------------------------------------------------------------------
--
-- Safe for the triggers themselves: PostgreSQL checks EXECUTE on a trigger
-- function when the trigger is CREATED, not when it fires. Verified against a
-- probe table, and asserted permanently in
-- supabase/tests/database/privileges.test.sql, which fires both triggers from
-- roles holding no EXECUTE at all.

revoke all on function public.handle_new_user() from service_role;
revoke all on function public.set_updated_at()  from service_role;

-- ---------------------------------------------------------------------------
-- 2. Default privileges for future functions
-- ---------------------------------------------------------------------------
--
-- PUBLIC, anon and authenticated were already revoked by 20260810033236;
-- restating them here makes this migration the single place the intended
-- end state can be read, and re-running a revoke is a no-op.

alter default privileges for role postgres in schema public
  revoke all on functions from public, anon, authenticated, service_role;
