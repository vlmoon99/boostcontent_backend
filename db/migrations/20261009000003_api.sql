-- migrate:up
-- The client API (PostgREST exposes schema `api` only). Reads = views running as the caller (RLS applies);
-- writes = SECURITY DEFINER functions that check ownership themselves. Errors carry a stable code in
-- DETAIL (quota_exceeded, not_found, …) so the app can branch on it.

-- ---------- account + quota ----------
create function private.current_account() returns uuid
language plpgsql security definer set search_path = private, public as $$
declare
  me uuid := private.uid();
  blocked_ boolean;
begin
  if me is null then
    raise exception 'sign in first' using errcode = '28000', detail = 'not_authenticated';
  end if;
  insert into private.accounts (id, is_anonymous)
  values (me, coalesce(private.jwt_claim('is_anonymous')::boolean, true))
  on conflict (id) do update set last_seen_at = now()
  returning blocked into blocked_;
  if blocked_ then
    raise exception 'account blocked' using errcode = '42501', detail = 'blocked';
  end if;
  return me;
end $$;

create function private.month_start(at timestamptz default now()) returns date
language sql immutable as $$ select date_trunc('month', at at time zone 'UTC')::date $$;

create function private.limits(acc uuid, out images_month int, out posts_month int, out images_per_post int)
language sql stable security definer set search_path = private as $$
  select coalesce(a.images_month_override, p.images_month), coalesce(a.posts_month_override, p.posts_month),
         p.images_per_post
  from private.accounts a join private.plans p on p.id = a.plan where a.id = acc
$$;

-- Take quota up front (in-flight work counts as used); refund() gives back what didn't happen.
create function private.reserve(acc uuid, images int, posts int) returns date
language plpgsql security definer set search_path = private as $$
declare
  m date := private.month_start();
  lim record;
  u private.usage_monthly;
  today_images int;
begin
  select * into lim from private.limits(acc);
  insert into private.usage_monthly (account_id, month) values (acc, m) on conflict do nothing;
  select * into u from private.usage_monthly where account_id = acc and month = m for update;
  if u.posts_used + posts > lim.posts_month or u.images_used + images > lim.images_month then
    raise exception 'monthly quota reached' using errcode = 'P0001', detail = 'quota_exceeded',
      hint = format('posts %s/%s, images %s/%s', u.posts_used, lim.posts_month, u.images_used, lim.images_month);
  end if;
  -- global safety cap (a bug or abuse must not burn the GPUs all night)
  select coalesce(sum(images_reserved), 0) into today_images from private.posts where created_at > now() - interval '1 day';
  if today_images + images > private.setting('daily_image_cap', '20000')::int then
    raise exception 'service is busy, try later' using errcode = 'P0001', detail = 'daily_cap';
  end if;
  update private.usage_monthly set images_used = images_used + images, posts_used = posts_used + posts
  where account_id = acc and month = m;
  return m;
end $$;

create function private.refund(acc uuid, m date, images int, posts int) returns void
language sql security definer set search_path = private as $$
  update private.usage_monthly
  set images_used = greatest(0, images_used - images), posts_used = greatest(0, posts_used - posts)
  where account_id = acc and month = m
$$;

create function private.own_business(b uuid) returns private.businesses
language plpgsql security definer set search_path = private as $$
declare r private.businesses;
begin
  select * into r from private.businesses where id = b and account_id = private.current_account() and deleted_at is null;
  if not found then
    raise exception 'business not found' using errcode = 'P0002', detail = 'not_found';
  end if;
  return r;
end $$;

-- ---------- api: me ----------
create function api.me() returns jsonb
language plpgsql security definer set search_path = private as $$
declare
  acc uuid := private.current_account();
  lim record;
  u record;
