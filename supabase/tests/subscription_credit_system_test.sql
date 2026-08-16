-- Journaltopia+ entitlement, the credit ledger, and the monthly grant.
--
-- Run with: supabase test db   (requires the local Supabase stack)
--
-- The properties here are the ones money depends on: a period grants once and only once, a
-- generation cannot be reserved without an entitlement, and every credit that moves leaves exactly
-- one row saying why. The storyboard lifecycle's own guarantees are covered by
-- storyboard_generation_lifecycle_test.sql and are not repeated; what is checked below is how that
-- lifecycle now appears in the ledger.

create extension if not exists pgtap with schema extensions;

begin;

select plan(56);

-- Fixtures -------------------------------------------------------------------------------------
-- Two accounts: one that will hold a subscription, one that never does.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
values
    (
        '00000000-0000-0000-0000-000000000000',
        'eeeeeeee-0000-4000-8000-000000000001',
        'authenticated', 'authenticated',
        'subscriber@example.com', 'x', now(), now()
    ),
    (
        '00000000-0000-0000-0000-000000000000',
        'eeeeeeee-0000-4000-8000-000000000002',
        'authenticated', 'authenticated',
        'free-user@example.com', 'x', now(), now()
    );

insert into public.entries (user_id, client_entry_id, title, content)
values
    (
        'eeeeeeee-0000-4000-8000-000000000001',
        'ffffffff-0000-4000-8000-000000000001',
        'A subscribed afternoon',
        'The credits came from a subscription.'
    ),
    (
        'eeeeeeee-0000-4000-8000-000000000002',
        'ffffffff-0000-4000-8000-000000000002',
        'An unsubscribed afternoon',
        'No plan, no generation.'
    );

-- A. New profiles start empty ---------------------------------------------------------------------
select is(
    (select generation_credits from public.profiles where id = 'eeeeeeee-0000-4000-8000-000000000001'),
    0,
    'a new profile starts with no credits'
);

select is(
    (select generation_credits from public.profiles where id = 'eeeeeeee-0000-4000-8000-000000000002'),
    0,
    'the free account starts with no credits either'
);

-- B / C. Entitlement and history are server-owned --------------------------------------------------
select is(
    has_table_privilege('authenticated', 'public.subscriptions', 'insert'),
    false,
    'a signed-in client may not declare itself subscribed'
);

select is(
    has_table_privilege('authenticated', 'public.subscriptions', 'update'),
    false,
    'a signed-in client may not extend its own subscription'
);

select is(
    has_table_privilege('authenticated', 'public.subscriptions', 'delete'),
    false,
    'a signed-in client may not delete subscription records'
);

select ok(
    has_table_privilege('authenticated', 'public.subscriptions', 'select'),
    'a signed-in client may read its own subscription state'
);

select is(
    has_table_privilege('anon', 'public.subscriptions', 'select'),
    false,
    'entitlement is not readable signed out'
);

select is(
    has_table_privilege('authenticated', 'public.credit_ledger', 'insert'),
    false,
    'a signed-in client may not write its own credit history'
);

select is(
    has_table_privilege('authenticated', 'public.credit_ledger', 'update'),
    false,
    'a signed-in client may not rewrite credit history'
);

select is(
    has_table_privilege('authenticated', 'public.credit_ledger', 'delete'),
    false,
    'a signed-in client may not erase credit history'
);

select ok(
    has_table_privilege('authenticated', 'public.credit_ledger', 'select'),
    'a signed-in client may read its own credit history'
);

select is(
    has_function_privilege('authenticated', 'public.grant_subscription_credits(uuid)', 'execute'),
    false,
    'a signed-in client may not grant itself subscription credits'
);

select is(
    has_function_privilege('anon', 'public.grant_subscription_credits(uuid)', 'execute'),
    false,
    'an anonymous caller may not grant subscription credits either'
);

select ok(
    has_function_privilege('service_role', 'public.grant_subscription_credits(uuid)', 'execute'),
    'the verified-purchase path may grant subscription credits'
);

