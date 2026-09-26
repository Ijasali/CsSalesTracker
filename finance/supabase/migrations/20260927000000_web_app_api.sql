-- The web app's API: one function per screen or action, called through PostgREST (supabase.rpc)
-- by a signed-in household member, or with `select public.app_x(...)` from the Claude artifact.
--
-- Every function takes one jsonb argument and returns jsonb. They run as the caller (security
-- invoker), so row level security decides what a signed-in person can see and change. When the
-- caller is not a signed-in user but a privileged database role (the artifact's Supabase
-- connector), app_household() falls back to the only household.
--
-- Logins: a person signs up with email and password. app_claim() links a login to the household
-- member whose email matches; app_pending_logins() and app_link_login() let a member approve a
-- login that has no matching email. These three are security definer because they read
-- auth.users; each checks the caller before doing anything.

alter table public.household_members add column email text;
create unique index household_members_email_key
  on public.household_members (lower(email)) where email is not null;

-- The caller's household.
create function public.app_household()
returns uuid
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select m.household_id from public.household_members m
      where m.user_id = (select auth.uid()) order by m.created_at limit 1),
    case when (select auth.uid()) is null and current_user not in ('anon', 'authenticated')
      then (select h.id from public.households h order by h.created_at limit 1) end
  );
$$;

-- ---------------------------------------------------------------------------------------------
-- Logins
-- ---------------------------------------------------------------------------------------------

-- Links the signed-in login to the member with the same email, if it has no login yet.
create function public.app_claim()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_email text;
  v_member public.household_members;
begin
  if v_uid is null then
    return null;
  end if;
  select * into v_member from public.household_members where user_id = v_uid limit 1;
  if found then
    return jsonb_build_object('member_id', v_member.id, 'name', v_member.display_name);
  end if;
  select u.email into v_email from auth.users u where u.id = v_uid;
  update public.household_members m set user_id = v_uid
    where m.user_id is null and m.email is not null and lower(m.email) = lower(v_email)
    returning * into v_member;
  if v_member.id is null then
    return null;
  end if;
  return jsonb_build_object('member_id', v_member.id, 'name', v_member.display_name);
end;
$$;

-- Logins that belong to no household yet, for a member to approve.
create function public.app_pending_logins()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id', u.id, 'email', u.email, 'created_at', u.created_at)
    order by u.created_at desc), '[]'::jsonb)
  from (
    select u.id, u.email, u.created_at from auth.users u
    where exists (select 1 from public.household_members me where me.user_id = (select auth.uid()))
      and not exists (select 1 from public.household_members m where m.user_id = u.id)
    order by u.created_at desc
    limit 20
  ) u;
$$;

-- Gives a member of the caller's household (one without a login) the login p.user_id.
create function public.app_link_login(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member uuid := (p ->> 'member_id')::uuid;
  v_user uuid := (p ->> 'user_id')::uuid;
  v_email text;
begin
  if not exists (
    select 1 from public.household_members target
    join public.household_members me on me.household_id = target.household_id and me.user_id = auth.uid()
    where target.id = v_member and target.user_id is null
  ) then
    raise exception 'That person already has a login, or is not in your household';
  end if;
  if exists (select 1 from public.household_members where user_id = v_user) then
    raise exception 'That login already belongs to someone';
  end if;
  select email into v_email from auth.users where id = v_user;
  if v_email is null then
    raise exception 'Login not found';
  end if;
  update public.household_members set user_id = v_user, email = coalesce(email, v_email) where id = v_member;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------------------------

create function public.app_boot(p jsonb default '{}')
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
        order by m.created_at) from public.household_members m where m.household_id = h),
    'accounts', (select jsonb_agg(jsonb_build_object('id', b.account_id, 'name', b.name, 'institution', b.institution,
        'type', b.type, 'owner', b.owner_member_id, 'incl', b.include_in_totals, 'active', b.is_active,
        'bal', round(b.balance, 2), 'contrib', round(b.contributed, 2), 'last_txn', b.last_txn) order by b.name)
      from public.account_balances b where b.household_id = h),
    'cats', (select jsonb_agg(jsonb_build_object('id', c.id, 'pid', c.parent_id, 'name', c.name, 'kind', c.kind) order by c.name)
      from public.categories c where c.household_id = h and not c.is_archived),
    'review', (select count(*) from public.transactions t where t.household_id = h and t.needs_review)
  );
end;
$$;

