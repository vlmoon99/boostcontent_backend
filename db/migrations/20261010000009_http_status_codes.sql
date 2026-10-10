-- migrate:up
-- Client errors get the HTTP status they mean (PostgREST turns SQLSTATE 'PTxyz' into HTTP xyz; the JSON body
-- keeps message / details / hint, and `details` stays the stable code the app branches on):
--   not_found 500 → 404 · quota_exceeded 400 → 402 · daily_cap 400 → 429 · limit_* 400 → 409 ·
--   not_authenticated 403 → 401.   bad_* stay 400, blocked stays 403.
-- Bodies are the live definitions (pg_get_functiondef) with only the errcode changed.

CREATE OR REPLACE FUNCTION private.current_account()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'public'
AS $function$
declare
  me uuid := private.uid();
  blocked_ boolean;
begin
  if me is null then
    raise exception 'sign in first' using errcode = 'PT401', detail = 'not_authenticated';
  end if;
  insert into private.accounts (id, is_anonymous)
  values (me, coalesce(private.jwt_claim('is_anonymous')::boolean, true))
  on conflict (id) do update set last_seen_at = now()
  returning blocked into blocked_;
  if blocked_ then
    raise exception 'account blocked' using errcode = '42501', detail = 'blocked';
  end if;
  return me;
end $function$;

CREATE OR REPLACE FUNCTION private.reserve(acc uuid, images integer, posts integer)
 RETURNS date
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private'
AS $function$
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
    raise exception 'monthly quota reached' using errcode = 'PT402', detail = 'quota_exceeded',
      hint = format('posts %s/%s, images %s/%s', u.posts_used, lim.posts_month, u.images_used, lim.images_month);
  end if;
  -- global safety cap (a bug or abuse must not burn the GPUs all night)
  select coalesce(sum(images_reserved), 0) into today_images from private.posts where created_at > now() - interval '1 day';
  if today_images + images > private.setting('daily_image_cap', '20000')::int then
    raise exception 'service is busy, try later' using errcode = 'PT429', detail = 'daily_cap';
  end if;
  update private.usage_monthly set images_used = images_used + images, posts_used = posts_used + posts
  where account_id = acc and month = m;
  return m;
end $function$;

CREATE OR REPLACE FUNCTION private.own_business(b uuid)
 RETURNS private.businesses
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private'
AS $function$
declare r private.businesses;
begin
  select * into r from private.businesses where id = b and account_id = private.current_account() and deleted_at is null;
  if not found then
    raise exception 'business not found' using errcode = 'PT404', detail = 'not_found';
  end if;
  return r;
end $function$;

CREATE OR REPLACE FUNCTION api.create_business(name text, description text DEFAULT ''::text, language text DEFAULT 'uk'::text, timezone text DEFAULT 'Europe/Kyiv'::text)
 RETURNS api.businesses
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private'
AS $function$
declare
  acc uuid := private.current_account();
  b private.businesses;
  r api.businesses;
begin
  if (select count(*) from private.businesses where account_id = acc and deleted_at is null) >= 50 then
    raise exception 'too many businesses' using errcode = 'PT409', detail = 'limit_businesses';
  end if;
  insert into private.businesses (account_id, name, description, language, timezone)
  values (acc, create_business.name, coalesce(create_business.description, ''), create_business.language,
          create_business.timezone)
  returning * into b;
  insert into private.profiles (business_id, account_id) values (b.id, acc);
  select * into r from api.businesses where id = b.id;
  return r;
end $function$;

CREATE OR REPLACE FUNCTION api.upload_url(business_id uuid, content_type text DEFAULT 'image/jpeg'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private'
AS $function$
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
    raise exception 'too many photos for one business' using errcode = 'PT409', detail = 'limit_photos';
  end if;
  insert into private.media (account_id, business_id, kind, object_key, content_type)
  values (b.account_id, b.id, 'photo', format('b/%s/photo/%s.%s', b.id, gen_random_uuid(), ext), lower(content_type))
  returning * into m;
  return jsonb_build_object('media_id', m.id, 'method', 'PUT', 'expires_in', 900,
                            'put_url', private.media_url(m.object_key, 'PUT', 'public', 900));
end $function$;

CREATE OR REPLACE FUNCTION api.photo_uploaded(media_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private'
AS $function$
begin
  update private.media set status = 'ready'
  where id = media_id and account_id = private.current_account() and kind = 'photo' and status = 'pending';
  if not found then
    raise exception 'photo not found' using errcode = 'PT404', detail = 'not_found';
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.post_signal(post_id uuid, kind text, data jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private'
AS $function$
declare p private.posts;
begin
  select * into p from private.posts where id = post_id and account_id = private.current_account();
  if not found then
    raise exception 'post not found' using errcode = 'PT404', detail = 'not_found';
  end if;
  if kind not in ('copied', 'downloaded', 'regenerated') then
    raise exception 'unknown signal' using errcode = 'P0001', detail = 'bad_signal';
  end if;
  insert into private.signals (account_id, post_id, business_id, kind, data)
  values (p.account_id, p.id, p.business_id, kind, coalesce(data, '{}'));
end $function$;

CREATE OR REPLACE FUNCTION api.edit_post(post_id uuid, caption text, hashtags text[] DEFAULT NULL::text[])
 RETURNS api.posts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private'
AS $function$
declare
  p private.posts;
  r api.posts;
begin
  select * into p from private.posts where id = post_id and account_id = private.current_account() and deleted_at is null;
  if not found then
    raise exception 'post not found' using errcode = 'PT404', detail = 'not_found';
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
end $function$;

-- migrate:down
CREATE OR REPLACE FUNCTION private.current_account()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'public'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION private.reserve(acc uuid, images integer, posts integer)
 RETURNS date
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION private.own_business(b uuid)
 RETURNS private.businesses
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private'
AS $function$
declare r private.businesses;
begin
  select * into r from private.businesses where id = b and account_id = private.current_account() and deleted_at is null;
  if not found then
    raise exception 'business not found' using errcode = 'P0002', detail = 'not_found';
  end if;
  return r;
end $function$;

CREATE OR REPLACE FUNCTION api.create_business(name text, description text DEFAULT ''::text, language text DEFAULT 'uk'::text, timezone text DEFAULT 'Europe/Kyiv'::text)
 RETURNS api.businesses
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION api.upload_url(business_id uuid, content_type text DEFAULT 'image/jpeg'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION api.photo_uploaded(media_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private'
AS $function$
begin
  update private.media set status = 'ready'
  where id = media_id and account_id = private.current_account() and kind = 'photo' and status = 'pending';
  if not found then
    raise exception 'photo not found' using errcode = 'P0002', detail = 'not_found';
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.post_signal(post_id uuid, kind text, data jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION api.edit_post(post_id uuid, caption text, hashtags text[] DEFAULT NULL::text[])
 RETURNS api.posts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private'
AS $function$
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
end $function$;
