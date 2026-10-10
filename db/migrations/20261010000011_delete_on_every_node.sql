-- migrate:up
-- delete_account removed the pictures from the master's storage only. Followers copy pictures with
-- "never delete" (a returning master must not wipe a follower), so a deleted account's pictures stayed on
-- them. Now the DELETE goes to every node's storage: setting `s3_node_endpoints` (comma-separated, written by
-- scripts/configure.sh from NODES); without it, the one internal endpoint as before.

create function private.signed_url(endpoint text, object_key text, method text, expires_s int default 3600) returns text
language plpgsql stable security definer set search_path = private, public as $$
declare
  host text := split_part(regexp_replace(rtrim(endpoint, '/'), '^https?://', ''), '/', 1);
  path text := '/' || private.setting('s3_bucket', 'bc-media') || '/' || private.uri_encode(object_key, true);
begin
  return rtrim(endpoint, '/') || path || '?' || private.sigv4_query(method, host, path, private.setting('s3_region', 'garage'),
         private.setting('s3_access_key'), private.setting('s3_secret_key'), expires_s);
end $$;
revoke all on function private.signed_url(text, text, text, int) from public;

create or replace function api.delete_account() returns void
language plpgsql security definer set search_path = private, net, public as $$
declare
  acc uuid := private.current_account();
  k text;
  e text;
begin
  for k in select object_key from private.media where account_id = acc loop
    foreach e in array string_to_array(coalesce(private.setting('s3_node_endpoints'), private.setting('s3_internal_endpoint')), ',') loop
      perform net.http_delete(url := private.signed_url(e, k, 'DELETE'), timeout_milliseconds := 30000);
    end loop;
  end loop;
  insert into private.deleted_accounts (id) values (acc) on conflict do nothing;
  delete from private.accounts where id = acc;
  delete from auth.users where id = acc;
end $$;

-- migrate:down
drop function private.signed_url(text, text, text, int);
