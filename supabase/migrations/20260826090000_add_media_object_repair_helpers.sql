-- Repair helpers for the journaltopia-media objects broken by 20260819000000.
--
-- What is broken
-- --------------
-- 20260819000000 moved deployed state onto the Journaltopia names. Line 13:
--
--     update storage.objects
--     set bucket_id = 'journaltopia-media'
--     where bucket_id = 'storytopia-media';
--
-- This is the same mistake 20260822090000 documents and walks back for `name` in
-- sample-story-assets, applied to a second column in the same migration and missed at the time.
-- The bytes live under a key derived from `bucket_id/name/version`, so rewriting bucket_id moved
-- the row and left the payload at the old key. All 86 objects in journaltopia-media — reference
-- photos, entry preview thumbnails and character photos alike — list correctly and 404 with
-- NoSuchKey on read.
--
-- Why this cannot be fixed in SQL
-- ------------------------------
-- Walking bucket_id back the way 20260822090000 walked `name` back would make the objects readable
-- again, but only under `storytopia-media`, and unlike the sample pack there is no path column to
-- follow: SupabaseReferencePhotoService, SupabaseEntryCharacterService, SupabaseEntryThumbnailService
-- and EntrySaveService all address the bucket through a hardcoded `journaltopia-media` constant.
-- The objects have to physically end up in the new bucket, and only the Storage API can do that —
-- it copies the bytes to the new key before it rewrites the row.
--
-- So the repair is two-phase per object, and this migration supplies the first phase: park the row
-- back on the bucket whose key its bytes are actually under, so that the Storage API can see the
-- object at all, then let the API relocate it for real. supabase/scripts/repair_media_bucket_paths.py
-- drives both phases and is the only intended caller of these functions.
--
-- Why functions rather than a script with a database password
-- -----------------------------------------------------------
-- The alternative is handing a repair script raw SQL access to storage.objects, where a mistyped
-- predicate rewrites the whole table. These three functions are the entire vocabulary the repair
-- needs: read the inventory, park one named object, unpark one named object. Each refuses anything
-- outside the two buckets involved, moves exactly one row, and raises rather than silently matching
-- nothing. They are service_role only — `authenticated` reaching park_media_object could hide any
-- user's file from the application by parking it on a bucket nothing reads.
--
-- These are repair tooling, not schema. Drop all three once the repair is verified; the runbook in
-- the script's docstring says so and gives the statements.

-- Inventory ------------------------------------------------------------------------------------
-- PostgREST cannot select storage.objects directly — it is not in an exposed schema — so this is
-- also how the script takes its pre-repair snapshot. Both buckets, because a run interrupted
-- between park and relocate leaves rows on the legacy bucket and a snapshot that omitted them would
-- omit exactly the rows most in need of recovering.
create or replace function public.media_object_inventory()
returns table (
    bucket_id text,
    id uuid,
    name text,
    version text,
    metadata jsonb,
    created_at timestamptz,
    updated_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
    select o.bucket_id, o.id, o.name, o.version, o.metadata, o.created_at, o.updated_at
    from storage.objects as o
    where o.bucket_id in ('journaltopia-media', 'storytopia-media')
    order by o.bucket_id, o.name;
$$;

comment on function public.media_object_inventory() is
    'Rows for both media buckets, for the 20260819000000 storage repair. Service role only.';

-- Park -----------------------------------------------------------------------------------------
-- journaltopia-media -> storytopia-media for one object, which is what makes its bytes reachable
-- again. The occupancy check is not ceremony: storage.objects is unique on (bucket_id, name), so a
-- name already present on the legacy bucket means either a resumed run that already parked this
-- object or a second object contending for the key. Both are cases to stop and look at rather than
-- to collide on.
create or replace function public.park_media_object(object_name text)
returns table (id uuid, bucket_id text, version text)
language plpgsql
security definer
set search_path = ''
as $$
begin
    if object_name is null or object_name = '' then
        raise exception 'object_name_required';
    end if;

    if exists (
        select 1
        from storage.objects as existing
        where existing.bucket_id = 'storytopia-media'
          and existing.name = object_name
    ) then
        raise exception 'already_parked';
    end if;

    return query
    update storage.objects as o
    set bucket_id = 'storytopia-media'
    where o.bucket_id = 'journaltopia-media'
      and o.name = object_name
    returning o.id, o.bucket_id, o.version;

    if not found then
        raise exception 'object_not_found_in_journaltopia_media';
    end if;
end;
$$;

comment on function public.park_media_object(text) is
    'Moves one object row from journaltopia-media to storytopia-media so the Storage API can read
     its bytes. Metadata only — no bytes move and version is untouched. Service role only.';

-- Unpark ---------------------------------------------------------------------------------------
-- The inverse, and the rollback for a run that died between park and relocate. The occupancy guard
-- carries the weight here: if the application re-uploaded to this path while the row was parked,
-- a fresh row now owns the name in journaltopia-media with good bytes behind it, and unparking
-- blind would either violate the unique constraint or bury a working object. Raising leaves both
-- rows intact for a human to compare.
create or replace function public.unpark_media_object(object_name text)
returns table (id uuid, bucket_id text, version text)
language plpgsql
security definer
set search_path = ''
as $$
begin
    if object_name is null or object_name = '' then
        raise exception 'object_name_required';
    end if;

    if exists (
        select 1
        from storage.objects as existing
        where existing.bucket_id = 'journaltopia-media'
          and existing.name = object_name
    ) then
        raise exception 'destination_occupied';
    end if;

    return query
    update storage.objects as o
    set bucket_id = 'journaltopia-media'
    where o.bucket_id = 'storytopia-media'
      and o.name = object_name
    returning o.id, o.bucket_id, o.version;

    if not found then
        raise exception 'object_not_found_in_storytopia_media';
    end if;
end;
$$;

comment on function public.unpark_media_object(text) is
    'Inverse of park_media_object, and the rollback for an interrupted repair. Service role only.';

revoke all on function public.media_object_inventory() from public, anon, authenticated;
revoke all on function public.park_media_object(text) from public, anon, authenticated;
revoke all on function public.unpark_media_object(text) from public, anon, authenticated;

grant execute on function public.media_object_inventory() to service_role;
grant execute on function public.park_media_object(text) to service_role;
grant execute on function public.unpark_media_object(text) to service_role;
