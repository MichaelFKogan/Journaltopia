create or replace function public.delete_sample_entry_media_assets(p_sample_entry_id uuid)
returns table (
    id uuid,
    storage_path text,
    asset_type text
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not exists (
        select 1
        from public.sample_story_admins
        where sample_story_admins.user_id = auth.uid()
    ) then
        raise exception 'Not authorized to edit sample story assets';
    end if;

    return query
    delete from public.sample_entry_assets as assets
    where assets.sample_entry_id = p_sample_entry_id
      and assets.asset_type <> 'thumbnail'
    returning assets.id, assets.storage_path, assets.asset_type;
end;
$$;

revoke all on function public.delete_sample_entry_media_assets(uuid) from public;
grant execute on function public.delete_sample_entry_media_assets(uuid) to authenticated;
