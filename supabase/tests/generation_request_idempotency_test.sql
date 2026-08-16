-- One intent, one reservation, one credit.
--
-- Run with: supabase test db   (requires the local Supabase stack)
--
-- Before the request id existed, every delivery of a generation request minted a fresh storyboard
-- and took fresh credits, and the only thing standing between a user and a double charge was an
-- in-memory flag on the client. These assertions cover the cases that flag cannot: a retry after a
-- dropped response, a relaunch after the process was killed, and two deliveries that overlap.

create extension if not exists pgtap with schema extensions;

begin;

select plan(16);

-- Fixtures -------------------------------------------------------------------------------------
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
values (
    '00000000-0000-0000-0000-000000000000',
    'dddddddd-0000-4000-8000-000000000001',
    'authenticated', 'authenticated',
    'idempotency@example.com', 'x', now(), now()
);

insert into public.entries (user_id, client_entry_id, title, content)
values (
    'dddddddd-0000-4000-8000-000000000001',
    'dddddddd-0000-4000-8000-0000000000e1',
    'A retried afternoon',
    'The request went out more than once.'
);

update public.profiles
set generation_credits = 10
where id = 'dddddddd-0000-4000-8000-000000000001';

insert into public.subscriptions (
    user_id, product_id, original_transaction_id, status,
    current_period_start, current_period_end
)
values (
    'dddddddd-0000-4000-8000-000000000001',
    'com.journaltopia.plus.monthly',
    'idempotency-original-transaction',
    'active',
    now() - interval '1 day',
    now() + interval '29 days'
);

select set_config(
    'request.jwt.claims',
    '{"sub":"dddddddd-0000-4000-8000-000000000001","role":"authenticated"}',
    true
);

-- The first delivery -------------------------------------------------------------------------------
select is(
    (select id from public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-0000000000d1',   -- storyboard id
        '99999999-0000-4000-8000-000000000001',   -- generation request id
        'dddddddd-0000-4000-8000-0000000000e1',
        'dddd/eeee/one.jpg', 'Anime', 'medium', 'a retried afternoon', 2
    )),
    'cccccccc-0000-4000-8000-0000000000d1',
    'the first delivery reserves the storyboard it was given'
);

select is(
    (select generation_credits from public.profiles where id = 'dddddddd-0000-4000-8000-000000000001'),
    8,
    'the first delivery spends the HD cost once'
);

-- A. / B. The retry ---------------------------------------------------------------------------------
-- The client could not know whether the first request landed, so it sends the same request id again.
-- A new storyboard id rides along, exactly as it would from a real retry, and must be ignored in
-- favour of the reservation that already exists.
select is(
    (select id from public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-0000000000d2',   -- a different storyboard id
        '99999999-0000-4000-8000-000000000001',   -- the same request id
        'dddddddd-0000-4000-8000-0000000000e1',
        'dddd/eeee/two.jpg', 'Anime', 'medium', 'a retried afternoon', 2
    )),
    'cccccccc-0000-4000-8000-0000000000d1',
    'a retry returns the storyboard the first delivery reserved'
);

select is(
    (select generation_credits from public.profiles where id = 'dddddddd-0000-4000-8000-000000000001'),
    8,
    'a retry does not deduct a second time'
);

select is(
    (select count(*)::int from public.entry_storyboards
     where user_id = 'dddddddd-0000-4000-8000-000000000001'),
    1,
    'a retry does not create a second storyboard row'
);

select is(
    (select count(*)::int from public.credit_ledger
     where user_id = 'dddddddd-0000-4000-8000-000000000001'
       and reason = 'storyboard_reservation'),
    1,
    'a retry does not write a second reservation ledger entry'
);

select is(
    (select count(*)::int from public.entry_storyboards
     where id = 'cccccccc-0000-4000-8000-0000000000d2'),
    0,
    'the retry''s unused storyboard id was never written'
);

-- The retry is answered from the reservation, not re-authorised ---------------------------------------
-- A subscription that lapsed between the two deliveries, or a balance now too small to afford the
-- generation, must not turn an already-paid reservation into an error. The user has been charged;
-- they are owed the storyboard.
update public.subscriptions
set status = 'expired'
where user_id = 'dddddddd-0000-4000-8000-000000000001';

update public.profiles
set generation_credits = 0
where id = 'dddddddd-0000-4000-8000-000000000001';

