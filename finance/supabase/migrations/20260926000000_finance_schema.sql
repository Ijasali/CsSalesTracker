-- Household finance tracker: schema
--
-- Amounts are signed from the account's point of view: money leaving an account is negative
-- (a purchase on a card, a bill paid from chequing), money arriving is positive (salary, a refund,
-- a card payment received). A credit card or mortgage balance is therefore negative while owed.
--
-- Transfers between the household's own accounts (card payments, moving money into a TFSA) are two
-- rows, one per account, sharing a transfer_group_id. They are never counted as spending or income.

create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------------------------

create type public.account_type as enum (
  'chequing', 'savings', 'cash', 'prepaid', 'credit_card', 'line_of_credit',
  'tfsa', 'rrsp', 'fhsa', 'resp', 'gic', 'non_registered', 'crypto',
  'property', 'mortgage', 'loan',
  -- money lent to someone else
  'receivable',
  'business'
);
create type public.txn_kind as enum ('expense', 'income', 'transfer', 'adjustment');
create type public.txn_status as enum ('pending', 'posted');
-- Where a transaction came from. 'legacy' is the spreadsheet exported from the previous app.
create type public.txn_source as enum ('manual', 'legacy', 'bank_file', 'email_alert', 'screenshot');
create type public.category_kind as enum ('expense', 'income');

-- ---------------------------------------------------------------------------------------------
-- Household and people
-- ---------------------------------------------------------------------------------------------

create table public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  currency text not null default 'CAD',
  created_at timestamptz not null default now()
);

-- A person in the household. user_id links a login; a person without a login can still own accounts.
create table public.household_members (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  user_id uuid references auth.users (id) on delete set null,
  display_name text not null,
  created_at timestamptz not null default now(),
  unique (household_id, display_name),
  unique (household_id, user_id),
  unique (id, household_id)
);

create function public.is_household_member(p_household_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.household_members m
    where m.household_id = p_household_id and m.user_id = (select auth.uid())
  );
$$;

-- ---------------------------------------------------------------------------------------------
-- Accounts, categories
-- ---------------------------------------------------------------------------------------------

create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  -- null = joint (owned by the household as a whole)
  owner_member_id uuid,
  name text not null,
  institution text,
  type public.account_type not null,
  last4 text check (last4 ~ '^[0-9]{4}$'),
  currency text not null default 'CAD',
  -- Balance on opening_date, before any transaction recorded here.
  opening_balance numeric(14, 2) not null default 0,
  opening_date date not null default current_date,
  credit_limit numeric(14, 2) check (credit_limit > 0),
  statement_due_day smallint check (statement_due_day between 1 and 31),
  interest_rate numeric(6, 3),
  renewal_date date,
  original_principal numeric(14, 2),
  is_active boolean not null default true,
  -- false keeps the account (for example a business account) out of household totals
  include_in_totals boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (household_id, name),
  unique (id, household_id),
  foreign key (owner_member_id, household_id)
    references public.household_members (id, household_id) on delete set null (owner_member_id)
);

-- Two levels: a category (Home expenses) and its subcategories (Mortgage, Hydro One).
create table public.categories (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  parent_id uuid,
  name text not null,
  kind public.category_kind not null,
  sort_order integer not null default 0,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  unique nulls not distinct (household_id, parent_id, kind, name),
  unique (id, household_id),
  foreign key (parent_id, household_id)
    references public.categories (id, household_id) on delete cascade
);

-- ---------------------------------------------------------------------------------------------
-- Imports: every file, email or screenshot is a batch; its rows are checked before they
-- become transactions.
-- ---------------------------------------------------------------------------------------------

create table public.import_batches (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  source public.txn_source not null check (source <> 'manual'),
  -- The account the file or screenshot belongs to, when it is a single account.
  account_id uuid,
  file_name text,
  storage_path text,
  status text not null default 'review'
    check (status in ('reading', 'review', 'committed', 'discarded')),
  row_count integer not null default 0,
  imported_count integer not null default 0,
  duplicate_count integer not null default 0,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  unique (id, household_id),
  foreign key (account_id, household_id)
    references public.accounts (id, household_id) on delete set null (account_id)
);

-- ---------------------------------------------------------------------------------------------
-- Transactions
-- ---------------------------------------------------------------------------------------------