-- One month: income, spending by category and account, budgets, 3-month averages.
create function public.app_month(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  m date := date_trunc('month', (p ->> 'm')::date)::date;
  r jsonb;
begin
  with t as (
    select t.*, coalesce(c.parent_id, c.id) as top_id
    from public.transactions t
    join public.accounts a on a.id = t.account_id and a.include_in_totals
    left join public.categories c on c.id = t.category_id
    where t.household_id = h and t.txn_date >= m and t.txn_date < m + interval '1 month'
  ), pm as (
    select t.* from public.transactions t
    join public.accounts a on a.id = t.account_id and a.include_in_totals
    where t.household_id = h and t.txn_date >= m - interval '1 month' and t.txn_date < m
  )
  select jsonb_build_object(
    'income', coalesce((select sum(amount) from t where kind = 'income'), 0),
    'spent', coalesce((select sum(-amount) from t where kind = 'expense'), 0),
    'prev_spent', coalesce((select sum(-amount) from pm where kind = 'expense'), 0),
    'prev_income', coalesce((select sum(amount) from pm where kind = 'income'), 0),
    'invested', coalesce((select sum(t.amount) from t join public.accounts a on a.id = t.account_id
      where t.kind = 'transfer' and t.amount > 0 and a.type in ('tfsa','rrsp','fhsa','resp','gic','non_registered','crypto')), 0),
    'exp', (select jsonb_agg(x order by x.amt desc) from (select top_id as cid, sum(-amount) as amt, count(*) as n
      from t where kind = 'expense' group by top_id) x),
    'inc', (select jsonb_agg(x order by x.amt desc) from (select top_id as cid, sum(amount) as amt, count(*) as n
      from t where kind = 'income' group by top_id) x),
    'accts', (select jsonb_agg(x order by x.amt desc) from (select account_id as aid, sum(-amount) as amt
      from t where kind = 'expense' group by account_id) x),
    'budgets', (select jsonb_agg(b) from (select * from (
        select distinct on (category_id) category_id as cid, amount, month from public.budgets
        where household_id = h and month <= m order by category_id, month desc) d where d.amount > 0) b),
    'avg3', (select jsonb_agg(x) from (select coalesce(c.parent_id, c.id) as cid, round(sum(-t.amount) / 3, 0) as amt
      from public.transactions t
      join public.accounts a on a.id = t.account_id and a.include_in_totals
      left join public.categories c on c.id = t.category_id
      where t.household_id = h and t.kind = 'expense' and t.txn_date >= m - interval '3 month' and t.txn_date < m
      group by 1) x)
  ) into r;
  return r;
end;
$$;

-- Transaction rows as the screens show them.
create function public.app_tx_json(t public.transactions)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object('id', t.id, 'd', t.txn_date, 'amt', t.amount, 'kind', t.kind, 'cid', t.category_id,
    'payee', t.payee, 'descr', t.description_raw, 'note', t.note, 'aid', t.account_id, 'grp', t.transfer_group_id,
    'source', t.source, 'review', t.needs_review,
    'other_aid', (select t2.account_id from public.transactions t2
      where t2.transfer_group_id = t.transfer_group_id and t2.id <> t.id limit 1));
$$;

create function public.app_recent(p jsonb default '{}')
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(public.app_tx_json(x.t) order by x.d desc, x.c desc), '[]')
  from (select t, t.txn_date as d, t.created_at as c from public.transactions t
    where t.household_id = public.app_household()
    order by t.txn_date desc, t.created_at desc limit 6) x;
$$;

-- Search (all years) or one month, optionally by kind, account, or only rows to review.
create function public.app_txns(p jsonb)
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
  k public.txn_kind := nullif(p ->> 'kind', 'all')::public.txn_kind;
  acct uuid := nullif(p ->> 'acct', '')::uuid;
  review boolean := coalesce((p ->> 'review')::boolean, false);
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
      and (acct is null or t.account_id = acct)
      and (not review or t.needs_review)
    order by t.txn_date desc, t.created_at desc
    limit 400
  ) x;
  return r;
end;
$$;