select is(
    (select id from public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-0000000000d3',
        '99999999-0000-4000-8000-000000000001',
        'dddddddd-0000-4000-8000-0000000000e1',
        'dddd/eeee/three.jpg', 'Anime', 'medium', 'a retried afternoon', 2
    )),
    'cccccccc-0000-4000-8000-0000000000d1',
    'a retry still returns its reservation after the subscription lapsed'
);

select is(
    (select generation_credits from public.profiles where id = 'dddddddd-0000-4000-8000-000000000001'),
    0,
    'answering a retry moves no credits'
);

-- C. A genuinely new generation ----------------------------------------------------------------------
update public.subscriptions
set status = 'active',
    current_period_end = now() + interval '29 days'
where user_id = 'dddddddd-0000-4000-8000-000000000001';

update public.profiles
set generation_credits = 5
where id = 'dddddddd-0000-4000-8000-000000000001';

select is(
    (select id from public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-0000000000d4',
        '99999999-0000-4000-8000-000000000002',   -- a new request id
        'dddddddd-0000-4000-8000-0000000000e1',
        'dddd/eeee/four.jpg', 'Anime', 'low', 'a retried afternoon', 1
    )),
    'cccccccc-0000-4000-8000-0000000000d4',
    'a new request id reserves a new storyboard'
);

select is(
    (select generation_credits from public.profiles where id = 'dddddddd-0000-4000-8000-000000000001'),
    4,
    'a genuinely new generation spends again'
);

select is(
    (select count(*)::int from public.entry_storyboards
     where user_id = 'dddddddd-0000-4000-8000-000000000001'),
    2,
    'the two intentional generations produced two storyboards'
);

-- The constraint itself ------------------------------------------------------------------------------
-- Enforced in Postgres, not only in the function, so a future caller cannot route around it.
select ok(
    exists (
        select 1 from pg_indexes
        where schemaname = 'public'
          and tablename = 'entry_storyboards'
          and indexname = 'entry_storyboards_generation_request_key'
    ),
    'the request id is enforced by a unique index rather than by convention alone'
);

-- Scoped per user: request ids are client-generated, so one account's id must not collide with
-- another's, and must not be usable to probe for it.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
values (
    '00000000-0000-0000-0000-000000000000',
    'dddddddd-0000-4000-8000-000000000002',
    'authenticated', 'authenticated',
    'idempotency-two@example.com', 'x', now(), now()
);

insert into public.entries (user_id, client_entry_id, title, content)
values (
    'dddddddd-0000-4000-8000-000000000002',
    'dddddddd-0000-4000-8000-0000000000e2',
    'Another account',
    'Same request id, different person.'
);

update public.profiles
set generation_credits = 5
where id = 'dddddddd-0000-4000-8000-000000000002';

insert into public.subscriptions (
    user_id, product_id, original_transaction_id, status,
    current_period_start, current_period_end
)
values (
    'dddddddd-0000-4000-8000-000000000002',
    'com.journaltopia.plus.monthly',
    'idempotency-original-transaction-two',
    'active',
    now() - interval '1 day',
    now() + interval '29 days'
);

select set_config(
    'request.jwt.claims',
    '{"sub":"dddddddd-0000-4000-8000-000000000002","role":"authenticated"}',
    true
);

select is(
    (select id from public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-0000000000d5',
        '99999999-0000-4000-8000-000000000001',   -- the first account's request id
        'dddddddd-0000-4000-8000-0000000000e2',
        'dddd/eeee/five.jpg', 'Anime', 'low', 'another account', 1
    )),
    'cccccccc-0000-4000-8000-0000000000d5',
    'the same request id from a different account reserves its own storyboard'
);

select is(
    (select generation_credits from public.profiles where id = 'dddddddd-0000-4000-8000-000000000002'),
    4,
    'the second account paid for its own generation'
);

-- A reservation with no request id is refused outright, so the idempotency key cannot be made
-- optional by a caller that simply omits it.
select throws_like(
    $$select public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-0000000000d6',
        null,
        'dddddddd-0000-4000-8000-0000000000e2',
        'dddd/eeee/six.jpg', 'Anime', 'low', 'another account', 1
    )$$,
    '%missing_generation_request_id%',
    'a reservation without a request id is refused'
);

select * from finish();

rollback;