create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  account_id uuid not null,
  txn_date date not null,
  amount numeric(14, 2) not null check (amount <> 0),
  kind public.txn_kind not null,
  category_id uuid,
  -- Clean merchant name shown in the app ("Tim Hortons"); description_raw is the bank's text
  -- ("TIM HORTONS #4417 TORONTO ON").
  payee text,
  description_raw text,
  note text,
  transfer_group_id uuid,
  status public.txn_status not null default 'posted',
  source public.txn_source not null default 'manual',
  import_batch_id uuid,
  -- The bank's own id for the transaction (the FITID in an OFX/QFX file), when it gives one.
  external_id text,
  -- See make_fingerprint(); set for every imported row.
  fingerprint text,
  category_source text check (category_source in ('manual', 'rule', 'ai', 'legacy')),
  category_confidence numeric(3, 2) check (category_confidence between 0 and 1),
  needs_review boolean not null default false,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (kind <> 'transfer' or transfer_group_id is not null),
  foreign key (account_id, household_id)
    references public.accounts (id, household_id) on delete cascade,
  foreign key (category_id, household_id)
    references public.categories (id, household_id) on delete set null (category_id),
  foreign key (import_batch_id, household_id)
    references public.import_batches (id, household_id) on delete set null (import_batch_id)
);

create unique index transactions_external_id_key
  on public.transactions (account_id, external_id) where external_id is not null;
create unique index transactions_fingerprint_key
  on public.transactions (account_id, fingerprint) where fingerprint is not null;
create index transactions_household_date_idx on public.transactions (household_id, txn_date desc);
create index transactions_account_date_idx on public.transactions (account_id, txn_date);
create index transactions_category_idx on public.transactions (category_id);
create index transactions_transfer_group_idx on public.transactions (transfer_group_id)
  where transfer_group_id is not null;
create index transactions_review_idx on public.transactions (household_id) where needs_review;

-- Rows read from a batch, waiting to be imported. raw keeps exactly what was read.
create table public.import_rows (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null,
  household_id uuid not null,
  row_number integer not null,
  raw jsonb not null,
  account_id uuid,
  txn_date date,
  amount numeric(14, 2),
  description text,
  external_id text,
  fingerprint text,
  suggested_kind public.txn_kind,
  suggested_category_id uuid,
  suggested_payee text,
  category_source text check (category_source in ('rule', 'ai', 'legacy')),
  confidence numeric(3, 2) check (confidence between 0 and 1),
  match_status text not null default 'new'
    check (match_status in (
      'new', 'exact_duplicate', 'possible_duplicate', 'transfer_match', 'imported', 'skipped'
    )),
  matched_transaction_id uuid references public.transactions (id) on delete set null,
  created_at timestamptz not null default now(),
  unique (batch_id, row_number),
  foreign key (batch_id, household_id)
    references public.import_batches (id, household_id) on delete cascade,
  foreign key (account_id, household_id)
    references public.accounts (id, household_id) on delete set null (account_id),
  foreign key (suggested_category_id, household_id)
    references public.categories (id, household_id) on delete set null (suggested_category_id)
);

-- ---------------------------------------------------------------------------------------------
-- Categorisation rules: "description contains COSTCO → Groceries, show as Costco"
-- ---------------------------------------------------------------------------------------------

create table public.category_rules (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  match_type text not null default 'contains'
    check (match_type in ('exact', 'starts_with', 'contains', 'regex')),
  pattern text not null check (length(trim(pattern)) > 0),
  -- Optional narrowing: only this account, only within an amount range (absolute amount).
  account_id uuid,
  amount_min numeric(14, 2),
  amount_max numeric(14, 2),
  category_id uuid,
  kind public.txn_kind,
  payee_rename text,
  priority integer not null default 100,
  origin text not null default 'manual' check (origin in ('manual', 'learned', 'legacy')),
  times_applied integer not null default 0,
  created_at timestamptz not null default now(),
  check (category_id is not null or kind is not null),
  foreign key (account_id, household_id)
    references public.accounts (id, household_id) on delete cascade,
  foreign key (category_id, household_id)
    references public.categories (id, household_id) on delete cascade
);

-- ---------------------------------------------------------------------------------------------
-- Budgets and balance snapshots
-- ---------------------------------------------------------------------------------------------

create table public.budgets (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  category_id uuid not null,
  month date not null check (extract(day from month) = 1),
  amount numeric(12, 2) not null check (amount >= 0),
  unique (category_id, month),
  foreign key (category_id, household_id)
    references public.categories (id, household_id) on delete cascade
);

