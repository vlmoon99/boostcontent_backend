-- migrate:up
-- 0007's check used current_user, which inside a SECURITY DEFINER function is the owner, never bc_admin.
create or replace function private.admin_pre_request() returns void
language plpgsql security definer set search_path = private as $$
begin
  if private.jwt_claim('role') = 'bc_admin' and coalesce(private.jwt_claim('pv'), '') is distinct from
     (select ((extract(epoch from set_at) * 1000)::bigint)::text from private.admin_auth) then
    raise exception 'session expired, log in again' using errcode = '28000';
  end if;
end $$;

-- migrate:down
