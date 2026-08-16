-- Storytopia+ entitlement. This is the record of what Apple has told us about a subscription, and
-- it is the only thing the server will accept as proof that a user is entitled.
--
-- Nothing here trusts a client. The table is written by the server alone; a signed-in user may read
-- their own rows and nothing else. StoreKit and App Store Server Notifications arrive in a later
-- phase and will write this table after verifying a signed transaction — until then rows are
-- created by hand or by tests, which is exactly the shape the verification path will use.

create table if not exists public.subscriptions (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,

    -- Apple is the only provider today. The column exists so that adding another one is a constraint
    -- change rather than a schema migration.
    provider text not null default 'apple',

    -- The App Store product this entitlement came from, e.g. the monthly Storytopia+ subscription.
    product_id text not null,

    -- Apple's stable identity for a subscription across every renewal. This is the join key for
    -- everything: renewals update the row rather than inserting a new one.
    original_transaction_id text not null,

    -- The most recent transaction seen for that subscription. Useful for debugging and for ignoring
    -- notifications that arrive out of order; not used for any decision yet.
    latest_transaction_id text,

    status text not null,

    -- The period currently paid for. `current_period_start` is also the identity of a monthly credit
    -- grant, so it has to move on renewal or the next grant will look like a repeat of the last one.
    current_period_start timestamptz not null,
    current_period_end timestamptz not null,

    auto_renew_status boolean,
    environment text,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint subscriptions_provider_check
        check (provider in ('apple')),

    -- Four states we can actually populate from App Store data. Deliberately no 'grace_period',
    -- 'paused' or 'trial': nothing writes them yet, and a state the server cannot set is a state the
    -- reader has to guess about.
    --
    --   active         paid for and inside its period; the only state that entitles
    --   expired        lapsed normally, whether cancelled or simply not renewed
    --   revoked        Apple took it back (refund, family sharing removal, fraud)
    --   billing_retry  renewal failed and Apple is retrying; not entitled while here
    constraint subscriptions_status_check
        check (status in ('active', 'expired', 'revoked', 'billing_retry')),

    constraint subscriptions_environment_check
        check (environment is null or environment in ('sandbox', 'production')),

    constraint subscriptions_period_check
        check (current_period_end > current_period_start)
);

-- One Apple subscription identity, one row, globally. This is what stops the same purchase from
-- entitling two Storytopia accounts: a second user who signs in and presents the same
-- original_transaction_id collides here instead of being granted a parallel entitlement.
--
-- Re-binding a subscription to a different account is still possible — it is an UPDATE of user_id on
-- the one row — which is the correct behaviour for a user who deletes their account and signs up
-- again with the same Apple ID. What is impossible is two live rows for one purchase.
create unique index if not exists subscriptions_provider_original_transaction_key
    on public.subscriptions (provider, original_transaction_id);

-- The entitlement lookup that runs on every storyboard reservation.
create index if not exists subscriptions_entitlement_idx
    on public.subscriptions (user_id, status, current_period_end);

drop trigger if exists set_subscriptions_updated_at on public.subscriptions;
create trigger set_subscriptions_updated_at
    before update on public.subscriptions
    for each row
    execute function public.set_updated_at();

-- Reading, and only reading ------------------------------------------------------------------------
alter table public.subscriptions enable row level security;

drop policy if exists "Users can read their own subscriptions" on public.subscriptions;
create policy "Users can read their own subscriptions"
    on public.subscriptions
    for select
    to authenticated
    using (auth.uid() = user_id);

-- No insert, update or delete policy exists on purpose. Entitlement is a server decision, so there
-- is deliberately no row a client can write to claim it. The grants below say the same thing a
-- second time, so that neither control is load-bearing on its own.
revoke all on public.subscriptions from anon, authenticated;

grant select on public.subscriptions to authenticated;
grant select, insert, update, delete on public.subscriptions to service_role;

-- Is this user entitled to Storytopia+ right now? -------------------------------------------------
-- One definition, used by the reservation path and by the client-facing read model, so the two can
-- never disagree about what "subscribed" means.
--
-- Not granted to clients: it takes a user id, and a definer function that answers questions about
-- an arbitrary user is a lookup oracle. A signed-in user learns their own entitlement by reading
-- their own row through the policy above.
create or replace function public.has_active_storytopia_plus(account uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.subscriptions
        where subscriptions.user_id = account
          and subscriptions.status = 'active'
          and subscriptions.current_period_end > now()
    );
$$;

revoke all on function public.has_active_storytopia_plus(uuid) from public, anon, authenticated;
