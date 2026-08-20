-- Let deleting an `auth.users` row actually finish.
--
-- Every user-owned table cascades from `auth.users`, so the deletion itself is one statement. What
-- stopped it was a trigger hanging off one of those cascades:
--
--   delete auth.users
--     -> cascade deletes journal_entries
--          -> fires touch_journal_updated_at (AFTER DELETE)
--               -> UPDATE public.journals    <-- permission denied
--
-- Referential actions run as the referencing table's owner, but an ordinary trigger function runs as
-- whoever issued the statement. The Admin API issues it as `supabase_auth_admin`, which has no
-- privileges in `public` and does not need any — so the cascade reached `journals`, was refused, and
-- the whole delete rolled back. GoTrue reports that as "Database error deleting user", which is why
-- the failure looked like an auth problem rather than a trigger problem.
--
-- The same wall stands in front of deleting a user from the Supabase dashboard, and stood there
-- before `delete-account` existed.
--
-- `security definer` is the fix, and the narrow one: the function runs as its owner and so may touch
-- `journals` no matter who set off the cascade. Granting `supabase_auth_admin` write access across
-- `public` would also work and is the wrong trade — it would hand the auth service standing
-- permission over every user's content to solve a problem in one trigger.
--
-- Safe to make definer: the function reads nothing from the caller. It bumps `updated_at` on exactly
-- the journal named by the row being written, using that row's own `user_id`, and changes nothing
-- else. There is no argument here that a caller could aim somewhere it should not reach.
create or replace function public.touch_journal_updated_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if tg_op = 'DELETE' then
        update public.journals
        set updated_at = now()
        where user_id = old.user_id
          and id = old.journal_id;

        return old;
    end if;

    update public.journals
    set updated_at = now()
    where user_id = new.user_id
      and id = new.journal_id;

    return new;
end;
$$;

comment on function public.touch_journal_updated_at() is
    'Keeps journals.updated_at current when memberships change. Security definer so that a cascade from auth.users can complete.';