-- One Apple subscription, one Journaltopia account ---------------------------------------------------
insert into public.subscriptions (
    id, user_id, product_id, original_transaction_id, status,
    current_period_start, current_period_end, environment
)
values (
    'aaaabbbb-0000-4000-8000-000000000001',
    'eeeeeeee-0000-4000-8000-000000000001',
    'com.journaltopia.plus.monthly',
    'apple-original-transaction-1',
    'active',
    date_trunc('second', now()) - interval '3 days',
    now() + interval '27 days',
    'sandbox'
);

select throws_ok(
    $$insert into public.subscriptions (
        user_id, product_id, original_transaction_id, status,
        current_period_start, current_period_end
    )
    values (
        'eeeeeeee-0000-4000-8000-000000000002',
        'com.journaltopia.plus.monthly',
        'apple-original-transaction-1',
        'active',
        now(),
        now() + interval '30 days'
    )$$,
    '23505',
    null,
    'the same Apple subscription cannot entitle a second account'
);

-- D / E / F. The monthly grant ---------------------------------------------------------------------
select is(
    (select granted from public.grant_subscription_credits('aaaabbbb-0000-4000-8000-000000000001')),
    25,
    'a period grant adds exactly 25 credits'
);

select is(
    (select generation_credits from public.profiles where id = 'eeeeeeee-0000-4000-8000-000000000001'),
    25,
    'the balance reflects the grant'
);

select is(
    (select count(*)::int from public.credit_ledger
     where user_id = 'eeeeeeee-0000-4000-8000-000000000001'
       and reason = 'subscription_monthly_grant'),
    1,
    'the grant is recorded once in the ledger'
);

select is(
    (select balance_after from public.credit_ledger
     where user_id = 'eeeeeeee-0000-4000-8000-000000000001'
       and reason = 'subscription_monthly_grant'),
    25,
    'the ledger entry records the balance it produced'
);

-- The repeat that a redelivered App Store notification would cause.
select is(
    (select granted from public.grant_subscription_credits('aaaabbbb-0000-4000-8000-000000000001')),
    0,
    're-running the same period grant adds nothing'
);

select is(
    (select already_granted from public.grant_subscription_credits('aaaabbbb-0000-4000-8000-000000000001')),
    true,
    'a repeat reports that the period was already granted'
);

select is(
    (select generation_credits from public.profiles where id = 'eeeeeeee-0000-4000-8000-000000000001'),
    25,
    'a repeated grant does not move the balance'
);

select is(
    (select count(*)::int from public.credit_ledger
     where user_id = 'eeeeeeee-0000-4000-8000-000000000001'
       and reason = 'subscription_monthly_grant'),
    1,
    'a repeated grant does not add a second ledger entry'
);

-- Spend some of it, then renew, to prove the grant adds rather than resets.
update public.profiles
set generation_credits = 7
where id = 'eeeeeeee-0000-4000-8000-000000000001';

update public.subscriptions
set current_period_start = date_trunc('second', now()) + interval '27 days',
    current_period_end = now() + interval '57 days'
where id = 'aaaabbbb-0000-4000-8000-000000000001';

select is(
    (select granted from public.grant_subscription_credits('aaaabbbb-0000-4000-8000-000000000001')),
    25,
    'a new subscription period grants again'
);

select is(
    (select generation_credits from public.profiles where id = 'eeeeeeee-0000-4000-8000-000000000001'),
    32,
    'unused credits roll over: 7 + 25 = 32 rather than a reset to 25'
);

select is(
    (select count(*)::int from public.credit_ledger
     where user_id = 'eeeeeeee-0000-4000-8000-000000000001'
       and reason = 'subscription_monthly_grant'),
    2,
    'each period leaves its own ledger entry'
);

-- A subscription that is not current cannot grant.
update public.subscriptions
set status = 'expired'
where id = 'aaaabbbb-0000-4000-8000-000000000001';

select throws_like(
    $$select public.grant_subscription_credits('aaaabbbb-0000-4000-8000-000000000001')$$,
    '%subscription_not_active%',
    'an inactive subscription cannot grant credits'
);

update public.subscriptions
set status = 'active',
    current_period_end = now() - interval '1 day',
    current_period_start = now() - interval '31 days'
where id = 'aaaabbbb-0000-4000-8000-000000000001';

