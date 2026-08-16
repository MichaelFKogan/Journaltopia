-- The lifecycle transitions for a background storyboard generation. Each one is a single locked
-- statement or block, so two executions of the same job — a retried background task, an overlapping
-- sweeper run — converge instead of compounding.
--
-- The rule the whole design rests on: a credit is handed back only on the one transition out of a
-- non-terminal state, taken under a row lock. A row that already reads 'completed' or 'failed' is
-- returned untouched, so a second caller cannot refund it again.

-- Reserves a generation: spends the credit and writes the pending row in one transaction. Doing
-- both here means a failure between them is impossible — either the user is charged and the job
-- exists, or neither happened. The spend itself still goes through the existing
-- spend_generation_credit RPC, so there is one place that knows how a credit is taken.
create or replace function public.reserve_storyboard_generation(
    storyboard_id uuid,
    client_entry_id uuid,
    storage_path text,
    art_style text,
    generation_quality text,
    prompt text,
    credit_cost integer
)
returns public.entry_storyboards
language plpgsql
security definer
set search_path = public
as $$
declare
    caller uuid := auth.uid();
    reserved public.entry_storyboards%rowtype;
begin
    if caller is null then
        raise exception 'not_authenticated';
    end if;

    if credit_cost is null or credit_cost <= 0 then
        raise exception 'invalid_credit_cost';
    end if;

    if not exists (
        select 1
        from public.entries
        where entries.user_id = caller
          and entries.client_entry_id = reserve_storyboard_generation.client_entry_id
    ) then
        raise exception 'entry_not_found';
    end if;

    perform public.spend_generation_credit(reserve_storyboard_generation.credit_cost);

    insert into public.entry_storyboards (
        id,
        user_id,
        client_entry_id,
        storage_path,
        art_style,
        generation_quality,
        panel_layout,
        prompt,
        is_primary,
        generation_status,
        reserved_credits
    )
    values (
        reserve_storyboard_generation.storyboard_id,
        caller,
        reserve_storyboard_generation.client_entry_id,
        reserve_storyboard_generation.storage_path,
        reserve_storyboard_generation.art_style,
        reserve_storyboard_generation.generation_quality,
        null,
        reserve_storyboard_generation.prompt,
        false,
        'pending',
        reserve_storyboard_generation.credit_cost
    )
    returning * into reserved;

    return reserved;
end;
$$;