begin
  select * into lim from private.limits(acc);
  select coalesce(images_used, 0) as images_used, coalesce(posts_used, 0) as posts_used into u
  from (select 1) x left join private.usage_monthly on account_id = acc and month = private.month_start();
  return jsonb_build_object(
    'account_id', acc,
    'is_anonymous', (select is_anonymous from private.accounts where id = acc),
    'month', private.month_start(),
    'limits', jsonb_build_object('images_month', lim.images_month, 'posts_month', lim.posts_month,
                                 'images_per_post', lim.images_per_post),
    'used', jsonb_build_object('images', u.images_used, 'posts', u.posts_used));
end $$;

-- ---------- api: businesses ----------
create view api.businesses with (security_invoker = true) as
  select b.id, b.name, b.description, b.language, b.timezone, b.created_at, b.updated_at,
         coalesce(p.status, 'none') as profile_status
  from private.businesses b left join private.profiles p on p.business_id = b.id
  where b.deleted_at is null;

create function api.create_business(name text, description text default '', language text default 'uk',
                                    timezone text default 'Europe/Kyiv') returns api.businesses
language plpgsql security definer set search_path = private as $$
declare
  acc uuid := private.current_account();
  b private.businesses;
  r api.businesses;
begin
  if (select count(*) from private.businesses where account_id = acc and deleted_at is null) >= 50 then
    raise exception 'too many businesses' using errcode = 'P0001', detail = 'limit_businesses';
  end if;
  insert into private.businesses (account_id, name, description, language, timezone)
  values (acc, create_business.name, coalesce(create_business.description, ''), create_business.language,
          create_business.timezone)
  returning * into b;
  insert into private.profiles (business_id, account_id) values (b.id, acc);
  select * into r from api.businesses where id = b.id;
  return r;
end $$;

create function api.update_business(id uuid, name text default null, description text default null,
                                    language text default null, timezone text default null) returns api.businesses
language plpgsql security definer set search_path = private as $$
declare r api.businesses;
begin
  perform private.own_business(update_business.id);
  update private.businesses b set
    name = coalesce(update_business.name, b.name),
    description = coalesce(update_business.description, b.description),
    language = coalesce(update_business.language, b.language),
    timezone = coalesce(update_business.timezone, b.timezone),
    updated_at = now()
  where b.id = update_business.id;
  select * into r from api.businesses where api.businesses.id = update_business.id;
  return r;
end $$;

create function api.delete_business(id uuid) returns void
language plpgsql security definer set search_path = private as $$
begin
  perform private.own_business(delete_business.id);
  update private.businesses set deleted_at = now() where private.businesses.id = delete_business.id;
  update private.jobs set status = 'failed', error = 'business deleted', finished_at = now()
  where business_id = delete_business.id and status = 'queued';
end $$;

-- ---------- api: photos (direct-to-storage upload) ----------
create view api.photos with (security_invoker = true) as
  select m.id, m.business_id, m.content_type, m.created_at,
         private.media_url(m.object_key, 'GET', 'public', 3600) as url
  from private.media m
  where m.kind = 'photo' and m.status = 'ready' and m.deleted_at is null;

-- 1) upload_url → PUT the bytes to `put_url`  2) photo_uploaded(media_id)
create function api.upload_url(business_id uuid, content_type text default 'image/jpeg') returns jsonb
language plpgsql security definer set search_path = private as $$
declare
  b private.businesses := private.own_business(upload_url.business_id);
  ext text := case lower(content_type) when 'image/png' then 'png' when 'image/webp' then 'webp'
                                       when 'image/heic' then 'heic' else 'jpg' end;
  m private.media;
begin
  if lower(content_type) not in ('image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/heic') then
    raise exception 'unsupported image type' using errcode = 'P0001', detail = 'bad_content_type';
  end if;
  if (select count(*) from private.media where media.business_id = b.id and kind = 'photo' and deleted_at is null) >= 30 then
    raise exception 'too many photos for one business' using errcode = 'P0001', detail = 'limit_photos';
  end if;
  insert into private.media (account_id, business_id, kind, object_key, content_type)
  values (b.account_id, b.id, 'photo', format('b/%s/photo/%s.%s', b.id, gen_random_uuid(), ext), lower(content_type))
  returning * into m;
  return jsonb_build_object('media_id', m.id, 'method', 'PUT', 'expires_in', 900,
                            'put_url', private.media_url(m.object_key, 'PUT', 'public', 900));
end $$;

create function api.photo_uploaded(media_id uuid) returns void
language plpgsql security definer set search_path = private as $$
begin
  update private.media set status = 'ready'
  where id = media_id and account_id = private.current_account() and kind = 'photo' and status = 'pending';
  if not found then
    raise exception 'photo not found' using errcode = 'P0002', detail = 'not_found';
  end if;
end $$;

create function api.delete_photo(media_id uuid) returns void
language plpgsql security definer set search_path = private as $$
begin
  update private.media set deleted_at = now()
  where id = media_id and account_id = private.current_account() and kind = 'photo';
end $$;

-- ---------- api: style profile ----------
create view api.profiles with (security_invoker = true) as
  select p.business_id, p.status, p.data, p.edited, p.updated_at, p.error
  from private.profiles p join private.businesses b on b.id = p.business_id where b.deleted_at is null;

create function private.queue_profile(b private.businesses) returns void
language plpgsql security definer set search_path = private as $$
begin
  if exists (select 1 from private.jobs where business_id = b.id and kind = 'profile' and status in ('queued', 'running')) then
    return;
  end if;
  update private.profiles set status = 'analyzing', error = null, updated_at = now() where business_id = b.id;
  insert into private.jobs (kind, account_id, business_id, priority) values ('profile', b.account_id, b.id, 10);
end $$;

create function api.analyze_business(business_id uuid) returns void
language plpgsql security definer set search_path = private as $$
begin
  perform private.queue_profile(private.own_business(analyze_business.business_id));
end $$;

create function api.update_profile(business_id uuid, data jsonb) returns api.profiles
language plpgsql security definer set search_path = private as $$
declare
  b private.businesses := private.own_business(update_profile.business_id);
  before jsonb;
  r api.profiles;
begin
  if jsonb_typeof(data) <> 'object' then
    raise exception 'profile must be a JSON object' using errcode = 'P0001', detail = 'bad_profile';
  end if;
  select p.data into before from private.profiles p where p.business_id = b.id;
  update private.profiles set data = update_profile.data, edited = true, status = 'ready', updated_at = now()
  where private.profiles.business_id = b.id;
  insert into private.signals (account_id, business_id, kind, data)
  values (b.account_id, b.id, 'profile_edited', jsonb_build_object('before', before, 'after', data));
  select * into r from api.profiles where api.profiles.business_id = b.id;
  return r;
end $$;

-- ---------- api: posts ----------
create view api.posts with (security_invoker = true) as
  select p.id, p.business_id, p.batch_id, p.status, p.language, p.caption, p.hashtags, p.error,
         p.created_at, p.ready_at,
         coalesce((select jsonb_agg(jsonb_build_object(
                     'position', i.position, 'status', i.status,
                     'url', case when i.status = 'ready' then private.media_url(m.object_key, 'GET', 'public', 3600) end)
                   order by i.position)
                   from private.post_images i left join private.media m on m.id = i.media_id
                   where i.post_id = p.id), '[]'::jsonb) as images
  from private.posts p join private.businesses b on b.id = p.business_id
  where p.deleted_at is null and b.deleted_at is null;

create function api.generate_posts(business_id uuid, n int default 3) returns setof api.posts
language plpgsql security definer set search_path = private as $$
declare
  b private.businesses := private.own_business(generate_posts.business_id);
  lim record;
  m date;
  batch uuid := gen_random_uuid();
  prof text;
