-- An account's balance counts transactions from its opening_date. When an older transaction is
-- added to an account that starts from zero, move opening_date back so the transaction counts
-- (otherwise it silently drops out of the balance). Accounts with a real opening balance keep
-- their date: that balance already includes everything before it.
create function public.extend_opening_date()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  update public.accounts set opening_date = new.txn_date
  where id = new.account_id and opening_date > new.txn_date and opening_balance = 0;
  return new;
end;
$$;

create trigger transactions_extend_opening_date
  after insert or update of txn_date, account_id on public.transactions
  for each row execute function public.extend_opening_date();
