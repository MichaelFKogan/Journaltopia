-- The one place a verified Apple subscription becomes Journaltopia+ entitlement.
--
-- Both server paths land here — the client-initiated sync after a purchase or restore, and the App
-- Store server notification that arrives with no client at all — so that a renewal grants the same
-- credits whichever of them observes it first. Everything above this function is transport and
-- signature verification; everything below it is the accounting that already existed.
--
-- Nothing here decides whether the Apple data is genuine. That decision is made before this is
-- called, by verifying Apple's signature chain, and this function's contract is that it is only ever
-- handed already-verified values.

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

    -- Locked for the whole decision, so two notifications for the same subscription — or a
    -- notification racing a client sync — serialise instead of both deciding it is new.
    select * into existing
    from public.subscriptions
    where subscriptions.provider = 'apple'
      and subscriptions.original_transaction_id = sync_apple_subscription.apple_original_transaction_id
    for update;

    if found then
        -- Cross-account protection. Apple's subscription identity already belongs to a Journaltopia
        -- account; binding it to a second one would give two users entitlement from one purchase,
        -- and re-pointing user_id would silently move an active subscription away from whoever is
        -- currently relying on it. Refused, reported, and nothing written — in particular no grant,
        -- so a collision cannot be used to mint credits.
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
        -- The notification path with nothing to attach to: Apple is telling us about a subscription
        -- no Journaltopia account has ever synced. There is no honest way to guess the owner, so it is
        -- reported rather than invented. The client sync will bind it the next time that user opens
        -- the app.
        return query
        select
            null::uuid, null::uuid, sync_apple_subscription.apple_status,
            false, 0, null::integer, false,
            'unknown_subscription'::text;
        return;
    end if;

    insert into public.subscriptions as s (
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
        target_user,
        'apple',
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
        -- Periods only ever move forward. An out-of-order notification — Apple redelivers, and
        -- delivery order is not guaranteed — must not rewind a subscription to a period that has
        -- already been granted, which would let the next in-order delivery grant it a second time.
        current_period_start = greatest(excluded.current_period_start, s.current_period_start),
        current_period_end = greatest(excluded.current_period_end, s.current_period_end),
        auto_renew_status = excluded.auto_renew_status,
        environment = coalesce(excluded.environment, s.environment)
    returning s.id into row_id;

    select * into existing from public.subscriptions where subscriptions.id = row_id;

    entitled := existing.status = 'active' and existing.current_period_end > now();

    -- A paid, current period earns its credits. grant_subscription_credits owns that decision and
    -- its idempotency; this does not reimplement any of it, which is what keeps the listener, launch
    -- reconciliation and server notifications from each granting their own 25.
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

    return query
    select
        existing.id, existing.user_id, existing.status, false,
        0,
        (select profiles.generation_credits from public.profiles where profiles.id = existing.user_id),
        false,
        null::text;
end;
$$;

-- Reachable only by the verification paths, which run as service_role inside Edge Functions. A
-- client that could call this could write its own entitlement, which is the entire thing Apple
-- verification exists to prevent.
revoke all on function public.sync_apple_subscription(uuid, text, text, text, text, timestamptz, timestamptz, boolean, text)
    from public, anon, authenticated;

grant execute on function public.sync_apple_subscription(uuid, text, text, text, text, timestamptz, timestamptz, boolean, text)
    to service_role;
