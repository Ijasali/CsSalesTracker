-- app_txns can list exactly the transactions behind Home's Income, Spent and Saved figures:
-- p.counted = only accounts whose income and spending count (include_in_totals), and
-- p.kind = 'inout' = income and expenses together (for Saved).
create or replace function public.app_txns(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  q text := nullif(trim(coalesce(p ->> 'q', '')), '');
  pat text := '%' || regexp_replace(coalesce(q, ''), '([\\%_])', '\\\1', 'g') || '%';
  m date := date_trunc('month', coalesce((p ->> 'month')::date, current_date))::date;
  kind_p text := coalesce(nullif(p ->> 'kind', ''), 'all');
  k public.txn_kind := case when kind_p in ('all', 'inout') then null else kind_p::public.txn_kind end;
  acct uuid := nullif(p ->> 'acct', '')::uuid;
  review boolean := coalesce((p ->> 'review')::boolean, false);
  counted boolean := coalesce((p ->> 'counted')::boolean, false);
  r jsonb;
begin
  select coalesce(jsonb_agg(public.app_tx_json(x.t) order by x.d desc, x.c desc), '[]') into r
  from (
    select t, t.txn_date as d, t.created_at as c from public.transactions t
    where t.household_id = h
      and case
        when q is not null then (t.payee ilike pat or t.note ilike pat or t.description_raw ilike pat
          or exists (select 1 from public.categories c where c.id = t.category_id and c.name ilike pat))
        when review then true
        else t.txn_date >= m and t.txn_date < m + interval '1 month'
      end
      and (k is null or t.kind = k)
      and (kind_p <> 'inout' or t.kind in ('income', 'expense'))
      and (acct is null or t.account_id = acct)
      and (not review or t.needs_review)
      and (not counted or exists (select 1 from public.accounts a where a.id = t.account_id and a.include_in_totals))
    order by t.txn_date desc, t.created_at desc
    limit 1000
  ) x;
  return r;
end;
$$;
