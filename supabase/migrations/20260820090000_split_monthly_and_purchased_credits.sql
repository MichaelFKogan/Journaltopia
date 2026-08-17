-- Splits one credit balance into two, because the two behave differently.
--
-- Monthly credits come with a subscription period and do not survive it: at the start of each new
-- period the bucket is *replaced* with 25, not topped up. Purchased credits are bought outright,
-- never expire, and stay on the account even after Journaltopia+ lapses — they simply cannot be
-- spent until it is active again.
--
-- Everything downstream follows from that one difference:
--
--   spending order   monthly first, because monthly is the balance that is about to disappear
--   refunds          back to the buckets the credits came from, which means the reservation has to
--                    record the split rather than a single total
--   renewal          resets monthly, never touches purchased
--
-- `profiles.generation_credits` does not become a third bucket. It is dropped and re-added as a
-- generated column over the two real ones, so it stays readable by everything that already reads it
-- — the entitlement view, `GenerationCreditService` — while being physically impossible to write.

-- The entitlement view reads generation_credits, so it has to go before the column can be replaced.
drop view if exists public.journaltopia_plus_entitlement;

-- The two real balances ---------------------------------------------------------------------------
alter table public.profiles
    add column if not exists monthly_generation_credits integer not null default 0,
    add column if not exists purchased_generation_credits integer not null default 0;

comment on column public.profiles.monthly_generation_credits is
    'Credits from the current subscription period. Replaced with 25 at each new period and zeroed
     when the subscription lapses; never rolls over.';
comment on column public.profiles.purchased_generation_credits is
    'Credits bought as consumable packs. Never expire and survive cancellation, but can only be spent
     while Journaltopia+ is active.';

-- Existing balances become purchased credits -------------------------------------------------------
-- The migration decision, stated plainly: what is in generation_credits today is a mixture of the
-- old signup grant and old additive subscription grants, and there is no record of which is which —
-- the ledger only reaches back to the accounts created after it existed. Faced with that ambiguity,
-- the two options are to treat the balance as monthly (where it would silently vanish at the next
-- renewal) or as purchased (where it keeps working).
--
-- Purchased is the only defensible choice. These are credits people already believe they own, and
-- expiring them as a side effect of a schema change would be taking something away without telling
-- anyone. Erring the other way costs, at most, a few credits per existing account.
update public.profiles
set purchased_generation_credits = purchased_generation_credits + generation_credits
where generation_credits > 0;

-- generation_credits becomes a derived total -------------------------------------------------------
alter table public.profiles
    drop constraint if exists profiles_generation_credits_nonnegative;

alter table public.profiles
    drop column generation_credits;

alter table public.profiles
    add column generation_credits integer
        generated always as (monthly_generation_credits + purchased_generation_credits) stored;

comment on column public.profiles.generation_credits is
    'Total spendable credits, derived. Kept so existing readers keep working; generated, so it can
     never drift from the two buckets and can never be written by anyone, including the server.';

alter table public.profiles
    drop constraint if exists profiles_credit_buckets_nonnegative;

alter table public.profiles
    add constraint profiles_credit_buckets_nonnegative
        check (monthly_generation_credits >= 0 and purchased_generation_credits >= 0);

-- The ledger learns which bucket moved -------------------------------------------------------------
alter table public.credit_ledger
    add column if not exists bucket text not null default 'purchased';

comment on column public.credit_ledger.bucket is
    'Which balance this entry moved. A single generation can produce one entry per bucket when its
     cost spans both, which is also why the bucket is part of the idempotency key.';

alter table public.credit_ledger
    drop constraint if exists credit_ledger_bucket_check;

alter table public.credit_ledger
    add constraint credit_ledger_bucket_check
        check (bucket in ('monthly', 'purchased'));

-- Reasons gain the monthly expiry that a reset produces.
alter table public.credit_ledger
    drop constraint if exists credit_ledger_reason_check;

alter table public.credit_ledger
    add constraint credit_ledger_reason_check check (reason in (
        'subscription_monthly_grant',
        'subscription_monthly_expiry',
        'storyboard_reservation',
        'storyboard_refund',
        'purchased_credit_pack'
    ));

-- Directions that are structurally impossible, so a wrong sign fails loudly.
alter table public.credit_ledger
    drop constraint if exists credit_ledger_delta_direction;

