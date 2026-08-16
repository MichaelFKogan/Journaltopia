-- The monthly Journaltopia+ credit grant.
--
-- Called once per subscription period, after something trustworthy has confirmed that period exists.
-- Today that means a row in public.subscriptions written by hand; from the StoreKit phase onward it
-- will mean a verified App Store transaction that wrote the same row. Either way this function reads
-- the subscription rather than being told about it, so there is no parameter a caller could use to
-- assert an entitlement they do not have.
--
-- The grant adds to the balance instead of replacing it, so unused credits roll over: a subscriber
-- with 7 credits left at renewal ends up with 32, not 25.

-- 25 credits per period. Kept as a function rather than inlined so the number has one home when the
-- purchased-pack path arrives and needs to talk about the same currency.
create or replace function public.storytopia_plus_period_credits()
returns integer
language sql
immutable
as $$
    select 25;
$$;

-- Grants the period's credits, exactly once.
--
-- Returns what happened rather than raising on a repeat, because a repeat is the expected case: App
-- Store notifications are delivered more than once by design, and a caller that has to distinguish
-- "already done" from "failed" by parsing an error message will eventually get it wrong.
--
--   granted         how many credits this call added; 0 when the period was already granted
--   balance         the balance afterwards, whether or not this call changed it
--   already_granted true when a previous call had already applied this period
create or replace function public.grant_subscription_credits(subscription_id uuid)
returns table (
    granted integer,
    balance integer,
    already_granted boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    subscription public.subscriptions%rowtype;
    period_source text;
    award integer := public.storytopia_plus_period_credits();
    updated_balance integer;
    ledger_id uuid;
begin
    -- The lock serialises two callers arriving for the same subscription. The unique constraint
    -- below would catch them anyway; this makes the second one wait for a decided outcome rather
    -- than race to a conflict.
    select * into subscription
    from public.subscriptions
    where subscriptions.id = grant_subscription_credits.subscription_id
    for update;

    if not found then
        raise exception 'subscription_not_found';
    end if;

    -- Only a period that is actually paid for and actually current may grant. An expired or revoked
    -- subscription granting credits would be the whole exploit.
    if subscription.status <> 'active' or subscription.current_period_end <= now() then
        raise exception 'subscription_not_active';
    end if;

    -- The identity of *this period of this subscription*. The transaction id is stable across
    -- renewals and the period start is not, so the pair changes exactly when a new period begins —
    -- which is exactly when another grant is due.
    period_source := subscription.original_transaction_id
        || ':'
        || extract(epoch from subscription.current_period_start)::bigint::text;

    -- The ledger insert is the idempotency check. It is attempted before the balance moves, so a
    -- repeat cannot get as far as adding credits.
    insert into public.credit_ledger (user_id, delta, reason, source_id)
    values (
        subscription.user_id,
        award,
        'subscription_monthly_grant',
        period_source
    )
    on conflict on constraint credit_ledger_unique_event do nothing
    returning credit_ledger.id into ledger_id;

    if ledger_id is null then
        return query
        select
            0,
            (select profiles.generation_credits from public.profiles where profiles.id = subscription.user_id),
            true;
        return;
    end if;

    update public.profiles
    set generation_credits = generation_credits + award
    where profiles.id = subscription.user_id
    returning generation_credits into updated_balance;

    if updated_balance is null then
        raise exception 'profile_not_found';
    end if;

    -- Recorded now that it is known. Same transaction, so the entry and the balance it describes
    -- commit together or not at all.
    update public.credit_ledger
    set balance_after = updated_balance
    where credit_ledger.id = ledger_id;

    return query select award, updated_balance, false;
end;
$$;

-- Server-owned, like every other accounting transition. A client that could call this could grant
-- itself credits for any subscription id it could guess.
revoke all on function public.grant_subscription_credits(uuid) from public, anon, authenticated;
revoke all on function public.storytopia_plus_period_credits() from public, anon, authenticated;

grant execute on function public.grant_subscription_credits(uuid) to service_role;
