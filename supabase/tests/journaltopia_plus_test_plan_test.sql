-- The Journaltopia+ test plan.
--
-- Run with: supabase test db   (requires the local Supabase stack)
--
-- The point of the test plan is that the server agrees with it. The properties below are the ones
-- that make that true and keep it from being a way to hand out free subscriptions: only an
-- allowlisted account may use it, it acts on the caller and nobody else, it produces an entitlement
-- the reservation path actually honours, and it never touches a real Apple subscription.

create extension if not exists pgtap with schema extensions;

begin;

select plan(12);

-- Fixtures -------------------------------------------------------------------------------------
-- Two accounts: one on the allowlist, one not.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
values
    (
        '00000000-0000-0000-0000-000000000000',
        'dddddddd-0000-4000-8000-000000000001',
        'authenticated', 'authenticated',
        'developer@example.com', 'x', now(), now()
    ),
    (
        '00000000-0000-0000-0000-000000000000',
        'dddddddd-0000-4000-8000-000000000002',
        'authenticated', 'authenticated',
        'stranger@example.com', 'x', now(), now()
    );

insert into public.journaltopia_plus_test_plan_allowlist (user_id, note)
values ('dddddddd-0000-4000-8000-000000000001', 'test fixture');

-- Not on the allowlist -------------------------------------------------------------------------
-- The whole reason this can ship. Without it, a definer function that grants entitlement is a free
-- subscription for anybody who can reach PostgREST.
select set_config(
    'request.jwt.claims',
    '{"sub":"dddddddd-0000-4000-8000-000000000002","role":"authenticated"}',
    true
);

select throws_ok(
    $$select public.set_journaltopia_plus_test_plan(true)$$,
    'test_plan_not_permitted',
    'an account that is not allowlisted cannot grant itself the test plan'
);

select is(
    (select count(*)::integer from public.subscriptions
     where user_id = 'dddddddd-0000-4000-8000-000000000002'),
    0,
    'and no subscription row is left behind by the refusal'
);

-- Signed out ------------------------------------------------------------------------------------
select set_config('request.jwt.claims', '', true);

select throws_ok(
    $$select public.set_journaltopia_plus_test_plan(true)$$,
    'not_authenticated',
    'there is no account for an entitlement to belong to'
);

-- On the allowlist ------------------------------------------------------------------------------
select set_config(
    'request.jwt.claims',
    '{"sub":"dddddddd-0000-4000-8000-000000000001","role":"authenticated"}',
    true
);

select is(
    public.set_journaltopia_plus_test_plan(true),
    true,
    'an allowlisted account can switch the test plan on'
);

-- The property the old client-side toggle could never have: the predicate the reservation path
-- consults says yes.
select is(
    public.has_active_journaltopia_plus('dddddddd-0000-4000-8000-000000000001'),
    true,
    'the server itself now considers the account entitled'
);

select is(
    (select is_active from public.journaltopia_plus_entitlement),
    true,
    'and the read model the app polls agrees'
);

-- Credits come with it, because entitlement on its own would only move the refusal from
-- subscription_required to insufficient_generation_credits.
select cmp_ok(
    (select monthly_generation_credits from public.profiles
     where id = 'dddddddd-0000-4000-8000-000000000001'),
    '>',
    0,
    'the monthly grant runs, so a storyboard can actually be generated'
);

select is(
    (select count(*)::integer from public.credit_ledger
     where user_id = 'dddddddd-0000-4000-8000-000000000001'
       and reason = 'subscription_monthly_grant'),
    1,
    'the grant is recorded on the ledger exactly once'
);

-- It acts on the caller and on nobody else.
select is(
    (select count(*)::integer from public.subscriptions
     where user_id = 'dddddddd-0000-4000-8000-000000000002'),
    0,
    'the other account is untouched'
);

-- Switching it back off --------------------------------------------------------------------------
select is(
    public.set_journaltopia_plus_test_plan(false),
    false,
    'switching the test plan off reports the account as no longer entitled'
);

select is(
    public.has_active_journaltopia_plus('dddddddd-0000-4000-8000-000000000001'),
    false,
    'and the reservation path would refuse again'
);

-- A real subscription is not the test plan's to remove -------------------------------------------
insert into public.subscriptions (
    user_id, provider, product_id, original_transaction_id, status,
    current_period_start, current_period_end, environment
)
values (
    'dddddddd-0000-4000-8000-000000000001',
    'apple',
    'com.journaltopia.plus.monthly',
    'apple-original-transaction-real',
    'active',
    now() - interval '2 days',
    now() + interval '28 days',
    'production'
);

select is(
    public.set_journaltopia_plus_test_plan(false),
    true,
    'switching the test plan off leaves a real Apple subscription entitling the account'
);

select is(
    (select count(*)::integer from public.subscriptions
     where user_id = 'dddddddd-0000-4000-8000-000000000001'
       and original_transaction_id = 'apple-original-transaction-real'),
    1,
    'and the real subscription row is still there'
);

select * from finish();

rollback;
