-- Binding a verified Apple subscription to a Journaltopia account.
--
-- Run with: supabase test db   (requires the local Supabase stack)
--
-- These assertions cover sync_apple_subscription, which is where Apple's verified state becomes
-- entitlement and credits. What they cannot cover is the verification itself: whether a signed
-- transaction is genuine is decided in the Edge Function by checking Apple's certificate chain, and
-- there is no signing key on this side of that boundary. What is asserted here instead is that the
-- database never has an opportunity to be fooled — it is unreachable by clients at all, so a forged
-- transaction has nowhere to arrive.

create extension if not exists pgtap with schema extensions;

begin;

select plan(35);

-- Fixtures -------------------------------------------------------------------------------------
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
values
    (
        '00000000-0000-0000-0000-000000000000',
        'abababab-0000-4000-8000-000000000001',
        'authenticated', 'authenticated',
        'apple-one@example.com', 'x', now(), now()
    ),
    (
        '00000000-0000-0000-0000-000000000000',
        'abababab-0000-4000-8000-000000000002',
        'authenticated', 'authenticated',
        'apple-two@example.com', 'x', now(), now()
    );

insert into public.entries (user_id, client_entry_id, title, content)
values (
    'abababab-0000-4000-8000-000000000001',
    'abababab-0000-4000-8000-0000000000e1',
    'A subscribed afternoon',
    'Bought through the App Store.'
);

-- H. Forged entitlement has nowhere to arrive -------------------------------------------------------
-- The verification that decides whether Apple's data is genuine happens in the Edge Function. The
-- guarantee the database provides is narrower and stronger: no client role can reach the write at
-- all, so unverified data cannot become entitlement no matter what the client sends.
select is(
    has_function_privilege('authenticated', 'public.sync_apple_subscription(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text)', 'execute'),
    false,
    'a signed-in client cannot record its own Apple subscription'
);

select is(
    has_function_privilege('anon', 'public.sync_apple_subscription(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text)', 'execute'),
    false,
    'an anonymous caller cannot record an Apple subscription'
);

select ok(
    has_function_privilege('service_role', 'public.sync_apple_subscription(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text)', 'execute'),
    'only the verifying server path may record an Apple subscription'
);

select is(
    has_table_privilege('authenticated', 'public.subscriptions', 'insert'),
    false,
    'a client still cannot write the subscriptions table directly'
);

-- A status Apple would never produce is refused rather than stored, so a bug upstream cannot invent
-- an entitlement state that has_active_journaltopia_plus has never been reasoned about.
select throws_like(
    $$select public.sync_apple_subscription(
        'abababab-0000-4000-8000-000000000001',
        'com.journaltopia.plus.monthly', 'apple-txn-bogus', 'apple-txn-bogus',
        'definitely_subscribed', now(), now() + interval '30 days', true, 'sandbox'
    )$$,
    '%invalid_subscription_status%',
    'an unrecognised subscription status is refused'
);

select throws_like(
    $$select public.sync_apple_subscription(
        'abababab-0000-4000-8000-000000000001',
        'com.journaltopia.plus.monthly', '', '',
        'active', now(), now() + interval '30 days', true, 'sandbox'
    )$$,
    '%missing_original_transaction_id%',
    'a transaction with no Apple identity is refused'
);

-- D. / E. First sync, then the same one again --------------------------------------------------------
select is(
    (select granted from public.sync_apple_subscription(
        'abababab-0000-4000-8000-000000000001',
        'com.journaltopia.plus.monthly', 'apple-txn-1', 'apple-txn-1',
        'active', date_trunc('second', now()), now() + interval '30 days', true, 'sandbox'
    )),
    25,
    'the first verified period grants 25 credits'
);

select is(
    (select generation_credits from public.profiles where id = 'abababab-0000-4000-8000-000000000001'),
    25,
    'the balance reflects the first grant'
);

select is(
    (select count(*)::int from public.subscriptions where original_transaction_id = 'apple-txn-1'),
    1,
    'the subscription is recorded once'
);

