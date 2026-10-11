-- migrate:up
-- The owner chooses how many pictures each option of a round gets: generate_posts(..., images => 2).
--   images is clamped to 1 .. the plan's images_per_post (me().limits.images_per_post); without it the plan's
--   number is used and nothing changes for older apps.
--   When the owner chose, the model is told to write exactly that many picture prompts, and if it still writes
--   fewer the ones it wrote are repeated, so every option gets the number that was asked for.
drop function api.generate_posts(uuid, int, uuid, text);
create function api.generate_posts(business_id uuid, n int default 3, item_id uuid default null,
                                   about text default null, images int default null)
returns setof api.posts
language plpgsql security definer set search_path = private as $$
declare
  b private.businesses := private.own_business(generate_posts.business_id);
  it private.items;
  subject text := nullif(left(btrim(coalesce(generate_posts.about, '')), 500), '');
  lim record;
  pics int;
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
  pics := least(greatest(coalesce(generate_posts.images, lim.images_per_post), 1), lim.images_per_post);
  m := private.reserve(b.account_id, n * pics, n);
  insert into private.posts (account_id, business_id, batch_id, language, quota_month, images_reserved, item_id, about)
  select b.account_id, b.id, batch, b.language, m, pics, it.id, subject from generate_series(1, n);
  -- the ideas job waits for the profile; make sure one exists or is on its way
  select status into prof from private.profiles where profiles.business_id = b.id;
  if coalesce(prof, 'none') in ('none', 'failed') then
    perform private.queue_profile(b);
  end if;
  insert into private.jobs (kind, account_id, business_id, batch_id, context)
  values ('ideas', b.account_id, b.id, batch, jsonb_strip_nulls(jsonb_build_object(
            'n', n, 'images_per_post', pics, 'images_exact', case when generate_posts.images is not null then true end,
            'item_id', it.id, 'item_name', it.name, 'item_description', nullif(it.description, ''),
            'about', subject)));
  return query select * from api.posts where api.posts.batch_id = batch order by created_at;
end $$;
grant execute on function api.generate_posts(uuid, int, uuid, text, int) to authenticated;

-- Both functions are long, so they are patched in place; a patch fails loudly if the text it expects is not there.
do $$
declare
  src text := pg_get_functiondef('private.build_request(private.jobs)'::regprocedure);
  old_text text := 'Each post gets %s image prompt(s) at most.';
  new_text text := 'Each post gets %s.';
  old_arg text := E'j.context->>''n'', j.context->>''images_per_post'',';
  new_arg text := E'j.context->>''n'', case when j.context ? ''images_exact'' then format(''exactly %s image prompt(s), each one a clearly different scene'', j.context->>''images_per_post'') else format(''%s image prompt(s) at most'', j.context->>''images_per_post'') end,';
begin
  if position(old_text in src) = 0 or position(old_arg in src) = 0 then
    raise exception 'build_request does not look as expected: the pictures patch was not applied';
  end if;
  execute replace(replace(src, old_text, new_text), old_arg, new_arg);
end $$;

do $$
declare
  src text := pg_get_functiondef('private.handle(private.jobs, jsonb)'::regprocedure);
  old_line text := 'n_img := least(jsonb_array_length(prompts), p.images_reserved);';
  new_line text := E'if j.context ? ''images_exact'' and jsonb_array_length(prompts) < p.images_reserved then\n        prompts := (select jsonb_agg(prompts->((g - 1) % jsonb_array_length(prompts)) order by g) from generate_series(1, p.images_reserved) g);\n      end if;\n      n_img := least(jsonb_array_length(prompts), p.images_reserved);';
begin
  if position(old_line in src) = 0 then
    raise exception 'handle does not look as expected: the pictures patch was not applied';
  end if;
  execute replace(src, old_line, new_line);
end $$;

-- migrate:down
do $$
declare
  src text := pg_get_functiondef('private.handle(private.jobs, jsonb)'::regprocedure);
  a int := position(E'if j.context ? ''images_exact'' and jsonb_array_length(prompts)' in src);
  z int := position('n_img := least(jsonb_array_length(prompts), p.images_reserved);' in src);
begin
  if a > 0 and z > a then
    execute left(src, a - 1) || substring(src from z);
  end if;
end $$;
do $$
declare
  src text := pg_get_functiondef('private.build_request(private.jobs)'::regprocedure);
  a int := position(E'case when j.context ? ''images_exact''' in src);
  z int;
begin
  if a > 0 then
    z := a + position('to_char(now() at time zone b.timezone' in substring(src from a)) - 1;
    src := left(src, a - 1) || E'j.context->>''images_per_post'',\n                ' || substring(src from z);
    execute replace(src, 'Each post gets %s.', 'Each post gets %s image prompt(s) at most.');
  end if;
end $$;
drop function api.generate_posts(uuid, int, uuid, text, int);
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
grant execute on function api.generate_posts(uuid, int, uuid, text) to authenticated;
