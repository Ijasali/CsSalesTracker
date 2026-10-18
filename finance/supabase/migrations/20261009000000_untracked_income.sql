-- Some accounts are not tracked transaction by transaction (Sherifa's Tangerine, where her pay
-- lands). For such an account, accounts.auto_income_category is set: every transfer out of it
-- also records the same amount, same day, as income in that category on the account, so its
-- balance stays at zero and the money counts as income. The income row points at the transfer
-- leg (mirror_of); it follows edits of that leg and is deleted with it.
alter table public.accounts
  add column auto_income_category uuid references public.categories (id);

alter table public.transactions
  add column mirror_of uuid references public.transactions (id) on delete cascade;

create unique index transactions_mirror_of_key on public.transactions (mirror_of) where mirror_of is not null;

create function public.mirror_untracked_income()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  c uuid;
begin
  if new.kind <> 'transfer' or new.amount >= 0 then
    if tg_op = 'UPDATE' then
      delete from public.transactions where mirror_of = new.id;
    end if;
    return null;
  end if;
  select auto_income_category into c from public.accounts where id = new.account_id;
  if c is null then
    return null;
  end if;
  if tg_op = 'UPDATE' then
    update public.transactions set amount = -new.amount, txn_date = new.txn_date, status = new.status
    where mirror_of = new.id;
    if found then
      return null;
    end if;
  end if;
  insert into public.transactions (household_id, account_id, txn_date, amount, kind, category_id, payee,
    note, status, source, category_source, mirror_of)
  values (new.household_id, new.account_id, new.txn_date, -new.amount, 'income', c, 'Salary',
    'Added automatically: this account is not tracked, so money leaving it is counted as salary', new.status,
    'manual', 'manual', new.id);
  return null;
end;
$$;

create trigger transactions_mirror_untracked_income
  after insert or update of amount, txn_date, status, kind on public.transactions
  for each row execute function public.mirror_untracked_income();

update public.accounts
set auto_income_category = (
  select c.id from public.categories c
  where c.household_id = accounts.household_id and c.kind = 'income' and c.name = 'Salary' and c.parent_id is null
  limit 1)
where name = 'Sherifa - tangerine';
