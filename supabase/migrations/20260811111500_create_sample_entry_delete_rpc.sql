create or replace function public.delete_authoring_sample_entry(p_sample_entry_id uuid)
returns table (
    id uuid,
    storage_path text
)
language plpgsql
security definer
set search_path = public, storage
as $$
declare
    v_pack_id uuid;
    v_deleted_id uuid;
begin
    if not exists (
        select 1
        from public.sample_story_admins
        where sample_story_admins.user_id = auth.uid()
    ) then
        raise exception 'Not authorized to delete sample entries';
    end if;

    select sample_story_packs.id
    into v_pack_id
    from public.sample_story_packs
    where sample_story_packs.slug = 'storytopia-first-run'
      and sample_story_packs.locale = 'en'
    order by sample_story_packs.version desc
    limit 1;

    if v_pack_id is null then
        raise exception 'Sample authoring pack not found';
    end if;

    return query
    select p_sample_entry_id, sample_storyboard_pages.storage_path
    from public.sample_storyboard_pages
    where sample_storyboard_pages.sample_entry_id = p_sample_entry_id
    union all
    select p_sample_entry_id, sample_entry_assets.storage_path
    from public.sample_entry_assets
    where sample_entry_assets.sample_entry_id = p_sample_entry_id;

    delete from public.sample_entries
    where sample_entries.id = p_sample_entry_id
      and sample_entries.pack_id = v_pack_id
    returning sample_entries.id into v_deleted_id;

    if v_deleted_id is null then
        raise exception 'Sample entry not found or was not deleted';
    end if;

    return query select v_deleted_id, null::text;
end;
$$;

revoke all on function public.delete_authoring_sample_entry(uuid) from public;
grant execute on function public.delete_authoring_sample_entry(uuid) to authenticated;
