-- migrate:up
-- S3 pre-signed URLs computed in SQL (AWS SigV4, query-string auth, UNSIGNED-PAYLOAD). Postgres never
-- touches image bytes: clients PUT/GET with these URLs, and the inference service does the same.
-- Works with Garage (local) and Cloudflare R2 / AWS (cloud). Path-style: <endpoint>/<bucket>/<key>.

-- RFC 3986 percent-encoding; '/' kept when encoding a path.
create function private.uri_encode(s text, keep_slash boolean default false) returns text
language plpgsql immutable strict as $$
declare
  b bytea := convert_to(s, 'UTF8');
  out text := '';
  c int;
begin
  for i in 0 .. length(b) - 1 loop
    c := get_byte(b, i);
    if (c between 48 and 57) or (c between 65 and 90) or (c between 97 and 122)
       or c in (45, 46, 95, 126) or (keep_slash and c = 47) then
      out := out || chr(c);
    else
      out := out || '%' || upper(lpad(to_hex(c), 2, '0'));
    end if;
  end loop;
  return out;
end $$;

create function private.hmac256(msg text, key bytea) returns bytea
language sql immutable strict as $$ select hmac(convert_to(msg, 'UTF8'), key, 'sha256') $$;

-- The SigV4 query string for one request. `host` is exactly what the client will send as Host
-- (with :port when not default); `path` is the canonical path, already percent-encoded.
create function private.sigv4_query(method text, host text, path text, region text, access_key text,
                                    secret text, expires_s int, at timestamptz default now()) returns text
language plpgsql immutable strict as $$
declare
  amz_date text := to_char(at at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"');
  day text := to_char(at at time zone 'UTC', 'YYYYMMDD');
  scope text := day || '/' || region || '/s3/aws4_request';
  q text;
  canonical text;
  to_sign text;
  k bytea;
begin
  q := 'X-Amz-Algorithm=AWS4-HMAC-SHA256'
    || '&X-Amz-Credential=' || private.uri_encode(access_key || '/' || scope)
    || '&X-Amz-Date=' || amz_date
    || '&X-Amz-Expires=' || expires_s
    || '&X-Amz-SignedHeaders=host';
  canonical := method || E'\n' || path || E'\n' || q || E'\n' || 'host:' || host || E'\n' || E'\n'
            || 'host' || E'\n' || 'UNSIGNED-PAYLOAD';
  to_sign := 'AWS4-HMAC-SHA256' || E'\n' || amz_date || E'\n' || scope || E'\n'
          || encode(digest(convert_to(canonical, 'UTF8'), 'sha256'), 'hex');
  k := private.hmac256(day, convert_to('AWS4' || secret, 'UTF8'));
  k := private.hmac256(region, k);
  k := private.hmac256('s3', k);
  k := private.hmac256('aws4_request', k);
  return q || '&X-Amz-Signature=' || encode(private.hmac256(to_sign, k), 'hex');
end $$;

-- A pre-signed URL for an object in the media bucket.
--   audience 'public'   → the client-facing endpoint (through Cloudflare), e.g. https://boostcontent.io
--   audience 'internal' → what the inference machines reach over the tailnet, e.g. http://100.64.0.1:3900
create function private.media_url(object_key text, method text default 'GET', audience text default 'public',
                                  expires_s int default 3600) returns text
language plpgsql stable security definer set search_path = private, public as $$
declare
  endpoint text := private.setting(case audience when 'internal' then 's3_internal_endpoint'
                                                   else 's3_public_endpoint' end);
  bucket text := private.setting('s3_bucket', 'bc-media');
  host text;
  path text;
begin
  if endpoint is null then
    raise exception 'storage not configured (s3_%_endpoint)', audience;
  end if;
  endpoint := rtrim(endpoint, '/');
  host := split_part(regexp_replace(endpoint, '^https?://', ''), '/', 1);
  path := '/' || bucket || '/' || private.uri_encode(object_key, true);
  return endpoint || path || '?' || private.sigv4_query(method, host, path, private.setting('s3_region', 'garage'),
         private.setting('s3_access_key'), private.setting('s3_secret_key'), expires_s);
end $$;
revoke all on function private.media_url(text, text, text, int) from public;
-- callable inside the api views (which run as the user); private.* is never exposed by PostgREST
grant execute on function private.media_url(text, text, text, int) to authenticated;

-- migrate:down
drop function private.media_url(text, text, text, int);
drop function private.sigv4_query(text, text, text, text, text, text, int, timestamptz);
drop function private.hmac256(text, bytea);
drop function private.uri_encode(text, boolean);
