-- Credit card due dates for the Home card. Each statement is a card's statement balance and its
-- due date (and the statement date, when known). What is still due is the statement balance minus
-- payments into the card made after the statement date.
create table public.card_statements (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  account_id uuid not null references public.accounts (id) on delete cascade,
  statement_date date,
  due_date date not null,
  amount numeric(14, 2) not null check (amount >= 0),
  created_at timestamptz not null default now(),
  unique (account_id, due_date)
);

alter table public.card_statements enable row level security;
create policy card_statements_member on public.card_statements for all to authenticated
  using (public.is_household_member(household_id)) with check (public.is_household_member(household_id));

-- Every active credit card with its balance and latest statement: due amount left, days to go.
create function public.app_cards(p jsonb default '{}')
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x.sort_due nulls last, x.name), '[]') from (
    select a.id as aid, a.name,
      -(a.opening_balance + coalesce((select sum(t.amount) from public.transactions t
        where t.account_id = a.id and t.txn_date >= a.opening_date), 0)) as owed,
      s.due_date as due, s.statement_date as stmt, s.amount as stmt_amt,
      case when s.id is null then null else greatest(0, s.amount - coalesce((select sum(t.amount) from public.transactions t
        where t.account_id = a.id and t.kind = 'transfer' and t.amount > 0
          and t.txn_date > coalesce(s.statement_date, s.due_date - 21)), 0)) end as left_due,
      s.due_date as sort_due
    from public.accounts a
    left join lateral (select * from public.card_statements cs where cs.account_id = a.id order by cs.due_date desc limit 1) s on true
    where a.household_id = public.app_household() and a.type = 'credit_card' and a.is_active
  ) x;
$$;

-- Save a statement (p.acct, p.due, p.amount, optional p.stmt); the same due date is replaced.
create function public.app_set_statement(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  acct uuid := (p ->> 'acct')::uuid;
  amt numeric := round(abs((p ->> 'amount')::numeric), 2);
begin
  perform public.app_check_account(h, acct);
  if (p ->> 'due') is null or amt is null then
    raise exception 'Enter the statement balance and due date';
  end if;
  insert into public.card_statements (household_id, account_id, statement_date, due_date, amount)
  values (h, acct, nullif(p ->> 'stmt', '')::date, (p ->> 'due')::date, amt)
  on conflict (account_id, due_date) do update set amount = excluded.amount, statement_date = excluded.statement_date;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.app_cards(jsonb) from public, anon;
grant execute on function public.app_cards(jsonb) to authenticated;
revoke execute on function public.app_set_statement(jsonb) from public, anon;
grant execute on function public.app_set_statement(jsonb) to authenticated;