select ok(
    public.has_active_journaltopia_plus('abababab-0000-4000-8000-000000000001'),
    'the synced subscriber is entitled'
);

-- The same transaction arriving again: a listener redelivery, a relaunch reconciliation, and an App
-- Store notification can all report the same period.
select is(
    (select granted from public.sync_apple_subscription(
        'abababab-0000-4000-8000-000000000001',
        'com.journaltopia.plus.monthly', 'apple-txn-1', 'apple-txn-1',
        'active', date_trunc('second', now()), now() + interval '30 days', true, 'sandbox'
    )),
    0,
    'syncing the same period again grants nothing further'
);

select is(
    (select already_granted from public.sync_apple_subscription(
        'abababab-0000-4000-8000-000000000001',
        'com.journaltopia.plus.monthly', 'apple-txn-1', 'apple-txn-1',
        'active', date_trunc('second', now()), now() + interval '30 days', true, 'sandbox'
    )),
    true,
    'a repeat reports that the period was already granted'
);

select is(
    (select generation_credits from public.profiles where id = 'abababab-0000-4000-8000-000000000001'),
    25,
    'repeated syncs do not move the balance'
);

select is(
    (select count(*)::int from public.subscriptions where original_transaction_id = 'apple-txn-1'),
    1,
    'repeated syncs do not create a duplicate subscription row'
);

-- K. Restore is just another repeat --------------------------------------------------------------
-- A restore replays whatever Apple currently considers active, which is the same period again.
select is(
    (select granted from public.sync_apple_subscription(
        'abababab-0000-4000-8000-000000000001',
        'com.journaltopia.plus.monthly', 'apple-txn-1', 'apple-txn-1',
        'active', date_trunc('second', now()), now() + interval '30 days', true, 'sandbox'
    )),
    0,
    'restoring does not grant a second time'
);

-- F. A genuine renewal ----------------------------------------------------------------------------
-- Spend some first, to show the renewal adds rather than resets.
update public.profiles
set generation_credits = 4
where id = 'abababab-0000-4000-8000-000000000001';

select is(
    (select granted from public.sync_apple_subscription(
        'abababab-0000-4000-8000-000000000001',
        'com.journaltopia.plus.monthly', 'apple-txn-1', 'apple-txn-2',
        'active', date_trunc('second', now()) + interval '30 days', now() + interval '60 days', true, 'sandbox'
    )),
    25,
    'a new paid period grants another 25'
);

select is(
    (select generation_credits from public.profiles where id = 'abababab-0000-4000-8000-000000000001'),
    29,
    'renewal credits roll over: 4 + 25 = 29'
);

select is(
    (select latest_transaction_id from public.subscriptions where original_transaction_id = 'apple-txn-1'),
    'apple-txn-2',
    'the renewal records the newer transaction id'
);

-- Apple redelivers, and out of order. A stale notification must not rewind the period, because the
-- next in-order delivery would then look like a new one and grant again.
select is(
    (select granted from public.sync_apple_subscription(
        'abababab-0000-4000-8000-000000000001',
        'com.journaltopia.plus.monthly', 'apple-txn-1', 'apple-txn-1',
        'active', date_trunc('second', now()), now() + interval '30 days', true, 'sandbox'
    )),
    0,
    'an out-of-order redelivery of the previous period grants nothing'
);

select is(
    (select generation_credits from public.profiles where id = 'abababab-0000-4000-8000-000000000001'),
    29,
    'an out-of-order redelivery does not move the balance'
);

select ok(
    (select current_period_end from public.subscriptions where original_transaction_id = 'apple-txn-1')
        > now() + interval '55 days',
    'an out-of-order redelivery does not rewind the period'
);

-- G. One Apple subscription, one Journaltopia account ------------------------------------------------
select is(
    (select conflict from public.sync_apple_subscription(
        'abababab-0000-4000-8000-000000000002',
        'com.journaltopia.plus.monthly', 'apple-txn-1', 'apple-txn-2',
        'active', date_trunc('second', now()) + interval '30 days', now() + interval '60 days', true, 'sandbox'
    )),
    'already_bound_to_another_account',
    'a second account cannot claim the same Apple subscription'
);

