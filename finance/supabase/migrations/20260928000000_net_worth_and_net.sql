-- Which accounts count towards household net worth, and monthly income against spending.
--
-- in_net_worth is separate from include_in_totals: include_in_totals decides whether an account's
-- income and spending count (business accounts don't), in_net_worth only whether its balance is
-- added to net worth. The app can still show everything for a moment without changing this.

alter table public.accounts add column in_net_worth boolean not null default true;

-- Start with investments and business money left out of net worth.
update public.accounts set in_net_worth = false
where type in ('tfsa', 'rrsp', 'fhsa', 'resp', 'gic', 'non_registered', 'crypto', 'business')
   or not include_in_totals;

create or replace function public.app_boot(p jsonb default '{}')
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  h uuid := public.app_household();
begin
  if h is null then
    return null;
  end if;
  return jsonb_build_object(
    'hh', (select jsonb_build_object('id', x.id, 'name', x.name) from public.households x where x.id = h),
    'me', (select m.id from public.household_members m where m.household_id = h and m.user_id = (select auth.uid())),
    'members', (select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.display_name, 'linked', m.user_id is not null)
        order by m.created_at, m.id) from public.household_members m where m.household_id = h),
    'accounts', (select jsonb_agg(jsonb_build_object('id', b.account_id, 'name', b.name, 'institution', b.institution,
        'type', b.type, 'owner', b.owner_member_id, 'incl', b.include_in_totals, 'active', b.is_active,
        'nw', a.in_net_worth, 'bal', round(b.balance, 2), 'contrib', round(b.contributed, 2), 'last_txn', b.last_txn)
        order by b.name)
      from public.account_balances b join public.accounts a on a.id = b.account_id where b.household_id = h),
    'cats', (select jsonb_agg(jsonb_build_object('id', c.id, 'pid', c.parent_id, 'name', c.name, 'kind', c.kind) order by c.name)
      from public.categories c where c.household_id = h and not c.is_archived),
    'review', (select count(*) from public.transactions t where t.household_id = h and t.needs_review)
  );
end;
$$;

-- Counts (on = true) or leaves out the accounts p.ids from net worth.
create function public.app_set_net_worth(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  n integer;
begin
  update public.accounts set in_net_worth = (p ->> 'on')::boolean
  where household_id = public.app_household()
    and id in (select (jsonb_array_elements_text(p -> 'ids'))::uuid);
  get diagnostics n = row_count;
  return jsonb_build_object('updated', n);
end;
$$;

-- Income and spending for each of the 12 months ending p.end (accounts that count in totals).
create function public.app_net(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  e date := date_trunc('month', (p ->> 'end')::date)::date;
  r jsonb;
begin
  select jsonb_agg(jsonb_build_object('m', g.m::date, 'income', coalesce(x.income, 0), 'spent', coalesce(x.spent, 0)) order by g.m)
  into r
  from generate_series(e - interval '11 month', e, interval '1 month') as g(m)
  left join (
    select date_trunc('month', t.txn_date)::date as m,
      sum(t.amount) filter (where t.kind = 'income') as income,
      sum(-t.amount) filter (where t.kind = 'expense') as spent
    from public.transactions t
    join public.accounts a on a.id = t.account_id and a.include_in_totals
    where t.household_id = h and t.kind in ('income', 'expense')
      and t.txn_date >= e - interval '11 month' and t.txn_date < e + interval '1 month'
    group by 1
  ) x on x.m = g.m::date;
  return r;
end;
$$;

revoke execute on function public.app_set_net_worth(jsonb) from public, anon;
grant execute on function public.app_set_net_worth(jsonb) to authenticated;
revoke execute on function public.app_net(jsonb) from public, anon;
grant execute on function public.app_net(jsonb) to authenticated;
