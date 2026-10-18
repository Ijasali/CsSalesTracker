-- Refunds and returns from a store are recorded as money back in the purchase's own expense
-- category (an expense with a positive amount), so they lower that category's spending and
-- its budget instead of counting as income. p.refund = true on an expense does this.
create or replace function public.app_add_txn(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  k public.txn_kind := (p ->> 'kind')::public.txn_kind;
  amt numeric := round(abs((p ->> 'amount')::numeric), 2);
  acct uuid := (p ->> 'acct')::uuid;
  dest uuid := nullif(p ->> 'to', '')::uuid;
  cat uuid := nullif(p ->> 'cat', '')::uuid;
  d date := (p ->> 'date')::date;
  refund boolean := coalesce((p ->> 'refund')::boolean, false);
  g uuid;
begin
  if amt is null or amt = 0 then
    raise exception 'Enter an amount';
  end if;
  perform public.app_check_account(h, acct);
  if k = 'transfer' then
    perform public.app_check_account(h, dest);
    g := gen_random_uuid();
    insert into public.transactions (household_id, account_id, txn_date, amount, kind, payee, note, transfer_group_id, source)
    values (h, acct, d, -amt, 'transfer', nullif(p ->> 'payee', ''), nullif(p ->> 'note', ''), g, 'manual'),
           (h, dest, d, amt, 'transfer', nullif(p ->> 'payee', ''), nullif(p ->> 'note', ''), g, 'manual');
  elsif k in ('expense', 'income') then
    insert into public.transactions (household_id, account_id, txn_date, amount, kind, category_id, payee, note, source, category_source)
    values (h, acct, d, case when k = 'expense' and not refund then -amt else amt end, k, cat,
      nullif(p ->> 'payee', ''), nullif(p ->> 'note', ''), 'manual', case when cat is not null then 'manual' end);
  else
    raise exception 'Unknown type';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
