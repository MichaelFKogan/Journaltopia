-- New accounts start with no credits.
--
-- The default of 10 came from 20260802090000, when credits were a free allowance and signing up was
-- the only way to get any. Under Storytopia+ credits arrive with a subscription period, so a signup
-- grant of 10 would be three free HD storyboards handed to every new account, and to every account
-- created after a deletion.
--
-- Existing balances are deliberately untouched. People who signed up under the old model keep what
-- they have; this changes what the *next* signup starts with. A one-time free generation, if we add
-- one, will be its own grant with its own ledger reason rather than a column default nobody can
-- audit.
--
-- handle_new_user inserts only (id, display_name, avatar_url), so the column default is what new
-- profiles pick up and there is no trigger change to make here.
alter table public.profiles
    alter column generation_credits set default 0;
