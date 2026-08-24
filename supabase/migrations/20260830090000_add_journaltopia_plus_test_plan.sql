-- A Journaltopia+ test plan that the *server* agrees with.
--
-- The Settings > Extra "Journaltopia+ Test Plan" toggle used to flip a value in UserDefaults and
-- nothing else. That made the app believe it was entitled while `reserve_storyboard_generation`
-- went on raising `subscription_required` on every attempt, so generation could never succeed with
-- the toggle on — and, worse, the disagreement drove a retry loop that hammered the reservation
-- path once a second.
--
-- The fix is to make the toggle write the same table Apple's verification path writes, so that
-- "subscribed" means one thing everywhere. What is created is a genuine `subscriptions` row: the
-- entitlement predicate, the monthly grant, the ledger and the reservation all behave exactly as
-- they do for a paying member, because as far as they are concerned this *is* one.
--
-- The reason this is safe to ship is the allowlist below. A definer function that grants
-- entitlement is, without one, a free subscription for anybody who can reach PostgREST.

-- Who may do this ----------------------------------------------------------------------------------
-- Deliberately a table rather than a hardcoded id: developer accounts change, and a code change to
-- add one would mean a migration on production every time. No client can read or write it — the
-- function below is security definer and reads it on the caller's behalf.
create table if not exists public.journaltopia_plus_test_plan_allowlist (
    user_id uuid primary key references auth.users(id) on delete cascade,
    note text,
    created_at timestamptz not null default now()
);

alter table public.journaltopia_plus_test_plan_allowlist enable row level security;

-- No policies on purpose. RLS with zero policies denies everything, and the grants say the same
-- thing again so that neither control is load-bearing on its own.
revoke all on public.journaltopia_plus_test_plan_allowlist from anon, authenticated;
grant select, insert, update, delete on public.journaltopia_plus_test_plan_allowlist to service_role;

-- Turning the test plan on and off ------------------------------------------------------------------
-- Acts on `auth.uid()` and never on an id supplied by the caller, so there is no argument that could
-- point it at somebody else's account.
--
-- The row it manages is identified by a synthetic `original_transaction_id` of
-- `test-plan:<user id>`, which is what keeps it from ever touching a real Apple subscription: the
-- unique index is on (provider, original_transaction_id), a real purchase can never produce that
-- value, and both branches below are scoped to it explicitly.
create or replace function public.set_journaltopia_plus_test_plan(active boolean)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := auth.uid();
    test_transaction_id text;
    test_subscription_id uuid;
begin
    if caller is null then
        raise exception 'not_authenticated';
    end if;

    if not exists (
        select 1
        from public.journaltopia_plus_test_plan_allowlist
        where journaltopia_plus_test_plan_allowlist.user_id = caller
    ) then
        raise exception 'test_plan_not_permitted';
    end if;

    test_transaction_id := 'test-plan:' || caller::text;

    if active then
        -- A real subscription outranks the test plan. Writing a second active row would work, but it
        -- would leave the account entitled by two records at once and make the toggle look like it
        -- had done something when the entitlement was already there.
        if exists (
            select 1
            from public.subscriptions
            where subscriptions.user_id = caller
              and subscriptions.status = 'active'
              and subscriptions.current_period_end > now()
              and subscriptions.original_transaction_id <> test_transaction_id
        ) then
            return true;
        end if;

        -- `current_period_start` moves to now() on every enable because it is half the identity of a
        -- monthly credit grant. Pinning it would make the second enable look to
        -- grant_subscription_credits like a redelivery of the first, and the test account would come
        -- back entitled with no credits to spend.
        insert into public.subscriptions (
            user_id,
            provider,
            product_id,
            original_transaction_id,
            latest_transaction_id,
            status,
            current_period_start,
            current_period_end,
            auto_renew_status,
            environment
        )
        values (
            caller,
            'apple',
            'com.journaltopia.plus.monthly',
            test_transaction_id,
            test_transaction_id,
            'active',
            now(),
            now() + interval '1 month',
            true,
            'sandbox'
        )
        on conflict (provider, original_transaction_id) do update
        set user_id = excluded.user_id,
            product_id = excluded.product_id,
            latest_transaction_id = excluded.latest_transaction_id,
            status = 'active',
            current_period_start = excluded.current_period_start,
            current_period_end = excluded.current_period_end,
            auto_renew_status = excluded.auto_renew_status,
            environment = excluded.environment
        returning subscriptions.id into test_subscription_id;

        -- The same grant a renewal runs. Credits are what makes the test plan actually testable:
        -- entitlement alone would move the refusal from `subscription_required` to
        -- `insufficient_generation_credits` and the storyboard still would not generate.
        perform * from public.grant_subscription_credits(test_subscription_id);

        return true;
    end if;

    -- Deleted rather than expired. An expired row would satisfy neither the entitlement predicate
    -- nor anything else, but it would sit in the table looking like a lapsed purchase, and the next
    -- enable would have to reason about which of the two states it was in.
    delete from public.subscriptions
    where subscriptions.user_id = caller
      and subscriptions.original_transaction_id = test_transaction_id;

    -- Whatever is left is the honest answer: an account with a real subscription stays entitled
    -- after the test plan is switched off.
    return public.has_active_journaltopia_plus(caller);
end;
$$;

revoke all on function public.set_journaltopia_plus_test_plan(boolean) from public, anon;
grant execute on function public.set_journaltopia_plus_test_plan(boolean) to authenticated;
