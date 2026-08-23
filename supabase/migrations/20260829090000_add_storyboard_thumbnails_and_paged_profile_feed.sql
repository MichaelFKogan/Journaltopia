alter table public.entry_storyboards
    add column if not exists thumbnail_storage_path text;

create or replace function public.completed_journal_storyboard_rows(
    p_limit integer default 9,
    p_offset integer default 0
)
returns table (
    id uuid,
    user_id uuid,
    client_entry_id uuid,
    storage_path text,
    thumbnail_storage_path text,
    created_at timestamptz,
    updated_at timestamptz,
    art_style text,
    generation_quality text,
    panel_layout text,
    prompt text,
    is_primary boolean,
    generation_status text
)
language sql
stable
security invoker
set search_path = public
as $$
    select
        s.id,
        s.user_id,
        s.client_entry_id,
        s.storage_path,
        s.thumbnail_storage_path,
        s.created_at,
        s.updated_at,
        s.art_style,
        s.generation_quality::text as generation_quality,
        s.panel_layout,
        s.prompt,
        s.is_primary,
        s.generation_status::text as generation_status
    from public.entry_storyboards s
    join public.entries e
      on e.user_id = s.user_id
     and e.client_entry_id = s.client_entry_id
    where s.user_id = auth.uid()
      and e.user_id = auth.uid()
      and e.status = 'completed'
      and coalesce(s.generation_status, 'completed') = 'completed'
      and s.storage_path not like 'journaltopia-first-run/%'
    order by s.created_at desc, s.id desc
    limit greatest(0, least(coalesce(p_limit, 9), 100))
    offset greatest(0, coalesce(p_offset, 0));
$$;

create or replace function public.completed_journal_storyboard_counts()
returns table (
    total_count integer,
    month_count integer
)
language sql
stable
security invoker
set search_path = public
as $$
    select
        count(*)::integer as total_count,
        count(*) filter (
            where s.created_at >= date_trunc('month', now())
              and s.created_at < date_trunc('month', now()) + interval '1 month'
        )::integer as month_count
    from public.entry_storyboards s
    join public.entries e
      on e.user_id = s.user_id
     and e.client_entry_id = s.client_entry_id
    where s.user_id = auth.uid()
      and e.user_id = auth.uid()
      and e.status = 'completed'
      and coalesce(s.generation_status, 'completed') = 'completed'
      and s.storage_path not like 'journaltopia-first-run/%';
$$;

revoke all on function public.completed_journal_storyboard_rows(integer, integer) from public, anon;
grant execute on function public.completed_journal_storyboard_rows(integer, integer) to authenticated;

revoke all on function public.completed_journal_storyboard_counts() from public, anon;
grant execute on function public.completed_journal_storyboard_counts() to authenticated;
