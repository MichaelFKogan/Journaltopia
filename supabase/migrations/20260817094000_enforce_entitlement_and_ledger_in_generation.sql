-- Puts Journaltopia+ in front of storyboard generation, and puts every credit movement in the ledger.
--
-- Two functions are replaced. Both keep the behaviour 20260815190000 gave them — the reservation is
-- still one transaction, the failing transition is still the only refund and still runs under
-- `for update` — and gain the accounting entry that goes with the balance change.
--
-- What is deliberately *not* touched: start_, complete_, the sweeper, every grant and revoke, and
-- the pg_cron schedule. Sample Studio generation is unaffected because it never reaches this path;
-- generate-sample-storyboard writes sample_* tables and spends no credits, which is what keeps
-- sample authoring free without needing an exemption here.

-- Reserving -----------------------------------------------------------------------------------------
-- The order of the checks is the design. Entitlement is verified before anything is spent, so a user
-- without a subscription is turned away having been charged nothing — the exception aborts the
-- transaction, and there is no path where the credit moves and the check then fails.
--
--   not_authenticated              no session
--   invalid_credit_cost            nonsense cost
--   entry_not_found                the entry is not the caller's
--   subscription_required          no active Journaltopia+          <- new
--   insufficient_generation_credits  entitled, but out of credits (raised by spend_generation_credit)
--
-- subscription_required and insufficient_generation_credits stay distinct because the app has to do
-- different things with them: one leads to the paywall, the other to buying credits.
create or replace function public.reserve_storyboard_generation(
    storyboard_id uuid,
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
    remaining_balance integer;
begin
    if caller is null then
        raise exception 'not_authenticated';
    end if;

    if credit_cost is null or credit_cost <= 0 then
        raise exception 'invalid_credit_cost';
    end if;

    if not exists (
        select 1
        from public.entries
        where entries.user_id = caller
          and entries.client_entry_id = reserve_storyboard_generation.client_entry_id
    ) then
        raise exception 'entry_not_found';
    end if;

    -- The authoritative entitlement check. The app has its own gating for the sake of a decent
    -- interface, but this is the one that decides: it runs inside the reserving transaction, as the
    -- authenticated caller, against a table no client can write.
    if not public.has_active_storytopia_plus(caller) then
        raise exception 'subscription_required';
    end if;

    -- Unchanged, and still the only place a credit is taken. The balance it returns is recorded on
    -- the ledger entry below rather than re-read, so the two cannot disagree.
    remaining_balance := public.spend_generation_credit(reserve_storyboard_generation.credit_cost);

    insert into public.entry_storyboards (
        id,
        user_id,
        client_entry_id,
        storage_path,
        art_style,
        generation_quality,
        panel_layout,
        prompt,
        is_primary,
        generation_status,
        reserved_credits
    )
    values (
        reserve_storyboard_generation.storyboard_id,
        caller,
        reserve_storyboard_generation.client_entry_id,
        reserve_storyboard_generation.storage_path,
        reserve_storyboard_generation.art_style,
        reserve_storyboard_generation.generation_quality,
        null,
        reserve_storyboard_generation.prompt,
        false,
        'pending',
        reserve_storyboard_generation.credit_cost
    )
    returning * into reserved;

    -- Same transaction as the spend and the row, so a reservation can never exist without its
    -- accounting entry. No `on conflict` clause: a repeated storyboard id fails on the primary key
    -- above before it reaches here, and a conflict at this point would mean something is wrong in a
    -- way that should abort rather than be swallowed.
    insert into public.credit_ledger (user_id, delta, reason, source_id, balance_after)
    values (
        caller,
        -reserve_storyboard_generation.credit_cost,
        'storyboard_reservation',
        reserve_storyboard_generation.storyboard_id::text,
        remaining_balance
    );

    return reserved;
end;
$$;

-- Failing -------------------------------------------------------------------------------------------
-- Unchanged in every respect that matters: the row is taken `for update`, terminal rows are returned
-- untouched, rows that once completed or were already refunded get a refund of zero, and the amount
-- comes from `reserved_credits` rather than being re-derived. The only addition is the ledger entry
-- that accompanies the balance change.
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
    refund integer;
    refunded_balance integer;
begin
    select * into storyboard
    from public.entry_storyboards
    where entry_storyboards.id = finish_failed_storyboard_generation.storyboard_id
    for update;

    if not found then
        raise exception 'storyboard_not_found';
    end if;

    -- The double-refund guard. A row that already reads completed or failed is reported back as it
    -- stands; the credit moves only on the one transition out of a non-terminal state, and only one
    -- caller can hold this lock while taking it.
    if storyboard.generation_status in ('completed', 'failed') then
        return query
        select storyboard.id, storyboard.generation_status, storyboard.refunded_credits;
        return;
    end if;

    -- Two more guards, for rows whose status was moved backwards. A client cannot touch
    -- completed_at or refunded_credits, so a generation that once finished, or was already
    -- refunded, can never be refunded again.
    if storyboard.completed_at is not null or storyboard.refunded_credits is not null then
        refund := 0;
    else
        refund := coalesce(storyboard.reserved_credits, 0);
    end if;

    if refund > 0 then
        update public.profiles
        set generation_credits = generation_credits + refund
        where profiles.id = storyboard.user_id
        returning generation_credits into refunded_balance;

        if refunded_balance is null then
            raise exception 'profile_not_found';
        end if;

        -- Keyed by the storyboard, so one generation can produce at most one refund entry no matter
        -- how many times anything retries. The reservation entry above shares this source_id and is
        -- kept apart by its reason, which is how a single storyboard legitimately has both.
        --
        -- `do nothing` rather than raising: the status guard means this is already unreachable
        -- twice, and a constraint violation here would abort the failing transition and leave the
        -- row non-terminal — turning a belt-and-braces check into the thing that strands a job.
        insert into public.credit_ledger (user_id, delta, reason, source_id, balance_after)
        values (
            storyboard.user_id,
            refund,
            'storyboard_refund',
            storyboard.id::text,
            refunded_balance
        )
        on conflict on constraint credit_ledger_unique_event do nothing;
    end if;

    update public.entry_storyboards
    set generation_status = 'failed',
        failed_at = now(),
        is_primary = false,
        refunded_credits = refund,
        generation_error = left(
            coalesce(
                nullif(btrim(finish_failed_storyboard_generation.generation_error), ''),
                'Storyboard generation failed. Please try again.'
            ),
            500
        )
    where entry_storyboards.id = storyboard.id;

    return query
    select storyboard.id, 'failed'::text, refund;
end;
$$;

-- Replacing a function resets its privileges to the default, which is EXECUTE for PUBLIC. Both of
-- these were locked down in 20260815190000 and have to be locked down again here, or this migration
-- silently reopens the reservation path to anon and hands every client the refunding transition.
revoke all on function public.reserve_storyboard_generation(uuid, uuid, text, text, text, text, integer)
    from public, anon, authenticated;
revoke all on function public.finish_failed_storyboard_generation(uuid, text)
    from public, anon, authenticated;

grant execute on function public.reserve_storyboard_generation(uuid, uuid, text, text, text, text, integer)
    to authenticated;

-- finish_failed_storyboard_generation stays ungranted: its two callers, fail_storyboard_generation
-- and the sweeper, are security definer functions owned by the same role and reach it by ownership.
