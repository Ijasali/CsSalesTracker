-- Editing a transaction can change its date (p.date). For a transfer both sides move together.
create or replace function public.app_update_txn(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  t public.transactions;
  cat uuid := nullif(p ->> 'cat', '')::uuid;
  d date := nullif(p ->> 'date', '')::date;
begin
  select * into t from public.transactions where id = (p ->> 'id')::uuid and household_id = h;
  if not found then
    raise exception 'Transaction not found';
  end if;
  if t.kind = 'transfer' then
    update public.transactions set note = nullif(p ->> 'note', '') where id = t.id;
  elsif cat is distinct from t.category_id then
    update public.transactions set note = nullif(p ->> 'note', ''), payee = nullif(p ->> 'payee', ''),
      category_id = cat, category_source = 'manual', needs_review = false
    where id = t.id;
  else
    update public.transactions set note = nullif(p ->> 'note', ''), payee = nullif(p ->> 'payee', ''), needs_review = false
    where id = t.id;
  end if;
  if d is not null and d is distinct from t.txn_date then
    update public.transactions set txn_date = d
    where household_id = h and (id = t.id or (t.transfer_group_id is not null and transfer_group_id = t.transfer_group_id));
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
