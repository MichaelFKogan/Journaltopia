-- The two-bucket credit model: monthly credits that expire, purchased credits that do not.
--
-- Run with: supabase test db   (requires the local Supabase stack)
--
-- Every property here is one where getting it wrong takes money or value from somebody: a renewal
-- that wipes purchased credits, a refund that returns a monthly credit as a permanent one, a pack
-- redeemed twice, or the same Apple transaction credited to two accounts.

create extension if not exists pgtap with schema extensions;

begin;

select plan(71);

-- Fixtures -------------------------------------------------------------------------------------
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
values
    (
        '00000000-0000-0000-0000-000000000000', '11111111-0000-4000-8000-000000000001',
        'authenticated', 'authenticated', 'buckets-one@example.com', 'x', now(), now()
    ),
    (
        '00000000-0000-0000-0000-000000000000', '11111111-0000-4000-8000-000000000002',
        'authenticated', 'authenticated', 'buckets-two@example.com', 'x', now(), now()
    );

insert into public.entries (user_id, client_entry_id, title, content)
values (
    '11111111-0000-4000-8000-000000000001',
    '22222222-0000-4000-8000-000000000001',
    'A two bucket afternoon',
    'Monthly first, then purchased.'
);

insert into public.subscriptions (
    id, user_id, product_id, original_transaction_id, status,
    current_period_start, current_period_end
)
values (
    '33333333-0000-4000-8000-000000000001',
    '11111111-0000-4000-8000-000000000001',
    'com.journaltopia.plus.monthly',
    'bucket-original-transaction',
    'active',
    date_trunc('second', now()) - interval '1 day',
    now() + interval '29 days'
);

