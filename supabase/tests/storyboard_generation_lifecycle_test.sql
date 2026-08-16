-- Lifecycle and refund guarantees for background storyboard generation.
--
-- Run with: supabase test db   (requires the local Supabase stack)
--
-- The properties that matter here are the ones no client can be trusted with: a job is claimed by
-- exactly one worker, a completed job stays completed, a failed job refunds exactly once, and the
-- sweeper can never turn one stuck generation into two refunds.

create extension if not exists pgtap with schema extensions;

begin;

select plan(67);

-- Fixtures -------------------------------------------------------------------------------------
-- The profile (and its 10 starting credits) is created by the on_auth_user_created trigger.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
values (
    '00000000-0000-0000-0000-000000000000',
    'aaaaaaaa-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'storyboard-lifecycle@example.com',
    'x',
    now(),
    now()
);

insert into public.entries (user_id, client_entry_id, title, content)
values (
    'aaaaaaaa-0000-4000-8000-000000000001',
    'bbbbbbbb-0000-4000-8000-000000000001',
    'A quiet afternoon',
    'We sat on the porch until it got cold.'
);

-- An older primary storyboard, so the completing transition has something to demote.
insert into public.entry_storyboards (
    id, user_id, client_entry_id, storage_path, is_primary, generation_status, completed_at
)
values (
    'cccccccc-0000-4000-8000-00000000000f',
    'aaaaaaaa-0000-4000-8000-000000000001',
    'bbbbbbbb-0000-4000-8000-000000000001',
    'aaaa/bbbb/older.jpg',
    true,
    'completed',
    now()
);

-- Everything below runs as the signed-in owner of that entry.
select set_config(
    'request.jwt.claims',
    '{"sub":"aaaaaaaa-0000-4000-8000-000000000001","role":"authenticated"}',
    true
);

-- Reserving ------------------------------------------------------------------------------------
select lives_ok(
    $$select public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000001',
        'bbbbbbbb-0000-4000-8000-000000000001',
        'aaaa/bbbb/one.jpg',
        'Anime',
        'low',
        'a quiet afternoon',
        1
    )$$,
    'reserving a generation succeeds for the entry owner'
);