select throws_like(
    $$select public.grant_subscription_credits('aaaabbbb-0000-4000-8000-000000000001')$$,
    '%subscription_not_active%',
    'a lapsed period cannot grant credits even while marked active'
);

select throws_like(
    $$select public.grant_subscription_credits('aaaabbbb-0000-4000-8000-00000000ffff')$$,
    '%subscription_not_found%',
    'granting against an unknown subscription fails rather than inventing one'
);

-- G. Generation requires an entitlement -------------------------------------------------------------
-- The free account, with credits but no subscription. Credits alone must not be enough, or the
-- paywall is decorative.
update public.profiles
set generation_credits = 10
where id = 'eeeeeeee-0000-4000-8000-000000000002';

select set_config(
    'request.jwt.claims',
    '{"sub":"eeeeeeee-0000-4000-8000-000000000002","role":"authenticated"}',
    true
);

select throws_like(
    $$select public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-0000000000a1',
        '70000008-0000-4000-8000-000000000008',
        'ffffffff-0000-4000-8000-000000000002',
        'eeee/ffff/one.jpg', 'Anime', 'low', 'an unsubscribed afternoon', 1
    )$$,
    '%subscription_required%',
    'reserving without Journaltopia+ is refused'
);

select is(
    (select generation_credits from public.profiles where id = 'eeeeeeee-0000-4000-8000-000000000002'),
    10,
    'a refused reservation does not deduct credits'
);

select is(
    (select count(*)::int from public.credit_ledger where user_id = 'eeeeeeee-0000-4000-8000-000000000002'),
    0,
    'a refused reservation writes no ledger entry'
);

select is(
    (select count(*)::int from public.entry_storyboards where id = 'cccccccc-0000-4000-8000-0000000000a1'),
    0,
    'a refused reservation creates no storyboard row'
);

-- H / J. Entitled, with credits ---------------------------------------------------------------------
update public.subscriptions
set status = 'active',
    current_period_start = date_trunc('second', now()) - interval '1 day',
    current_period_end = now() + interval '29 days'
where id = 'aaaabbbb-0000-4000-8000-000000000001';

update public.profiles
set generation_credits = 3
where id = 'eeeeeeee-0000-4000-8000-000000000001';

select set_config(
    'request.jwt.claims',
    '{"sub":"eeeeeeee-0000-4000-8000-000000000001","role":"authenticated"}',
    true
);

select lives_ok(
    $$select public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-0000000000b1',
        '70000009-0000-4000-8000-000000000009',
        'ffffffff-0000-4000-8000-000000000001',
        'eeee/ffff/hd.jpg', 'Anime', 'medium', 'a subscribed afternoon', 2
    )$$,
    'an entitled subscriber with credits can reserve'
);

select is(
    (select generation_credits from public.profiles where id = 'eeeeeeee-0000-4000-8000-000000000001'),
    1,
    'the HD reservation deducts two credits'
);

select is(
    (select count(*)::int from public.credit_ledger
     where reason = 'storyboard_reservation'
       and source_id = 'cccccccc-0000-4000-8000-0000000000b1'),
    1,
    'the reservation writes exactly one ledger entry'
);

select is(
    (select delta from public.credit_ledger
     where reason = 'storyboard_reservation'
       and source_id = 'cccccccc-0000-4000-8000-0000000000b1'),
    -2,
    'the reservation entry is negative and matches the cost'
);

select is(
    (select balance_after from public.credit_ledger
     where reason = 'storyboard_reservation'
       and source_id = 'cccccccc-0000-4000-8000-0000000000b1'),
    1,
    'the reservation entry records the balance it left behind'
);

-- I. Entitled but out of credits --------------------------------------------------------------------
-- The distinction that matters for the UI: this is not subscription_required.
select throws_like(
    $$select public.reserve_storyboard_generation(
        'cccccccc-0000-4000-8000-0000000000b2',
        '70000010-0000-4000-8000-000000000010',
        'ffffffff-0000-4000-8000-000000000001',
        'eeee/ffff/broke.jpg', 'Anime', 'medium', 'a subscribed afternoon', 2
    )$$,
    '%insufficient_generation_credits%',
    'an entitled subscriber without enough credits gets the credit error, not the paywall error'
);

