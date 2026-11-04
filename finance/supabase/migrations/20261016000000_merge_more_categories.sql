-- More duplicate categories merged (Nov 4 2026), the same way as 20261015. Everything that points at a
-- duplicate (transactions, import suggestions, rules, budgets, the untracked-income setting,
-- subcategories) moves to the category kept, and the emptied duplicate is archived, which the app
-- hides. A copy of the tables from before is in schema backup_20261104.
create function pg_temp.cat(parent text, child text) returns uuid language sql as $$
  select c.id from public.categories c left join public.categories p on p.id = c.parent_id
  where c.name = child and coalesce(p.name, '') = parent and c.kind = 'expense' and not c.is_archived; $$;

create function pg_temp.merge(src uuid, dst uuid) returns void language plpgsql as $$
begin
  if src is null or dst is null or src = dst then raise exception 'merge: missing category'; end if;
  update public.transactions set category_id = dst where category_id = src;
  update public.import_rows set suggested_category_id = dst where suggested_category_id = src;
  update public.category_rules set category_id = dst where category_id = src;
  update public.budgets set category_id = dst where category_id = src;
  update public.accounts set auto_income_category = dst where auto_income_category = src;
  update public.categories set parent_id = dst where parent_id = src;
  update public.categories set is_archived = true where id = src;
end; $$;

do $$
begin
  -- Fuel: Motor Vehicle expenses › Gas
  perform pg_temp.merge(pg_temp.cat('Transportation', 'Car Fuel'), pg_temp.cat('Motor Vehicle expenses', 'Gas'));
  -- Health › Health into Health
  perform pg_temp.merge(pg_temp.cat('Health', 'Health'), pg_temp.cat('', 'Health'));
  -- One QuickBooks, under Subscriptions
  perform pg_temp.merge(pg_temp.cat('Monthly subscription-business', 'Quick books'), pg_temp.cat('Subscriptions', 'Quickbooks'));
  -- One Mobile bill, under Home expenses
  perform pg_temp.merge(pg_temp.cat('Home expenses', 'mobile bill - Sharee'), pg_temp.cat('Home expenses', 'Mobile bill - Ijas& Sharee'));
  update public.categories set name = 'Mobile bill' where id = pg_temp.cat('Home expenses', 'Mobile bill - Ijas& Sharee');
end $$;
