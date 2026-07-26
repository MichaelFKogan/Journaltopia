create table if not exists public.entry_characters (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    entry_id uuid not null references public.entries(id) on delete cascade,
    client_entry_id uuid not null,
    name text not null,
    role text not null,
    source_photo_id uuid,
    storage_path text not null,
    mime_type text not null,
    byte_size bigint not null,
    width integer not null,
    height integer not null,
    sort_order integer not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint entry_characters_storage_path_key unique (user_id, storage_path),
    constraint entry_characters_role_check
        check (role in ('mainCharacter', 'supportingCharacter', 'pet', 'other'))
);

create index if not exists entry_characters_user_entry_sort_order_idx
    on public.entry_characters (user_id, entry_id, sort_order);

create index if not exists entry_characters_user_client_entry_sort_order_idx
    on public.entry_characters (user_id, client_entry_id, sort_order);

drop trigger if exists set_entry_characters_updated_at on public.entry_characters;
create trigger set_entry_characters_updated_at
    before update on public.entry_characters
    for each row
    execute function public.set_updated_at();

alter table public.entry_characters enable row level security;

drop policy if exists "Users can read their own entry characters" on public.entry_characters;
create policy "Users can read their own entry characters"
    on public.entry_characters
    for select
    to authenticated
    using (auth.uid() = user_id);

drop policy if exists "Users can insert their own entry characters" on public.entry_characters;
create policy "Users can insert their own entry characters"
    on public.entry_characters
    for insert
    to authenticated
    with check (auth.uid() = user_id);

drop policy if exists "Users can update their own entry characters" on public.entry_characters;
create policy "Users can update their own entry characters"
    on public.entry_characters
    for update
    to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

drop policy if exists "Users can delete their own entry characters" on public.entry_characters;
create policy "Users can delete their own entry characters"
    on public.entry_characters
    for delete
    to authenticated
    using (auth.uid() = user_id);
