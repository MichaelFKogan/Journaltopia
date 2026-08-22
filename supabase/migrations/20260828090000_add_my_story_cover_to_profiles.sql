alter table public.profiles
    add column if not exists my_story_cover_color_hex text,
    add column if not exists my_story_cover_storage_path text,
    add column if not exists my_story_cover_storyboard_id uuid,
    add column if not exists my_story_cover_image_name text,
    add column if not exists my_story_cover_source text,
    add column if not exists my_story_cover_image_url text,
    add column if not exists my_story_cover_thumb_url text,
    add column if not exists my_story_cover_attribution_name text,
    add column if not exists my_story_cover_attribution_url text,
    add column if not exists my_story_cover_download_location text;

alter table public.profiles
    drop constraint if exists profiles_my_story_cover_source_check;

alter table public.profiles
    add constraint profiles_my_story_cover_source_check
    check (
        my_story_cover_source is null
        or my_story_cover_source in ('color', 'asset', 'local', 'unsplash')
    );

comment on column public.profiles.my_story_cover_storyboard_id is
    'Optional account-level My Story cover chosen from one of the user storyboards.';

comment on column public.profiles.my_story_cover_storage_path is
    'Optional custom My Story cover stored in the journal-covers bucket.';

grant update (
    my_story_cover_color_hex,
    my_story_cover_storage_path,
    my_story_cover_storyboard_id,
    my_story_cover_image_name,
    my_story_cover_source,
    my_story_cover_image_url,
    my_story_cover_thumb_url,
    my_story_cover_attribution_name,
    my_story_cover_attribution_url,
    my_story_cover_download_location
) on public.profiles to authenticated;
