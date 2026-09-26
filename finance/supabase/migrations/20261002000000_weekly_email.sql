-- The weekly budget email, built in the database so the weekly job only has to send it.
--
-- app_weekly_email(p {today}) returns {subject, html, text} for the 7 days ending yesterday
-- (Friday's email covers Friday to Thursday) and the month those days end in. It never mentions
-- income. Layout: tables with inline styles, 600px wide, light background (email clients ignore
-- most CSS). Blue bars = within budget, orange = over, as in the app.

create function public.fmt_money(n numeric, cents boolean default true)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when n < 0 then '−' else '' end || '$' ||
    case when cents then to_char(abs(n), 'FM999,999,990.00') else to_char(round(abs(n)), 'FM999,999,990') end;
$$;

create function public.email_bar(pct numeric, over boolean)
returns text
language sql
immutable
set search_path = ''
as $$
  select '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#ECE9E2;border-radius:5px"><tr>'
    || case when least(100, greatest(0, round(pct))) > 0
         then '<td width="' || least(100, greatest(0, round(pct))) || '%" style="background:' || case when over then '#C2571A' else '#2A6CC4' end
           || ';height:10px;font-size:0;line-height:0;border-radius:5px">&nbsp;</td>' else '' end
    || case when round(pct) < 100 then '<td style="height:10px;font-size:0;line-height:0">&nbsp;</td>' else '' end
    || '</tr></table>';
$$;

create function public.app_weekly_email(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  h uuid := public.app_household();
  today date := (p ->> 'today')::date;
  wk_end date := today - 1;
  wk_start date := today - 7;
  m date := date_trunc('month', today - 1)::date;
  month_days int := extract(day from (m + interval '1 month' - interval '1 day'))::int;
  days_left int := greatest(0, (m + interval '1 month')::date - today);
  month_name text := trim(to_char(m, 'Month'));
  font text := '-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,Helvetica,Arial,sans-serif';
  total_b numeric; total_s numeric; lft numeric; pct numeric; elapsed numeric;
  week numeric; prev numeric; month_spent numeric;
  headline text; pace text; week_line text; date_range text; subject text;
  html text; body text := ''; rows text; r record; n int;
begin
  if h is null then
    raise exception 'No household';
  end if;

  -- budgets for the month and what was spent in each (top-level categories)
  create temp table if not exists wk_cats (name text, budget numeric, spent numeric) on commit drop;
  truncate wk_cats;
  insert into wk_cats
  select c.name, b.amount, coalesce((
      select sum(-t.amount) from public.transactions t
      join public.accounts a on a.id = t.account_id and a.include_in_totals
      join public.categories tc on tc.id = t.category_id
      where t.household_id = h and t.kind = 'expense' and coalesce(tc.parent_id, tc.id) = c.id
        and t.txn_date >= m and t.txn_date < m + interval '1 month'), 0)
  from public.app_budgets_for(h, m) b join public.categories c on c.id = b.cid
  where b.amount > 0;

  select coalesce(sum(budget), 0), coalesce(sum(spent), 0) into total_b, total_s from wk_cats;
  lft := total_b - total_s;
  pct := case when total_b > 0 then total_s / total_b * 100 else 0 end;
  elapsed := (month_days - days_left)::numeric / month_days * 100;

  select coalesce(sum(-t.amount) filter (where t.txn_date between wk_start and wk_end), 0),
         coalesce(sum(-t.amount) filter (where t.txn_date between wk_start - 7 and wk_end - 7), 0),
         coalesce(sum(-t.amount) filter (where t.txn_date >= m and t.txn_date < m + interval '1 month'), 0)
  into week, prev, month_spent
  from public.transactions t join public.accounts a on a.id = t.account_id and a.include_in_totals
  where t.household_id = h and t.kind = 'expense' and t.txn_date >= least(wk_start - 7, m);

  if lft >= 0 then
    headline := public.fmt_money(lft) || ' left in the budget';
    pace := case when days_left = 0 then month_name || ' is over'
      else (case when pct <= elapsed + 3 then 'On pace' else 'Spending faster than the month' end)
        || ' · ' || days_left || ' day' || case when days_left = 1 then '' else 's' end || ' to go' end;
  else
    headline := public.fmt_money(-lft) || ' over budget';
    pace := case when days_left = 0 then month_name || ' is over'
      else days_left || ' day' || case when days_left = 1 then '' else 's' end || ' left in ' || month_name end;
  end if;
  week_line := case when week <= prev then public.fmt_money(prev - week, false) || ' less than the week before ('
                 else public.fmt_money(week - prev, false) || ' more than the week before (' end
               || public.fmt_money(prev, false) || ')';
  date_range := to_char(wk_start, 'Mon FMDD') || ' – ' || to_char(wk_end, 'Mon FMDD, YYYY');
  subject := 'Zasvia Finance · ' || month_name || ': ' || headline;

  -- a category row
  -- over budget, worst first
  rows := '';
  n := 0;
  for r in select * from wk_cats where spent > budget order by spent - budget desc loop
    n := n + 1;
    rows := rows || '<tr><td style="padding:12px 0 4px;font:600 15px ' || font || ';color:#15171A">' || replace(replace(r.name, '&', '&amp;'), '<', '&lt;') || '</td>'
      || '<td align="right" style="padding:12px 0 4px;font:13px ' || font || ';color:#5B5F64;white-space:nowrap">' || public.fmt_money(r.spent, false) || ' of ' || public.fmt_money(r.budget, false)
      || ' · <b style="color:#A8430F">' || round(r.spent / r.budget * 100) || '%</b></td></tr>'
      || '<tr><td colspan="2">' || public.email_bar(r.spent / r.budget * 100, true) || '</td></tr>'
      || '<tr><td colspan="2" style="padding:4px 0 8px;font:700 13px ' || font || ';color:#A8430F">' || public.fmt_money(r.spent - r.budget) || ' over</td></tr>';
  end loop;
  if n > 0 then
    body := body || '<tr><td style="padding:0 24px 16px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#FFFFFF;border-radius:14px">'
      || '<tr><td style="padding:20px 20px 8px;font:700 17px ' || font || ';color:#15171A">Over budget (' || n || ')</td></tr>'
      || '<tr><td style="padding:0 20px 14px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0">' || rows || '</table></td></tr></table></td></tr>';
  end if;

  rows := '';
  n := 0;
  for r in select * from wk_cats where spent <= budget order by budget desc loop
    n := n + 1;
    rows := rows || '<tr><td style="padding:12px 0 4px;font:600 15px ' || font || ';color:#15171A">' || replace(replace(r.name, '&', '&amp;'), '<', '&lt;') || '</td>'
      || '<td align="right" style="padding:12px 0 4px;font:13px ' || font || ';color:#5B5F64;white-space:nowrap">' || public.fmt_money(r.spent, false) || ' of ' || public.fmt_money(r.budget, false)
      || ' · <b style="color:#15171A">' || round(r.spent / r.budget * 100) || '%</b></td></tr>'
      || '<tr><td colspan="2">' || public.email_bar(r.spent / r.budget * 100, false) || '</td></tr>'
      || '<tr><td colspan="2" style="padding:4px 0 8px;font:13px ' || font || '"><b style="color:#15171A">' || public.fmt_money(r.budget - r.spent) || ' left</b>'
      || case when days_left > 0 and r.budget > r.spent then '<span style="color:#5B5F64"> · ' || public.fmt_money((r.budget - r.spent) / days_left, false) || '/day</span>' else '' end
      || '</td></tr>';
  end loop;
  if n > 0 then
    body := body || '<tr><td style="padding:0 24px 16px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#FFFFFF;border-radius:14px">'
      || '<tr><td style="padding:20px 20px 8px;font:700 17px ' || font || ';color:#15171A">Within budget (' || n || ')</td></tr>'
      || '<tr><td style="padding:0 20px 14px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0">' || rows || '</table></td></tr></table></td></tr>';
  end if;

  -- biggest spends this week
  rows := '';
  for r in
    select t.txn_date d, coalesce(nullif(t.payee, ''), nullif(t.note, ''), c.name, 'Expense') payee, -t.amount amt, a.name acct
    from public.transactions t join public.accounts a on a.id = t.account_id and a.include_in_totals
    left join public.categories c on c.id = t.category_id
    where t.household_id = h and t.kind = 'expense' and t.txn_date between wk_start and wk_end
    order by t.amount limit 5
  loop
    rows := rows || '<tr><td style="padding:9px 0;border-top:1px solid #E3E0D8;font:14px ' || font || ';color:#15171A">' || replace(replace(r.payee, '&', '&amp;'), '<', '&lt;')
      || '<div style="font:12px ' || font || ';color:#5B5F64">' || to_char(r.d, 'Dy Mon FMDD') || ' · ' || replace(replace(r.acct, '&', '&amp;'), '<', '&lt;') || '</div></td>'
      || '<td align="right" style="padding:9px 0;border-top:1px solid #E3E0D8;font:700 14px ' || font || ';color:#15171A;white-space:nowrap">' || public.fmt_money(r.amt) || '</td></tr>';
  end loop;
  if rows <> '' then
    body := body || '<tr><td style="padding:0 24px 16px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#FFFFFF;border-radius:14px">'
      || '<tr><td style="padding:20px 20px 8px;font:700 17px ' || font || ';color:#15171A">Biggest spends this week</td></tr>'
      || '<tr><td style="padding:0 20px 14px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0">' || rows || '</table></td></tr></table></td></tr>';
  end if;

  -- spending with no budget this month
  select string_agg(replace(replace(x.name, '&', '&amp;'), '<', '&lt;') || ' ' || public.fmt_money(x.amt, false), ' · ' order by x.amt desc) into rows
  from (
    select coalesce(pc.name, c.name) name, sum(-t.amount) amt
    from public.transactions t join public.accounts a on a.id = t.account_id and a.include_in_totals
    join public.categories c on c.id = t.category_id left join public.categories pc on pc.id = c.parent_id
    where t.household_id = h and t.kind = 'expense' and t.txn_date >= m and t.txn_date < m + interval '1 month'
      and coalesce(c.parent_id, c.id) not in (select b.cid from public.app_budgets_for(h, m) b where b.amount > 0)
    group by 1
  ) x;
  if rows is not null then
    body := body || '<tr><td style="padding:0 24px 16px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#FFFFFF;border-radius:14px">'
      || '<tr><td style="padding:20px 20px 8px;font:700 17px ' || font || ';color:#15171A">Spending with no budget</td></tr>'
      || '<tr><td style="padding:0 20px 18px;font:14px ' || font || ';color:#15171A">' || rows || '</td></tr></table></td></tr>';
  end if;

  html := '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light only"><title>Zasvia Finance weekly budget</title></head>'
    || '<body style="margin:0;padding:0;background:#F4F2ED"><div style="display:none;max-height:0;overflow:hidden">' || headline || ' · This week: ' || week_line || '</div>'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F4F2ED"><tr><td align="center" style="padding:24px 8px">'
    || '<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:100%;max-width:600px">'
    || '<tr><td style="padding:0 24px 16px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#0E1B2E;border-radius:14px"><tr><td style="padding:20px">'
    || '<div style="font:700 20px Georgia,''Times New Roman'',serif;color:#FFFFFF">Zasvia <span style="color:#C9A24B">Finance</span></div>'
    || '<div style="font:13px ' || font || ';color:#C9CCD1;padding-top:4px">Weekly budget check · ' || date_range || '</div></td></tr></table></td></tr>'
    || '<tr><td style="padding:0 24px 16px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#FFFFFF;border-radius:14px">'
    || '<tr><td style="padding:22px 20px 6px;font:600 13px ' || font || ';color:#5B5F64;text-transform:uppercase;letter-spacing:.6px">' || month_name || ' budget so far</td></tr>'
    || '<tr><td style="padding:0 20px;font:700 30px ' || font || ';color:' || case when lft < 0 then '#A8430F' else '#15171A' end || '">' || headline || '</td></tr>'
    || '<tr><td style="padding:4px 20px 14px;font:14px ' || font || ';color:#5B5F64">' || pace || '</td></tr>'
    || '<tr><td style="padding:0 20px">' || public.email_bar(pct, pct > 100) || '</td></tr>'
    || '<tr><td style="padding:6px 20px 0;font:13px ' || font || ';color:#5B5F64">Spent <b style="color:#15171A">' || public.fmt_money(total_s) || '</b> of ' || public.fmt_money(total_b)
    || ' (' || round(pct) || '%) · ' || round(elapsed) || '% of the month gone</td></tr>'
    || '<tr><td style="padding:16px 20px 20px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>'
    || '<td width="33%" style="padding:10px 12px;background:#F4F2ED;border-radius:10px"><div style="font:12px ' || font || ';color:#5B5F64">This week</div><div style="font:700 16px ' || font || ';color:#15171A">' || public.fmt_money(week, false) || '</div></td><td width="8"></td>'
    || '<td width="33%" style="padding:10px 12px;background:#F4F2ED;border-radius:10px"><div style="font:12px ' || font || ';color:#5B5F64">Week before</div><div style="font:700 16px ' || font || ';color:#15171A">' || public.fmt_money(prev, false) || '</div></td><td width="8"></td>'
    || '<td width="33%" style="padding:10px 12px;background:#F4F2ED;border-radius:10px"><div style="font:12px ' || font || ';color:#5B5F64">All spending in ' || to_char(m, 'Mon') || '</div><div style="font:700 16px ' || font || ';color:#15171A">' || public.fmt_money(month_spent, false) || '</div></td>'
    || '</tr></table><div style="font:13px ' || font || ';color:#5B5F64;padding-top:10px">This week: ' || week_line || '.</div></td></tr></table></td></tr>'
    || body
    || '<tr><td align="center" style="padding:8px 24px"><a href="https://ijasali.github.io/CsSalesTracker/finance/app/" style="display:inline-block;background:#0E1B2E;color:#FFFFFF;text-decoration:none;font:700 15px ' || font || ';padding:13px 28px;border-radius:12px">Open Zasvia Finance</a></td></tr>'
    || '<tr><td align="center" style="padding:12px 24px 24px;font:12px ' || font || ';color:#5B5F64">Sent every Friday to Ijas and Sherifa. Change a budget in the app under Budgets → Budget setting.</td></tr>'
    || '</table></td></tr></table></body></html>';

  return jsonb_build_object(
    'subject', subject,
    'html', html,
    'text', 'Zasvia Finance, weekly budget check (' || date_range || ')' || E'\n\n'
      || month_name || ': ' || headline || '. ' || pace || '.' || E'\n'
      || 'Spent ' || public.fmt_money(total_s) || ' of ' || public.fmt_money(total_b) || ' budgeted (' || round(pct) || '%).' || E'\n'
      || 'This week: ' || public.fmt_money(week, false) || ', ' || week_line || '.' || E'\n\n'
      || 'Open the app: https://ijasali.github.io/CsSalesTracker/finance/app/'
  );
end;
$$;

revoke execute on function public.app_weekly_email(jsonb) from public, anon, authenticated;