-- Claims a pending row for one background worker. The status predicate is the claim: the first
-- execution to run this owns the job, and any later one sees false and stands down.
create or replace function public.start_storyboard_generation(storyboard_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    claimed boolean;
begin
    if auth.uid() is null then
        raise exception 'not_authenticated';
    end if;

    update public.entry_storyboards
    set generation_status = 'processing',
        processing_started_at = now()
    where entry_storyboards.id = start_storyboard_generation.storyboard_id
      and entry_storyboards.user_id = auth.uid()
      and entry_storyboards.generation_status = 'pending'
    returning true into claimed;

    return coalesce(claimed, false);
end;
$$;

-- Records the finished artwork and promotes it in one transaction, so a storyboard can never be
-- visible as completed without also being its entry's primary page.
create or replace function public.complete_storyboard_generation(
    storyboard_id uuid,
    storage_path text default null,
    panel_layout text default null
)
returns public.entry_storyboards
language plpgsql
security definer
set search_path = public
as $$
declare
    storyboard public.entry_storyboards%rowtype;
begin
    if auth.uid() is null then
        raise exception 'not_authenticated';
    end if;

    select * into storyboard
    from public.entry_storyboards
    where entry_storyboards.id = complete_storyboard_generation.storyboard_id
      and entry_storyboards.user_id = auth.uid()
    for update;

    if not found then
        raise exception 'storyboard_not_found';
    end if;

    -- A retried background task finds its own work already done and takes the row as the answer.
    if storyboard.generation_status = 'completed' then
        return storyboard;
    end if;

    -- The sweeper already failed and refunded this job. Completing it now would hand the user a
    -- storyboard they were refunded for, so the row stays failed and the image is left orphaned.
    if storyboard.generation_status = 'failed' then
        raise exception 'storyboard_already_failed';
    end if;

    update public.entry_storyboards
    set is_primary = false
    where entry_storyboards.user_id = storyboard.user_id
      and entry_storyboards.client_entry_id = storyboard.client_entry_id
      and entry_storyboards.is_primary = true
      and entry_storyboards.id <> storyboard.id;

    update public.entry_storyboards
    set generation_status = 'completed',
        completed_at = now(),
        is_primary = true,
        generation_error = null,
        storage_path = coalesce(
            complete_storyboard_generation.storage_path,
            entry_storyboards.storage_path
        ),
        panel_layout = coalesce(
            complete_storyboard_generation.panel_layout,
            entry_storyboards.panel_layout
        )
    where entry_storyboards.id = storyboard.id
    returning * into storyboard;

    return storyboard;
end;
$$;

-- The single failing transition, shared by the background worker and the sweeper. Nothing else may
-- write 'failed', and nothing else refunds, so this is the only place a reservation is ever
-- returned. It is internal; the wrappers below decide who may reach it.
create or replace function public.finish_failed_storyboard_generation(
    storyboard_id uuid,
    generation_error text
)
returns table (
    id uuid,
    generation_status text,
    refunded_credits integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
    storyboard public.entry_storyboards%rowtype;
    refund integer;
begin
    select * into storyboard
    from public.entry_storyboards
    where entry_storyboards.id = finish_failed_storyboard_generation.storyboard_id
    for update;

    if not found then
        raise exception 'storyboard_not_found';
    end if;

    -- Terminal rows are reported back untouched. This is the double-refund guard: the credit moves
    -- only on the transition out of pending/processing, and only one caller can hold this lock
    -- while taking it.
    if storyboard.generation_status in ('completed', 'failed') then
        return query
        select storyboard.id, storyboard.generation_status, storyboard.refunded_credits;
        return;
    end if;

    -- Two more guards, for rows whose status was moved backwards. A client may still write
    -- generation_status directly, but it cannot touch completed_at or refunded_credits, so a
    -- generation that once finished, or was already refunded, can never be refunded again.
    if storyboard.completed_at is not null or storyboard.refunded_credits is not null then
        refund := 0;
    else
        refund := coalesce(storyboard.reserved_credits, 0);
    end if;

    if refund > 0 then
        update public.profiles
        set generation_credits = generation_credits + refund
        where profiles.id = storyboard.user_id;

        if not found then
            raise exception 'profile_not_found';
        end if;
    end if;

    update public.entry_storyboards
    set generation_status = 'failed',
        failed_at = now(),
        is_primary = false,
        refunded_credits = refund,
        generation_error = left(
            coalesce(
                nullif(btrim(finish_failed_storyboard_generation.generation_error), ''),
                'Storyboard generation failed. Please try again.'
            ),
            500
        )
    where entry_storyboards.id = storyboard.id;

    return query
    select storyboard.id, 'failed'::text, refund;
end;
$$;

-- The worker-facing wrapper. Ownership is checked here so the shared transition can stay usable by
-- the sweeper, which runs with no authenticated user at all.
create or replace function public.fail_storyboard_generation(
    storyboard_id uuid,
    generation_error text
)
returns table (
    id uuid,
    generation_status text,
    refunded_credits integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if auth.uid() is null then
        raise exception 'not_authenticated';
    end if;

    if not exists (
        select 1
        from public.entry_storyboards
        where entry_storyboards.id = fail_storyboard_generation.storyboard_id
          and entry_storyboards.user_id = auth.uid()
    ) then
        raise exception 'storyboard_not_found';
    end if;

    return query
    select *
    from public.finish_failed_storyboard_generation(
        fail_storyboard_generation.storyboard_id,
        fail_storyboard_generation.generation_error
    );
end;
$$;

-- Recovery for jobs no client can resolve: the background task was killed, the isolate was shut
-- down, or the row was written and never picked up. The thresholds are deliberately generous — the
-- OpenAI call is capped at 5 minutes and the Edge Function wall clock is shorter still, so anything
-- past these numbers is dead rather than slow:
--
--   pending    > 15 minutes   no worker ever claimed it
--   processing > 20 minutes   a worker claimed it and never came back
--
-- `for update skip locked` hands each row to exactly one sweeper run, and the failing transition
-- re-checks the status under that same lock, so overlapping runs cannot both refund one job.
create or replace function public.sweep_stale_storyboard_generations(
    pending_timeout interval default interval '15 minutes',
    processing_timeout interval default interval '20 minutes',
    max_rows integer default 100
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    stale record;
    swept integer := 0;
begin
    for stale in
        select entry_storyboards.id, entry_storyboards.generation_status
        from public.entry_storyboards
        where (
                entry_storyboards.generation_status = 'pending'
                and entry_storyboards.created_at
                    < now() - sweep_stale_storyboard_generations.pending_timeout
            )
           or (
                entry_storyboards.generation_status = 'processing'
                and coalesce(entry_storyboards.processing_started_at, entry_storyboards.created_at)
                    < now() - sweep_stale_storyboard_generations.processing_timeout
            )
        order by entry_storyboards.created_at
        limit sweep_stale_storyboard_generations.max_rows
        for update skip locked
    loop
        perform public.finish_failed_storyboard_generation(
            stale.id,
            case stale.generation_status
                when 'pending' then 'This storyboard never started generating. Your credits were returned.'
                else 'Storyboard generation stopped before it finished. Your credits were returned.'
            end
        );

        swept := swept + 1;
    end loop;

    if swept > 0 then
        raise log '[sweep_stale_storyboard_generations] failed and refunded % stale generation(s)', swept;
    end if;

    return swept;
end;
$$;

-- Only the caller-facing wrappers are reachable by a signed-in client. The shared transition and
-- the sweeper are server-side only: a client that could call them could fail and refund its own
-- generations at will.
revoke all on function public.finish_failed_storyboard_generation(uuid, text) from public, anon, authenticated;
revoke all on function public.sweep_stale_storyboard_generations(interval, interval, integer) from public, anon, authenticated;

grant execute on function public.reserve_storyboard_generation(uuid, uuid, text, text, text, text, integer) to authenticated;
grant execute on function public.start_storyboard_generation(uuid) to authenticated;
grant execute on function public.complete_storyboard_generation(uuid, text, text) to authenticated;
grant execute on function public.fail_storyboard_generation(uuid, text) to authenticated;

-- Credit bookkeeping and lifecycle timestamps are written by these functions and by nothing else.
-- Without this, a client could insert a pending row claiming a large reservation, wait for the
-- sweeper, and be "refunded" credits it never spent. Every column the app actually writes today —
-- the storyboard's own metadata and its primary flag — stays writable.
revoke insert, update on public.entry_storyboards from authenticated;

grant insert (
    id,
    user_id,
    client_entry_id,
    storage_path,
    created_at,
    updated_at,
    art_style,
    generation_quality,
    panel_layout,
    prompt,
    is_primary,
    generation_status
) on public.entry_storyboards to authenticated;

-- The update list has to cover every column the app's upserts write, because
-- INSERT ... ON CONFLICT DO UPDATE is privilege-checked on its whole SET list whether or not a
-- conflict happens. RLS still pins user_id to the caller, so the wider list grants nothing extra.
grant update (
    id,
    user_id,
    client_entry_id,
    storage_path,
    created_at,
    updated_at,
    art_style,
    generation_quality,
    panel_layout,
    prompt,
    is_primary,
    generation_status
) on public.entry_storyboards to authenticated;

-- Every five minutes is far more often than the thresholds require, and each run is one index scan
-- over the handful of unfinished rows.
do $$
begin
    begin
        create extension if not exists pg_cron;
    exception
        when others then
            raise notice 'pg_cron is unavailable here; schedule sweep_stale_storyboard_generations() by other means.';
            return;
    end;

    if exists (select 1 from cron.job where jobname = 'sweep-stale-storyboard-generations') then
        perform cron.unschedule('sweep-stale-storyboard-generations');
    end if;

    perform cron.schedule(
        'sweep-stale-storyboard-generations',
        '*/5 * * * *',
        $cron$select public.sweep_stale_storyboard_generations();$cron$
    );
end $$;
