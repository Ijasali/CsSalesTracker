-- Merging duplicate categories (the household's choices, Nov 4 2026). Everything that points at a
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
  -- One Toll and one Parking, under Transportation
  perform pg_temp.merge(pg_temp.cat('Motor Vehicle expenses', 'Toll'), pg_temp.cat('Transportation', 'Toll'));
  perform pg_temp.merge(pg_temp.cat('Transportation', 'Car Parking'), pg_temp.cat('Transportation', 'Parking'));
  perform pg_temp.merge(pg_temp.cat('Motor Vehicle expenses', 'Parking'), pg_temp.cat('Transportation', 'Parking'));
  -- Car repairs: Motor Vehicle expenses › Maintenance
  perform pg_temp.merge(pg_temp.cat('Transportation', 'Car maintenance'), pg_temp.cat('Motor Vehicle expenses', 'Maintenance'));
  -- One car loan, under Motor Vehicle expenses
  perform pg_temp.merge(pg_temp.cat('Home expenses', 'Vehicle Emi'), pg_temp.cat('Motor Vehicle expenses', 'EMI'));
  update public.categories set name = 'Car loan EMI' where id = pg_temp.cat('Motor Vehicle expenses', 'EMI');
  -- Gym and sports under Social Life
  perform pg_temp.merge(pg_temp.cat('Health', 'Badminton'), pg_temp.cat('Social Life', 'Badminton'));
  perform pg_temp.merge(pg_temp.cat('Health', 'Cricket'), pg_temp.cat('Social Life', 'Cricket'));
  perform pg_temp.merge(pg_temp.cat('Health', 'Soccer'), pg_temp.cat('Social Life', 'Soccer'));
  perform pg_temp.merge(pg_temp.cat('Home expenses', 'Gym'), pg_temp.cat('Social Life', 'Gym'));
  update public.categories set parent_id = pg_temp.cat('', 'Social Life') where id = pg_temp.cat('Health', 'Fitness');
  -- One Meals and entertainment
  perform pg_temp.merge(pg_temp.cat('Meals and entertainment', 'Meals and entertainment'), pg_temp.cat('', 'Meals and entertainment'));
  -- Property tax, by name, under Home expenses
  update public.categories set name = 'Property tax' where id = pg_temp.cat('Home expenses', 'Tax');
end $$;
