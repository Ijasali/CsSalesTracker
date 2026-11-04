-- Beauty reorganised, the last duplicates merged and clearer names (Nov 4 2026), the same way as 20261015. Everything that points at a
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
declare beauty uuid := pg_temp.cat('', 'Beauty'); hc uuid; mc uuid;
begin
  -- Beauty: Haircut, Makeup & cosmetics, Accessories
  insert into public.categories (household_id, parent_id, name, kind)
  select household_id, id, 'Haircut', 'expense' from public.categories where id = beauty returning id into hc;
  mc := pg_temp.cat('Beauty', 'Makeup');
  update public.categories set name = 'Makeup & cosmetics' where id = mc;
  perform pg_temp.merge(pg_temp.cat('Beauty', 'Cosmetics'), mc);
  update public.transactions set category_id = hc
   where category_id in (pg_temp.cat('Beauty', 'Beauty'), mc)
     and (payee ilike '%haircut%' or payee ilike 'atru%' or payee ilike 'salon%');
  perform pg_temp.merge(pg_temp.cat('Beauty', 'Beauty'), mc);
  update public.transactions set category_id = mc where category_id = beauty;
  update public.category_rules set category_id = hc
   where category_id = mc and (pattern ilike '%haircut%' or pattern ilike '%atru%' or pattern ilike '%salon%' or pattern ilike '%barber%');
  -- Games and Fashion
  perform pg_temp.merge(pg_temp.cat('Entertainment', 'Games'), pg_temp.cat('Social Life', 'Other games'));
  perform pg_temp.merge(pg_temp.cat('Apparel', 'Fashion'), pg_temp.cat('Apparel', 'Clothing'));
  -- Clearer names
  update public.categories set name = 'Home maintenance' where id = pg_temp.cat('Household', 'Maintenance');
  update public.categories set name = 'Staff salary' where id = pg_temp.cat('', 'Salary');
  update public.categories set name = 'Car insurance' where id = pg_temp.cat('Motor Vehicle expenses', 'Insurance');
end $$;
