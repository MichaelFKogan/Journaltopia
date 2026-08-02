alter table public.profiles
add column if not exists generation_credits integer not null default 10;

alter table public.profiles
drop constraint if exists profiles_generation_credits_nonnegative;

alter table public.profiles
add constraint profiles_generation_credits_nonnegative
check (generation_credits >= 0);

create or replace function public.spend_generation_credit(credit_cost integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    updated_balance integer;
begin
    if auth.uid() is null then
        raise exception 'not_authenticated';
    end if;

    if credit_cost is null or credit_cost <= 0 then
        raise exception 'invalid_credit_cost';
    end if;

    update public.profiles
    set generation_credits = generation_credits - credit_cost
    where id = auth.uid()
      and generation_credits >= credit_cost
    returning generation_credits into updated_balance;

    if updated_balance is null then
        raise exception 'insufficient_generation_credits';
    end if;

    return updated_balance;
end;
$$;
