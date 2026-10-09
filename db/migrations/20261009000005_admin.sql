-- migrate:up
-- Owner console API, served by a SECOND PostgREST bound to the tailnet IP only (schema admin_api,
-- its own JWT secret). The first visit sets the password (bcrypt); login returns a JWT signed here.

create schema admin_api;
grant usage on schema admin_api to bc_admin_anon, bc_admin;
grant usage on schema private to bc_admin;

create table private.admin_auth (
  id boolean primary key default true check (id),     -- single row
  password_hash text not null,
  set_at timestamptz not null default now()
);
create table private.admin_login_attempts (at timestamptz not null default now(), ok boolean not null);
alter table private.admin_auth enable row level security;
alter table private.admin_login_attempts enable row level security;

create function private.b64url(b bytea) returns text
language sql immutable as $$ select translate(rtrim(encode(b, 'base64'), '='), E'+/\n', '-_') $$;

create function private.admin_token() returns text
language plpgsql security definer set search_path = private, public as $$
declare
  secret text := private.setting('admin_jwt_secret');
  head text := private.b64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'UTF8'));
  body text := private.b64url(convert_to(jsonb_build_object(
                 'role', 'bc_admin', 'exp', extract(epoch from now() + interval '7 days')::bigint)::text, 'UTF8'));
begin
  if secret is null then
    raise exception 'admin_jwt_secret not configured';
  end if;
  return head || '.' || body || '.' || private.b64url(hmac(convert_to(head || '.' || body, 'UTF8'), convert_to(secret, 'UTF8'), 'sha256'));
end $$;

create function admin_api.state() returns jsonb
language sql security definer set search_path = private as $$
  select jsonb_build_object('setup_needed', not exists (select 1 from private.admin_auth))
$$;

create function admin_api.setup(password text) returns jsonb
language plpgsql security definer set search_path = private, public as $$
begin
  lock table private.admin_auth in exclusive mode;            -- first come, first served, exactly once
  if exists (select 1 from private.admin_auth) then
    raise exception 'password already set' using errcode = '42501', detail = 'already_set';
  end if;
  if length(password) < 10 then
    raise exception 'password must be at least 10 characters' using errcode = 'P0001', detail = 'weak_password';
  end if;
  insert into private.admin_auth (password_hash) values (crypt(password, gen_salt('bf', 10)));
  return jsonb_build_object('token', private.admin_token());
end $$;

create function admin_api.login(password text) returns jsonb
language plpgsql security definer set search_path = private, public as $$
declare ok boolean;
begin
  if (select count(*) from private.admin_login_attempts where not admin_login_attempts.ok and at > now() - interval '5 minutes') >= 10 then
    raise exception 'too many attempts, wait 5 minutes' using errcode = '42501', detail = 'throttled';
  end if;
  select password_hash = crypt(password, password_hash) into ok from private.admin_auth;
  insert into private.admin_login_attempts (ok) values (coalesce(ok, false));
  delete from private.admin_login_attempts where at < now() - interval '1 day';
  if not coalesce(ok, false) then
    perform pg_sleep(1);
    raise exception 'wrong password' using errcode = '28P01', detail = 'wrong_password';
  end if;
  return jsonb_build_object('token', private.admin_token());
end $$;

-- ---------- what the owner sees ----------
create view admin_api.accounts as
  select a.id, a.created_at, a.last_seen_at, a.is_anonymous, a.blocked, a.plan, a.note,
         l.images_month, l.posts_month, l.images_per_post,
         a.images_month_override, a.posts_month_override,
         coalesce(u.images_used, 0) as images_used_month, coalesce(u.posts_used, 0) as posts_used_month,
         (select count(*) from private.businesses b where b.account_id = a.id and b.deleted_at is null) as businesses,
         (select count(*) from private.posts p where p.account_id = a.id and p.deleted_at is null) as posts_total
  from private.accounts a
  cross join lateral private.limits(a.id) l
  left join private.usage_monthly u on u.account_id = a.id and u.month = private.month_start();

create view admin_api.businesses as
  select b.id, b.account_id, b.name, b.description, b.language, b.timezone, b.created_at, b.deleted_at,
         pr.status as profile_status, pr.data as profile, pr.edited as profile_edited,
         (select count(*) from private.media m where m.business_id = b.id and m.kind = 'photo' and m.status = 'ready' and m.deleted_at is null) as photos,
         (select count(*) from private.posts p where p.business_id = b.id and p.deleted_at is null) as posts
  from private.businesses b left join private.profiles pr on pr.business_id = b.id;

create view admin_api.photos as
  select m.id, m.business_id, m.account_id, m.created_at, m.status,
         private.media_url(m.object_key, 'GET', 'internal', 3600) as url
  from private.media m where m.kind = 'photo' and m.deleted_at is null;

create view admin_api.posts as
  select p.id, p.account_id, p.business_id, p.status, p.language, p.caption, p.hashtags, p.idea_en, p.error,
         p.created_at, p.ready_at, p.deleted_at,
         coalesce((select jsonb_agg(jsonb_build_object('position', i.position, 'status', i.status, 'prompt', i.prompt_en,
                     'error', i.error,
                     'url', case when i.status = 'ready' then private.media_url(m.object_key, 'GET', 'internal', 3600) end)
                   order by i.position)
                   from private.post_images i left join private.media m on m.id = i.media_id where i.post_id = p.id), '[]') as images
  from private.posts p;

create view admin_api.jobs as
  select id, kind, account_id, business_id, post_id, status, attempts, error, created_at, started_at, finished_at
  from private.jobs;

create view admin_api.plans as select * from private.plans;

create view admin_api.signals as select * from private.signals;

create function admin_api.stats() returns jsonb
language sql stable security definer set search_path = private as $$
  select jsonb_build_object(
    'accounts', (select count(*) from private.accounts),
    'accounts_active_7d', (select count(*) from private.accounts where last_seen_at > now() - interval '7 days'),
    'businesses', (select count(*) from private.businesses where deleted_at is null),
    'posts_total', (select count(*) from private.posts),
    'posts_24h', (select count(*) from private.posts where created_at > now() - interval '1 day'),
    'images_24h', (select count(*) from private.post_images i join private.posts p on p.id = i.post_id
                   where i.status = 'ready' and p.created_at > now() - interval '1 day'),
    'jobs', (select coalesce(jsonb_object_agg(status, n), '{}') from (select status, count(*) n from private.jobs group by status) x),
    'jobs_failed_24h', (select count(*) from private.jobs where status = 'failed' and finished_at > now() - interval '1 day'),
    'avg_job_s_24h', (select coalesce(jsonb_object_agg(kind, s), '{}') from (
        select kind, round(avg(extract(epoch from finished_at - started_at))::numeric, 1) s from private.jobs
        where status = 'done' and finished_at > now() - interval '1 day' group by kind) x))
$$;

create function admin_api.set_quota(account_id uuid, images_month int default null, posts_month int default null,
                                    plan text default null) returns setof admin_api.accounts
language plpgsql security definer set search_path = private as $$
begin
  update private.accounts a set
    images_month_override = set_quota.images_month,
    posts_month_override = set_quota.posts_month,
    plan = coalesce(set_quota.plan, a.plan)
  where a.id = set_quota.account_id;
  if not found then raise exception 'account not found' using errcode = 'P0002'; end if;
  return query select * from admin_api.accounts where id = set_quota.account_id;
end $$;

create function admin_api.set_blocked(account_id uuid, blocked boolean, note text default null) returns setof admin_api.accounts
language plpgsql security definer set search_path = private as $$
begin
  update private.accounts a set blocked = set_blocked.blocked, note = coalesce(set_blocked.note, a.note)
  where a.id = set_blocked.account_id;
  return query select * from admin_api.accounts where id = set_blocked.account_id;
end $$;

create function admin_api.update_plan(id text, images_month int, posts_month int, images_per_post int default 3)
returns setof admin_api.plans
language sql security definer set search_path = private as $$
  insert into private.plans (id, images_month, posts_month, images_per_post) values (id, images_month, posts_month, images_per_post)
  on conflict (id) do update set images_month = excluded.images_month, posts_month = excluded.posts_month,
    images_per_post = excluded.images_per_post
  returning *
$$;

-- fine-tuning export: one JSON line per model step with what the user did afterwards
create function admin_api.training_export(since timestamptz default now() - interval '30 days') returns setof jsonb
language sql stable security definer set search_path = private as $$
  select jsonb_build_object('step', t.step, 'prompt_version', t.prompt_version, 'model', t.model,
           'input', t.input, 'output', t.output, 'ok', t.ok, 'created_at', t.created_at,
           'signals', (select coalesce(jsonb_agg(jsonb_build_object('kind', s.kind, 'data', s.data)), '[]')
                       from private.signals s where t.post_id is not null and s.post_id = t.post_id))
  from private.gen_trace t where t.created_at >= since and t.step <> 'image' order by t.id
$$;

revoke execute on all functions in schema admin_api from public;
grant execute on function admin_api.state(), admin_api.setup(text), admin_api.login(text) to bc_admin_anon, bc_admin;
grant execute on all functions in schema admin_api to bc_admin;
grant select on all tables in schema admin_api to bc_admin;
grant execute on function private.media_url(text, text, text, int), private.limits(uuid), private.month_start(timestamptz)
  to bc_admin;

-- migrate:down
drop schema admin_api cascade;
drop function private.admin_token(), private.b64url(bytea);
drop table private.admin_login_attempts, private.admin_auth;