select is(
    (select user_id from public.subscriptions where original_transaction_id = 'apple-txn-1'),
    'abababab-0000-4000-8000-000000000001',
    'the collision leaves the original binding untouched'
);

select is(
    (select generation_credits from public.profiles where id = 'abababab-0000-4000-8000-000000000002'),
    0,
    'the colliding account is granted nothing'
);

select is(
    (select count(*)::int from public.credit_ledger where user_id = 'abababab-0000-4000-8000-000000000002'),
    0,
    'the colliding account gets no ledger entry either'
);

select ok(
    not public.has_active_journaltopia_plus('abababab-0000-4000-8000-000000000002'),
    'the colliding account is not entitled'
);

-- I. Expiry removes entitlement but not what was earned ---------------------------------------------
select is(
    (select is_entitled from public.sync_apple_subscription(
        'abababab-0000-4000-8000-000000000001',
        'com.journaltopia.plus.monthly', 'apple-txn-1', 'apple-txn-2',
        'expired', date_trunc('second', now()) + interval '30 days', now() + interval '60 days', false, 'sandbox'
    )),
    false,
    'an expired subscription is not entitled'
);

select ok(
    not public.has_active_journaltopia_plus('abababab-0000-4000-8000-000000000001'),
    'expiry removes generation entitlement'
);

select is(
    (select generation_credits from public.profiles where id = 'abababab-0000-4000-8000-000000000001'),
    29,
    'expiry leaves already-granted credits alone'
);

-- Existing storyboards stay readable: nothing about entitlement touches the storyboard tables, and
-- the select policy has never consulted it.
select ok(
    has_table_privilege('authenticated', 'public.entry_storyboards', 'select'),
    'existing storyboards remain readable after a subscription lapses'
);

-- Generation, however, stops.
select set_config(
    'request.jwt.claims',
    '{"sub":"abababab-0000-4000-8000-000000000001","role":"authenticated"}',
    true
);

select throws_like(
    $$select public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-0000000000f1',
        '88888888-0000-4000-8000-000000000001',
        'abababab-0000-4000-8000-0000000000e1',
        'abab/abab/one.jpg', 'Anime', 'low', 'a subscribed afternoon', 1
    )$$,
    '%subscription_required%',
    'a lapsed subscriber cannot start a new generation even with credits in hand'
);

-- J. Revocation ------------------------------------------------------------------------------------
select set_config('request.jwt.claims', '{"role":"service_role"}', true);

select is(
    (select is_entitled from public.sync_apple_subscription(
        'abababab-0000-4000-8000-000000000001',
        'com.journaltopia.plus.monthly', 'apple-txn-1', 'apple-txn-2',
        'revoked', date_trunc('second', now()) + interval '30 days', now() + interval '60 days', false, 'sandbox'
    )),
    false,
    'a revoked subscription is not entitled'
);

select ok(
    not public.has_active_journaltopia_plus('abababab-0000-4000-8000-000000000001'),
    'revocation removes entitlement even while the period would otherwise be current'
);

-- The notification path with no signed-in caller ------------------------------------------------------
-- Apple's notifications carry no Supabase session, so the owner comes from the row its identity
-- already points at. A notification about a subscription nobody has synced is reported rather than
-- attached to a guess.
select is(
    (select conflict from public.sync_apple_subscription(
        null,
        'com.journaltopia.plus.monthly', 'apple-txn-never-seen', 'apple-txn-never-seen',
        'active', now(), now() + interval '30 days', true, 'sandbox'
    )),
    'unknown_subscription',
    'a notification for an unknown subscription is reported, not bound to a guess'
);

select is(
    (select bound_user_id from public.sync_apple_subscription(
        null,
        'com.journaltopia.plus.monthly', 'apple-txn-1', 'apple-txn-2',
        'active', date_trunc('second', now()) + interval '30 days', now() + interval '60 days', true, 'sandbox'
    )),
    'abababab-0000-4000-8000-000000000001',
    'a notification for a known subscription resolves its owner from the existing row'
);

select * from finish();

rollback;
