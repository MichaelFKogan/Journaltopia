-- What the app needs to know about the signed-in user's plan, in one row.
--
-- The Swift side is not built yet, but the shape it will read is worth settling now so that the
-- entitlement question has one answer rather than three screens each assembling their own from
-- profiles and subscriptions.
--
-- A view rather than an RPC because this is a read of existing rows, and `security_invoker` makes it
-- obey the same RLS the underlying tables already have: no new privilege is created, and a caller
-- sees exactly the profile and subscription rows their own policies allow. The balance is selected
-- from profiles rather than stored again, so this adds a reader, not a second source of truth.
create or replace view public.storytopia_plus_entitlement
with (security_invoker = true) as
select
    profiles.id                              as user_id,
    profiles.generation_credits              as generation_credits,
    (entitlement.id is not null)             as is_active,
    entitlement.product_id                   as product_id,
    entitlement.current_period_end           as current_period_end
from public.profiles
left join lateral (
    -- The subscription that entitles right now, if any. A user can accumulate rows over time —
    -- expired ones, a revoked one, a current one — so this picks the live one rather than assuming
    -- there is only ever a single row.
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

comment on view public.storytopia_plus_entitlement is
    'The signed-in user''s plan and credit balance. is_active is the same entitlement test the
     reservation path enforces server-side; reading false here is a reason to show the paywall, not
     permission to skip the server check.';

revoke all on public.storytopia_plus_entitlement from anon, authenticated;

grant select on public.storytopia_plus_entitlement to authenticated;