alter table public.credit_ledger
    add constraint credit_ledger_delta_direction check (
        case reason
            when 'storyboard_reservation' then delta < 0
            when 'subscription_monthly_expiry' then delta < 0
            else delta > 0
        end
    );

-- Idempotency now keys on the bucket too. Without it, an HD generation that spent one credit from
-- each bucket would be two rows with an identical (user, reason, source) and could not be written.
alter table public.credit_ledger
    drop constraint if exists credit_ledger_unique_event;

alter table public.credit_ledger
    add constraint credit_ledger_unique_event unique (user_id, reason, bucket, source_id);

-- One Apple transaction redeems once, globally rather than per account.
--
-- The constraint above is scoped to a user, which would let the same signed consumable be presented
-- by two different Journaltopia accounts and credited to both. Apple transaction ids are unique
-- across the store, so this index says the same thing the store does.
create unique index if not exists credit_ledger_credit_pack_transaction_key
    on public.credit_ledger (source_id)
    where reason = 'purchased_credit_pack';

-- Reservations record the split ---------------------------------------------------------------------
-- Without this the refund has to guess which bucket a credit came from, and guessing wrong either
-- gives someone a non-expiring credit they did not buy or takes one away that they did.
alter table public.entry_storyboards
    add column if not exists reserved_monthly_credits integer,
    add column if not exists reserved_purchased_credits integer,
    add column if not exists refunded_monthly_credits integer,
    add column if not exists refunded_purchased_credits integer;

comment on column public.entry_storyboards.reserved_monthly_credits is
    'How much of this reservation came from the monthly bucket. The refund reads this rather than
     re-deriving it, so the two can never disagree.';

-- Rows reserved before the split are all purchased-bucket by construction: the migration above moved
-- every existing balance there, so anything they refund has to go back there.
update public.entry_storyboards
set reserved_monthly_credits = 0,
    reserved_purchased_credits = coalesce(reserved_credits, 0)
where reserved_monthly_credits is null;

update public.entry_storyboards
set refunded_monthly_credits = 0,
    refunded_purchased_credits = coalesce(refunded_credits, 0)
where refunded_credits is not null
  and refunded_monthly_credits is null;

alter table public.entry_storyboards
    drop constraint if exists entry_storyboards_bucket_amounts_check;

alter table public.entry_storyboards
    add constraint entry_storyboards_bucket_amounts_check check (
        (reserved_monthly_credits is null or reserved_monthly_credits >= 0)
        and (reserved_purchased_credits is null or reserved_purchased_credits >= 0)
        and (refunded_monthly_credits is null or refunded_monthly_credits >= 0)
        and (refunded_purchased_credits is null or refunded_purchased_credits >= 0)
    );

-- Spending ------------------------------------------------------------------------------------------
-- Replaces spend_generation_credit, which knew about one balance. Monthly first, then purchased for
-- the remainder, under a row lock so two concurrent reservations cannot both read the same balance
-- and both decide they can afford it.
drop function if exists public.spend_generation_credit(integer);

