-- app_net also returns, per month, money moved into investment and business accounts minus money
-- taken back out ("invested"), for the % invested column under the Net chart.
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
  select jsonb_agg(jsonb_build_object('m', g.m::date, 'income', coalesce(x.income, 0), 'spent', coalesce(x.spent, 0),
      'invested', coalesce(v.invested, 0)) order by g.m)
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
  ) x on x.m = g.m::date
  left join (
    select date_trunc('month', t.txn_date)::date as m, sum(t.amount) as invested
    from public.transactions t
    join public.accounts a on a.id = t.account_id
    where t.household_id = h and t.kind = 'transfer'
      and a.type in ('tfsa','rrsp','fhsa','resp','gic','non_registered','crypto','business')
      and t.txn_date >= s and t.txn_date < e + interval '1 month'
    group by 1
  ) v on v.m = g.m::date;
  return r;
end;
$$;
