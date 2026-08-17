-- Apple refunds a credit pack, and the credits come back off the account.
--
-- Run with: supabase test db   (requires the local Supabase stack)
--
-- The two mistakes this guards against pull in opposite directions. Reversing nothing is a revenue
-- leak — buy a 60-pack, refund it, keep the credits. Reversing too much invents a debt: taking 10
-- back from someone who has already spent 7 leaves them at -7, which they never agreed to and which
-- would silently eat their next purchase. The policy is a clamped reversal, and most of what is
-- asserted below is the clamp holding at both ends.

create extension if not exists pgtap with schema extensions;

begin;

select plan(43);

-- Fixtures -------------------------------------------------------------------------------------
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
values
    (
        '00000000-0000-0000-0000-000000000000', '99999999-0000-4000-8000-000000000001',
        'authenticated', 'authenticated', 'refund-one@example.com', 'x', now(), now()
    ),
    (
        '00000000-0000-0000-0000-000000000000', '99999999-0000-4000-8000-000000000002',
        'authenticated', 'authenticated', 'refund-two@example.com', 'x', now(), now()
    );

insert into public.subscriptions (
    id, user_id, product_id, original_transaction_id, status,
    current_period_start, current_period_end
)
values
    (
        'aaaa9999-0000-4000-8000-000000000001', '99999999-0000-4000-8000-000000000001',
        'com.journaltopia.plus.monthly', 'refund-original-transaction-one', 'active',
        date_trunc('second', now()) - interval '1 day', now() + interval '29 days'
    ),
    (
        'aaaa9999-0000-4000-8000-000000000002', '99999999-0000-4000-8000-000000000002',
        'com.journaltopia.plus.monthly', 'refund-original-transaction-two', 'active',
        date_trunc('second', now()) - interval '1 day', now() + interval '29 days'
    );

-- A. A refunded 10-pack removes 10 ---------------------------------------------------------------
select is(
    (select credits_granted from public.redeem_credit_pack(
        '99999999-0000-4000-8000-000000000001', 'refund-txn-10', 'com.journaltopia.credits.10'
    )),
    10,
    'the 10-pack is redeemed'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '99999999-0000-4000-8000-000000000001'),
    10,
    'the purchased bucket holds 10'
);

select is(
    (select reclaimed from public.reverse_credit_pack_purchase('refund-txn-10')),
    10,
    'the refund reclaims all 10'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '99999999-0000-4000-8000-000000000001'),
    0,
    'the purchased bucket is emptied by the refund'
);

select is(
    (select delta from public.credit_ledger
     where reason = 'purchased_credit_pack_refund' and source_id = 'refund-txn-10'),
    -10,
    'the reversal is recorded in the ledger'
);

-- The pair of rows is the audit trail: how much was granted, and how much came back.
select is(
    (select count(*)::int from public.credit_ledger where source_id = 'refund-txn-10'),
    2,
    'the grant and its reversal share a source id'
);

-- B. / C. The other two packs ---------------------------------------------------------------------
select is(
    (select credits_granted from public.redeem_credit_pack(
        '99999999-0000-4000-8000-000000000001', 'refund-txn-25', 'com.journaltopia.credits.25'
    )),
    25,
    'the 25-pack is redeemed'
);

select is(
    (select reclaimed from public.reverse_credit_pack_purchase('refund-txn-25')),
    25,
    'a refunded 25-pack reclaims 25'
);

select is(
    (select credits_granted from public.redeem_credit_pack(
        '99999999-0000-4000-8000-000000000001', 'refund-txn-60', 'com.journaltopia.credits.60'
    )),
    60,
    'the 60-pack is redeemed'
);

select is(
    (select reclaimed from public.reverse_credit_pack_purchase('refund-txn-60')),
    60,
    'a refunded 60-pack reclaims 60'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '99999999-0000-4000-8000-000000000001'),
    0,
    'the bucket is back to zero after all three refunds'
);

