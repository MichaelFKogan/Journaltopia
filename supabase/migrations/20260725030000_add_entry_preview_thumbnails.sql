alter table public.entries
    add column if not exists thumbnail_storage_path text,
    add column if not exists thumbnail_updated_at timestamptz;

create index if not exists entries_user_thumbnail_updated_at_idx
    on public.entries (user_id, thumbnail_updated_at desc)
    where thumbnail_storage_path is not null;
