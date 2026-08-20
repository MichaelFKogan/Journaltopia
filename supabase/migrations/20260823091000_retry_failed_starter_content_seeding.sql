-- Recovery for starter content that failed to seed at signup.
--
-- `20260823090000` wraps the seeding call so that a failure cannot break signup itself. That was the
-- right trade, but it left the failure with nowhere to go: `handle_new_user` runs once, on the insert
-- into auth.users, and never again. A template edit that violates a constraint, or a lock timeout at
-- a bad moment, would leave that account with no starter content permanently — and because the
-- sub-transaction rolls back the marker along with the partial rows, nothing recorded that it had
-- even been attempted.
--
-- This adds the thing that looks again. It is the same shape as `sweep-stale-storyboard-generations`
-- from `20260815190000`: a scheduled function that finds unfinished work and finishes it, with a
-- `verify_*` companion so "the job is scheduled" is a thing you can check rather than assume.
--
-- The failure worth designing for is not the random one. It is the systematic one: a bad template
-- edit fails *every* signup until someone notices. The sweeper turns that from "everybody who signed
-- up during the bad window is permanently empty" into "everybody who signed up during the bad window
-- gets their content within five minutes of the fix."


-- 1. Eligibility ----------------------------------------------------------------------------------
-- The sweeper cannot simply look for `starter_content_seeded_at is null`. Every account that predates
-- starter content matches that too, and seeding them is exactly what must not happen by accident.
--
-- So eligibility is recorded separately, and — this is the point — it is stamped by the profile
-- insert in `handle_new_user`, which sits *outside* the exception block that swallows a seeding
-- failure. A plpgsql `begin/exception` rolls back only its own sub-transaction, so when seeding
-- fails, the eligibility stamp survives while the seeding marker does not. That difference is what
-- the sweeper reads.
--
-- Accounts that existed before this migration have null here forever and can never be swept.
alter table public.profiles
    add column if not exists starter_content_eligible_at timestamptz;

comment on column public.profiles.starter_content_eligible_at is
    'When this account became eligible for starter content, stamped at signup. Null means the account predates starter content and must never be seeded automatically.';

-- Empty in the steady state: a row leaves this index the moment it is seeded, so the sweep is an
-- index scan over whatever failed rather than over the profiles table.
create index if not exists profiles_starter_content_pending_idx
    on public.profiles (starter_content_eligible_at)
    where starter_content_eligible_at is not null
      and starter_content_seeded_at is null;


-- 2. The trigger stamps eligibility ---------------------------------------------------------------
-- Identical to `20260823090000` apart from the new column in the insert. Deliberately absent from the
-- `on conflict do update` list: a conflict means the profile already existed, which is not a new
-- account, and stamping it would make an old account newly eligible for seeding.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (id, display_name, avatar_url, starter_content_eligible_at)
    values (
        new.id,
        coalesce(
            new.raw_user_meta_data ->> 'full_name',
            new.raw_user_meta_data ->> 'name',
            new.email
        ),
        new.raw_user_meta_data ->> 'avatar_url',
        now()
    )
    on conflict (id) do update
    set
        display_name = excluded.display_name,
        avatar_url = excluded.avatar_url,
        updated_at = now();

    begin
        perform public.seed_starter_content(new.id);
    exception
        when others then
            raise warning 'Journaltopia: starter content seeding failed for user %: %', new.id, sqlerrm;
    end;

    return new;
end;
$$;


