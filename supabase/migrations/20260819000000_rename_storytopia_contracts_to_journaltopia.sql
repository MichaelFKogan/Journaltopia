-- Forward rename from Storytopia database/storage contracts to Journaltopia.
-- Historical migrations keep the original names they applied; this migration moves deployed state.

-- Media bucket -------------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
select 'journaltopia-media', 'journaltopia-media', public
from storage.buckets
where id = 'storytopia-media'
on conflict (id) do update
set name = excluded.name,
    public = excluded.public;

update storage.objects
set bucket_id = 'journaltopia-media'
where bucket_id = 'storytopia-media';

delete from storage.buckets
where id = 'storytopia-media';

drop policy if exists "Users can read their own storytopia media" on storage.objects;
drop policy if exists "Users can insert their own storytopia media" on storage.objects;
drop policy if exists "Users can update their own storytopia media" on storage.objects;
drop policy if exists "Users can delete their own storytopia media" on storage.objects;

drop policy if exists "Users can read their own journaltopia media" on storage.objects;
create policy "Users can read their own journaltopia media"
    on storage.objects
    for select
    to authenticated
    using (
        bucket_id = 'journaltopia-media'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

drop policy if exists "Users can insert their own journaltopia media" on storage.objects;
create policy "Users can insert their own journaltopia media"
    on storage.objects
    for insert
    to authenticated
    with check (
        bucket_id = 'journaltopia-media'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

drop policy if exists "Users can update their own journaltopia media" on storage.objects;
create policy "Users can update their own journaltopia media"
    on storage.objects
    for update
    to authenticated
    using (
        bucket_id = 'journaltopia-media'
        and (storage.foldername(name))[1] = auth.uid()::text
    )
    with check (
        bucket_id = 'journaltopia-media'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

drop policy if exists "Users can delete their own journaltopia media" on storage.objects;
create policy "Users can delete their own journaltopia media"
    on storage.objects
    for delete
    to authenticated
    using (
        bucket_id = 'journaltopia-media'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

-- Sample pack slug and object path prefixes ---------------------------------------------------
update public.sample_story_packs
set slug = 'journaltopia-first-run',
    title = replace(title, 'Storytopia', 'Journaltopia')
where slug = 'storytopia-first-run'
  and not exists (
      select 1
      from public.sample_story_packs existing
      where existing.slug = 'journaltopia-first-run'
        and existing.locale = sample_story_packs.locale
        and existing.version = sample_story_packs.version
  );

update public.sample_storyboard_pages
set storage_path = regexp_replace(storage_path, '^storytopia-first-run/', 'journaltopia-first-run/')
where storage_path like 'storytopia-first-run/%';

update public.sample_entry_assets
set storage_path = regexp_replace(storage_path, '^storytopia-first-run/', 'journaltopia-first-run/')
where storage_path like 'storytopia-first-run/%';

update storage.objects
set name = regexp_replace(name, '^storytopia-first-run/', 'journaltopia-first-run/')
where bucket_id = 'sample-story-assets'
  and name like 'storytopia-first-run/%';

-- Journaltopia+ credit helper -----------------------------------------------------------------
create or replace function public.journaltopia_plus_period_credits()
returns integer
language sql
immutable
as $$
    select 25;
$$;

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
    award integer := public.journaltopia_plus_period_credits();
    updated_balance integer;
    ledger_id uuid;
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

    update public.credit_ledger
    set balance_after = updated_balance
    where credit_ledger.id = ledger_id;

    return query select award, updated_balance, false;
end;
$$;

revoke all on function public.grant_subscription_credits(uuid) from public, anon, authenticated;
revoke all on function public.journaltopia_plus_period_credits() from public, anon, authenticated;
grant execute on function public.grant_subscription_credits(uuid) to service_role;

drop function if exists public.storytopia_plus_period_credits();

-- Journaltopia+ entitlement predicate and read model ------------------------------------------
create or replace function public.has_active_journaltopia_plus(account uuid)
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

revoke all on function public.has_active_journaltopia_plus(uuid) from public, anon, authenticated;

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

    if not public.has_active_journaltopia_plus(caller) then
        raise exception 'subscription_required';
    end if;

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

drop function if exists public.has_active_storytopia_plus(uuid);

create or replace view public.journaltopia_plus_entitlement
with (security_invoker = true) as
select
    profiles.id                              as user_id,
    profiles.generation_credits              as generation_credits,
    (entitlement.id is not null)             as is_active,
    entitlement.product_id                   as product_id,
    entitlement.current_period_end           as current_period_end
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
    'The signed-in user''s plan and credit balance. is_active is the same entitlement test the
     reservation path enforces server-side; reading false here is a reason to show the paywall, not
     permission to skip the server check.';

revoke all on public.journaltopia_plus_entitlement from anon, authenticated;
grant select on public.journaltopia_plus_entitlement to authenticated;

drop view if exists public.storytopia_plus_entitlement;
