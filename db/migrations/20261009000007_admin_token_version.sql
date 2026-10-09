-- migrate:up
-- Admin tokens die with the password: each token carries `pv` (the password's set_at), and the admin
-- PostgREST runs private.admin_pre_request() before every request (PGRST_DB_PRE_REQUEST).

create or replace function private.admin_token() returns text
language plpgsql security definer set search_path = private, public as $$
declare
  secret text := private.setting('admin_jwt_secret');
  pv bigint := (select (extract(epoch from set_at) * 1000)::bigint from private.admin_auth);
  head text := private.b64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'UTF8'));
  body text := private.b64url(convert_to(jsonb_build_object(
                 'role', 'bc_admin', 'pv', pv, 'exp', extract(epoch from now() + interval '7 days')::bigint)::text, 'UTF8'));
begin
  if secret is null then
    raise exception 'admin_jwt_secret not configured';
  end if;
  return head || '.' || body || '.' || private.b64url(hmac(convert_to(head || '.' || body, 'UTF8'), convert_to(secret, 'UTF8'), 'sha256'));
end $$;

create function private.admin_pre_request() returns void
language plpgsql security definer set search_path = private as $$
begin
  if current_user = 'bc_admin' and coalesce(private.jwt_claim('pv'), '') is distinct from
     (select ((extract(epoch from set_at) * 1000)::bigint)::text from private.admin_auth) then
    raise exception 'session expired, log in again' using errcode = '28000';
  end if;
end $$;
grant execute on function private.admin_pre_request() to bc_admin, bc_admin_anon;
grant usage on schema private to bc_admin_anon;
grant execute on function private.jwt_claim(text) to bc_admin, bc_admin_anon;

-- migrate:down
drop function private.admin_pre_request();