-- 3. The sweeper ----------------------------------------------------------------------------------
-- `for update skip locked` hands each profile to exactly one run, so overlapping runs cannot both
-- seed the same account. `seed_starter_content` re-checks the marker under that same lock anyway, so
-- the two guards are independent.
--
-- Each account is seeded inside its own exception block. One account whose seeding still fails must
-- not abort the batch and take the accounts after it down with it — those are different users, and a
-- single unlucky row should cost only itself.
create or replace function public.sweep_unseeded_starter_content(
    max_rows integer default 100
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    pending record;
    seeded integer := 0;
    failed integer := 0;
begin
    for pending in
        select profiles.id
        from public.profiles
        where profiles.starter_content_eligible_at is not null
          and profiles.starter_content_seeded_at is null
        order by profiles.starter_content_eligible_at
        limit sweep_unseeded_starter_content.max_rows
        for update skip locked
    loop
        begin
            if public.seed_starter_content(pending.id) then
                seeded := seeded + 1;
            end if;
        exception
            when others then
                failed := failed + 1;
                raise warning '[sweep_unseeded_starter_content] retry failed for user %: %',
                    pending.id, sqlerrm;
        end;
    end loop;

    -- Logged rather than silent, because a run that seeds nothing and fails everything is the
    -- signature of a broken template, and it will repeat every five minutes until someone reads this.
    if seeded > 0 or failed > 0 then
        raise log '[sweep_unseeded_starter_content] seeded % account(s), % still failing', seeded, failed;
    end if;

    return seeded;
end;
$$;

revoke all on function public.sweep_unseeded_starter_content(integer) from public, anon, authenticated;
grant execute on function public.sweep_unseeded_starter_content(integer) to service_role;


-- 4. The schedule ---------------------------------------------------------------------------------
-- pg_cron is already a hard requirement of this database; `20260815190000` installs it and fails the
-- migration if it cannot. Five minutes matches the storyboard sweeper, and is the difference between
-- a new user seeing an empty app for a moment and seeing one forever.
create extension if not exists pg_cron;

do $$
begin
    if exists (select 1 from cron.job where jobname = 'sweep-unseeded-starter-content') then
        perform cron.unschedule('sweep-unseeded-starter-content');
    end if;

    perform cron.schedule(
        'sweep-unseeded-starter-content',
        '*/5 * * * *',
        $cron$select public.sweep_unseeded_starter_content();$cron$
    );
end $$;


-- 5. Checking that it is actually scheduled -------------------------------------------------------
-- A recovery path nobody can verify is a recovery path nobody should trust:
--
--   supabase db query --linked "select * from public.verify_starter_content_sweeper();"
--   supabase db query --local  "select * from public.verify_starter_content_sweeper();"
create or replace function public.verify_starter_content_sweeper()
returns table (check_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
declare
    expected_schedule constant text := '*/5 * * * *';
    expected_command constant text := 'sweep_unseeded_starter_content';
    job record;
begin
    if to_regclass('cron.job') is null then
        return query select
            'pg_cron_installed'::text,
            false,
            'pg_cron is not installed: failed starter content seeding will never be retried.'::text;
        return;
    end if;

    return query select 'pg_cron_installed'::text, true, 'pg_cron is installed.'::text;

    select * into job
    from cron.job
    where cron.job.jobname = 'sweep-unseeded-starter-content';

    if not found then
        return query select
            'sweeper_job_exists'::text,
            false,
            'No cron job named sweep-unseeded-starter-content.'::text;
        return;
    end if;

    return query select
        'sweeper_job_exists'::text,
        true,
        format('cron job %s owned by %s', job.jobid, job.username);

    return query select
        'sweeper_job_active'::text,
        coalesce(job.active, false),
        format('active = %s', coalesce(job.active, false));

    return query select
        'sweeper_schedule'::text,
        job.schedule = expected_schedule,
        format('schedule is %L, expected %L', job.schedule, expected_schedule);

    return query select
        'sweeper_command'::text,
        position(expected_command in coalesce(job.command, '')) > 0,
        format('command is %L', coalesce(job.command, ''));
end;
$$;

revoke all on function public.verify_starter_content_sweeper() from public, anon, authenticated;
grant execute on function public.verify_starter_content_sweeper() to service_role;


-- What the sweeper will and will not pick up ------------------------------------------------------
--
--   eligible, not seeded    a signup whose seeding failed          retried every five minutes
--   eligible, seeded        the ordinary case                      never touched again
--   not eligible            an account older than this feature     never touched, ever
--
-- The middle row is what protects a user who deleted the journals we gave them: the marker outlives
-- the rows, so an emptied account is "seeded" and the sweeper passes over it. Deleting starter
-- content stays permanent.
--
-- To see what is currently pending:
--
--   select id, starter_content_eligible_at from public.profiles
--   where starter_content_eligible_at is not null and starter_content_seeded_at is null;