select is(
    (select generation_credits from public.profiles where id = 'eeeeeeee-0000-4000-8000-000000000001'),
    1,
    'the failed reservation left the balance alone'
);

-- K / L. Refunds appear once ------------------------------------------------------------------------
select is(
    public.start_storyboard_generation('cccccccc-0000-4000-8000-0000000000b1'),
    true,
    'the reserved job is claimed'
);

select is(
    (select refunded_credits from public.fail_storyboard_generation(
        'cccccccc-0000-4000-8000-0000000000b1',
        'OpenAI did not return a storyboard image.'
    )),
    2,
    'failing refunds the whole reservation'
);

select is(
    (select generation_credits from public.profiles where id = 'eeeeeeee-0000-4000-8000-000000000001'),
    3,
    'the refund returns the balance to what it was before the reservation'
);

select is(
    (select count(*)::int from public.credit_ledger
     where reason = 'storyboard_refund'
       and source_id = 'cccccccc-0000-4000-8000-0000000000b1'),
    1,
    'the refund writes exactly one ledger entry'
);

select is(
    (select delta from public.credit_ledger
     where reason = 'storyboard_refund'
       and source_id = 'cccccccc-0000-4000-8000-0000000000b1'),
    2,
    'the refund entry is positive and matches the reservation'
);

-- One storyboard, two entries, kept apart by reason rather than by source.
select is(
    (select count(*)::int from public.credit_ledger
     where source_id = 'cccccccc-0000-4000-8000-0000000000b1'),
    2,
    'a reserved-then-failed storyboard leaves one spend and one refund'
);

select is(
    (select refunded_credits from public.fail_storyboard_generation(
        'cccccccc-0000-4000-8000-0000000000b1',
        'a duplicated failure path'
    )),
    2,
    'a repeated failure reports the refund that already happened'
);

select is(
    (select generation_credits from public.profiles where id = 'eeeeeeee-0000-4000-8000-000000000001'),
    3,
    'a repeated failure does not refund a second time'
);

select is(
    (select count(*)::int from public.credit_ledger
     where reason = 'storyboard_refund'
       and source_id = 'cccccccc-0000-4000-8000-0000000000b1'),
    1,
    'a repeated failure does not add a second refund entry'
);

-- M. Sample authoring is outside all of this --------------------------------------------------------
-- Sample Studio generation never calls reserve_storyboard_generation — generate-sample-storyboard
-- writes the sample_* tables and spends nothing — so entitlement cannot apply to it. Asserted
-- structurally: the sample tables carry no credit or entitlement coupling to reach.
select is(
    (select count(*)::int
     from information_schema.columns
     where table_schema = 'public'
       and table_name like 'sample%'
       and (column_name like '%credit%' or column_name like '%subscription%')),
    0,
    'sample content has no credit or subscription coupling, so authoring stays free'
);

select is(
    (select count(*)::int from public.credit_ledger
     where user_id = 'eeeeeeee-0000-4000-8000-000000000002'),
    0,
    'the unsubscribed account never had a credit event at all'
);

-- The read model ------------------------------------------------------------------------------------
select ok(
    has_table_privilege('authenticated', 'public.storytopia_plus_entitlement', 'select'),
    'the app can read its own entitlement and balance in one place'
);

select is(
    (select is_active from public.storytopia_plus_entitlement),
    true,
    'the read model reports an active subscriber as entitled'
);

select is(
    (select generation_credits from public.storytopia_plus_entitlement),
    3,
    'the read model reports the balance from profiles rather than a second copy'
);

select is(
    (select product_id from public.storytopia_plus_entitlement),
    'com.journaltopia.plus.monthly',
    'the read model reports which product entitles the user'
);

-- Signed in as the account with no subscription.
select set_config(
    'request.jwt.claims',
    '{"sub":"eeeeeeee-0000-4000-8000-000000000002","role":"authenticated"}',
    true
);

select is(
    (select is_active from public.storytopia_plus_entitlement),
    false,
    'the read model reports an unsubscribed account as not entitled'
);

select * from finish();

rollback;
