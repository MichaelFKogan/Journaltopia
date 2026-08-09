create table if not exists public.sample_story_admins (
    user_id uuid primary key references auth.users(id) on delete cascade,
    email text unique,
    created_at timestamptz not null default now()
);

alter table public.sample_story_admins enable row level security;

drop policy if exists "Sample admins can read their own admin row" on public.sample_story_admins;
create policy "Sample admins can read their own admin row"
    on public.sample_story_admins
    for select
    to authenticated
    using (auth.uid() = user_id);

drop policy if exists "Sample admins can insert sample story packs" on public.sample_story_packs;
create policy "Sample admins can insert sample story packs"
    on public.sample_story_packs
    for insert
    to authenticated
    with check (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );

drop policy if exists "Sample admins can update sample story packs" on public.sample_story_packs;
create policy "Sample admins can update sample story packs"
    on public.sample_story_packs
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

drop policy if exists "Sample admins can insert sample entries" on public.sample_entries;
create policy "Sample admins can insert sample entries"
    on public.sample_entries
    for insert
    to authenticated
    with check (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );

drop policy if exists "Sample admins can update sample entries" on public.sample_entries;
create policy "Sample admins can update sample entries"
    on public.sample_entries
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

drop policy if exists "Sample admins can delete sample entries" on public.sample_entries;
create policy "Sample admins can delete sample entries"
    on public.sample_entries
    for delete
    to authenticated
    using (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );

drop policy if exists "Sample admins can insert storyboard pages" on public.sample_storyboard_pages;
create policy "Sample admins can insert storyboard pages"
    on public.sample_storyboard_pages
    for insert
    to authenticated
    with check (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );

drop policy if exists "Sample admins can update storyboard pages" on public.sample_storyboard_pages;
create policy "Sample admins can update storyboard pages"
    on public.sample_storyboard_pages
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

drop policy if exists "Sample admins can delete storyboard pages" on public.sample_storyboard_pages;
create policy "Sample admins can delete storyboard pages"
    on public.sample_storyboard_pages
    for delete
    to authenticated
    using (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );

drop policy if exists "Sample admins can insert sample entry assets" on public.sample_entry_assets;
create policy "Sample admins can insert sample entry assets"
    on public.sample_entry_assets
    for insert
    to authenticated
    with check (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );

drop policy if exists "Sample admins can update sample entry assets" on public.sample_entry_assets;
create policy "Sample admins can update sample entry assets"
    on public.sample_entry_assets
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

drop policy if exists "Sample admins can delete sample entry assets" on public.sample_entry_assets;
create policy "Sample admins can delete sample entry assets"
    on public.sample_entry_assets
    for delete
    to authenticated
    using (
        exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );

drop policy if exists "Sample admins can upload sample story assets" on storage.objects;
create policy "Sample admins can upload sample story assets"
    on storage.objects
    for insert
    to authenticated
    with check (
        bucket_id = 'sample-story-assets'
        and exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );

drop policy if exists "Sample admins can update sample story assets" on storage.objects;
create policy "Sample admins can update sample story assets"
    on storage.objects
    for update
    to authenticated
    using (
        bucket_id = 'sample-story-assets'
        and exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    )
    with check (
        bucket_id = 'sample-story-assets'
        and exists (
            select 1
            from public.sample_story_admins
            where sample_story_admins.user_id = auth.uid()
        )
    );
