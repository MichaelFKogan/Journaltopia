create table if not exists public.sample_journals (
    id uuid primary key,
    pack_id uuid not null references public.sample_story_packs(id) on delete cascade,
    title text not null,
    subtitle text,
    color_hex text,
    symbol text,
    cover_image_name text,
    remote_cover jsonb,
    kind text not null default 'journal',
    is_favorite boolean not null default false,
    display_order integer not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint sample_journals_kind_check check (kind in ('journal', 'storyboard')),
    constraint sample_journals_pack_title_key unique (pack_id, title),
    constraint sample_journals_pack_display_order_key unique (pack_id, display_order)
);

create table if not exists public.sample_journal_entries (
    id uuid primary key default gen_random_uuid(),
    sample_journal_id uuid not null references public.sample_journals(id) on delete cascade,
    sample_entry_id uuid not null references public.sample_entries(id) on delete cascade,
    position integer not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint sample_journal_entries_membership_key unique (sample_journal_id, sample_entry_id),
    constraint sample_journal_entries_position_key unique (sample_journal_id, position)
);

create index if not exists sample_journals_pack_order_idx
    on public.sample_journals (pack_id, display_order);

create index if not exists sample_journal_entries_journal_order_idx
    on public.sample_journal_entries (sample_journal_id, position);

create index if not exists sample_journal_entries_entry_idx
    on public.sample_journal_entries (sample_entry_id);

drop trigger if exists set_sample_journals_updated_at on public.sample_journals;
create trigger set_sample_journals_updated_at
    before update on public.sample_journals
    for each row
    execute function public.set_updated_at();

drop trigger if exists set_sample_journal_entries_updated_at on public.sample_journal_entries;
create trigger set_sample_journal_entries_updated_at
    before update on public.sample_journal_entries
    for each row
    execute function public.set_updated_at();

alter table public.sample_journals enable row level security;
alter table public.sample_journal_entries enable row level security;

drop policy if exists "Anyone can read active sample journals" on public.sample_journals;
create policy "Anyone can read active sample journals"
    on public.sample_journals
    for select
    to anon, authenticated
    using (
        exists (
            select 1
            from public.sample_story_packs
            where sample_story_packs.id = sample_journals.pack_id
              and sample_story_packs.is_active = true
        )
    );

drop policy if exists "Anyone can read active sample journal entries" on public.sample_journal_entries;
create policy "Anyone can read active sample journal entries"
    on public.sample_journal_entries
    for select
    to anon, authenticated
    using (
        exists (
            select 1
            from public.sample_journals
            join public.sample_story_packs
              on sample_story_packs.id = sample_journals.pack_id
            where sample_journals.id = sample_journal_entries.sample_journal_id
              and sample_story_packs.is_active = true
        )
    );

alter table public.sample_entry_assets
    drop constraint if exists sample_entry_assets_type_check;

alter table public.sample_entry_assets
    add constraint sample_entry_assets_type_check
    check (asset_type in ('thumbnail', 'reference_photo', 'character', 'character_photo'));

alter table public.sample_entries
    drop constraint if exists sample_entries_pack_display_order_key;

alter table public.sample_journals
    drop constraint if exists sample_journals_pack_display_order_key;

alter table public.sample_journal_entries
    drop constraint if exists sample_journal_entries_position_key;

drop policy if exists "Sample admins can insert sample journals" on public.sample_journals;
create policy "Sample admins can insert sample journals"
    on public.sample_journals
    for insert
    to authenticated
    with check (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );

drop policy if exists "Sample admins can update sample journals" on public.sample_journals;
create policy "Sample admins can update sample journals"
    on public.sample_journals
    for update
    to authenticated
    using (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    )
    with check (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );

drop policy if exists "Sample admins can delete sample journals" on public.sample_journals;
create policy "Sample admins can delete sample journals"
    on public.sample_journals
    for delete
    to authenticated
    using (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );

drop policy if exists "Sample admins can insert sample journal entries" on public.sample_journal_entries;
create policy "Sample admins can insert sample journal entries"
    on public.sample_journal_entries
    for insert
    to authenticated
    with check (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );

drop policy if exists "Sample admins can update sample journal entries" on public.sample_journal_entries;
create policy "Sample admins can update sample journal entries"
    on public.sample_journal_entries
    for update
    to authenticated
    using (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    )
    with check (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );

drop policy if exists "Sample admins can delete sample journal entries" on public.sample_journal_entries;
create policy "Sample admins can delete sample journal entries"
    on public.sample_journal_entries
    for delete
    to authenticated
    using (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );
