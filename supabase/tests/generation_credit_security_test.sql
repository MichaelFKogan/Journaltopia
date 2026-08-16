-- The credit system's security boundary: who is allowed to change a balance, and how.
--
-- Run with: supabase test db   (requires the local Supabase stack)
--
-- storyboard_generation_lifecycle_test.sql already proves the lifecycle's own accounting — that
-- reserving spends, that failing refunds exactly once, that a repeated failure does not refund
-- again, and that the sweeper cannot double-refund. This file covers the other half: that those
-- server-owned paths are the *only* way the number moves. The end-to-end case at the bottom then
-- re-proves spend-and-refund-once through the locked-down grants, because the risk in tightening
-- privileges is breaking the security definer chain that the lifecycle depends on.
--
-- Privileges are asserted against the catalog rather than by impersonating roles, for the same
-- reason the lifecycle test gives: this is the privilege Postgres itself consults at call time, and
-- pgTAP's bookkeeping cannot be written as `authenticated` mid-transaction. What that does and does
-- not establish is written out at the end of this file.

create extension if not exists pgtap with schema extensions;

begin;

select plan(18);

-- Fixtures -------------------------------------------------------------------------------------
-- The profile, and its 10 starting credits, come from the on_auth_user_created trigger.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
values (
    '00000000-0000-0000-0000-000000000000',
    'aaaaaaaa-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'credit-security@example.com',
    'x',
    now(),
    now()
);

insert into public.entries (user_id, client_entry_id, title, content)
values (
    'aaaaaaaa-0000-4000-8000-000000000002',
    'bbbbbbbb-0000-4000-8000-000000000002',
    'A locked down afternoon',
    'The credits stayed where they were put.'
);

-- Profiles start at zero since 20260817092000, and reserving needs an active subscription since
-- 20260817094000. Both are arranged here so the assertions below stay about privileges.
update public.profiles
set generation_credits = 10
where id = 'aaaaaaaa-0000-4000-8000-000000000002';

insert into public.subscriptions (
    user_id, product_id, original_transaction_id, status,
    current_period_start, current_period_end
)
values (
    'aaaaaaaa-0000-4000-8000-000000000002',
    'com.storytopia.plus.monthly',
    'credit-security-original-transaction',
    'active',
    now() - interval '1 day',
    now() + interval '29 days'
);

-- The legacy refund RPC is gone -----------------------------------------------------------------
-- It took a caller-supplied amount, added it to the caller's balance, and was reachable by any
-- signed-in client through PostgREST. Nothing about it was salvageable: there was no reservation to
-- check the amount against.
select ok(
    to_regprocedure('public.refund_generation_credit(integer)') is null,
    'the legacy client-callable refund RPC no longer exists'
);

-- Spending is reachable only through a reservation ----------------------------------------------
select is(
    has_function_privilege('authenticated', 'public.spend_generation_credit(integer)', 'execute'),
    false,
    'a signed-in client may not spend a credit directly'
);

select is(
    has_function_privilege('anon', 'public.spend_generation_credit(integer)', 'execute'),
    false,
    'an anonymous caller may not spend a credit directly'
);

-- Revoked from PUBLIC, which is where service_role inherited it. The background worker never spends;
-- it only claims, completes, and fails.
select is(
    has_function_privilege('service_role', 'public.spend_generation_credit(integer)', 'execute'),
    false,
    'even the service role reaches spending only through a reservation'
);

select is(
    has_function_privilege(
        'authenticated',
        'public.reserve_storyboard_generation(uuid,uuid,text,text,text,text,integer)',
        'execute'
    ),
    true,
    'reserving a generation is still the one credit operation a client may perform'
);

-- profiles is column-locked ---------------------------------------------------------------------
-- The RLS policy pins the row to auth.uid(), which is what made the table-wide UPDATE grant look
-- safe. It says nothing about columns, so the balance needed a grant of its own to be protected.
select is(
    has_column_privilege('authenticated', 'public.profiles', 'generation_credits', 'update'),
    false,
    'a signed-in client may not write its own credit balance'
);

-- Reading is asserted relative to an ordinary profile column rather than as an absolute `true`,
-- because the absolute answer is a property of the environment and not of this lockdown.
--
-- No migration in this repository grants SELECT to `authenticated` on anything. The hosted project
-- works because it was provisioned when Supabase auto-exposed new public tables to the Data API
-- roles; a database built purely from these migrations — which is what `supabase db reset` produces
-- — grants no SELECT on any table, so an absolute assertion here passes or fails on which of those
-- two databases it happens to run against.
--
-- What Phase 1 is actually responsible for is narrower and testable everywhere: the balance column
-- must not have been singled out for read restriction. Whatever read access a client has to an
-- ordinary column like display_name, it has to generation_credits as well. Contrast this with
-- UPDATE, where the two are asserted to differ — that difference is the whole point of the change.
select is(
    has_column_privilege('authenticated', 'public.profiles', 'generation_credits', 'select'),
    has_column_privilege('authenticated', 'public.profiles', 'display_name', 'select'),
    'the balance is no harder to read than any other profile column'
);

select is(
    has_column_privilege('authenticated', 'public.profiles', 'display_name', 'update'),
    true,
    'profile editing keeps the columns it owns'
);

select is(
    has_column_privilege('authenticated', 'public.profiles', 'avatar_url', 'update'),
    true,
    'profile editing keeps its avatar column'
);

select is(
    has_column_privilege('authenticated', 'public.profiles', 'id', 'update'),
    false,
    'a signed-in client may not move its profile to another id'
);

select is(
    has_column_privilege('authenticated', 'public.profiles', 'created_at', 'update'),
    false,
    'a signed-in client may not rewrite when its profile was created'
);

-- The lifecycle still works through the tightened grants ------------------------------------------
-- Reserving calls spend_generation_credit, which no client role may execute any more. It works here
-- because reserve_storyboard_generation is security definer and owned by the same role, so it
-- reaches the spend by ownership rather than through a grant. That is the exact thing a privilege
-- change like this can break, so it is proved rather than assumed.
select set_config(
    'request.jwt.claims',
    '{"sub":"aaaaaaaa-0000-4000-8000-000000000002","role":"authenticated"}',
    true
);

select lives_ok(
    $$select public.reserve_storyboard_generation(
        'dddddddd-0000-4000-8000-000000000001',
        'bbbbbbbb-0000-4000-8000-000000000002',
        'aaaa/bbbb/locked.jpg',
        'Anime',
        'medium',
        'a locked down afternoon',
        2
    )$$,
    'reserving still spends through the definer chain after the revoke'
);

select is(
    (select generation_credits from public.profiles where id = 'aaaaaaaa-0000-4000-8000-000000000002'),
    8,
    'an HD reservation still deducts two credits'
);

select is(
    (select reserved_credits from public.entry_storyboards where id = 'dddddddd-0000-4000-8000-000000000001'),
    2,
    'the reservation still records what it spent'
);

select is(
    (select refunded_credits from public.fail_storyboard_generation(
        'dddddddd-0000-4000-8000-000000000001',
        'OpenAI did not return a storyboard image.'
    )),
    2,
    'the server-owned failing transition still refunds the whole reservation'
);

select is(
    (select generation_credits from public.profiles where id = 'aaaaaaaa-0000-4000-8000-000000000002'),
    10,
    'the refund lands even though no role may write the column directly'
);

select is(
    (select refunded_credits from public.fail_storyboard_generation(
        'dddddddd-0000-4000-8000-000000000001',
        'a duplicated failure path'
    )),
    2,
    'a repeated failure reports the refund that already happened'
);

select is(
    (select generation_credits from public.profiles where id = 'aaaaaaaa-0000-4000-8000-000000000002'),
    10,
    'a repeated failure still does not refund a second time'
);

-- What these assertions do and do not establish ---------------------------------------------------
--
-- has_column_privilege and has_function_privilege read the same grants the executor consults, so a
-- false here means the statement is refused for that role — this is the real control, not a proxy
-- for it.
--
-- Two things are deliberately not covered, because neither can be exercised from inside a pgTAP
-- transaction that has to keep writing as the test owner:
--
--   * A literal `set role authenticated; update public.profiles set generation_credits = 999;`
--     round trip. Switching role mid-transaction breaks pgTAP's own bookkeeping, and switching back
--     requires privileges the switched-to role does not have. The catalog assertion above is the
--     same check that statement would fail.
--
--   * The PostgREST layer. Whether Supabase's API exposes a function or column is downstream of
--     these grants, but the HTTP surface itself is not reachable from SQL. `POST
--     /rest/v1/rpc/refund_generation_credit` now 404s because the function is gone from the
--     catalog, which is what the first assertion checks.
--
-- One environment difference is worth knowing about while reading the results here: this repository
-- never grants SELECT, INSERT, UPDATE or DELETE to `anon` or `authenticated` on any table except
-- through the two column-level grants in 20260815190000 and 20260816090000. A database reset from
-- these migrations therefore gives `authenticated` no read access to profiles, entries, journals or
-- storyboards at all, while the hosted project — provisioned back when Supabase auto-exposed new
-- public tables — has them. That gap belongs to its own change, not to the credit lockdown, but it
-- is why the read assertion above is written as a comparison.

select * from finish();

rollback;
