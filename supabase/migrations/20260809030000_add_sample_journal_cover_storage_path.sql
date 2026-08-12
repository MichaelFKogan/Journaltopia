alter table public.sample_journals
    add column if not exists cover_storage_path text;
