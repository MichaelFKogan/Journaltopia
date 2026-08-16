-- Makes the Data API access model explicit, so a database built from these migrations behaves the
-- same as the hosted project.
--
-- Until now not one migration granted SELECT, INSERT, UPDATE or DELETE to `anon` or `authenticated`
-- on any table. The app worked anyway because the hosted project was provisioned back when Supabase
-- auto-exposed new public tables to the Data API roles. A `supabase db reset` gets the current
-- default instead — nothing is auto-exposed — so RLS policies existed with no privilege behind them
-- and every read failed before a policy was ever consulted.
--
-- Both halves are required, and they answer different questions:
--
--     GRANT   may this role touch this table at all?
--     POLICY  which rows, of the ones it may touch?
--
-- Everything below is derived from the policies already in place rather than chosen fresh: a
-- privilege is granted here only where a policy exists to constrain it. The policies are unchanged.
--
-- Each table is revoked first and then granted, so the end state is the same whether or not the
-- project ever auto-exposed anything. The two revokes that would undo earlier security work are
-- deliberately narrowed; see the notes on profiles and entry_storyboards.

-- Users' own content ------------------------------------------------------------------------------
-- Four policies each — select, insert, update, delete, all `to authenticated` and all keyed on
-- `auth.uid() = user_id`. Full DML matches that, and RLS keeps it to the caller's own rows.
revoke all on public.entries                from anon, authenticated;
revoke all on public.entry_reference_photos from anon, authenticated;
revoke all on public.entry_characters       from anon, authenticated;
revoke all on public.journals               from anon, authenticated;
revoke all on public.journal_entries        from anon, authenticated;

grant select, insert, update, delete on public.entries                to authenticated;
grant select, insert, update, delete on public.entry_reference_photos to authenticated;
grant select, insert, update, delete on public.entry_characters       to authenticated;
grant select, insert, update, delete on public.journals               to authenticated;
grant select, insert, update, delete on public.journal_entries        to authenticated;

-- Storyboards -------------------------------------------------------------------------------------
-- INSERT and UPDATE are column-level, granted by 20260815190000 so that generation_status,
-- reserved_credits, refunded_credits and the lifecycle timestamps stay server-owned. They are left
-- out of both statements here: revoking them at table level is unnecessary (no table-level grant
-- exists to remove) and granting them back would hand over the very columns that migration took
-- away. Only the two privileges it did not restrict are settled here.
revoke select, delete, truncate, references, trigger on public.entry_storyboards from anon, authenticated;

grant select, delete on public.entry_storyboards to authenticated;

-- Profiles ----------------------------------------------------------------------------------------
-- Same shape, for the same reason: 20260816090000 replaced table-wide UPDATE with a column grant on
-- (display_name, avatar_url) so a client cannot write its own generation_credits. UPDATE is
-- therefore absent from the revoke below — a table-level revoke does not remove a column grant, but
-- naming it here would invite someone to "restore" it later — and absent from the grant.
--
-- There are only two policies on this table, select and update, so SELECT is all that is added.
-- Rows are created by the handle_new_user trigger and never deleted directly, which is why no INSERT
-- or DELETE is granted: neither has a policy, so both would be refused by RLS regardless.
revoke select, insert, delete, truncate, references, trigger on public.profiles from anon, authenticated;

grant select on public.profiles to authenticated;

-- Sample content: public reading ------------------------------------------------------------------
-- Six tables carry an "Anyone can read active sample …" policy `to anon, authenticated`. This is the
-- signed-out browsing experience, and it is the only reason `anon` needs any privilege at all.
--
-- The four detail tables reach their pack through a subquery — sample_entry_assets and
-- sample_storyboard_pages read sample_entries, sample_journal_entries reads sample_journals, and all
-- of them read sample_story_packs to check the pack is active. Policy expressions are evaluated as
-- the invoking role, so those parent tables have to be readable by the same role or the child
-- policy fails. Granting the whole set together is what keeps that consistent.
revoke all on public.sample_story_packs      from anon, authenticated;
revoke all on public.sample_entries          from anon, authenticated;
revoke all on public.sample_journals         from anon, authenticated;
revoke all on public.sample_entry_assets     from anon, authenticated;
revoke all on public.sample_journal_entries  from anon, authenticated;
revoke all on public.sample_storyboard_pages from anon, authenticated;
revoke all on public.sample_story_admins     from anon, authenticated;

grant select on public.sample_story_packs      to anon, authenticated;
grant select on public.sample_entries          to anon, authenticated;
grant select on public.sample_journals         to anon, authenticated;
grant select on public.sample_entry_assets     to anon, authenticated;
grant select on public.sample_journal_entries  to anon, authenticated;
grant select on public.sample_storyboard_pages to anon, authenticated;

-- Sample content: authoring -----------------------------------------------------------------------
-- The write policies are `to authenticated` and gated on membership of sample_story_admins, so the
-- privilege is granted to every signed-in user and the policy is what makes it an admin operation.
-- A non-admin holding INSERT here can still write nothing.
--
-- sample_story_packs gets no DELETE: it has insert, select and update policies and no delete policy,
-- so a delete would be refused by RLS anyway. Granting it would only widen the surface.
grant insert, update, delete on public.sample_entries          to authenticated;
grant insert, update, delete on public.sample_journals         to authenticated;
grant insert, update, delete on public.sample_entry_assets     to authenticated;
grant insert, update, delete on public.sample_journal_entries  to authenticated;
grant insert, update, delete on public.sample_storyboard_pages to authenticated;
grant insert, update           on public.sample_story_packs    to authenticated;

-- The admin roster itself is readable so the subqueries above can resolve, and writable by nobody:
-- it has a single select policy, and membership is granted out of band.
grant select on public.sample_story_admins to authenticated;

-- The server role ---------------------------------------------------------------------------------
-- service_role bypasses RLS but is still subject to table privileges, and it had none either. It is
-- reachable only from the server with the secret key, and it is the role the Edge Functions run
-- their background work as, so it gets ordinary DML across the schema.
--
-- Note for later: bypassing RLS is not permission to bypass the credit accounting. The storyboard
-- lifecycle deliberately moves credits only through security definer functions, and anything that
-- writes a balance in a future phase should go through an RPC for the same reason, not through a
-- direct service_role update.
grant select, insert, update, delete on all tables in schema public to service_role;

-- Anything created after this migration still needs its own grants; there is no default privilege
-- rule here on purpose. Making new tables reachable by accident is what produced the confusion this
-- migration exists to clear up, so a new table should arrive with the grants its policies imply,
-- written next to those policies.