-- A known balance on a date. For investments, the home and the mortgage this is their value; for
-- bank accounts and cards it is a statement balance used to check that nothing is missing.
create table public.balance_snapshots (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  account_id uuid not null,
  as_of date not null,
  balance numeric(14, 2) not null,
  note text,
  created_at timestamptz not null default now(),
  unique (account_id, as_of),
  foreign key (account_id, household_id)
    references public.accounts (id, household_id) on delete cascade
);

-- ---------------------------------------------------------------------------------------------
-- Functions used by imports
-- ---------------------------------------------------------------------------------------------

-- Lower-case, drop store numbers and punctuation: "TIM HORTONS #4417 TORONTO" → "tim hortons toronto"
create function public.normalize_description(raw text)
returns text
language sql
immutable
set search_path = ''
as $$
  select trim(regexp_replace(
    regexp_replace(lower(coalesce(raw, '')), '[^a-z&]+', ' ', 'g'),
    '\s+', ' ', 'g'
  ));
$$;

-- Identifies one imported row. occurrence counts identical rows in the same file (1, 2, …) so that
-- two real $2.15 coffees on the same day are kept, while re-importing the same file adds nothing.
create function public.make_fingerprint(
  p_account_id uuid, p_date date, p_amount numeric, p_description text, p_occurrence integer default 1
)
returns text
language sql
immutable
set search_path = ''
as $$
  select md5(concat_ws('|',
    p_account_id::text, p_date::text, round(p_amount, 2)::text,
    public.normalize_description(p_description), coalesce(p_occurrence, 1)::text
  ));
$$;

-- Transactions that may be the same one seen from another source: same account and amount within
-- a few days (an email alert on the purchase date, the statement a day or two later).
create function public.find_possible_duplicates(
  p_account_id uuid, p_date date, p_amount numeric, p_description text, p_days integer default 3
)
returns table (transaction_id uuid, txn_date date, payee text, description_raw text, similarity real)
language sql
stable
set search_path = public, extensions
as $$
  select t.id, t.txn_date, t.payee, t.description_raw,
    similarity(
      public.normalize_description(coalesce(t.description_raw, t.payee)),
      public.normalize_description(p_description)
    )
  from public.transactions t
  where t.account_id = p_account_id
    and t.amount = round(p_amount, 2)
    and t.txn_date between p_date - p_days and p_date + p_days
  order by abs(t.txn_date - p_date), 5 desc;
$$;

-- The best rule for a description, or nothing.
create function public.match_category_rule(
  p_household_id uuid, p_account_id uuid, p_description text, p_amount numeric
)
returns table (rule_id uuid, category_id uuid, kind public.txn_kind, payee_rename text)
language sql
stable
set search_path = ''
as $$
  select r.id, r.category_id, r.kind, r.payee_rename
  from public.category_rules r
  where r.household_id = p_household_id
    and (r.account_id is null or r.account_id = p_account_id)
    and (r.amount_min is null or abs(p_amount) >= r.amount_min)
    and (r.amount_max is null or abs(p_amount) <= r.amount_max)
    and case r.match_type
      when 'exact' then public.normalize_description(p_description) = public.normalize_description(r.pattern)
      when 'starts_with' then starts_with(public.normalize_description(p_description), public.normalize_description(r.pattern))
      when 'contains' then strpos(public.normalize_description(p_description), public.normalize_description(r.pattern)) > 0
      when 'regex' then p_description ~* r.pattern
    end
  order by r.priority, length(r.pattern) desc
  limit 1;
$$;

-- When someone changes a transaction's category by hand, remember it for next time.
create unique index category_rules_learned_key
  on public.category_rules (household_id, (public.normalize_description(pattern)))
  where origin = 'learned';

create function public.learn_category_rule()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.category_source = 'manual'
     and new.category_id is not null
     and new.category_id is distinct from old.category_id
     and public.normalize_description(coalesce(new.description_raw, new.payee)) <> '' then
    insert into public.category_rules (household_id, match_type, pattern, category_id, payee_rename, priority, origin)
    values (new.household_id, 'exact', coalesce(new.description_raw, new.payee), new.category_id, new.payee, 50, 'learned')
    on conflict (household_id, (public.normalize_description(pattern))) where origin = 'learned'
    do update set category_id = excluded.category_id, payee_rename = excluded.payee_rename;
  end if;
  return new;