create or replace function public.spend_generation_credits(credit_cost integer)
returns table (
    spent_monthly integer,
    spent_purchased integer,
    monthly_balance integer,
    purchased_balance integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := auth.uid();
    available_monthly integer;
    available_purchased integer;
    take_monthly integer;
    take_purchased integer;
begin
    if caller is null then
        raise exception 'not_authenticated';
    end if;

    if credit_cost is null or credit_cost <= 0 then
        raise exception 'invalid_credit_cost';
    end if;

    select profiles.monthly_generation_credits, profiles.purchased_generation_credits
    into available_monthly, available_purchased
    from public.profiles
    where profiles.id = caller
    for update;

    if not found then
        raise exception 'profile_not_found';
    end if;

    if available_monthly + available_purchased < credit_cost then
        raise exception 'insufficient_generation_credits';
    end if;

    -- Monthly first, because monthly is the balance that expires. Spending purchased credits while
    -- monthly ones sit unused would quietly destroy value the user paid for.
    take_monthly := least(available_monthly, credit_cost);
    take_purchased := credit_cost - take_monthly;

    update public.profiles
    set monthly_generation_credits = monthly_generation_credits - take_monthly,
        purchased_generation_credits = purchased_generation_credits - take_purchased
    where profiles.id = caller
    returning monthly_generation_credits, purchased_generation_credits
    into available_monthly, available_purchased;

    return query select take_monthly, take_purchased, available_monthly, available_purchased;
end;
$$;

revoke all on function public.spend_generation_credits(integer) from public, anon, authenticated;

-- The monthly grant is now a reset ------------------------------------------------------------------
-- A new period replaces whatever is left of the old one. The expiry is written to the ledger as its
-- own entry rather than being folded into the grant, so "you had 3 credits and they went" is a
-- readable fact rather than arithmetic someone has to reconstruct.
-- Dropped rather than replaced: the return type gains the bucket balances and the expiry it
-- performed, and `create or replace` cannot widen a function's result columns.
drop function if exists public.grant_subscription_credits(uuid);

create or replace function public.grant_subscription_credits(subscription_id uuid)
returns table (
    granted integer,
    balance integer,
    already_granted boolean,
    monthly_balance integer,
    purchased_balance integer,
    expired_monthly integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    subscription public.subscriptions%rowtype;
    period_source text;
    award integer := public.journaltopia_plus_period_credits();
    ledger_id uuid;
    expiring integer;
    updated_monthly integer;
    updated_purchased integer;
begin
    select * into subscription
    from public.subscriptions
    where subscriptions.id = grant_subscription_credits.subscription_id
    for update;

    if not found then
        raise exception 'subscription_not_found';
    end if;

    if subscription.status <> 'active' or subscription.current_period_end <= now() then
        raise exception 'subscription_not_active';
    end if;

    period_source := subscription.original_transaction_id
        || ':'
        || extract(epoch from subscription.current_period_start)::bigint::text;

    -- The ledger insert is the idempotency check, attempted before anything moves, so a redelivered
    -- notification cannot reset a bucket the user has since spent from.
    insert into public.credit_ledger (user_id, delta, reason, bucket, source_id)
    values (subscription.user_id, award, 'subscription_monthly_grant', 'monthly', period_source)
    on conflict on constraint credit_ledger_unique_event do nothing
    returning credit_ledger.id into ledger_id;

    if ledger_id is null then
        select profiles.monthly_generation_credits, profiles.purchased_generation_credits
        into updated_monthly, updated_purchased
        from public.profiles where profiles.id = subscription.user_id;

        return query
        select 0, updated_monthly + updated_purchased, true, updated_monthly, updated_purchased, 0;
        return;
    end if;

    select profiles.monthly_generation_credits into expiring
    from public.profiles where profiles.id = subscription.user_id
    for update;

    if expiring is null then
        raise exception 'profile_not_found';
    end if;

    if expiring > 0 then
        insert into public.credit_ledger (user_id, delta, reason, bucket, source_id, balance_after)
        values (subscription.user_id, -expiring, 'subscription_monthly_expiry', 'monthly', period_source, 0)
        on conflict on constraint credit_ledger_unique_event do nothing;
    end if;

    -- A replacement, not an increment. Purchased credits are deliberately untouched.
    update public.profiles
    set monthly_generation_credits = award
    where profiles.id = subscription.user_id
    returning monthly_generation_credits, purchased_generation_credits
    into updated_monthly, updated_purchased;

    update public.credit_ledger
    set balance_after = updated_monthly
    where credit_ledger.id = ledger_id;

    return query
    select award, updated_monthly + updated_purchased, false, updated_monthly, updated_purchased, expiring;
end;
$$;

revoke all on function public.grant_subscription_credits(uuid) from public, anon, authenticated;
grant execute on function public.grant_subscription_credits(uuid) to service_role;

-- Reserving ------------------------------------------------------------------------------------------
-- Unchanged in its guarantees — idempotent per request id, entitlement before spending, one credit
-- movement per delivery — and extended so the split is recorded on the row and in the ledger.
create or replace function public.reserve_storyboard_generation(
    storyboard_id uuid,
    generation_request_id uuid,
    client_entry_id uuid,
    storage_path text,
    art_style text,
    generation_quality text,
    prompt text,
    credit_cost integer
)
returns public.entry_storyboards
language plpgsql
security definer
set search_path = ''
as $$
declare
    caller uuid := auth.uid();
    reserved public.entry_storyboards%rowtype;
    spend record;
begin
    if caller is null then
        raise exception 'not_authenticated';
    end if;

    if generation_request_id is null then
        raise exception 'missing_generation_request_id';
    end if;

    if credit_cost is null or credit_cost <= 0 then
        raise exception 'invalid_credit_cost';
    end if;

    select * into reserved
    from public.entry_storyboards
    where entry_storyboards.user_id = caller
      and entry_storyboards.generation_request_id = reserve_storyboard_generation.generation_request_id;

    if found then
        return reserved;
    end if;

    if not exists (
        select 1
        from public.entries
        where entries.user_id = caller
          and entries.client_entry_id = reserve_storyboard_generation.client_entry_id
    ) then
        raise exception 'entry_not_found';
    end if;

    -- Entitlement gates spending from *either* bucket. Purchased credits survive cancellation but
    -- are not spendable without an active subscription, and this is where that is enforced.
    if not public.has_active_journaltopia_plus(caller) then
        raise exception 'subscription_required';
    end if;

    begin
        select * into spend from public.spend_generation_credits(reserve_storyboard_generation.credit_cost);

        insert into public.entry_storyboards (
            id,
            user_id,
            client_entry_id,
            generation_request_id,
            storage_path,
            art_style,
            generation_quality,
            panel_layout,
            prompt,
            is_primary,
            generation_status,
            reserved_credits,
            reserved_monthly_credits,
            reserved_purchased_credits
        )
        values (
            reserve_storyboard_generation.storyboard_id,
            caller,
            reserve_storyboard_generation.client_entry_id,
            reserve_storyboard_generation.generation_request_id,
            reserve_storyboard_generation.storage_path,
            reserve_storyboard_generation.art_style,
            reserve_storyboard_generation.generation_quality,
            null,
            reserve_storyboard_generation.prompt,
            false,
            'pending',
            reserve_storyboard_generation.credit_cost,
            spend.spent_monthly,
            spend.spent_purchased
        )
        returning * into reserved;

        -- One entry per bucket that actually moved, so the history reads as what happened rather
        -- than as a total that has to be unpicked.
        if spend.spent_monthly > 0 then
            insert into public.credit_ledger (user_id, delta, reason, bucket, source_id, balance_after)
            values (
                caller, -spend.spent_monthly, 'storyboard_reservation', 'monthly',
                reserve_storyboard_generation.storyboard_id::text, spend.monthly_balance
            );
        end if;

        if spend.spent_purchased > 0 then
            insert into public.credit_ledger (user_id, delta, reason, bucket, source_id, balance_after)
            values (
                caller, -spend.spent_purchased, 'storyboard_reservation', 'purchased',
                reserve_storyboard_generation.storyboard_id::text, spend.purchased_balance
            );
        end if;
    exception
        when unique_violation then
            select * into reserved
            from public.entry_storyboards
            where entry_storyboards.user_id = caller
              and entry_storyboards.generation_request_id
                  = reserve_storyboard_generation.generation_request_id;

            if not found then
                raise;
            end if;

            return reserved;
    end;

    return reserved;
end;
$$;

revoke all on function public.reserve_storyboard_generation(uuid, uuid, uuid, text, text, text, text, integer)
    from public, anon, authenticated;
grant execute on function public.reserve_storyboard_generation(uuid, uuid, uuid, text, text, text, text, integer)
    to authenticated;

-- Failing ---------------------------------------------------------------------------------------------
-- Every guarantee from before is intact: the row is taken `for update`, terminal rows are returned
-- untouched, a row that once completed or was already refunded refunds nothing, and the amounts come
-- from what the reservation recorded. The change is that there are now two amounts, and each goes
-- home to the bucket it came from.
create or replace function public.finish_failed_storyboard_generation(
    storyboard_id uuid,
    generation_error text
)
returns table (
    id uuid,
    generation_status text,
    refunded_credits integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    storyboard public.entry_storyboards%rowtype;
    refund_monthly integer;
    refund_purchased integer;
    updated_monthly integer;
    updated_purchased integer;
begin
    select * into storyboard
    from public.entry_storyboards
    where entry_storyboards.id = finish_failed_storyboard_generation.storyboard_id
    for update;

    if not found then
        raise exception 'storyboard_not_found';
    end if;

    if storyboard.generation_status in ('completed', 'failed') then
        return query
        select storyboard.id, storyboard.generation_status, storyboard.refunded_credits;
        return;
    end if;

    if storyboard.completed_at is not null or storyboard.refunded_credits is not null then
        refund_monthly := 0;
        refund_purchased := 0;
    else
        -- Falls back to the total in the purchased bucket for any row reserved before the split, of
        -- which there are none after this migration's backfill, but the coalesce keeps a row written
        -- by an older function from refunding nothing at all.
        refund_monthly := coalesce(storyboard.reserved_monthly_credits, 0);
        refund_purchased := coalesce(
            storyboard.reserved_purchased_credits,
            coalesce(storyboard.reserved_credits, 0) - coalesce(storyboard.reserved_monthly_credits, 0)
        );
    end if;

    if refund_monthly > 0 or refund_purchased > 0 then
        update public.profiles
        set monthly_generation_credits = monthly_generation_credits + refund_monthly,
            purchased_generation_credits = purchased_generation_credits + refund_purchased
        where profiles.id = storyboard.user_id
        returning monthly_generation_credits, purchased_generation_credits
        into updated_monthly, updated_purchased;

        if updated_monthly is null then
            raise exception 'profile_not_found';
        end if;

        -- Keyed by the storyboard and the bucket, so one generation produces at most one refund per
        -- bucket however many times anything retries. `do nothing` rather than raising: the status
        -- guard already makes this unreachable twice, and a constraint violation here would abort
        -- the failing transition and strand the job.
        if refund_monthly > 0 then
            insert into public.credit_ledger (user_id, delta, reason, bucket, source_id, balance_after)
            values (
                storyboard.user_id, refund_monthly, 'storyboard_refund', 'monthly',
                storyboard.id::text, updated_monthly
            )
            on conflict on constraint credit_ledger_unique_event do nothing;
        end if;

        if refund_purchased > 0 then
            insert into public.credit_ledger (user_id, delta, reason, bucket, source_id, balance_after)
            values (
                storyboard.user_id, refund_purchased, 'storyboard_refund', 'purchased',
                storyboard.id::text, updated_purchased
            )
            on conflict on constraint credit_ledger_unique_event do nothing;
        end if;
    end if;

    update public.entry_storyboards
    set generation_status = 'failed',
        failed_at = now(),
        is_primary = false,
        refunded_credits = refund_monthly + refund_purchased,
        refunded_monthly_credits = refund_monthly,
        refunded_purchased_credits = refund_purchased,
        generation_error = left(
            coalesce(
                nullif(btrim(finish_failed_storyboard_generation.generation_error), ''),
                'Storyboard generation failed. Please try again.'
            ),
            500
        )
    where entry_storyboards.id = storyboard.id;

    return query
    select storyboard.id, 'failed'::text, refund_monthly + refund_purchased;
end;
$$;

revoke all on function public.finish_failed_storyboard_generation(uuid, text)
    from public, anon, authenticated;

-- The read model exposes both buckets ------------------------------------------------------------------
create or replace view public.journaltopia_plus_entitlement
with (security_invoker = true) as
select
    profiles.id                                  as user_id,
    profiles.generation_credits                  as generation_credits,
    profiles.monthly_generation_credits          as monthly_generation_credits,
    profiles.purchased_generation_credits        as purchased_generation_credits,
    (entitlement.id is not null)                 as is_active,
    entitlement.product_id                       as product_id,
    entitlement.current_period_end               as current_period_end
from public.profiles
left join lateral (
    select
        subscriptions.id,
        subscriptions.product_id,
        subscriptions.current_period_end
    from public.subscriptions
    where subscriptions.user_id = profiles.id
      and subscriptions.status = 'active'
      and subscriptions.current_period_end > now()
    order by subscriptions.current_period_end desc
    limit 1
) as entitlement on true
where profiles.id = auth.uid();

comment on view public.journaltopia_plus_entitlement is
    'The signed-in user''s plan and both credit balances. generation_credits is the derived total.
     is_active is the same entitlement test the reservation path enforces server-side; reading false
     here is a reason to show the paywall, not permission to skip the server check.';

revoke all on public.journaltopia_plus_entitlement from anon, authenticated;
grant select on public.journaltopia_plus_entitlement to authenticated;
