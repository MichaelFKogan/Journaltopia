-- Lifecycle and refund guarantees for background storyboard generation.
--
-- Run with: supabase test db   (requires the local Supabase stack)
--
-- The properties that matter here are the ones no client can be trusted with: a job is claimed by
-- exactly one worker, a completed job stays completed, a failed job refunds exactly once, and the
-- sweeper can never turn one stuck generation into two refunds.

create extension if not exists pgtap with schema extensions;

begin;

select plan(39);

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
select lives_ok(
    $$select public.complete_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000001',
        'aaaa/bbbb/one.jpg',
        null
    )$$,
    'a claimed job can be completed'
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

select lives_ok(
    $$select public.complete_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000001',
        'aaaa/bbbb/one.jpg',
        null
    )$$,
    'a retried background task can complete the same job again'
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

select throws_ok(
    $$select public.complete_storyboard_generation(
        'cccccccc-0000-4000-8000-000000000002',
        'aaaa/bbbb/two.jpg',
        null
    )$$,
    'storyboard_already_failed',
    'a refunded generation cannot be completed afterwards'
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

select * from finish();

rollback;