end;
$$;

create trigger transactions_learn_category
  after update of category_id on public.transactions
  for each row execute function public.learn_category_rule();

create function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger transactions_updated_at
  before update on public.transactions
  for each row execute function public.set_updated_at();

-- Creates a household with the signed-in user as its first member.
create function public.create_household(p_name text, p_display_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Sign in first';
  end if;
  insert into public.households (name) values (p_name) returning id into v_household_id;
  insert into public.household_members (household_id, user_id, display_name)
  values (v_household_id, auth.uid(), p_display_name);
  return v_household_id;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Views the screens read
-- ---------------------------------------------------------------------------------------------

-- Current balance of every account. Investments, property, mortgages and loans use their latest
-- snapshot plus anything recorded after it; other accounts add every transaction to the opening
-- balance. contributed = money put in, for showing an investment's gain.
create view public.account_balances with (security_invoker = true) as
select
  a.id as account_id,
  a.household_id,
  a.owner_member_id,
  a.name,
  a.institution,
  a.type,
  a.include_in_totals,
  case
    when a.type in ('tfsa', 'rrsp', 'fhsa', 'resp', 'gic', 'non_registered', 'crypto', 'property', 'mortgage', 'loan', 'receivable', 'business')
      and s.balance is not null
      then s.balance + coalesce((
        select sum(t.amount) from public.transactions t
        where t.account_id = a.id and t.txn_date > s.as_of
      ), 0)
    else a.opening_balance + coalesce((
      select sum(t.amount) from public.transactions t
      where t.account_id = a.id and t.txn_date >= a.opening_date
    ), 0)
  end as balance,
  a.opening_balance + coalesce((
    select sum(t.amount) from public.transactions t
    where t.account_id = a.id and t.txn_date >= a.opening_date
  ), 0) as contributed,
  s.as_of as valued_on
from public.accounts a
left join lateral (
  select b.balance, b.as_of from public.balance_snapshots b
  where b.account_id = a.id order by b.as_of desc limit 1
) s on true
where a.is_active;

-- Spending per month, category and subcategory (positive numbers; refunds reduce them).
-- category_id is the top-level category; uncategorised spending has null ids.
create view public.monthly_category_spending with (security_invoker = true) as
select
  t.household_id,
  date_trunc('month', t.txn_date)::date as month,
  coalesce(c.parent_id, c.id) as category_id,
  c.id as subcategory_id,
  sum(-t.amount) as spent,
  count(*) as txn_count
from public.transactions t
left join public.categories c on c.id = t.category_id
where t.kind = 'expense'
group by 1, 2, 3, 4;

-- ---------------------------------------------------------------------------------------------
-- Row level security: members see and change only their own household's data
-- ---------------------------------------------------------------------------------------------

alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.accounts enable row level security;
alter table public.categories enable row level security;
alter table public.import_batches enable row level security;
alter table public.transactions enable row level security;
alter table public.import_rows enable row level security;
alter table public.category_rules enable row level security;
alter table public.budgets enable row level security;
alter table public.balance_snapshots enable row level security;

create policy "members read their household" on public.households
  for select to authenticated using (public.is_household_member(id));
create policy "members rename their household" on public.households
  for update to authenticated using (public.is_household_member(id)) with check (public.is_household_member(id));

create policy "members manage members" on public.household_members
  for all to authenticated
  using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

create policy "members manage accounts" on public.accounts
  for all to authenticated
  using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

create policy "members manage categories" on public.categories
  for all to authenticated
  using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

create policy "members manage import batches" on public.import_batches
  for all to authenticated
  using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

create policy "members manage transactions" on public.transactions
  for all to authenticated
  using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

create policy "members manage import rows" on public.import_rows
  for all to authenticated
  using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

create policy "members manage category rules" on public.category_rules
  for all to authenticated
  using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

create policy "members manage budgets" on public.budgets
  for all to authenticated
  using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

create policy "members manage balance snapshots" on public.balance_snapshots
  for all to authenticated
  using (public.is_household_member(household_id))
  with check (public.is_household_member(household_id));

revoke execute on function public.create_household(text, text) from public, anon;
grant execute on function public.create_household(text, text) to authenticated;
revoke execute on function public.is_household_member(uuid) from public, anon;
grant execute on function public.is_household_member(uuid) to authenticated;
