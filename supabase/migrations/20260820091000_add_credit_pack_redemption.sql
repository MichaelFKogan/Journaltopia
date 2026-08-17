-- Redeeming a verified Apple consumable into purchased credits, and clearing the monthly bucket
-- when a subscription lapses.
--
-- The rule this file exists to enforce: the number of credits a pack is worth is decided here, from
-- the product id Apple signed, and never by anything the client sends. A client that could name its
-- own amount would be a client that could name any amount.

-- How many credits each product is worth. A function rather than a table because it is a price list
-- the server owns, not data anyone administers, and because a missing product returning 0 is the
-- safe failure — an unknown product grants nothing rather than defaulting to something.
create or replace function public.credit_pack_credit_amount(product_id text)
returns integer
language sql
immutable
as $$
    select case product_id
        when 'com.journaltopia.credits.10' then 10
        when 'com.journaltopia.credits.25' then 25
        when 'com.journaltopia.credits.60' then 60
        else 0
    end;
$$;

revoke all on function public.credit_pack_credit_amount(text) from public, anon, authenticated;

-- Redeems one verified consumable transaction.
--
-- Called only by redeem-credit-purchase, after that function has verified Apple's signature over the
-- transaction and taken the product id and transaction id out of the *verified* payload. This
-- function's contract is that both arguments are already trustworthy; what it adds is the
-- accounting, the entitlement check, and the guarantee that one transaction credits one account once.
--
-- Outcomes are returned rather than raised, because a repeat is expected: StoreKit redelivers
-- unfinished transactions on every launch, and a caller that had to distinguish "already done" from
-- "failed" by reading an error string would eventually get it wrong and either double-credit or
-- strand the purchase forever.
create or replace function public.redeem_credit_pack(
    account uuid,
    apple_transaction_id text,
    apple_product_id text
)
returns table (
    credits_granted integer,
    monthly_balance integer,
    purchased_balance integer,
    already_redeemed boolean,
    conflict text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    award integer;
    ledger_id uuid;
    updated_monthly integer;
    updated_purchased integer;
begin
    if account is null then
        raise exception 'not_authenticated';
    end if;

    if apple_transaction_id is null or btrim(apple_transaction_id) = '' then
        raise exception 'missing_transaction_id';
    end if;

    award := public.credit_pack_credit_amount(apple_product_id);

    -- A product this server does not sell credits nothing. Reported rather than raised so a stray
    -- transaction for some future product can be finished by the client instead of being retried
    -- forever.
    if award <= 0 then
        select profiles.monthly_generation_credits, profiles.purchased_generation_credits
        into updated_monthly, updated_purchased
        from public.profiles where profiles.id = account;

        return query
        select 0, coalesce(updated_monthly, 0), coalesce(updated_purchased, 0), false, 'unknown_product'::text;
        return;
    end if;

    -- Packs are a subscriber benefit. Enforced here as well as in the UI, because the UI is a
    -- suggestion and this is the only copy that a modified client cannot skip. Purchased credits
    -- survive cancellation, but acquiring them requires an active plan — as does spending them.
    if not public.has_active_journaltopia_plus(account) then
        select profiles.monthly_generation_credits, profiles.purchased_generation_credits
        into updated_monthly, updated_purchased
        from public.profiles where profiles.id = account;

        return query
        select 0, coalesce(updated_monthly, 0), coalesce(updated_purchased, 0), false, 'subscription_required'::text;
        return;
    end if;

    -- The ledger insert is the idempotency check, and it is attempted before the balance moves.
    --
    -- Two constraints guard it. The per-user one makes a redelivery to the same account a no-op. The
    -- partial unique index on source_id makes a redelivery to a *different* account a conflict —
    -- which is the cross-account case, since Apple transaction ids are unique store-wide. Both land
    -- here as unique_violation, and they are told apart below by looking at who owns the entry.
    begin
        insert into public.credit_ledger (user_id, delta, reason, bucket, source_id)
        values (account, award, 'purchased_credit_pack', 'purchased', apple_transaction_id)
        returning credit_ledger.id into ledger_id;
    exception
        when unique_violation then
            if exists (
                select 1 from public.credit_ledger
                where credit_ledger.reason = 'purchased_credit_pack'
                  and credit_ledger.source_id = apple_transaction_id
                  and credit_ledger.user_id = account
            ) then
                select profiles.monthly_generation_credits, profiles.purchased_generation_credits
                into updated_monthly, updated_purchased
                from public.profiles where profiles.id = account;

                return query
                select 0, updated_monthly, updated_purchased, true, null::text;
                return;
            end if;

            -- Someone else's purchase. Nothing is credited, and the client is told plainly rather
            -- than being left to retry a transaction that will never be accepted for this account.
            select profiles.monthly_generation_credits, profiles.purchased_generation_credits
            into updated_monthly, updated_purchased
            from public.profiles where profiles.id = account;

            return query
            select 0, coalesce(updated_monthly, 0), coalesce(updated_purchased, 0), false,
                   'already_redeemed_by_another_account'::text;
            return;
    end;

    update public.profiles
    set purchased_generation_credits = purchased_generation_credits + award
    where profiles.id = account
    returning monthly_generation_credits, purchased_generation_credits
    into updated_monthly, updated_purchased;

    if updated_purchased is null then
        raise exception 'profile_not_found';
    end if;

    update public.credit_ledger
    set balance_after = updated_purchased
    where credit_ledger.id = ledger_id;

    return query select award, updated_monthly, updated_purchased, false, null::text;
end;
$$;

revoke all on function public.redeem_credit_pack(uuid, text, text) from public, anon, authenticated;
grant execute on function public.redeem_credit_pack(uuid, text, text) to service_role;

-- Monthly credits do not outlive the subscription -------------------------------------------------
-- Entitlement already stops them being spent — the reservation refuses without an active plan — so
-- this is about the number the user sees rather than about safety. Leaving 12 monthly credits on
-- screen for a lapsed account promises something that will never be honoured, and they are gone at
-- the next renewal anyway.
--
-- Done at reconciliation rather than on a schedule: the moment the server learns a subscription is
-- no longer active is exactly the moment the bucket should empty, and a cron job would only make
-- that happen later.
create or replace function public.expire_monthly_credits(account uuid, reason_source text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    expiring integer;
begin
    select profiles.monthly_generation_credits into expiring
    from public.profiles where profiles.id = account
    for update;

    if expiring is null or expiring <= 0 then
        return 0;
    end if;

    insert into public.credit_ledger (user_id, delta, reason, bucket, source_id, balance_after)
    values (account, -expiring, 'subscription_monthly_expiry', 'monthly', reason_source, 0)
    on conflict on constraint credit_ledger_unique_event do nothing;

    update public.profiles
    set monthly_generation_credits = 0
    where profiles.id = account;

    return expiring;
end;
$$;

revoke all on function public.expire_monthly_credits(uuid, text) from public, anon, authenticated;

-- The sync path empties the bucket on the way out --------------------------------------------------
-- Same function as before in every other respect: same cross-account protection, same period
-- monotonicity, same idempotent grant. The addition is the `else` branch — a subscription that
-- verifies as expired, revoked or in billing retry clears whatever monthly credits are left.
create or replace function public.sync_apple_subscription(
    account uuid,
    apple_product_id text,
    apple_original_transaction_id text,
    apple_latest_transaction_id text,
    apple_status text,
    period_start timestamptz,
    period_end timestamptz,
    apple_auto_renew boolean,
    apple_environment text
)
returns table (
    subscription_id uuid,
    bound_user_id uuid,
    resulting_status text,
    is_entitled boolean,
    granted integer,
    balance integer,
    already_granted boolean,
    conflict text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    existing public.subscriptions%rowtype;
    target_user uuid := account;
    row_id uuid;
    grant_result record;
    entitled boolean;
begin
    if apple_original_transaction_id is null or btrim(apple_original_transaction_id) = '' then
        raise exception 'missing_original_transaction_id';
    end if;

    if apple_status is null or apple_status not in ('active', 'expired', 'revoked', 'billing_retry') then
        raise exception 'invalid_subscription_status';
    end if;

    select * into existing
    from public.subscriptions
    where subscriptions.provider = 'apple'
      and subscriptions.original_transaction_id = sync_apple_subscription.apple_original_transaction_id
    for update;

    if found then
        if target_user is not null and existing.user_id <> target_user then
            return query
            select
                existing.id,
                existing.user_id,
                existing.status,
                (existing.status = 'active' and existing.current_period_end > now()),
                0,
                (select profiles.generation_credits from public.profiles where profiles.id = target_user),
                false,
                'already_bound_to_another_account'::text;
            return;
        end if;

        target_user := existing.user_id;
    elsif target_user is null then
        return query
        select
            null::uuid, null::uuid, sync_apple_subscription.apple_status,
            false, 0, null::integer, false,
            'unknown_subscription'::text;
        return;
    end if;

    insert into public.subscriptions as s (
        user_id, provider, product_id, original_transaction_id, latest_transaction_id,
        status, current_period_start, current_period_end, auto_renew_status, environment
    )
    values (
        target_user, 'apple',
        sync_apple_subscription.apple_product_id,
        sync_apple_subscription.apple_original_transaction_id,
        sync_apple_subscription.apple_latest_transaction_id,
        sync_apple_subscription.apple_status,
        sync_apple_subscription.period_start,
        sync_apple_subscription.period_end,
        sync_apple_subscription.apple_auto_renew,
        sync_apple_subscription.apple_environment
    )
    on conflict (provider, original_transaction_id) do update
    set product_id = excluded.product_id,
        latest_transaction_id = coalesce(excluded.latest_transaction_id, s.latest_transaction_id),
        status = excluded.status,
        current_period_start = greatest(excluded.current_period_start, s.current_period_start),
        current_period_end = greatest(excluded.current_period_end, s.current_period_end),
        auto_renew_status = excluded.auto_renew_status,
        environment = coalesce(excluded.environment, s.environment)
    returning s.id into row_id;

    select * into existing from public.subscriptions where subscriptions.id = row_id;

    entitled := existing.status = 'active' and existing.current_period_end > now();

    if entitled then
        select * into grant_result
        from public.grant_subscription_credits(row_id);

        return query
        select
            existing.id, existing.user_id, existing.status, true,
            grant_result.granted, grant_result.balance, grant_result.already_granted,
            null::text;
        return;
    end if;

    -- Not entitled any more. Monthly credits go; purchased credits are deliberately untouched and
    -- will still be there if the user comes back.
    perform public.expire_monthly_credits(
        existing.user_id,
        existing.original_transaction_id || ':lapsed:'
            || extract(epoch from existing.current_period_end)::bigint::text
    );

    return query
    select
        existing.id, existing.user_id, existing.status, false,
        0,
        (select profiles.generation_credits from public.profiles where profiles.id = existing.user_id),
        false,
        null::text;
end;
$$;

revoke all on function public.sync_apple_subscription(uuid, text, text, text, text, timestamptz, timestamptz, boolean, text)
    from public, anon, authenticated;
grant execute on function public.sync_apple_subscription(uuid, text, text, text, text, timestamptz, timestamptz, boolean, text)
    to service_role;