select is(
    (select generation_status from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000001'),
    'pending',
    'a reserved generation starts pending'
);

select is(
    (select reserved_credits from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000001'),
    1,
    'the reservation records what it spent'
);

select is(
    (select generation_credits from public.profiles where id = 'aaaaaaaa-0000-4000-8000-000000000001'),
    9,
    'reserving spends the credit up front'
);

-- Claiming -------------------------------------------------------------------------------------
select is(
    public.start_storyboard_generation('cccccccc-0000-4000-8000-000000000001'),
    true,
    'the first worker claims the job'
);

select is(
    public.start_storyboard_generation('cccccccc-0000-4000-8000-000000000001'),
    false,
    'a second execution of the same job stands down'
);

select isnt(
    (select processing_started_at from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000001'),
    null,
    'claiming stamps processing_started_at in server time'
);

-- Completing -----------------------------------------------------------------------------------
-- The outcome comes back as data, because the worker has to act on it: only 'already_failed'
-- licenses it to delete the image it just uploaded.
select is(
    (select completion_status from public.complete_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000001',
        'aaaa/bbbb/one.jpg',
        null
    )),
    'completed',
    'completing a claimed job reports completed'
);

select is(
    (select generation_status from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000001'),
    'completed',
    'completing writes the terminal state'
);

select isnt(
    (select completed_at from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000001'),
    null,
    'completing stamps completed_at'
);

select is(
    (select is_primary from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000001'),
    true,
    'the finished storyboard becomes the entry primary'
);

select is(
    (select is_primary from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-00000000000f'),
    false,
    'the previous primary is demoted in the same transaction'
);

select is(
    (select completion_status from public.complete_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000001',
        'aaaa/bbbb/one.jpg',
        null
    )),
    'already_completed',
    'a retried background task is told the work was already done'
);

select is(
    (select generation_status from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000001'),
    'completed',
    'completing twice leaves one completed row'
);

-- Failing --------------------------------------------------------------------------------------
select lives_ok(
    $$select public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000002',
        'bbbbbbbb-0000-4000-8000-000000000001',
        'aaaa/bbbb/two.jpg',
        'Anime',
        'medium',
        'a quiet afternoon',
        2
    )$$,
    'a second generation can be reserved for the same entry'
);

select is(
    (select generation_credits from public.profiles where id = 'aaaaaaaa-0000-4000-8000-000000000001'),
    7,
    'an HD reservation spends two credits'
);

select is(
    public.start_storyboard_generation('cccccccc-0000-4000-8000-000000000002'),
    true,
    'the second job is claimed'
);

select is(
    (select refunded_credits from public.fail_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000002',
        'OpenAI did not return a storyboard image.'
    )),
    2,
    'failing refunds the whole reservation'
);

select is(
    (select generation_status from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000002'),
    'failed',
    'failing writes the terminal state'
);

select is(
    (select generation_error from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000002'),
    'OpenAI did not return a storyboard image.',
    'the server-provided error is stored for the client to display'
);

select isnt(
    (select failed_at from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000002'),
    null,
    'failing stamps failed_at'
);

select is(
    (select generation_credits from public.profiles where id = 'aaaaaaaa-0000-4000-8000-000000000001'),
    9,
    'the reserved credits come back exactly once'
);

select is(
    (select refunded_credits from public.fail_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000002',
        'a duplicated failure path'
    )),
    2,
    'a repeated failure reports the refund that already happened'
);

select is(
    (select generation_credits from public.profiles where id = 'aaaaaaaa-0000-4000-8000-000000000001'),
    9,
    'a repeated failure does not refund a second time'
);

-- The late-success race, from the database's side: the worker's image is already uploaded, the row
-- is already failed and refunded, and the worker is told so plainly enough to clean up after itself.
select is(
    (select completion_status from public.complete_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000002',
        'aaaa/bbbb/two.jpg',
        null
    )),
    'already_failed',
    'a refunded generation reports already_failed instead of completing'
);

select is(
    (select generation_status from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000002'),
    'failed',
    'losing the race leaves the row failed'
);

-- Sweeping stale jobs --------------------------------------------------------------------------
select lives_ok(
    $$select public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000003',
        'bbbbbbbb-0000-4000-8000-000000000001',
        'aaaa/bbbb/three.jpg',
        'Anime',
        'low',
        'a quiet afternoon',
        1
    )$$,
    'a third generation is reserved, to be abandoned'
);

select is(
    (select generation_credits from public.profiles where id = 'aaaaaaaa-0000-4000-8000-000000000001'),
    8,
    'the third reservation spends its credit'
);

-- The worker for this one never came back.
update public.entry_storyboards
set generation_status = 'processing',
    processing_started_at = now() - interval '45 minutes',
    created_at = now() - interval '45 minutes'
where id = 'cccccccc-0000-4000-8000-000000000003';

-- A fresh job, to prove the sweeper only takes the ones that are actually dead.
select lives_ok(
    $$select public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000004',
        'bbbbbbbb-0000-4000-8000-000000000001',
        'aaaa/bbbb/four.jpg',
        'Anime',
        'low',
        'a quiet afternoon',
        1
    )$$,
    'a fresh generation is reserved alongside the stale one'
);

select is(public.sweep_stale_storyboard_generations(), 1, 'the sweeper takes only the stale job');

select is(
    (select generation_status from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000003'),
    'failed',
    'the stale job is failed by the server'
);

select is(
    (select refunded_credits from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000003'),
    1,
    'the stale job records its refund'
);

select isnt(
    (select generation_error from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000003'),
    null,
    'the stale job gets a user-displayable reason'
);

select is(
    (select generation_status from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000004'),
    'pending',
    'a fresh job is left alone'
);

select is(
    (select generation_credits from public.profiles where id = 'aaaaaaaa-0000-4000-8000-000000000001'),
    8,
    'sweeping refunds the stale job and nothing else'
);

select is(public.sweep_stale_storyboard_generations(), 0, 'a second sweep finds nothing to do');

select is(
    (select generation_credits from public.profiles where id = 'aaaaaaaa-0000-4000-8000-000000000001'),
    8,
    'overlapping sweeps cannot double-refund'
);

-- A generation that once completed can never be refunded, whatever its status is moved to later.
update public.entry_storyboards
set generation_status = 'pending',
    created_at = now() - interval '45 minutes'
where id = 'cccccccc-0000-4000-8000-000000000001';

select is(public.sweep_stale_storyboard_generations(), 1, 'the sweeper resolves a job pushed back to pending');

select is(
    (select refunded_credits from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-000000000001'),
    0,
    'a generation that already completed is refunded nothing'
);

select is(
    (select generation_credits from public.profiles where id = 'aaaaaaaa-0000-4000-8000-000000000001'),
    8,
    'rewinding a completed generation cannot mint credits'
);

-- Working with no session at all ---------------------------------------------------------------
-- The background worker runs as service_role, long after the request that created the job. These
-- two rows are reserved while the user's claims are still set, then settled with no auth.uid() at
-- all, which is what the worker's calls look like.
select lives_ok(
    $$select public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000005',
        'bbbbbbbb-0000-4000-8000-000000000001',
        'aaaa/bbbb/five.jpg',
        'Anime',
        'low',
        'a quiet afternoon',
        1
    )$$,
    'a fifth generation is reserved by the signed-in owner'
);

select lives_ok(
    $$select public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000006',
        'bbbbbbbb-0000-4000-8000-000000000001',
        'aaaa/bbbb/six.jpg',
        'Anime',
        'low',
        'a quiet afternoon',
        1
    )$$,
    'a sixth generation is reserved by the signed-in owner'
);

-- Claims with no subject: auth.uid() is null from here, exactly as it is for service_role.
select set_config('request.jwt.claims', '{"role":"service_role"}', true);

select is(
    public.start_storyboard_generation('cccccccc-0000-4000-8000-000000000005'),
    true,
    'claiming a job needs no user session'
);

select is(
    (select completion_status from public.complete_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000005',
        'aaaa/bbbb/five.jpg',
        null
    )),
    'completed',
    'completing a job needs no user session'
);

select is(
    (select refunded_credits from public.fail_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000006',
        'OpenAI is unavailable.'
    )),
    1,
    'failing a job needs no user session and still refunds the row owner'
);

select is(
    (select generation_credits from public.profiles where id = 'aaaaaaaa-0000-4000-8000-000000000001'),
    7,
    'the refund lands on the owner recorded in the row, not on the caller'
);

-- Who may call what ------------------------------------------------------------------------------
-- Executed as catalog assertions rather than by impersonating the roles: this is the same privilege
-- Postgres itself consults at call time, and pgTAP's own bookkeeping cannot be written as
-- `authenticated` mid-transaction.
select is(
    has_function_privilege(
        'authenticated',
        'public.reserve_storyboard_generation(uuid,uuid,text,text,text,text,integer)',
        'execute'
    ),
    true,
    'a signed-in client may reserve its own generation'
);

select is(
    has_function_privilege('authenticated', 'public.start_storyboard_generation(uuid)', 'execute'),
    false,
    'a signed-in client may not claim a job'
);

select is(
    has_function_privilege('authenticated', 'public.complete_storyboard_generation(uuid,text,text)', 'execute'),
    false,
    'a signed-in client may not complete a job'
);

-- The one that would otherwise be an outright exploit: the image is readable in the caller's own
-- storage folder a moment before the row is settled, so a client that could fail its own row could
-- keep the artwork and take the refund.
select is(
    has_function_privilege('authenticated', 'public.fail_storyboard_generation(uuid,text)', 'execute'),
    false,
    'a signed-in client may not fail a job or trigger its refund'
);

select is(
    has_function_privilege('authenticated', 'public.finish_failed_storyboard_generation(uuid,text)', 'execute'),
    false,
    'a signed-in client may not reach the shared failing transition'
);

select is(
    has_function_privilege(
        'authenticated',
        'public.sweep_stale_storyboard_generations(interval,interval,integer)',
        'execute'
    ),
    false,
    'a signed-in client may not run the sweeper'
);

select is(
    has_function_privilege('anon', 'public.fail_storyboard_generation(uuid,text)', 'execute'),
    false,
    'an anonymous caller may not fail a job either'
);

select is(
    has_function_privilege('service_role', 'public.start_storyboard_generation(uuid)', 'execute'),
    true,
    'the background worker may claim a job'
);

select is(
    has_function_privilege('service_role', 'public.complete_storyboard_generation(uuid,text,text)', 'execute'),
    true,
    'the background worker may complete a job'
);

select is(
    has_function_privilege('service_role', 'public.fail_storyboard_generation(uuid,text)', 'execute'),
    true,
    'the background worker may fail a job'
);

select is(
    has_function_privilege('service_role', 'public.finish_failed_storyboard_generation(uuid,text)', 'execute'),
    false,
    'even the worker reaches the shared transition only through the entry point'
);

-- Lifecycle and credit columns are server-owned; storyboard metadata stays the client's to write.
select is(
    has_column_privilege('authenticated', 'public.entry_storyboards', 'generation_status', 'update'),
    false,
    'a signed-in client may not move a generation between states'
);

select is(
    has_column_privilege('authenticated', 'public.entry_storyboards', 'generation_status', 'insert'),
    false,
    'a signed-in client may not choose the state a storyboard is born in'
);

select is(
    has_column_privilege('authenticated', 'public.entry_storyboards', 'reserved_credits', 'insert'),
    false,
    'a signed-in client may not claim a reservation it never paid'
);

select is(
    has_column_privilege('authenticated', 'public.entry_storyboards', 'refunded_credits', 'update'),
    false,
    'a signed-in client may not rewrite what it was refunded'
);

select is(
    has_column_privilege('authenticated', 'public.entry_storyboards', 'completed_at', 'update'),
    false,
    'a signed-in client may not erase the record that a generation finished'
);

select is(
    has_column_privilege('authenticated', 'public.entry_storyboards', 'is_primary', 'update'),
    true,
    'choosing the primary storyboard is still the client its own'
);

select is(
    has_column_privilege('authenticated', 'public.entry_storyboards', 'storage_path', 'insert'),
    true,
    'storyboard duplication can still write its own metadata'
);

-- The sweeper is scheduled ------------------------------------------------------------------------
select case
    when to_regclass('cron.job') is null
        then skip('pg_cron is not installed in this database', 1)
    else is(
        (select count(*)::int from public.verify_storyboard_sweeper() where not passed),
        0,
        'every sweeper schedule check passes'
    )
end;

-- Remove the job and prove the verification notices. The transaction rolls back either way, and the
-- job is rescheduled below regardless.
do $$
begin
    if to_regclass('cron.job') is not null
       and exists (select 1 from cron.job where jobname = 'sweep-stale-storyboard-generations')
    then
        perform cron.unschedule('sweep-stale-storyboard-generations');
    end if;
end $$;

select case
    when to_regclass('cron.job') is null
        then skip('pg_cron is not installed in this database', 1)
    else ok(
        exists (select 1 from public.verify_storyboard_sweeper() where not passed),
        'verification fails when the sweeper job is missing'
    )
end;

select case
    when to_regclass('cron.job') is null
        then skip('pg_cron is not installed in this database', 1)
    else throws_ok(
        'select public.assert_storyboard_sweeper_scheduled()',
        'P0001',
        'the deployment assertion refuses to pass without a scheduled sweeper'
    )
end;

do $$
begin
    if to_regclass('cron.job') is not null then
        perform cron.schedule(
            'sweep-stale-storyboard-generations',
            '*/5 * * * *',
            $cron$select public.sweep_stale_storyboard_generations();$cron$
        );
    end if;
end $$;

select * from finish();

rollback;
