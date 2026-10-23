-- The category page follows the Insights period: app_cat totals by p.unit ('week' from Monday,
-- 'month' or 'year') from p.from to the period starting p.end, and app_cat_tx lists the
-- transactions from p.from to p.to (or, as before, the month p.m).
create or replace function public.app_cat(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  cid uuid := (p ->> 'cid')::uuid;
  u text := case when p ->> 'unit' in ('week', 'year') then p ->> 'unit' else 'month' end;
  e date := date_trunc(u, (p ->> 'end')::date)::date;
  s date := coalesce(date_trunc(u, (p ->> 'from')::date)::date, (e - interval '11 month')::date);
  k public.txn_kind := coalesce(p ->> 'kind', 'expense')::public.txn_kind;
  r jsonb;
begin
  select jsonb_build_object('rows', jsonb_agg(x)) into r from (
    select date_trunc(u, t.txn_date)::date as m, t.category_id as sub,
      sum(case when k = 'income' then t.amount else -t.amount end) as amt, count(*) as n
    from public.transactions t
    join public.accounts a on a.id = t.account_id and a.include_in_totals
    join public.categories c on c.id = t.category_id
    where t.household_id = h and t.kind = k and (c.id = cid or c.parent_id = cid)
      and t.txn_date >= s and t.txn_date < e + ('1 ' || u)::interval
    group by 1, 2
  ) x;
  return r;
end;
$$;

create or replace function public.app_cat_tx(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  cid uuid := (p ->> 'cid')::uuid;
  f date := coalesce((p ->> 'from')::date, date_trunc('month', (p ->> 'm')::date)::date);
  e date := coalesce((p ->> 'to')::date, (date_trunc('month', (p ->> 'm')::date) + interval '1 month - 1 day')::date);
  k public.txn_kind := coalesce(p ->> 'kind', 'expense')::public.txn_kind;
  r jsonb;
begin
  select coalesce(jsonb_agg(public.app_tx_json(x.t) order by x.d desc), '[]') into r from (
    select t, t.txn_date as d from public.transactions t
    join public.categories c on c.id = t.category_id
    join public.accounts a on a.id = t.account_id and a.include_in_totals
    where t.household_id = h and t.kind = k and (c.id = cid or c.parent_id = cid)
      and t.txn_date between f and e
    order by t.txn_date desc limit 500
  ) x;
  return r;
end;
$$;
