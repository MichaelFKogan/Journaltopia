-- Manual ordering for the My Characters library. Distinct from sort_order,
-- which orders characters inside a single entry.
alter table public.entry_characters
    add column if not exists library_sort_order integer;

create index if not exists entry_characters_user_library_sort_order_idx
    on public.entry_characters (user_id, library_sort_order);