-- D. The clamp: a refund after spending ------------------------------------------------------------
select is(
    (select credits_granted from public.redeem_credit_pack(
        '99999999-0000-4000-8000-000000000001', 'refund-txn-spent', 'com.journaltopia.credits.10'
    )),
    10,
    'a 10-pack is redeemed and then partly spent'
);

-- Seven credits' worth of storyboards have already been delivered; only three are still there.
update public.profiles
set purchased_generation_credits = 3
where id = '99999999-0000-4000-8000-000000000001';

select is(
    (select reclaimed from public.reverse_credit_pack_purchase('refund-txn-spent')),
    3,
    'the refund reclaims only what is left, not the full 10'
);

select is(
    (select originally_granted from public.reverse_credit_pack_purchase('refund-txn-spent')),
    10,
    'the reversal still reports the original 10, so the shortfall is visible'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '99999999-0000-4000-8000-000000000001'),
    0,
    'the balance stops at zero rather than going negative'
);

select ok(
    (select purchased_generation_credits >= 0 from public.profiles where id = '99999999-0000-4000-8000-000000000001'),
    'the user is never left in debt'
);

-- A refund with nothing left to take is still recorded, so a silent no-op is distinguishable from a
-- notification that was never processed at all.
select is(
    (select credits_granted from public.redeem_credit_pack(
        '99999999-0000-4000-8000-000000000001', 'refund-txn-empty', 'com.journaltopia.credits.10'
    )),
    10,
    'another 10-pack is redeemed'
);

update public.profiles
set purchased_generation_credits = 0
where id = '99999999-0000-4000-8000-000000000001';

select is(
    (select reclaimed from public.reverse_credit_pack_purchase('refund-txn-empty')),
    0,
    'a refund with nothing left reclaims nothing'
);

select is(
    (select count(*)::int from public.credit_ledger
     where reason = 'purchased_credit_pack_refund' and source_id = 'refund-txn-empty'),
    1,
    'and is still written to the ledger'
);

-- E. Monthly credits are never touched ---------------------------------------------------------------
update public.profiles
set monthly_generation_credits = 25, purchased_generation_credits = 10
where id = '99999999-0000-4000-8000-000000000001';

select is(
    (select credits_granted from public.redeem_credit_pack(
        '99999999-0000-4000-8000-000000000001', 'refund-txn-monthly-guard', 'com.journaltopia.credits.10'
    )),
    10,
    'a pack is redeemed alongside a full monthly bucket'
);

select is(
    (select reclaimed from public.reverse_credit_pack_purchase('refund-txn-monthly-guard')),
    10,
    'the refund reclaims its 10'
);

select is(
    (select monthly_generation_credits from public.profiles where id = '99999999-0000-4000-8000-000000000001'),
    25,
    'a consumable refund never removes monthly credits'
);

select is(
    (select count(*)::int from public.credit_ledger
     where user_id = '99999999-0000-4000-8000-000000000001'
       and reason = 'purchased_credit_pack_refund'
       and bucket = 'monthly'),
    0,
    'no reversal is ever written against the monthly bucket'
);

-- F. / G. Repeated notifications ------------------------------------------------------------------------
-- Apple redelivers for days. The second delivery must be inert.
update public.profiles
set purchased_generation_credits = 20
where id = '99999999-0000-4000-8000-000000000001';

select is(
    (select credits_granted from public.redeem_credit_pack(
        '99999999-0000-4000-8000-000000000001', 'refund-txn-twice', 'com.journaltopia.credits.10'
    )),
    10,
    'a pack is redeemed, bringing the bucket to 30'
);

select is(
    (select reclaimed from public.reverse_credit_pack_purchase('refund-txn-twice')),
    10,
    'the first refund reclaims 10'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '99999999-0000-4000-8000-000000000001'),
    20,
    'the bucket drops to 20'
);

