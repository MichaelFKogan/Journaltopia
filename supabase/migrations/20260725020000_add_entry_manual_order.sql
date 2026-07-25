alter table public.entries
    add column if not exists display_order integer not null default 0;

update public.entries
set display_order = ordered_entries.display_order
from (
    select
        id,
        row_number() over (
            partition by user_id
            order by created_at desc, id
        ) - 1 as display_order
    from public.entries
) as ordered_entries
where public.entries.id = ordered_entries.id;

create index if not exists entries_user_display_order_idx
    on public.entries (user_id, display_order, created_at desc);
