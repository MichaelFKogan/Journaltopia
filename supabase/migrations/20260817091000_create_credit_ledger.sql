-- Every event that moved a credit balance, and why.
--
-- `profiles.generation_credits` stays as it is: the current balance, read on every screen, spent and
-- refunded under a row lock. This table is the history behind that number. Keeping both is a
-- deliberate trade — the balance is a cache that can be recomputed from here, and the ledger is what
-- makes "why does this user have 32 credits" answerable at all.
--
-- The unique constraint at the bottom is the real reason this table exists. Grants, purchases and
-- refunds all arrive from paths that can retry — an App Store notification delivered twice, a
-- background job re-run, a sweeper racing a worker — and a ledger row is what makes the second
-- delivery a no-op instead of free credits.

create table if not exists public.credit_ledger (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,

    -- Signed: negative spends, positive grants and refunds. Never zero; an event that moved nothing
    -- is not an event.
    delta integer not null,

    reason text not null,

    -- What this entry is *about*, in whatever identity that reason uses. Text rather than uuid
    -- because the identities differ in kind: a storyboard is a uuid, a subscription period is a
    -- transaction id and a period start, a purchase will be an Apple transaction id.
    source_id text not null,

    -- The balance immediately after this entry was applied, recorded by the function that applied
    -- it. Not authoritative — `profiles.generation_credits` is — but it turns the ledger into
    -- something you can read top to bottom when a balance looks wrong, without replaying every row.
    balance_after integer,

    created_at timestamptz not null default now(),

    constraint credit_ledger_reason_check check (reason in (
        'subscription_monthly_grant',
        'storyboard_reservation',
        'storyboard_refund',
        'purchased_credit_pack'
    )),

    constraint credit_ledger_delta_nonzero check (delta <> 0),

    -- Directions that are structurally impossible, so a caller passing the wrong sign fails loudly
    -- rather than quietly inverting an accounting entry.
    constraint credit_ledger_delta_direction check (
        case reason
            when 'storyboard_reservation' then delta < 0
            else delta > 0
        end
    ),

    -- Idempotency, enforced by the database rather than by whoever remembers to check.
    --
    -- One entry per (user, kind of event, thing the event is about):
    --   a subscription period grants once           (user, subscription_monthly_grant, txn:period_start)
    --   a storyboard reserves once                  (user, storyboard_reservation,     storyboard_id)
    --   a storyboard refunds once                   (user, storyboard_refund,          storyboard_id)
    --   a purchase credits once                     (user, purchased_credit_pack,      transaction_id)
    --
    -- Reservation and refund share a source_id and are separated by reason, which is what lets one
    -- storyboard legitimately produce both entries and never two of either.
    constraint credit_ledger_unique_event unique (user_id, reason, source_id)
);

-- The account history, newest first.
create index if not exists credit_ledger_user_created_at_idx
    on public.credit_ledger (user_id, created_at desc);

-- Append-only, and readable only by its owner ------------------------------------------------------
alter table public.credit_ledger enable row level security;

drop policy if exists "Users can read their own credit ledger" on public.credit_ledger;
create policy "Users can read their own credit ledger"
    on public.credit_ledger
    for select
    to authenticated
    using (auth.uid() = user_id);

-- No insert, update or delete policy, and no grant. Entries are written by the security definer
-- functions that move the balance, in the same transaction as the balance move, so an entry cannot
-- exist without its effect or the effect without its entry.
--
-- Append-only is a property of who may write rather than of a trigger: nothing that can reach this
-- table has UPDATE or DELETE on it, including service_role, so history cannot be rewritten through
-- the Data API at all.
revoke all on public.credit_ledger from anon, authenticated;

grant select on public.credit_ledger to authenticated;
grant select, insert on public.credit_ledger to service_role;