-- A top-level category's totals per month and subcategory, for the 12 months ending p.end.
create function public.app_cat(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  cid uuid := (p ->> 'cid')::uuid;
  e date := date_trunc('month', (p ->> 'end')::date)::date;
  k public.txn_kind := coalesce(p ->> 'kind', 'expense')::public.txn_kind;
  r jsonb;
begin
  select jsonb_build_object('rows', jsonb_agg(x)) into r from (
    select date_trunc('month', t.txn_date)::date as m, t.category_id as sub,
      sum(case when k = 'income' then t.amount else -t.amount end) as amt, count(*) as n
    from public.transactions t
    join public.accounts a on a.id = t.account_id and a.include_in_totals
    join public.categories c on c.id = t.category_id
    where t.household_id = h and t.kind = k and (c.id = cid or c.parent_id = cid)
      and t.txn_date >= e - interval '11 month' and t.txn_date < e + interval '1 month'
    group by 1, 2
  ) x;
  return r;
end;
$$;

create function public.app_cat_tx(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  cid uuid := (p ->> 'cid')::uuid;
  m date := date_trunc('month', (p ->> 'm')::date)::date;
  k public.txn_kind := coalesce(p ->> 'kind', 'expense')::public.txn_kind;
  r jsonb;
begin
  select coalesce(jsonb_agg(public.app_tx_json(x.t) order by x.d desc), '[]') into r from (
    select t, t.txn_date as d from public.transactions t
    join public.categories c on c.id = t.category_id
    join public.accounts a on a.id = t.account_id and a.include_in_totals
    where t.household_id = h and t.kind = k and (c.id = cid or c.parent_id = cid)
      and t.txn_date >= m and t.txn_date < m + interval '1 month'
    order by t.txn_date desc limit 200
  ) x;
  return r;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Writes
-- ---------------------------------------------------------------------------------------------

create function public.app_check_account(h uuid, a uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if h is null or not exists (select 1 from public.accounts where id = a and household_id = h) then
    raise exception 'Unknown account';
  end if;
end;
$$;

-- A transaction typed in by hand. p.amount is positive; kind decides the sign.
create function public.app_add_txn(p jsonb)
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
    values (h, acct, d, case when k = 'expense' then -amt else amt end, k, cat,
      nullif(p ->> 'payee', ''), nullif(p ->> 'note', ''), 'manual', case when cat is not null then 'manual' end);
  else
    raise exception 'Unknown type';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Note, payee and category. A changed category is marked manual so the app learns a rule.
create function public.app_update_txn(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  t public.transactions;
  cat uuid := nullif(p ->> 'cat', '')::uuid;
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
  return jsonb_build_object('ok', true);
end;
$$;

-- Deletes a transaction, or both sides of a transfer.
create function public.app_delete_txn(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  t public.transactions;
  n integer;
begin
  select * into t from public.transactions where id = (p ->> 'id')::uuid and household_id = h;
  if not found then
    raise exception 'Transaction not found';
  end if;
  if t.transfer_group_id is not null then
    delete from public.transactions where transfer_group_id = t.transfer_group_id and household_id = h;
  else
    delete from public.transactions where id = t.id;
  end if;
  get diagnostics n = row_count;
  return jsonb_build_object('deleted', n);
end;
$$;

-- A monthly limit from p.month on (it carries forward until changed).
create function public.app_set_budget(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  v numeric := round((p ->> 'amount')::numeric, 2);
begin
  if v is null or v < 0 then
    raise exception 'Enter the monthly limit as a number';
  end if;
  if not exists (select 1 from public.categories where id = (p ->> 'cid')::uuid and household_id = h) then
    raise exception 'Unknown category';
  end if;
  insert into public.budgets (household_id, category_id, month, amount)
  values (h, (p ->> 'cid')::uuid, date_trunc('month', (p ->> 'month')::date)::date, v)
  on conflict (category_id, month) do update set amount = excluded.amount;
  return jsonb_build_object('ok', true);
end;
$$;

-- Stops a budget from p.month on; earlier months keep theirs.
create function public.app_remove_budget(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  c uuid := (p ->> 'cid')::uuid;
  m date := date_trunc('month', (p ->> 'month')::date)::date;
begin
  delete from public.budgets where household_id = h and category_id = c and month >= m;
  insert into public.budgets (household_id, category_id, month, amount)
  select h, c, m, 0
  where exists (select 1 from public.budgets where household_id = h and category_id = c and month < m);
  return jsonb_build_object('ok', true);
end;
$$;

-- For rows read from screenshots: already saved (same fingerprint), possible duplicates, and the
-- matching category rule. p = {acct, rows: [{i, d, descr, amt, occ}]}.
create function public.app_import_check(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = public, extensions
as $$
declare
  h uuid := public.app_household();
  acct uuid := (p ->> 'acct')::uuid;
  res jsonb;
begin
  perform public.app_check_account(h, acct);
  select coalesce(jsonb_agg(x), '[]') into res from (
    select r.i,
      exists (select 1 from public.transactions t where t.account_id = acct
        and t.fingerprint = public.make_fingerprint(acct, r.d, r.amt, r.descr, r.occ)) as exact,
      (select jsonb_agg(jsonb_build_object('d', f.txn_date, 'payee', coalesce(f.payee, f.description_raw,
          (select c.name from public.transactions t2 join public.categories c on c.id = t2.category_id where t2.id = f.transaction_id))))
        from (select * from public.find_possible_duplicates(acct, r.d, r.amt, r.descr) limit 2) f) as dups,
      (select to_jsonb(mr) from public.match_category_rule(h, acct, r.descr, r.amt) mr) as rule
    from jsonb_to_recordset(p -> 'rows') as r(i int, d date, descr text, amt numeric, occ int)
  ) x;
  return res;
end;
$$;

-- Saves the rows chosen after review. p = {acct, label, row_count, dup_count, rows: [{d, descr,
-- payee, amt, occ, kind, cat, csrc, conf, pending, to, grp}]}. A row whose fingerprint is already
-- saved is skipped; a transfer also gets its other side in account "to".
create function public.app_import_save(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  acct uuid := (p ->> 'acct')::uuid;
  b uuid;
  n_saved integer;
  n_legs integer;
begin
  perform public.app_check_account(h, acct);
  if exists (select 1 from jsonb_array_elements(p -> 'rows') e
    where e ->> 'kind' = 'transfer' and not exists (
      select 1 from public.accounts a where a.id = (e ->> 'to')::uuid and a.household_id = h)) then
    raise exception 'Choose the other account for each transfer';
  end if;
  insert into public.import_batches (household_id, source, account_id, file_name, status, row_count, duplicate_count)
  values (h, 'screenshot', acct, p ->> 'label', 'committed', (p ->> 'row_count')::int, (p ->> 'dup_count')::int)
  returning id into b;

  with r as (
    select * from jsonb_to_recordset(p -> 'rows') as x(d date, descr text, payee text, amt numeric, occ int,
      kind public.txn_kind, cat uuid, csrc text, conf numeric, pending boolean, "to" uuid, grp uuid)
  ), ins as (
    insert into public.transactions (household_id, account_id, txn_date, amount, kind, category_id, payee,
      description_raw, transfer_group_id, status, source, import_batch_id, fingerprint, category_source,
      category_confidence, needs_review)
    select h, acct, r.d, round(r.amt, 2), r.kind, case when r.kind = 'transfer' then null else r.cat end,
      nullif(r.payee, ''), r.descr, case when r.kind = 'transfer' then coalesce(r.grp, gen_random_uuid()) end,
      case when r.pending then 'pending' else 'posted' end::public.txn_status, 'screenshot', b,
      public.make_fingerprint(acct, r.d, r.amt, r.descr, r.occ),
      case when r.kind <> 'transfer' and r.cat is not null then r.csrc end,
      case when r.kind <> 'transfer' and r.cat is not null then least(1, greatest(0, r.conf)) end,
      (r.kind <> 'transfer' and r.cat is null)
    from r
    on conflict (account_id, fingerprint) where fingerprint is not null do nothing
    returning id, kind, transfer_group_id, txn_date, amount, payee, description_raw
  ), leg as (
    insert into public.transactions (household_id, account_id, txn_date, amount, kind, payee, description_raw,
      transfer_group_id, source, import_batch_id)
    select h, r."to", i.txn_date, -i.amount, 'transfer', i.payee, i.description_raw, i.transfer_group_id, 'screenshot', b
    from ins i
    join r on i.kind = 'transfer' and r.grp = i.transfer_group_id
    returning id
  )
  select (select count(*) from ins), (select count(*) from leg) into n_saved, n_legs;

  update public.import_batches set imported_count = n_saved where id = b;
  return jsonb_build_object('saved', n_saved, 'legs', n_legs, 'batch', b);
end;
$$;

-- Only signed-in people (and the database's own roles) may call these.
do $$
declare
  f text;
begin
  foreach f in array array[
    'app_household()', 'app_claim()', 'app_pending_logins()', 'app_link_login(jsonb)', 'app_boot(jsonb)',
    'app_month(jsonb)', 'app_tx_json(public.transactions)', 'app_recent(jsonb)', 'app_txns(jsonb)',
    'app_cat(jsonb)', 'app_cat_tx(jsonb)', 'app_check_account(uuid, uuid)', 'app_add_txn(jsonb)',
    'app_update_txn(jsonb)', 'app_delete_txn(jsonb)', 'app_set_budget(jsonb)', 'app_remove_budget(jsonb)',
    'app_import_check(jsonb)', 'app_import_save(jsonb)'
  ] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end;
$$;

-- The web app lets anyone create a login, so a login must not be able to start its own household.
revoke execute on function public.create_household(text, text) from authenticated;