select is(
    (select reclaimed from public.reverse_credit_pack_purchase('refund-txn-twice')),
    0,
    'a redelivered refund reclaims nothing'
);

select is(
    (select already_reversed from public.reverse_credit_pack_purchase('refund-txn-twice')),
    true,
    'a redelivered refund reports itself as already handled'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '99999999-0000-4000-8000-000000000001'),
    20,
    'a redelivered refund does not remove credits twice'
);

select is(
    (select count(*)::int from public.credit_ledger
     where reason = 'purchased_credit_pack_refund' and source_id = 'refund-txn-twice'),
    1,
    'exactly one reversal entry, however many notifications arrive'
);

-- The constraint, not the code, is what makes that true — so a second caller racing the first
-- collides at the database rather than relying on having read a flag first.
select ok(
    exists (
        select 1 from pg_constraint
        where conrelid = 'public.credit_ledger'::regclass
          and conname = 'credit_ledger_unique_event'
    ),
    'reversal idempotency rests on a database constraint'
);

-- H. A consumable refund does not cancel the subscription --------------------------------------------
select ok(
    public.has_active_journaltopia_plus('99999999-0000-4000-8000-000000000001'),
    'the subscription is untouched by a credit pack refund'
);

select is(
    (select status from public.subscriptions where id = 'aaaa9999-0000-4000-8000-000000000001'),
    'active',
    'the subscription row is untouched by a credit pack refund'
);

select is(
    (select monthly_generation_credits from public.profiles where id = '99999999-0000-4000-8000-000000000001'),
    25,
    'and the monthly grant survives it'
);

-- I. A subscription revocation does not reverse unrelated packs ----------------------------------------
update public.profiles
set monthly_generation_credits = 25, purchased_generation_credits = 40
where id = '99999999-0000-4000-8000-000000000002';

select is(
    (select is_entitled from public.sync_apple_subscription(
        '99999999-0000-4000-8000-000000000002',
        'com.journaltopia.plus.monthly', 'refund-original-transaction-two', 'refund-latest-two',
        'revoked', date_trunc('second', now()) - interval '1 day', now() + interval '29 days', false, 'sandbox'
    )),
    false,
    'a revoked subscription is not entitled'
);

select is(
    (select purchased_generation_credits from public.profiles where id = '99999999-0000-4000-8000-000000000002'),
    40,
    'revoking a subscription leaves purchased credits alone'
);

select is(
    (select monthly_generation_credits from public.profiles where id = '99999999-0000-4000-8000-000000000002'),
    0,
    'revoking a subscription clears only the monthly bucket'
);

select is(
    (select count(*)::int from public.credit_ledger
     where user_id = '99999999-0000-4000-8000-000000000002'
       and reason = 'purchased_credit_pack_refund'),
    0,
    'a subscription revocation writes no consumable reversal'
);

-- A refund for a transaction this server never redeemed --------------------------------------------------
select is(
    (select conflict from public.reverse_credit_pack_purchase('refund-txn-never-seen')),
    'unknown_transaction',
    'a refund for an unredeemed transaction is reported rather than guessed at'
);

select is(
    (select count(*)::int from public.credit_ledger where source_id = 'refund-txn-never-seen'),
    0,
    'and writes nothing'
);

-- Server-owned ---------------------------------------------------------------------------------------------
select is(
    has_function_privilege('authenticated', 'public.reverse_credit_pack_purchase(text)', 'execute'),
    false,
    'a signed-in client cannot reverse a purchase'
);

select is(
    has_function_privilege('anon', 'public.reverse_credit_pack_purchase(text)', 'execute'),
    false,
    'an anonymous caller cannot reverse a purchase'
);

select ok(
    has_function_privilege('service_role', 'public.reverse_credit_pack_purchase(text)', 'execute'),
    'only the verifying notification handler may reverse a purchase'
);

select * from finish();

rollback;
