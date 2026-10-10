-- migrate:up
-- Market items: the things a business sells, each with a name, a description and its own photos.
-- A round of posts can now be about ONE item and about a subject the owner names:
--   generate_posts(business_id, n, item_id?, about?)
-- With an item, the model gets that item's name and description and only its photos (so "photo 1" is the
-- item's first photo). Without one, everything works as before. Nothing existing changes shape:
-- api.posts, api.photos and the other functions are untouched.

-- ---------- 1. the table ----------
create table private.items (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references private.accounts(id) on delete cascade,
  business_id uuid not null references private.businesses(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 120),
  description text not null default '' check (char_length(description) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index on private.items (business_id) where deleted_at is null;
alter table private.items enable row level security;
grant select on private.items to authenticated;
create policy own_rows on private.items for select to authenticated using (account_id = private.uid());

alter table private.media add column item_id uuid references private.items(id) on delete set null;
create index on private.media (item_id) where item_id is not null and deleted_at is null;
alter table private.posts add column item_id uuid references private.items(id) on delete set null,
                          add column about text;

-- ---------- 2. the API ----------
create view api.items with (security_invoker = true) as
  select i.id, i.business_id, i.name, i.description, i.created_at, i.updated_at,
         (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', m.id, 'url', private.media_url(m.object_key, 'GET', 'public', 3600))
                  order by m.created_at, m.id), '[]'::jsonb)
          from private.media m
          where m.item_id = i.id and m.kind = 'photo' and m.status = 'ready' and m.deleted_at is null) as photos
  from private.items i
  where i.deleted_at is null;

create function private.own_item(i uuid) returns private.items
language plpgsql security definer set search_path = private as $$
declare r private.items;
begin
  select * into r from private.items where id = i and account_id = private.current_account() and deleted_at is null;
  if not found then
    raise exception 'item not found' using errcode = 'PT404', detail = 'not_found';
  end if;
  return r;
end $$;

create function api.create_item(business_id uuid, name text, description text default '') returns api.items
language plpgsql security definer set search_path = private as $$
declare b private.businesses := private.own_business(create_item.business_id);
        new_id uuid;
        r api.items;
begin
  insert into private.items (account_id, business_id, name, description)
  values (b.account_id, b.id, btrim(create_item.name), coalesce(create_item.description, ''))
  returning id into new_id;
  select * into r from api.items where api.items.id = new_id;
  return r;
end $$;

create function api.update_item(id uuid, name text default null, description text default null) returns api.items
language plpgsql security definer set search_path = private as $$
declare r api.items;
begin
  perform private.own_item(update_item.id);
  update private.items i set
    name = coalesce(nullif(btrim(update_item.name), ''), i.name),
    description = coalesce(update_item.description, i.description),
    updated_at = now()
  where i.id = update_item.id;
  select * into r from api.items where api.items.id = update_item.id;
  return r;
end $$;

create function api.delete_item(id uuid) returns void        -- the item and its photos go; its posts stay
language plpgsql security definer set search_path = private as $$
begin
  perform private.own_item(delete_item.id);
  update private.media set deleted_at = now() where item_id = delete_item.id and kind = 'photo' and deleted_at is null;
  update private.items set deleted_at = now() where items.id = delete_item.id;
end $$;

-- An uploaded photo (upload_url → PUT → photo_uploaded, as before) is given to an item; null takes it back.
create function api.set_photo_item(media_id uuid, item_id uuid default null) returns void
language plpgsql security definer set search_path = private as $$
declare it private.items;
begin
  if set_photo_item.item_id is not null then
    it := private.own_item(set_photo_item.item_id);
  end if;
  update private.media m set item_id = set_photo_item.item_id
  where m.id = set_photo_item.media_id and m.account_id = private.current_account() and m.kind = 'photo'
    and m.deleted_at is null and (it.id is null or m.business_id = it.business_id);
  if not found then
    raise exception 'photo not found' using errcode = 'PT404', detail = 'not_found';
  end if;
end $$;

-- ---------- 3. a round about one item and/or one subject ----------
create function private.photo_list(b uuid, item uuid) returns jsonb    -- the item's photos, or all when item is null
language sql stable security definer set search_path = private as $$
  select case when item is null then private.photo_list(b) else (
    select coalesce(jsonb_agg(jsonb_build_object('n', rn, 'id', id, 'key', object_key) order by rn), '[]')
    from (select id, object_key, row_number() over (order by created_at, id) as rn
          from private.media
          where business_id = b and item_id = item and kind = 'photo' and status = 'ready' and deleted_at is null
          order by created_at, id limit 12) x) end
$$;

drop function api.generate_posts(uuid, int);
create function api.generate_posts(business_id uuid, n int default 3, item_id uuid default null,
                                   about text default null) returns setof api.posts
