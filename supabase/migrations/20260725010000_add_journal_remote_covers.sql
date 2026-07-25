alter table public.journals
    add column if not exists cover_source text,
    add column if not exists cover_image_url text,
    add column if not exists cover_thumb_url text,
    add column if not exists cover_attribution_name text,
    add column if not exists cover_attribution_url text,
    add column if not exists cover_download_location text;

alter table public.journals
    drop constraint if exists journals_cover_source_check;

alter table public.journals
    add constraint journals_cover_source_check
        check (
            cover_source is null
            or cover_source in ('color', 'asset', 'local', 'unsplash')
        );