begin
  if n not between 1 and 10 then
    raise exception 'n must be 1..10' using errcode = 'P0001', detail = 'bad_n';
  end if;
  select * into lim from private.limits(b.account_id);
  m := private.reserve(b.account_id, n * lim.images_per_post, n);
  insert into private.posts (account_id, business_id, batch_id, language, quota_month, images_reserved)
  select b.account_id, b.id, batch, b.language, m, lim.images_per_post from generate_series(1, n);
  -- the ideas job waits for the profile; make sure one exists or is on its way
  select status into prof from private.profiles where profiles.business_id = b.id;
  if coalesce(prof, 'none') in ('none', 'failed') then
    perform private.queue_profile(b);
  end if;
  insert into private.jobs (kind, account_id, business_id, batch_id, context)
  values ('ideas', b.account_id, b.id, batch, jsonb_build_object('n', n, 'images_per_post', lim.images_per_post));
  return query select * from api.posts where api.posts.batch_id = batch order by created_at;
end $$;

-- What the user did with a post: copied, downloaded, deleted, regenerated (training signals).
create function api.post_signal(post_id uuid, kind text, data jsonb default '{}') returns void
language plpgsql security definer set search_path = private as $$
declare p private.posts;
begin
  select * into p from private.posts where id = post_id and account_id = private.current_account();
  if not found then
    raise exception 'post not found' using errcode = 'P0002', detail = 'not_found';
  end if;
  if kind not in ('copied', 'downloaded', 'regenerated') then
    raise exception 'unknown signal' using errcode = 'P0001', detail = 'bad_signal';
  end if;
  insert into private.signals (account_id, post_id, business_id, kind, data)
  values (p.account_id, p.id, p.business_id, kind, coalesce(data, '{}'));
end $$;

-- The user rewrote the caption: keep it, and keep before/after as the most valuable training pair.
create function api.edit_post(post_id uuid, caption text, hashtags text[] default null) returns api.posts
language plpgsql security definer set search_path = private as $$
declare
  p private.posts;
  r api.posts;
begin
  select * into p from private.posts where id = post_id and account_id = private.current_account() and deleted_at is null;
  if not found then
    raise exception 'post not found' using errcode = 'P0002', detail = 'not_found';
  end if;
  insert into private.signals (account_id, post_id, business_id, kind, data)
  values (p.account_id, p.id, p.business_id, 'edited', jsonb_build_object(
    'before', jsonb_build_object('caption', p.caption, 'hashtags', p.hashtags),
    'after', jsonb_build_object('caption', caption, 'hashtags', coalesce(hashtags, p.hashtags)),
    'idea_en', p.idea_en));
  update private.posts set caption = edit_post.caption, hashtags = coalesce(edit_post.hashtags, posts.hashtags)
  where id = p.id;
  select * into r from api.posts where id = p.id;
  return r;
end $$;

create function api.delete_post(post_id uuid) returns void
language plpgsql security definer set search_path = private as $$
declare p private.posts;
begin
  update private.posts set deleted_at = now()
  where id = post_id and account_id = private.current_account() and deleted_at is null
  returning * into p;
  if found then
    insert into private.signals (account_id, post_id, business_id, kind) values (p.account_id, p.id, p.business_id, 'deleted');
  end if;
end $$;

-- ---------- grants: only what the client may call ----------
revoke execute on all functions in schema api from public;
revoke execute on all functions in schema private from public;
grant select on all tables in schema api to authenticated;
grant execute on all functions in schema api to authenticated;
grant execute on function private.uid(), private.jwt_claim(text), private.media_url(text, text, text, int)
  to authenticated;

-- migrate:down
drop function api.delete_post(uuid), api.edit_post(uuid, text, text[]), api.post_signal(uuid, text, jsonb),
  api.generate_posts(uuid, int), api.update_profile(uuid, jsonb), api.analyze_business(uuid),
  private.queue_profile(private.businesses), api.delete_photo(uuid), api.photo_uploaded(uuid), api.upload_url(uuid, text),
  api.delete_business(uuid), api.update_business(uuid, text, text, text, text),
  api.create_business(text, text, text, text), api.me(), private.own_business(uuid), private.refund(uuid, date, int, int),
  private.reserve(uuid, int, int), private.limits(uuid), private.month_start(timestamptz), private.current_account();
drop view api.posts, api.profiles, api.photos, api.businesses;