-- E. New profiles start empty, and the derived total tracks both buckets --------------------------
select is(
    (select generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    0,
    'a new profile starts with no credits in either bucket'
);

select ok(
    (select is_generated = 'ALWAYS' from information_schema.columns
     where table_schema = 'public' and table_name = 'profiles' and column_name = 'generation_credits'),
    'the old single balance is now derived, so it cannot be written or drift'
);

-- A. A new period sets monthly to exactly 25 -------------------------------------------------------
select is(
    (select granted from public.grant_subscription_credits('33333333-0000-4000-8000-000000000001')),
    25,
    'a new subscription period grants 25 monthly credits'
);

select is(
    (select monthly_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    25,
    'the monthly bucket holds exactly 25'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    0,
    'the grant puts nothing in the purchased bucket'
);

select is(
    (select generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    25,
    'the derived total reflects the grant'
);

-- B. The same period twice -------------------------------------------------------------------------
select is(
    (select granted from public.grant_subscription_credits('33333333-0000-4000-8000-000000000001')),
    0,
    'the same period does not grant again'
);

select is(
    (select already_granted from public.grant_subscription_credits('33333333-0000-4000-8000-000000000001')),
    true,
    'a repeat reports the period as already granted'
);

-- Crucially, a redelivery must not *reset* a bucket the user has spent from either.
update public.profiles
set monthly_generation_credits = 4
where id = '11111111-0000-4000-8000-000000000001';

select is(
    (select granted from public.grant_subscription_credits('33333333-0000-4000-8000-000000000001')),
    0,
    'a redelivered period grants nothing'
);

select is(
    (select monthly_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    4,
    'a redelivered period does not reset a partly spent monthly bucket'
);

-- C. / D. A genuinely new period replaces monthly and leaves purchased alone -----------------------
update public.profiles
set purchased_generation_credits = 20
where id = '11111111-0000-4000-8000-000000000001';

update public.subscriptions
set current_period_start = date_trunc('second', now()) + interval '29 days',
    current_period_end = now() + interval '59 days'
where id = '33333333-0000-4000-8000-000000000001';

select is(
    (select granted from public.grant_subscription_credits('33333333-0000-4000-8000-000000000001')),
    25,
    'a new period grants again'
);

select is(
    (select monthly_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    25,
    'the new period replaces the remaining 4 monthly credits with 25 rather than adding to them'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    20,
    'purchased credits survive the monthly reset untouched'
);

select is(
    (select generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    45,
    'the total is 25 monthly + 20 purchased'
);

-- The expiry is recorded rather than being silent arithmetic.
select is(
    (select delta from public.credit_ledger
     where user_id = '11111111-0000-4000-8000-000000000001'
       and reason = 'subscription_monthly_expiry'),
    -4,
    'the 4 expiring monthly credits are written to the ledger'
);

select is(
    (select count(*)::int from public.credit_ledger
     where user_id = '11111111-0000-4000-8000-000000000001'
       and reason = 'subscription_monthly_grant'),
    2,
    'each period leaves exactly one grant entry'
);

-- F. Standard spends monthly first -----------------------------------------------------------------
select set_config(
    'request.jwt.claims',
    '{"sub":"11111111-0000-4000-8000-000000000001","role":"authenticated"}',
    true
);

select lives_ok(
    $$select public.reserve_storyboard_generation(
        '44444444-0000-4000-8000-000000000001',
        '55555555-0000-4000-8000-000000000001',
        '22222222-0000-4000-8000-000000000001',
        'a/b/std.jpg', 'Anime', 'low', 'a two bucket afternoon', 1
    )$$,
    'a Standard generation reserves'
);

select is(
    (select monthly_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    24,
    'Standard takes its credit from the monthly bucket'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    20,
    'Standard leaves purchased credits alone while monthly ones remain'
);

select is(
    (select reserved_monthly_credits from public.entry_storyboards where id = '44444444-0000-4000-8000-000000000001'),
    1,
    'the reservation records that it took a monthly credit'
);

select is(
    (select reserved_purchased_credits from public.entry_storyboards where id = '44444444-0000-4000-8000-000000000001'),
    0,
    'and that it took no purchased credit'
);

select is(
    (select bucket from public.credit_ledger
     where reason = 'storyboard_reservation' and source_id = '44444444-0000-4000-8000-000000000001'),
    'monthly',
    'the ledger says which bucket the credit came from'
);

-- G. HD spans both buckets ---------------------------------------------------------------------------
update public.profiles
set monthly_generation_credits = 1, purchased_generation_credits = 10
where id = '11111111-0000-4000-8000-000000000001';

select lives_ok(
    $$select public.reserve_storyboard_generation(
        '44444444-0000-4000-8000-000000000002',
        '55555555-0000-4000-8000-000000000002',
        '22222222-0000-4000-8000-000000000001',
        'a/b/hd.jpg', 'Anime', 'medium', 'a two bucket afternoon', 2
    )$$,
    'an HD generation reserves across both buckets'
);

select is(
    (select monthly_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    0,
    'the last monthly credit is spent first'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    9,
    'the remainder comes from purchased'
);

select is(
    (select reserved_monthly_credits from public.entry_storyboards where id = '44444444-0000-4000-8000-000000000002'),
    1,
    'the split is recorded: one monthly'
);

select is(
    (select reserved_purchased_credits from public.entry_storyboards where id = '44444444-0000-4000-8000-000000000002'),
    1,
    'the split is recorded: one purchased'
);

select is(
    (select count(*)::int from public.credit_ledger
     where reason = 'storyboard_reservation' and source_id = '44444444-0000-4000-8000-000000000002'),
    2,
    'a generation spanning buckets writes one ledger entry per bucket'
);

-- K. A mixed-bucket failure restores both buckets accurately -------------------------------------------
select is(
    public.start_storyboard_generation('44444444-0000-4000-8000-000000000002'),
    true,
    'the mixed reservation is claimed'
);

select is(
    (select refunded_credits from public.fail_storyboard_generation(
        '44444444-0000-4000-8000-000000000002', 'OpenAI did not return a storyboard image.'
    )),
    2,
    'failing refunds the whole reservation'
);

select is(
    (select monthly_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    1,
    'the monthly credit goes back to the monthly bucket'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    10,
    'the purchased credit goes back to the purchased bucket, not the monthly one'
);

select is(
    (select refunded_monthly_credits from public.entry_storyboards where id = '44444444-0000-4000-8000-000000000002'),
    1,
    'the row records what went back to monthly'
);

select is(
    (select refunded_purchased_credits from public.entry_storyboards where id = '44444444-0000-4000-8000-000000000002'),
    1,
    'the row records what went back to purchased'
);

-- L. A repeated failure cannot double-refund either bucket -----------------------------------------
select is(
    (select refunded_credits from public.fail_storyboard_generation(
        '44444444-0000-4000-8000-000000000002', 'a duplicated failure path'
    )),
    2,
    'a repeated failure reports the refund that already happened'
);

select is(
    (select monthly_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    1,
    'a repeated failure does not refund the monthly bucket twice'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    10,
    'a repeated failure does not refund the purchased bucket twice'
);

select is(
    (select count(*)::int from public.credit_ledger
     where reason = 'storyboard_refund' and source_id = '44444444-0000-4000-8000-000000000002'),
    2,
    'exactly one refund entry per bucket, however many times it is retried'
);

-- H. Purchased credits are used when monthly is empty -------------------------------------------------
update public.profiles
set monthly_generation_credits = 0, purchased_generation_credits = 10
where id = '11111111-0000-4000-8000-000000000001';

select lives_ok(
    $$select public.reserve_storyboard_generation(
        '44444444-0000-4000-8000-000000000003',
        '55555555-0000-4000-8000-000000000003',
        '22222222-0000-4000-8000-000000000001',
        'a/b/purchased.jpg', 'Anime', 'low', 'a two bucket afternoon', 1
    )$$,
    'a generation reserves from purchased credits when monthly is empty'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    9,
    'the purchased bucket covers it'
);

-- I. Insufficient total still fails --------------------------------------------------------------------
update public.profiles
set monthly_generation_credits = 0, purchased_generation_credits = 1
where id = '11111111-0000-4000-8000-000000000001';

select throws_like(
    $$select public.reserve_storyboard_generation(
        '44444444-0000-4000-8000-000000000004',
        '55555555-0000-4000-8000-000000000004',
        '22222222-0000-4000-8000-000000000001',
        'a/b/broke.jpg', 'Anime', 'medium', 'a two bucket afternoon', 2
    )$$,
    '%insufficient_generation_credits%',
    'one credit across both buckets does not buy an HD page'
);

select is(
    (select generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    1,
    'a refused reservation moves nothing'
);

-- M. / N. Expiration ------------------------------------------------------------------------------------
update public.profiles
set monthly_generation_credits = 5, purchased_generation_credits = 12
where id = '11111111-0000-4000-8000-000000000001';

select set_config('request.jwt.claims', '{"role":"service_role"}', true);

select is(
    (select is_entitled from public.sync_apple_subscription(
        '11111111-0000-4000-8000-000000000001',
        'com.journaltopia.plus.monthly', 'bucket-original-transaction', 'bucket-latest',
        'expired', date_trunc('second', now()) + interval '29 days', now() + interval '59 days', false, 'sandbox'
    )),
    false,
    'an expired subscription is not entitled'
);

select is(
    (select monthly_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    0,
    'monthly credits are cleared when the subscription lapses'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    12,
    'purchased credits survive expiration and stay on the account'
);

select set_config(
    'request.jwt.claims',
    '{"sub":"11111111-0000-4000-8000-000000000001","role":"authenticated"}',
    true
);

select throws_like(
    $$select public.reserve_storyboard_generation(
        '44444444-0000-4000-8000-000000000005',
        '55555555-0000-4000-8000-000000000005',
        '22222222-0000-4000-8000-000000000001',
        'a/b/lapsed.jpg', 'Anime', 'low', 'a two bucket afternoon', 1
    )$$,
    '%subscription_required%',
    'purchased credits cannot be spent without an active subscription'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    12,
    'the refused generation left the purchased credits alone'
);

-- O/P/Q/R. The product price list -----------------------------------------------------------------------
select is(public.credit_pack_credit_amount('com.journaltopia.credits.10'), 10, 'the 10 pack is worth 10');
select is(public.credit_pack_credit_amount('com.journaltopia.credits.25'), 25, 'the 25 pack is worth 25');
select is(public.credit_pack_credit_amount('com.journaltopia.credits.60'), 60, 'the 60 pack is worth 60');
select is(public.credit_pack_credit_amount('com.journaltopia.credits.9999'), 0, 'an unknown product is worth nothing');
select is(public.credit_pack_credit_amount(null), 0, 'a missing product is worth nothing');

-- S. Non-subscribers cannot redeem ------------------------------------------------------------------------
select set_config('request.jwt.claims', '{"role":"service_role"}', true);

select is(
    (select conflict from public.redeem_credit_pack(
        '11111111-0000-4000-8000-000000000001', 'apple-pack-txn-1', 'com.journaltopia.credits.25'
    )),
    'subscription_required',
    'a lapsed account cannot redeem a credit pack'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    12,
    'the refused redemption credited nothing'
);

-- T. One transaction redeems once --------------------------------------------------------------------------
update public.subscriptions
set status = 'active', current_period_end = now() + interval '30 days'
where id = '33333333-0000-4000-8000-000000000001';

select is(
    (select credits_granted from public.redeem_credit_pack(
        '11111111-0000-4000-8000-000000000001', 'apple-pack-txn-1', 'com.journaltopia.credits.25'
    )),
    25,
    'a subscriber redeeming a 25 pack gets 25 purchased credits'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    37,
    'the pack lands in the purchased bucket: 12 + 25'
);

select is(
    (select monthly_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    0,
    'a pack never touches the monthly bucket'
);

select is(
    (select credits_granted from public.redeem_credit_pack(
        '11111111-0000-4000-8000-000000000001', 'apple-pack-txn-1', 'com.journaltopia.credits.25'
    )),
    0,
    'the same Apple transaction redeems only once'
);

select is(
    (select already_redeemed from public.redeem_credit_pack(
        '11111111-0000-4000-8000-000000000001', 'apple-pack-txn-1', 'com.journaltopia.credits.25'
    )),
    true,
    'a repeat reports the transaction as already redeemed'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000001'),
    37,
    'a repeated redemption adds nothing'
);

-- V. Cross-account redemption ---------------------------------------------------------------------------------
insert into public.subscriptions (
    user_id, product_id, original_transaction_id, status, current_period_start, current_period_end
)
values (
    '11111111-0000-4000-8000-000000000002',
    'com.journaltopia.plus.monthly', 'bucket-original-transaction-two', 'active',
    date_trunc('second', now()) - interval '1 day', now() + interval '29 days'
);

select is(
    (select conflict from public.redeem_credit_pack(
        '11111111-0000-4000-8000-000000000002', 'apple-pack-txn-1', 'com.journaltopia.credits.25'
    )),
    'already_redeemed_by_another_account',
    'the same Apple transaction cannot be redeemed by a second Journaltopia account'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000002'),
    0,
    'the second account is credited nothing'
);

-- R. An unknown product credits nothing ------------------------------------------------------------------------
select is(
    (select conflict from public.redeem_credit_pack(
        '11111111-0000-4000-8000-000000000002', 'apple-pack-txn-unknown', 'com.journaltopia.credits.9999'
    )),
    'unknown_product',
    'an unrecognised product is reported rather than credited'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '11111111-0000-4000-8000-000000000002'),
    0,
    'an unknown product grants zero credits'
);

-- Server-owned, like every other accounting transition -----------------------------------------------------------
select is(
    has_function_privilege('authenticated', 'public.redeem_credit_pack(uuid,text,text)', 'execute'),
    false,
    'a signed-in client cannot redeem a pack for itself'
);

select is(
    has_function_privilege('anon', 'public.redeem_credit_pack(uuid,text,text)', 'execute'),
    false,
    'an anonymous caller cannot redeem a pack'
);

select ok(
    has_function_privilege('service_role', 'public.redeem_credit_pack(uuid,text,text)', 'execute'),
    'only the verifying server path may redeem a pack'
);

select is(
    has_function_privilege('authenticated', 'public.spend_generation_credits(integer)', 'execute'),
    false,
    'spending is still reachable only through a reservation'
);

select is(
    has_column_privilege('authenticated', 'public.profiles', 'purchased_generation_credits', 'update'),
    false,
    'a client cannot write its own purchased balance'
);

select is(
    has_column_privilege('authenticated', 'public.profiles', 'monthly_generation_credits', 'update'),
    false,
    'a client cannot write its own monthly balance'
);

select ok(
    has_column_privilege('authenticated', 'public.profiles', 'purchased_generation_credits', 'select'),
    'a client can read its own purchased balance'
);

select * from finish();

rollback;
