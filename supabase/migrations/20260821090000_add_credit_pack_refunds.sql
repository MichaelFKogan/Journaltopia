-- Apple refunds a credit pack; the credits come back off the account.
--
-- Until now a refunded consumable left its credits in place, which is a straight revenue leak: buy a
-- 60-pack, request a refund, keep the credits. This closes it, and the whole design is about not
-- over-correcting while doing so.
--
-- The rule is *clamped reversal*. A refund removes up to what that transaction granted, and never
-- more than the purchased balance currently holds. Someone who bought 10 and spent 7 has 3 taken
-- back, not 10 — the other 7 were already turned into storyboards they received. The alternative,
-- letting the balance go negative, would invent a debt the user has no way to see coming and would
-- silently swallow their next purchase.
--
-- Two things a consumable refund must never do, both enforced by construction below: touch the
-- monthly bucket, and affect Journaltopia+ entitlement. A refunded pack is not a cancelled
-- subscription.

-- The reversal is a ledger reason of its own, so a refund is never mistaken for a spend and the two
-- can be counted separately.
alter table public.credit_ledger
    drop constraint if exists credit_ledger_reason_check;

alter table public.credit_ledger
    add constraint credit_ledger_reason_check check (reason in (
        'subscription_monthly_grant',
        'subscription_monthly_expiry',
        'storyboard_reservation',
        'storyboard_refund',
        'purchased_credit_pack',
        'purchased_credit_pack_refund'
    ));

-- A reversal that reclaimed nothing is still an event worth recording: it is the difference between
-- "Apple refunded this and we took the credits back" and "Apple refunded this and we never noticed".
-- It is the only reason permitted a zero delta, and the exception is written narrowly so the
-- constraint keeps its meaning everywhere else.
alter table public.credit_ledger
    drop constraint if exists credit_ledger_delta_nonzero;

alter table public.credit_ledger
    add constraint credit_ledger_delta_nonzero
        check (delta <> 0 or reason = 'purchased_credit_pack_refund');

alter table public.credit_ledger
    drop constraint if exists credit_ledger_delta_direction;

alter table public.credit_ledger
    add constraint credit_ledger_delta_direction check (
        case reason
            when 'storyboard_reservation' then delta < 0
            when 'subscription_monthly_expiry' then delta < 0
            when 'purchased_credit_pack_refund' then delta <= 0
            else delta > 0
        end
    );

-- Reverses one refunded credit-pack transaction.
--
-- Idempotency is the existing `(user_id, reason, bucket, source_id)` key doing its job: the reversal
-- shares the Apple transaction id with the grant it undoes and is distinguished by its reason, so a
-- redelivered REFUND notification — and Apple redelivers for days — collides and does nothing. That
-- is a database constraint rather than a check in TypeScript, so two notifications arriving at once
-- cannot both pass it.
--
-- How much was granted and how much came back are both recoverable afterwards: the grant row and the
-- reversal row share a source_id, so `10 granted, 3 reclaimed` reads straight off the pair without
-- needing a column to hold the difference.
create or replace function public.reverse_credit_pack_purchase(apple_transaction_id text)
returns table (
    reclaimed integer,
    originally_granted integer,
    purchased_balance integer,
    already_reversed boolean,
    conflict text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    grant_entry public.credit_ledger%rowtype;
    available integer;
    reclaim integer;
    updated_purchased integer;
    reversal_id uuid;
begin
    if apple_transaction_id is null or btrim(apple_transaction_id) = '' then
        raise exception 'missing_transaction_id';
    end if;

    -- The grant is what says who was credited and how much. Without one there is nothing to reverse:
    -- a refund for a transaction this server never redeemed is reported rather than guessed at.
    select * into grant_entry
    from public.credit_ledger
    where credit_ledger.reason = 'purchased_credit_pack'
      and credit_ledger.source_id = apple_transaction_id;

    if not found then
        return query select 0, 0, null::integer, false, 'unknown_transaction'::text;
        return;
    end if;

    -- Locked before the balance is read, so a concurrent generation cannot spend between the read
    -- and the write and drive the bucket negative.
    select profiles.purchased_generation_credits into available
    from public.profiles
    where profiles.id = grant_entry.user_id
    for update;

    if available is null then
        raise exception 'profile_not_found';
    end if;

    -- Clamped: never more than was granted, never more than remains. Both halves matter — the first
    -- stops a refund taking credits that came from somewhere else, the second stops it creating debt.
    reclaim := least(grant_entry.delta, available);
    reclaim := greatest(reclaim, 0);

    begin
        insert into public.credit_ledger (user_id, delta, reason, bucket, source_id)
        values (
            grant_entry.user_id, -reclaim, 'purchased_credit_pack_refund', 'purchased',
            apple_transaction_id
        )
        returning credit_ledger.id into reversal_id;
    exception
        when unique_violation then
            -- A redelivered notification. Nothing moves, and the caller is told so plainly enough to
            -- acknowledge Apple rather than leaving it to retry.
            return query
            select 0, grant_entry.delta, available, true, null::text;
            return;
    end;

    if reclaim > 0 then
        update public.profiles
        set purchased_generation_credits = purchased_generation_credits - reclaim
        where profiles.id = grant_entry.user_id
        returning purchased_generation_credits into updated_purchased;
    else
        updated_purchased := available;
    end if;

    update public.credit_ledger
    set balance_after = updated_purchased
    where credit_ledger.id = reversal_id;

    return query select reclaim, grant_entry.delta, updated_purchased, false, null::text;
end;
$$;

-- Server-owned, like every other accounting transition. Reachable only by the notification handler,
-- which runs as service_role after verifying Apple's signature over the refund.
revoke all on function public.reverse_credit_pack_purchase(text) from public, anon, authenticated;
grant execute on function public.reverse_credit_pack_purchase(text) to service_role;
