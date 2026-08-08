insert into storage.buckets (id, name, public)
values ('sample-story-assets', 'sample-story-assets', true)
on conflict (id) do update
set public = true;

create table if not exists public.sample_story_packs (
    id uuid primary key,
    slug text not null,
    title text not null,
    version integer not null default 1,
    locale text not null default 'en',
    is_active boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint sample_story_packs_slug_locale_version_key unique (slug, locale, version)
);

create table if not exists public.sample_entries (
    id uuid primary key,
    pack_id uuid not null references public.sample_story_packs(id) on delete cascade,
    title text not null,
    body_text text not null,
    rich_text jsonb,
    status text not null default 'draft',
    location text,
    entry_date timestamptz,
    date_precision text not null default 'exact',
    display_order integer not null default 0,
    paper_style_raw_value text,
    paper_color_index integer,
    text_color_index integer,
    text_size double precision,
    font_choice_raw_value text,
    text_alignment_raw_value text,
    is_bold boolean not null default false,
    is_italic boolean not null default false,
    is_underlined boolean not null default false,
    is_strikethrough boolean not null default false,
    is_highlighted boolean not null default false,
    art_style text,
    is_private boolean not null default false,
    onboarding_callouts jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint sample_entries_status_check check (status in ('draft', 'completed')),
    constraint sample_entries_date_precision_check check (date_precision in ('noDate', 'exact', 'dateOnly', 'monthAndYear', 'yearOnly')),
    constraint sample_entries_pack_display_order_key unique (pack_id, display_order)
);

create table if not exists public.sample_storyboard_pages (
    id uuid primary key,
    sample_entry_id uuid not null references public.sample_entries(id) on delete cascade,
    storage_path text not null,
    page_index integer not null default 0,
    is_primary boolean not null default false,
    caption text,
    art_style text,
    generation_quality text,
    panel_layout text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint sample_storyboard_pages_entry_page_key unique (sample_entry_id, page_index),
    constraint sample_storyboard_pages_storage_path_key unique (storage_path),
    constraint sample_storyboard_pages_generation_quality_check check (generation_quality is null or generation_quality in ('standard', 'hd'))
);

create table if not exists public.sample_entry_assets (
    id uuid primary key,
    sample_entry_id uuid not null references public.sample_entries(id) on delete cascade,
    storage_path text not null,
    asset_type text not null,
    sort_order integer not null default 0,
    caption text,
    mime_type text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint sample_entry_assets_type_check check (asset_type in ('reference_photo', 'character_photo')),
    constraint sample_entry_assets_entry_sort_key unique (sample_entry_id, asset_type, sort_order),
    constraint sample_entry_assets_storage_path_key unique (storage_path)
);

create index if not exists sample_story_packs_active_locale_idx
    on public.sample_story_packs (is_active, locale, updated_at desc);

create index if not exists sample_entries_pack_order_idx
    on public.sample_entries (pack_id, display_order);

create index if not exists sample_storyboard_pages_entry_order_idx
    on public.sample_storyboard_pages (sample_entry_id, page_index);

create index if not exists sample_entry_assets_entry_order_idx
    on public.sample_entry_assets (sample_entry_id, asset_type, sort_order);

drop trigger if exists set_sample_story_packs_updated_at on public.sample_story_packs;
create trigger set_sample_story_packs_updated_at
    before update on public.sample_story_packs
    for each row
    execute function public.set_updated_at();

drop trigger if exists set_sample_entries_updated_at on public.sample_entries;
create trigger set_sample_entries_updated_at
    before update on public.sample_entries
    for each row
    execute function public.set_updated_at();

drop trigger if exists set_sample_storyboard_pages_updated_at on public.sample_storyboard_pages;
create trigger set_sample_storyboard_pages_updated_at
    before update on public.sample_storyboard_pages
    for each row
    execute function public.set_updated_at();

drop trigger if exists set_sample_entry_assets_updated_at on public.sample_entry_assets;
create trigger set_sample_entry_assets_updated_at
    before update on public.sample_entry_assets
    for each row
    execute function public.set_updated_at();

alter table public.sample_story_packs enable row level security;
alter table public.sample_entries enable row level security;
alter table public.sample_storyboard_pages enable row level security;
alter table public.sample_entry_assets enable row level security;

drop policy if exists "Anyone can read active sample story packs" on public.sample_story_packs;
create policy "Anyone can read active sample story packs"
    on public.sample_story_packs
    for select
    to anon, authenticated
    using (is_active = true);

drop policy if exists "Anyone can read active sample entries" on public.sample_entries;
create policy "Anyone can read active sample entries"
    on public.sample_entries
    for select
    to anon, authenticated
    using (
        exists (
            select 1
            from public.sample_story_packs
            where sample_story_packs.id = sample_entries.pack_id
              and sample_story_packs.is_active = true
        )
    );

drop policy if exists "Anyone can read active sample storyboard pages" on public.sample_storyboard_pages;
create policy "Anyone can read active sample storyboard pages"
    on public.sample_storyboard_pages
    for select
    to anon, authenticated
    using (
        exists (
            select 1
            from public.sample_entries
            join public.sample_story_packs
              on sample_story_packs.id = sample_entries.pack_id
            where sample_entries.id = sample_storyboard_pages.sample_entry_id
              and sample_story_packs.is_active = true
        )
    );

drop policy if exists "Anyone can read active sample entry assets" on public.sample_entry_assets;
create policy "Anyone can read active sample entry assets"
    on public.sample_entry_assets
    for select
    to anon, authenticated
    using (
        exists (
            select 1
            from public.sample_entries
            join public.sample_story_packs
              on sample_story_packs.id = sample_entries.pack_id
            where sample_entries.id = sample_entry_assets.sample_entry_id
              and sample_story_packs.is_active = true
        )
    );

drop policy if exists "Anyone can read sample story assets" on storage.objects;
create policy "Anyone can read sample story assets"
    on storage.objects
    for select
    to anon, authenticated
    using (bucket_id = 'sample-story-assets');
