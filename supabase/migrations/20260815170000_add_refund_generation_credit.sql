-- Credits are reserved before the image request goes out, so a generation that never produces an
-- image has to give the reservation back. Doing it in an RPC keeps the refund atomic instead of a
-- read-modify-write from the client.
create or replace function public.refund_generation_credit(credit_cost integer)
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
    set generation_credits = generation_credits + credit_cost
    where id = auth.uid()
    returning generation_credits into updated_balance;

    if updated_balance is null then
        raise exception 'profile_not_found';
    end if;

    return updated_balance;
end;
$$;