language plpgsql security definer set search_path = private as $$
declare
  b private.businesses := private.own_business(generate_posts.business_id);
  it private.items;
  subject text := nullif(left(btrim(coalesce(generate_posts.about, '')), 500), '');
  lim record;
  m date;
  batch uuid := gen_random_uuid();
  prof text;
begin
  if n not between 1 and 10 then
    raise exception 'n must be 1..10' using errcode = 'P0001', detail = 'bad_n';
  end if;
  if generate_posts.item_id is not null then
    it := private.own_item(generate_posts.item_id);
    if it.business_id <> b.id then
      raise exception 'item not found' using errcode = 'PT404', detail = 'not_found';
    end if;
  end if;
  select * into lim from private.limits(b.account_id);
  m := private.reserve(b.account_id, n * lim.images_per_post, n);
  insert into private.posts (account_id, business_id, batch_id, language, quota_month, images_reserved, item_id, about)
  select b.account_id, b.id, batch, b.language, m, lim.images_per_post, it.id, subject from generate_series(1, n);
  -- the ideas job waits for the profile; make sure one exists or is on its way
  select status into prof from private.profiles where profiles.business_id = b.id;
  if coalesce(prof, 'none') in ('none', 'failed') then
    perform private.queue_profile(b);
  end if;
  insert into private.jobs (kind, account_id, business_id, batch_id, context)
  values ('ideas', b.account_id, b.id, batch, jsonb_strip_nulls(jsonb_build_object(
            'n', n, 'images_per_post', lim.images_per_post, 'item_id', it.id, 'item_name', it.name,
            'item_description', nullif(it.description, ''), 'about', subject)));
  return query select * from api.posts where api.posts.batch_id = batch order by created_at;
end $$;

grant select on api.items to authenticated;
grant execute on function api.create_item(uuid, text, text), api.update_item(uuid, text, text), api.delete_item(uuid),
                          api.set_photo_item(uuid, uuid), api.generate_posts(uuid, int, uuid, text) to authenticated;

-- The ideas request: the item's photos instead of all photos, and two more lines of text. The function is
-- long, so it is patched in place; the patch fails loudly if the text it expects is not there.
do $$
declare
  src text := pg_get_functiondef('private.build_request(private.jobs)'::regprocedure);
  old_photos text := E'select data, learned into prof, mem from private.profiles where business_id = b.id;\n    photos := private.photo_list(b.id);';
  new_photos text := E'select data, learned into prof, mem from private.profiles where business_id = b.id;\n    photos := private.photo_list(b.id, (j.context->>''item_id'')::uuid);';
  old_line text := E'|| format(E''Product photos available: %s\\nWrite %s posts.';
  new_line text := E'|| case when j.context ? ''item_name'' then format(E''This round is about ONE product: %s. %s\\nEvery option must be about this product and restyle one of its photos.\\n'', j.context->>''item_name'', coalesce(j.context->>''item_description'', '''')) else '''' end\n      || case when j.context ? ''about'' then format(E''The owner says what these posts must be about: %s\\n'', j.context->>''about'') else '''' end\n      || format(E''Product photos available: %s\\nWrite %s posts.';
begin
  if position(old_photos in src) = 0 or position(old_line in src) = 0 then
    raise exception 'build_request does not look as expected: the items patch was not applied';
  end if;
  execute replace(replace(src, old_photos, new_photos), old_line, new_line);
end $$;

-- migrate:down
do $$
declare
  src text := pg_get_functiondef('private.build_request(private.jobs)'::regprocedure);
  a int := position(E'|| case when j.context ? ''item_name''' in src);
  z int := position(E'|| format(E''Product photos available:' in src);
begin
  if a > 0 and z > a then
    src := left(src, a - 1) || substring(src from z);
  end if;
  execute replace(src, E'private.photo_list(b.id, (j.context->>''item_id'')::uuid)', 'private.photo_list(b.id)');
end $$;
drop function api.generate_posts(uuid, int, uuid, text);
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
  select status into prof from private.profiles where profiles.business_id = b.id;
  if coalesce(prof, 'none') in ('none', 'failed') then
    perform private.queue_profile(b);
  end if;
  insert into private.jobs (kind, account_id, business_id, batch_id, context)
  values ('ideas', b.account_id, b.id, batch, jsonb_build_object('n', n, 'images_per_post', lim.images_per_post));
  return query select * from api.posts where api.posts.batch_id = batch order by created_at;
end $$;
grant execute on function api.generate_posts(uuid, int) to authenticated;
drop function private.photo_list(uuid, uuid);
drop function api.set_photo_item(uuid, uuid);
drop function api.delete_item(uuid);
drop function api.update_item(uuid, text, text);
drop function api.create_item(uuid, text, text);
drop function private.own_item(uuid);
drop view api.items;
alter table private.posts drop column about, drop column item_id;
alter table private.media drop column item_id;
drop table private.items;
