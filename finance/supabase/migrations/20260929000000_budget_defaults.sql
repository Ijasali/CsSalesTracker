-- Budgets work like the previous app: each category has a default monthly budget that applies from
-- the month it was set until it is changed, and any single month can be given its own amount.
--
--   scope = 'default': applies from `month` on, until a later default row.
--   scope = 'month':   applies to `month` only and wins over the default.
-- The budget for a month is its 'month' row if there is one, else the latest default on or before it.

alter table public.budgets add column scope text not null default 'default'
  check (scope in ('default', 'month'));
alter table public.budgets drop constraint budgets_category_id_month_key;
alter table public.budgets add constraint budgets_category_month_scope_key unique (category_id, month, scope);

-- Each category's budget for month m (0 or missing when there is none).
create function public.app_budgets_for(h uuid, m date)
returns table (cid uuid, amount numeric, is_month boolean)
language sql
stable
set search_path = ''
as $$
  select c.id,
    coalesce(o.amount, d.amount),
    o.amount is not null
  from public.categories c
  left join public.budgets o on o.category_id = c.id and o.scope = 'month' and o.month = m
  left join lateral (
    select b.amount from public.budgets b
    where b.category_id = c.id and b.scope = 'default' and b.month <= m
    order by b.month desc limit 1
  ) d on true
  where c.household_id = h and coalesce(o.amount, d.amount) is not null;
$$;

