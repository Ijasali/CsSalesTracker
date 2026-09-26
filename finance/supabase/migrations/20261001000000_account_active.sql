-- Lets the app mark an account inactive (kept with its history, never counted, listed under
-- "inactive accounts") or active again.
create function public.app_set_account_active(p jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  n integer;
begin
  update public.accounts set is_active = (p ->> 'active')::boolean
  where id = (p ->> 'id')::uuid and household_id = public.app_household();
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'Account not found';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.app_set_account_active(jsonb) from public, anon;
grant execute on function public.app_set_account_active(jsonb) to authenticated;
