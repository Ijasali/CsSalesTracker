-- Charts can scroll back to the first transaction, and an edit can change a transaction's amount.

-- app_cat and app_net take p.from (first month to include); without it they keep 12 months.
create or replace function public.app_cat(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  cid uuid := (p ->> 'cid')::uuid;
  e date := date_trunc('month', (p ->> 'end')::date)::date;
  s date := coalesce(date_trunc('month', (p ->> 'from')::date)::date, e - interval '11 month');
  k public.txn_kind := coalesce(p ->> 'kind', 'expense')::public.txn_kind;
  r jsonb;
begin
  select jsonb_build_object('rows', jsonb_agg(x)) into r from (
    select date_trunc('month', t.txn_date)::date as m, t.category_id as sub,
      sum(case when k = 'income' then t.amount else -t.amount end) as amt, count(*) as n
    from public.transactions t
    join public.accounts a on a.id = t.account_id and a.include_in_totals
    join public.categories c on c.id = t.category_id
    where t.household_id = h and t.kind = k and (c.id = cid or c.parent_id = cid)
      and t.txn_date >= s and t.txn_date < e + interval '1 month'
    group by 1, 2
  ) x;
  return r;
end;
$$;

create or replace function public.app_net(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  e date := date_trunc('month', (p ->> 'end')::date)::date;
  s date := coalesce(date_trunc('month', (p ->> 'from')::date)::date, e - interval '11 month');
  r jsonb;
begin
  select jsonb_agg(jsonb_build_object('m', g.m::date, 'income', coalesce(x.income, 0), 'spent', coalesce(x.spent, 0)) order by g.m)
  into r
  from generate_series(s, e, interval '1 month') as g(m)
  left join (
    select date_trunc('month', t.txn_date)::date as m,
      sum(t.amount) filter (where t.kind = 'income') as income,
      sum(-t.amount) filter (where t.kind = 'expense') as spent
    from public.transactions t
    join public.accounts a on a.id = t.account_id and a.include_in_totals
    where t.household_id = h and t.kind in ('income', 'expense')
      and t.txn_date >= s and t.txn_date < e + interval '1 month'
    group by 1
  ) x on x.m = g.m::date;
  return r;
end;
$$;

-- The month of the household's first transaction, for the charts.
create function public.app_first_month(p jsonb default '{}')
returns jsonb
language sql
stable
set search_path = ''
as $$
  select to_jsonb(date_trunc('month', min(t.txn_date))::date)
  from public.transactions t where t.household_id = public.app_household();
$$;
revoke execute on function public.app_first_month(jsonb) from public, anon;
grant execute on function public.app_first_month(jsonb) to authenticated;

-- p.amount (positive) changes the amount; expenses stay money out, income money in, and a
-- transfer's two sides both change.
create or replace function public.app_update_txn(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  t public.transactions;
  cat uuid := nullif(p ->> 'cat', '')::uuid;
  d date := nullif(p ->> 'date', '')::date;
  amt numeric := round(abs(nullif(p ->> 'amount', '')::numeric), 2);
begin
  select * into t from public.transactions where id = (p ->> 'id')::uuid and household_id = h;
  if not found then
    raise exception 'Transaction not found';
  end if;
  if amt = 0 then
    raise exception 'Enter an amount';
  end if;
  if t.kind = 'transfer' then
    update public.transactions set note = nullif(p ->> 'note', '') where id = t.id;
  elsif cat is distinct from t.category_id then
    update public.transactions set note = nullif(p ->> 'note', ''), payee = nullif(p ->> 'payee', ''),
      category_id = cat, category_source = 'manual', needs_review = false
    where id = t.id;
  else
    update public.transactions set note = nullif(p ->> 'note', ''), payee = nullif(p ->> 'payee', ''), needs_review = false
    where id = t.id;
  end if;
  if d is not null and d is distinct from t.txn_date then
    update public.transactions set txn_date = d
    where household_id = h and (id = t.id or (t.transfer_group_id is not null and transfer_group_id = t.transfer_group_id));
  end if;
  if amt is not null and amt <> abs(t.amount) then
    if t.transfer_group_id is not null then
      update public.transactions set amount = sign(amount) * amt
      where household_id = h and transfer_group_id = t.transfer_group_id;
    else
      update public.transactions set amount = case when t.amount < 0 then -amt else amt end where id = t.id;
    end if;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
