-- Each card's monthly cycle: the statement closes on accounts.statement_day (the month's last day
-- when the month is shorter) and is due statement_grace days later (21 for RBC and Debut). With it,
-- app_cards works out the latest statement itself: the balance owed at the close date is what's due,
-- less payments since. A statement entered by hand for that cycle (card_statements) wins.
alter table public.accounts
  add column statement_day smallint check (statement_day between 1 and 31),
  add column statement_grace smallint not null default 21 check (statement_grace between 1 and 60);

create function public.card_last_close(d int, today date)
returns date
language sql
immutable
set search_path = ''
as $$
  select case when c <= today then c
    else least(make_date(extract(year from today - interval '1 month')::int, extract(month from today - interval '1 month')::int, 1)
      + (d - 1), (date_trunc('month', today) - interval '1 day')::date) end
  from (select least(date_trunc('month', today)::date + (d - 1), (date_trunc('month', today) + interval '1 month - 1 day')::date) as c) x;
$$;

create or replace function public.app_cards(p jsonb default '{}')
returns jsonb
language sql
stable
set search_path = ''
as $$
  with base as (
    select a.*, coalesce((p ->> 'today')::date, (now() at time zone 'America/Toronto')::date) as today
    from public.accounts a
    where a.household_id = public.app_household() and a.type = 'credit_card' and a.is_active
  ), c as (
    select b.*, case when b.statement_day is not null then public.card_last_close(b.statement_day, b.today) end as close
    from base b
  ), pick as (
    select c.id, c.name, c.opening_balance, c.opening_date, c.close, c.statement_day,
      s.id as sid, s.due_date as sdue, s.statement_date as sstmt, s.amount as samt,
      c.close + c.statement_grace as adue
    from c
    left join lateral (select * from public.card_statements cs where cs.account_id = c.id order by cs.due_date desc limit 1) s on true
  ), x as (
    select pk.id as aid,
      -(pk.opening_balance + coalesce((select sum(t.amount) from public.transactions t
        where t.account_id = pk.id and t.txn_date >= pk.opening_date), 0)) as owed,
      -- a hand-entered statement for this cycle (or a later one) wins over the worked-out one
      (pk.sid is not null and (pk.close is null or pk.sdue >= pk.adue - 5)) as manual,
      pk.*
    from pick pk
  ), y as (
    select x.aid, x.name, x.owed, x.statement_day as day, not x.manual and x.close is not null as est,
      case when x.manual then x.sdue else x.adue end as due,
      case when x.manual then coalesce(x.sstmt, x.sdue - 21) else x.close end as stmt,
      case when x.manual then x.samt
        when x.close is not null then greatest(0, -(x.opening_balance + coalesce((select sum(t.amount) from public.transactions t
          where t.account_id = x.aid and t.txn_date >= x.opening_date and t.txn_date <= x.close), 0))) end as stmt_amt
    from x
  )
  select coalesce(jsonb_agg(z order by z.due nulls last, z.name), '[]') from (
    select y.*, case when y.stmt_amt is null then null else greatest(0, y.stmt_amt - coalesce((select sum(t.amount) from public.transactions t
      where t.account_id = y.aid and t.kind = 'transfer' and t.amount > 0 and t.txn_date > y.stmt), 0)) end as left_due
    from y
  ) z;
$$;

-- p.day (1-31) sets the day the card's statement closes; with p.due and p.amount it also saves a statement.
create or replace function public.app_set_statement(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  acct uuid := (p ->> 'acct')::uuid;
  amt numeric := round(abs(nullif(p ->> 'amount', '')::numeric), 2);
begin
  perform public.app_check_account(h, acct);
  if nullif(p ->> 'day', '') is not null then
    update public.accounts set statement_day = (p ->> 'day')::smallint where id = acct;
  end if;
  if nullif(p ->> 'due', '') is not null and amt is not null then
    insert into public.card_statements (household_id, account_id, statement_date, due_date, amount)
    values (h, acct, nullif(p ->> 'stmt', '')::date, (p ->> 'due')::date, amt)
    on conflict (account_id, due_date) do update set amount = excluded.amount, statement_date = excluded.statement_date;
  elsif nullif(p ->> 'day', '') is null then
    raise exception 'Enter the statement day, or the statement balance and due date';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.card_last_close(int, date) from public, anon;
grant execute on function public.card_last_close(int, date) to authenticated;

update public.accounts set statement_day = 8 where name = 'RBC Credit card - Sharee';
update public.accounts set statement_day = 9 where name = 'RBC Credit Card - Ijas';
update public.accounts set statement_day = 16 where name = 'Debut credit card';
update public.card_statements set statement_date = '2026-10-09'
where account_id = (select id from public.accounts where name = 'RBC Credit Card - Ijas') and due_date = '2026-10-30';
