alter table public.sample_entry_assets
    add column if not exists character_role text,
    add column if not exists source_photo_id uuid;

alter table public.sample_entry_assets
    drop constraint if exists sample_entry_assets_character_role_check;

alter table public.sample_entry_assets
    add constraint sample_entry_assets_character_role_check
    check (
        character_role is null
        or character_role in ('mainCharacter', 'supportingCharacter', 'pet', 'other')
    );
