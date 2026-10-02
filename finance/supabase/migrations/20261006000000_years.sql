-- Insights → Years: per calendar year, what was saved (income − spending, accounts counted in totals)
-- and what was invested (money moved into investment and business accounts, minus money taken out).
create function public.app_years(p jsonb default '{}')
returns jsonb
language sql
stable
set search_path = ''
as $$
  with t as (
    select extract(year from t.txn_date)::int as yr, t.kind, t.amount, a.type, a.include_in_totals as incl
    from public.transactions t join public.accounts a on a.id = t.account_id
    where t.household_id = public.app_household()
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'yr', yr, 'income', income, 'spent', spent, 'inv', inv, 'biz', biz) order by yr), '[]')
  from (
    select yr,
      coalesce(sum(amount) filter (where kind = 'income' and incl), 0) as income,
      coalesce(sum(-amount) filter (where kind = 'expense' and incl), 0) as spent,
      coalesce(sum(amount) filter (where kind = 'transfer' and type in ('tfsa','rrsp','fhsa','resp','gic','non_registered','crypto')), 0) as inv,
      coalesce(sum(amount) filter (where kind = 'transfer' and type = 'business'), 0) as biz
    from t group by yr
  ) x;
$$;

-- Money moved into or out of investment and business accounts in one year (p.year).
create function public.app_year_moves(p jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(public.app_tx_json(x.t) || jsonb_build_object('acct_type', x.type) order by x.d desc), '[]')
  from (
    select t, t.txn_date as d, a.type
    from public.transactions t join public.accounts a on a.id = t.account_id
    where t.household_id = public.app_household() and t.kind = 'transfer'
      and a.type in ('tfsa','rrsp','fhsa','resp','gic','non_registered','crypto','business')
      and extract(year from t.txn_date) = (p ->> 'year')::int
  ) x;
$$;

revoke execute on function public.app_years(jsonb) from public, anon;
grant execute on function public.app_years(jsonb) to authenticated;
revoke execute on function public.app_year_moves(jsonb) from public, anon;
grant execute on function public.app_year_moves(jsonb) to authenticated;