create or replace function public.app_month(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  m date := date_trunc('month', (p ->> 'm')::date)::date;
  r jsonb;
begin
  with t as (
    select t.*, coalesce(c.parent_id, c.id) as top_id
    from public.transactions t
    join public.accounts a on a.id = t.account_id and a.include_in_totals
    left join public.categories c on c.id = t.category_id
    where t.household_id = h and t.txn_date >= m and t.txn_date < m + interval '1 month'
  ), pm as (
    select t.* from public.transactions t
    join public.accounts a on a.id = t.account_id and a.include_in_totals
    where t.household_id = h and t.txn_date >= m - interval '1 month' and t.txn_date < m
  )
  select jsonb_build_object(
    'income', coalesce((select sum(amount) from t where kind = 'income'), 0),
    'spent', coalesce((select sum(-amount) from t where kind = 'expense'), 0),
    'prev_spent', coalesce((select sum(-amount) from pm where kind = 'expense'), 0),
    'prev_income', coalesce((select sum(amount) from pm where kind = 'income'), 0),
    'invested', coalesce((select sum(t.amount) from t join public.accounts a on a.id = t.account_id
      where t.kind = 'transfer' and t.amount > 0 and a.type in ('tfsa','rrsp','fhsa','resp','gic','non_registered','crypto')), 0),
    'exp', (select jsonb_agg(x order by x.amt desc) from (select top_id as cid, sum(-amount) as amt, count(*) as n
      from t where kind = 'expense' group by top_id) x),
    'inc', (select jsonb_agg(x order by x.amt desc) from (select top_id as cid, sum(amount) as amt, count(*) as n
      from t where kind = 'income' group by top_id) x),
    'accts', (select jsonb_agg(x order by x.amt desc) from (select account_id as aid, sum(-amount) as amt
      from t where kind = 'expense' group by account_id) x),
    'budgets', (select jsonb_agg(jsonb_build_object('cid', b.cid, 'amount', b.amount, 'is_month', b.is_month))
      from public.app_budgets_for(h, m) b where b.amount > 0),
    'avg3', (select jsonb_agg(x) from (select coalesce(c.parent_id, c.id) as cid, round(sum(-t.amount) / 3, 0) as amt
      from public.transactions t
      join public.accounts a on a.id = t.account_id and a.include_in_totals
      left join public.categories c on c.id = t.category_id
      where t.household_id = h and t.kind = 'expense' and t.txn_date >= m - interval '3 month' and t.txn_date < m
      group by 1) x)
  ) into r;
  return r;
end;
$$;

-- One category's year: the default in force now, and each month's budget and spending.
create function public.app_budget_year(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  v_cid uuid := (p ->> 'cid')::uuid;
  y int := (p ->> 'year')::int;
  cur date := date_trunc('month', (p ->> 'today')::date)::date;
  r jsonb;
begin
  select jsonb_build_object(
    'default', (select b.amount from public.budgets b where b.category_id = v_cid and b.household_id = h
      and b.scope = 'default' and b.month <= cur order by b.month desc limit 1),
    'months', (select jsonb_agg(jsonb_build_object(
        'm', g.m::date,
        'amount', (select x.amount from public.app_budgets_for(h, g.m::date) x where x.cid = v_cid),
        'is_month', coalesce((select x.is_month from public.app_budgets_for(h, g.m::date) x where x.cid = v_cid), false),
        'spent', coalesce((select sum(-t.amount) from public.transactions t
          join public.accounts a on a.id = t.account_id and a.include_in_totals
          join public.categories c on c.id = t.category_id
          where t.household_id = h and t.kind = 'expense' and (c.id = v_cid or c.parent_id = v_cid)
            and t.txn_date >= g.m and t.txn_date < g.m + interval '1 month'), 0)
      ) order by g.m)
      from generate_series(make_date(y, 1, 1), make_date(y, 12, 1), interval '1 month') g(m))
  ) into r;
  return r;
end;
$$;

-- p = {cid, month, amount, scope}. scope 'default' sets the default from p.month on (replacing any
-- later default); scope 'month' sets p.month only.
create or replace function public.app_set_budget(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  c uuid := (p ->> 'cid')::uuid;
  m date := date_trunc('month', (p ->> 'month')::date)::date;
  v numeric := round((p ->> 'amount')::numeric, 2);
  sc text := coalesce(p ->> 'scope', 'default');
begin
  if v is null or v < 0 then
    raise exception 'Enter the monthly budget as a number';
  end if;
  if sc not in ('default', 'month') then
    raise exception 'Unknown budget type';
  end if;
  if not exists (select 1 from public.categories where id = c and household_id = h) then
    raise exception 'Unknown category';
  end if;
  if sc = 'default' then
    delete from public.budgets where household_id = h and category_id = c and scope = 'default' and month > m;
  end if;
  insert into public.budgets (household_id, category_id, month, amount, scope)
  values (h, c, m, v, sc)
  on conflict (category_id, month, scope) do update set amount = excluded.amount;
  return jsonb_build_object('ok', true);
end;
$$;

-- Puts one month back to the default.
create function public.app_clear_budget_month(p jsonb)
returns jsonb
language sql
set search_path = ''
as $$
  delete from public.budgets
  where household_id = public.app_household() and category_id = (p ->> 'cid')::uuid
    and scope = 'month' and month = date_trunc('month', (p ->> 'month')::date)::date;
  select jsonb_build_object('ok', true);
$$;

-- Stops a category's budget from p.month on; earlier months keep theirs.
create or replace function public.app_remove_budget(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  c uuid := (p ->> 'cid')::uuid;
  m date := date_trunc('month', (p ->> 'month')::date)::date;
begin
  delete from public.budgets where household_id = h and category_id = c and month >= m;
  insert into public.budgets (household_id, category_id, month, amount, scope)
  select h, c, m, 0, 'default'
  where exists (select 1 from public.budgets where household_id = h and category_id = c and scope = 'default' and month < m);
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.app_budgets_for(uuid, date) from public, anon;
grant execute on function public.app_budgets_for(uuid, date) to authenticated;
revoke execute on function public.app_budget_year(jsonb) from public, anon;
grant execute on function public.app_budget_year(jsonb) to authenticated;
revoke execute on function public.app_clear_budget_month(jsonb) from public, anon;
grant execute on function public.app_clear_budget_month(jsonb) to authenticated;
