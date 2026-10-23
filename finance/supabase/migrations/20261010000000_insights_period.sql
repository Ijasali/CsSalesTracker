-- Insights for any period (a week, a year or chosen dates), like app_month but for p.from to
-- p.to inclusive. The comparison is the period of the same length just before it, or p.pfrom
-- to p.pto when given (the previous year for a year).
create function public.app_period(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  f date := (p ->> 'from')::date;
  e date := (p ->> 'to')::date;
  pf date := coalesce((p ->> 'pfrom')::date, f - (e - f + 1));
  pe date := coalesce((p ->> 'pto')::date, f - 1);
  r jsonb;
begin
  if f is null or e is null or e < f then
    raise exception 'Choose a start and end date';
  end if;
  with t as (
    select t.*, coalesce(c.parent_id, c.id) as top_id
    from public.transactions t
    join public.accounts a on a.id = t.account_id and a.include_in_totals
    left join public.categories c on c.id = t.category_id
    where t.household_id = h and t.txn_date between f and e
  ), pm as (
    select t.* from public.transactions t
    join public.accounts a on a.id = t.account_id and a.include_in_totals
    where t.household_id = h and t.txn_date between pf and pe
  )
  select jsonb_build_object(
    'income', coalesce((select sum(amount) from t where kind = 'income'), 0),
    'spent', coalesce((select sum(-amount) from t where kind = 'expense'), 0),
    'prev_spent', coalesce((select sum(-amount) from pm where kind = 'expense'), 0),
    'prev_income', coalesce((select sum(amount) from pm where kind = 'income'), 0),
    'invested', coalesce((select sum(t.amount) from public.transactions t join public.accounts a on a.id = t.account_id
      where t.household_id = h and t.kind = 'transfer' and t.txn_date between f and e
        and a.type in ('tfsa','rrsp','fhsa','resp','gic','non_registered','crypto','business')), 0),
    'exp', (select jsonb_agg(x order by x.amt desc) from (select top_id as cid, sum(-amount) as amt, count(*) as n
      from t where kind = 'expense' group by top_id) x),
    'inc', (select jsonb_agg(x order by x.amt desc) from (select top_id as cid, sum(amount) as amt, count(*) as n
      from t where kind = 'income' group by top_id) x),
    'accts', (select jsonb_agg(x order by x.amt desc) from (select account_id as aid, sum(-amount) as amt
      from t where kind = 'expense' group by account_id) x)
  ) into r;
  return r;
end;
$$;

revoke execute on function public.app_period(jsonb) from public, anon;
grant execute on function public.app_period(jsonb) to authenticated;
