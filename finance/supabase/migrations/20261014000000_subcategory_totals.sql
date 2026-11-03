-- Spending (or income) by subcategory for p.from to p.to, so Insights can list each category's
-- subcategories. Rows: top (the category), sub (the subcategory, or the category itself when a
-- transaction has no subcategory), amt.
create function public.app_subs(p jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by x.amt desc), '[]') from (
    select coalesce(c.parent_id, c.id) as top, c.id as sub,
      sum(case when t.kind = 'income' then t.amount else -t.amount end) as amt
    from public.transactions t
    join public.accounts a on a.id = t.account_id and a.include_in_totals
    join public.categories c on c.id = t.category_id
    where t.household_id = public.app_household()
      and t.kind = coalesce(p ->> 'kind', 'expense')::public.txn_kind
      and t.txn_date between (p ->> 'from')::date and (p ->> 'to')::date
    group by 1, 2
  ) x;
$$;

revoke execute on function public.app_subs(jsonb) from public, anon;
grant execute on function public.app_subs(jsonb) to authenticated;
