-- Enumerating one account's private Storage objects, so `delete-account` can remove them.
--
-- Deleting a row from `auth.users` cascades through every table that references it — all ten of the
-- user-owned tables in this schema declare `on delete cascade`, and so do the eight `auth` tables
-- Supabase ships. Storage is the one thing that is *not* in that graph: `storage.objects` has no
-- foreign key to `auth.users` at all. Deleting the account therefore leaves every object row in
-- place and the bytes behind them in the object store — private reference photos, journal covers and
-- generated storyboards belonging to someone who asked to be forgotten, and now attached to no
-- account that any dashboard can show. `delete-account` removes them explicitly, before it removes
-- the user, and this function is how it finds them.
--
-- Enumeration is SQL's half of that job and deletion is the Storage API's half, for a reason worth
-- stating: a `delete from storage.objects` drops the index entry and orphans the payload, so the
-- bytes have to go through the API that removes both. But the API's `list` is per-directory and
-- paginated, and these paths nest as `<uid>/entries/<entry-id>/<file>` — walking an account with a
-- few hundred entries would take a few hundred round trips, each one a chance to half-finish. This
-- is one query.
--
-- The bucket list is here rather than in the Edge Function so that "which buckets hold user files"
-- is stated once, in the same place as the policies that define what owning a file means: the first
-- path segment is the owner's uid.

create or replace function public.user_storage_object_names(account uuid)
returns table (bucket_id text, name text)
language sql
stable
security definer
set search_path = ''
as $$
    select o.bucket_id, o.name
    from storage.objects as o
    where o.bucket_id in (
            'journaltopia-media',
            'generated-storyboards',
            'journal-covers',
            -- Drained into `journaltopia-media` by 20260819000000, which could not always remove the
            -- empty bucket itself. Swept anyway: on a project where that migration half-applied this
            -- is the difference between deleting a user's photos and leaving them, and on every
            -- other project it matches nothing and costs nothing.
            'storytopia-media'
        )
      -- Both halves are the same predicate. `like` is the one the planner can answer from
      -- `name_prefix_search`; `path_tokens[1]` is the one that is literally the storage policy, so a
      -- name that merely starts with the uid — `<uid>-other/file` — cannot slip through.
      and o.name like account::text || '/%'
      and o.path_tokens[1] = account::text
$$;

comment on function public.user_storage_object_names(uuid) is
    'Every private Storage object owned by one account, by bucket and name. For account deletion; service role only.';

-- Nobody but the server. The function reads `storage.objects` as its definer and so ignores the
-- policies that would otherwise confine a caller to their own prefix — which is exactly why it must
-- never be reachable by `authenticated`, where it would become a way to enumerate anyone's files.
revoke all on function public.user_storage_object_names(uuid) from public, anon, authenticated;
grant execute on function public.user_storage_object_names(uuid) to service_role;
