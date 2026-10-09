-- migrate:up
-- The generation engine, entirely in Postgres: pg_cron runs private.tick() every few seconds;
-- tick() collects finished pg_net responses, retries or fails what timed out, and dispatches queued jobs
-- to the inference gateway (LiteLLM, OpenAI-compatible) within concurrency limits.
--
--   profile  : vision LLM over the description + product photos → structured English style profile
--   ideas    : one LLM call per generate_posts() batch → n post ideas (structured English)
--   localize : caption + hashtags into the business language (skipped for en)
--   image    : Qwen-Edit of the chosen product photo (or a blank canvas) via pre-signed GET/PUT URLs
--
-- Every model call lands in private.gen_trace (input, raw output, parsed output, prompt version, latency).

-- ---------- prompts (structured English; versions go into every trace) ----------
insert into private.prompts (key, version, body) values
('profile', 'p1', $p$You are a senior social-media strategist. You study a small business from its own
description and product photos and write a compact style profile that a copywriter and a photographer
will follow. Write in English. Return ONLY a JSON object with exactly these keys:
{
  "summary": "one sentence: what the business sells and to whom",
  "customers": "who buys, with age range and situation",
  "tone": "3-6 words describing the voice",
  "best_days": ["days of the week when posts work best for this business"],
  "brand_colors": ["#rrggbb", "... 2 to 5 hex colors seen in the photos or implied by the brand"],
  "products": [{"name": "short product name", "photo": 1, "description": "what is visible in that photo"}],
  "content_pillars": ["3 to 5 recurring post themes"],
  "visual_style": "lighting, backgrounds and mood that suit the photos",
  "avoid": ["things the posts must not do"]
}
"photo" is the 1-based number of the photo that shows the product, or null. Use only what the
description and photos support; never invent prices, addresses or awards.$p$),
('ideas', 'i1', $p$You are the content manager of the business described below. Write social-media posts
that sell without sounding like ads. Use the style profile. Every post must be different in angle.
Write in English (it is translated later). Return ONLY a JSON object:
{"posts": [{
  "angle": "the idea in one line (offer, story, behind the scenes, seasonal, tip, social proof...)",
  "product": "product name from the profile, or null",
  "photo": 1,
  "audience": "who this post is for",
  "caption_en": "the full caption, 2-5 short sentences, ending with a soft call to action",
  "hashtags": ["5 to 10 tags without #"],
  "image_prompts": ["1 to 3 instructions for an image editor that restyles the product photo: scene, light, props, season. The product itself must stay exactly the same."]
}]}
"photo" is the 1-based photo number to restyle, or null for a post without a product photo; then each
image prompt describes a full picture to paint from nothing.$p$),
('localize', 'l1', $p$Translate this social-media post into {LANG}. Keep the meaning, tone, emojis and
line breaks; make it sound native, not translated. Translate hashtags into natural {LANG} tags (no #),
keep brand names as they are. Return ONLY a JSON object: {"caption": "...", "hashtags": ["..."]}$p$);

-- ---------- helpers ----------
create function private.json_loose(t text) returns jsonb
language plpgsql immutable as $$
declare a int; z int;
begin
  if t is null then return null; end if;
  a := strpos(t, '{');
  z := length(t) - strpos(reverse(t), '}') + 1;
  if a = 0 or z <= a then return null; end if;
  return substr(t, a, z - a + 1)::jsonb;
exception when others then
  return null;
end $$;

create function private.llm_body(system_prompt text, user_content jsonb, max_tokens int default 2000) returns jsonb
language sql stable security definer set search_path = private as $$
  select jsonb_build_object(
    'model', private.setting('llm_model', 'qwen3.6-35b'),
    'messages', jsonb_build_array(jsonb_build_object('role', 'system', 'content', system_prompt),
                                  jsonb_build_object('role', 'user', 'content', user_content)),
    'response_format', jsonb_build_object('type', 'json_object'),
    'chat_template_kwargs', jsonb_build_object('enable_thinking', false),
    'temperature', 0.6,
    'max_tokens', max_tokens)
$$;

create function private.post_send(path text, body jsonb, timeout_ms int) returns bigint
language sql security definer set search_path = private, net, public as $$
  select net.http_post(
    url := rtrim(private.setting('inference_url'), '/') || path,
    body := body,
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'Authorization', 'Bearer ' || private.setting('inference_key')),
    timeout_milliseconds := timeout_ms)
$$;

create function private.photo_list(b uuid) returns jsonb       -- [{n, id, key}] stable order = photo numbers
language sql stable security definer set search_path = private as $$
  select coalesce(jsonb_agg(jsonb_build_object('n', rn, 'id', id, 'key', object_key) order by rn), '[]')
  from (select id, object_key, row_number() over (order by created_at, id) as rn
        from private.media where business_id = b and kind = 'photo' and status = 'ready' and deleted_at is null
        order by created_at, id limit 12) x
$$;

-- ---------- request builders ----------
create function private.build_request(j private.jobs) returns jsonb   -- {path, body, timeout_ms, context}
language plpgsql security definer set search_path = private as $$
declare
  b private.businesses;
  prof jsonb;
  photos jsonb;
  content jsonb;
  ph jsonb;
  p private.posts;
  pi private.post_images;
  src private.media;
  out_key text;
begin
  select * into b from private.businesses where id = j.business_id;
  if j.kind = 'profile' then
    photos := private.photo_list(b.id);
    content := jsonb_build_array(jsonb_build_object('type', 'text', 'text', format(
      E'Business name: %s\nDescription: %s\nPhotos attached: %s (numbered in order).', b.name, b.description,
      jsonb_array_length(photos))));
    for ph in select * from jsonb_array_elements(photos) loop
      content := content || jsonb_build_array(jsonb_build_object('type', 'text', 'text', 'Photo ' || (ph->>'n')),
        jsonb_build_object('type', 'image_url', 'image_url',
          jsonb_build_object('url', private.media_url(ph->>'key', 'GET', 'internal', 3600))));
    end loop;
    return jsonb_build_object('path', '/v1/chat/completions', 'timeout_ms', 300000,
      'context', jsonb_build_object('photos', photos, 'prompt_version', (select version from private.prompts where key = 'profile')),
      'body', private.llm_body((select body from private.prompts where key = 'profile'), content, 1500));

  elsif j.kind = 'ideas' then
    select data into prof from private.profiles where business_id = b.id;
    photos := private.photo_list(b.id);
    content := to_jsonb(format(E'Business: %s\nDescription: %s\nStyle profile (JSON): %s\nProduct photos available: %s\nWrite %s posts. Each post gets %s image prompt(s) at most. Today is %s.',
      b.name, b.description, coalesce(prof::text, '{}'), jsonb_array_length(photos),
      j.context->>'n', j.context->>'images_per_post', to_char(now() at time zone b.timezone, 'FMDay, DD Month YYYY')));
    return jsonb_build_object('path', '/v1/chat/completions', 'timeout_ms', 300000,
      'context', j.context || jsonb_build_object('photos', photos, 'prompt_version', (select version from private.prompts where key = 'ideas')),
      'body', private.llm_body((select body from private.prompts where key = 'ideas'), content,
                               600 * greatest(1, (j.context->>'n')::int)));

  elsif j.kind = 'localize' then
    select * into p from private.posts where id = j.post_id;
    return jsonb_build_object('path', '/v1/chat/completions', 'timeout_ms', 180000,
      'context', jsonb_build_object('prompt_version', (select version from private.prompts where key = 'localize')),
      'body', private.llm_body(replace((select body from private.prompts where key = 'localize'), '{LANG}',
                                       case p.language when 'uk' then 'Ukrainian' when 'ru' then 'Russian' else 'English' end),
                               to_jsonb(jsonb_build_object('caption', p.idea_en->>'caption_en', 'hashtags', p.idea_en->'hashtags')::text), 1500));

  elsif j.kind = 'image' then
    select * into pi from private.post_images where id = j.post_image_id;
    select * into src from private.media where id = pi.source_media_id and status = 'ready' and deleted_at is null;
    out_key := format('b/%s/gen/%s.png', b.id, gen_random_uuid());
    return jsonb_build_object('path', '/v1/images/generations', 'timeout_ms', 600000,
      'context', jsonb_build_object('out_key', out_key),
      'body', jsonb_strip_nulls(jsonb_build_object(
        'model', private.setting('image_model', 'qwen-image-edit'),
        'prompt', pi.prompt_en,
        'size', private.setting('image_size', '1024x1280'),
        'image_url', case when src.id is not null then private.media_url(src.object_key, 'GET', 'internal', 3600) end,
        'output_put_url', private.media_url(out_key, 'PUT', 'internal', 3600))));
  end if;
  raise exception 'unknown job kind %', j.kind;
end $$;

-- ---------- post completion ----------
create function private.settle_post(pid uuid) returns void
language plpgsql security definer set search_path = private as $$
declare
  p private.posts;
  total int; done int; good int;
begin
  select * into p from private.posts where id = pid for update;
  if p.status in ('ready', 'partial', 'failed') or p.caption is null then return; end if;
  select count(*), count(*) filter (where status in ('ready', 'failed')), count(*) filter (where status = 'ready')
    into total, done, good from private.post_images where post_id = pid;
  if done < total then return; end if;
  update private.posts set status = case when good = total then 'ready' else 'partial' end, ready_at = now()
  where id = pid;
end $$;

-- ---------- response handlers (raise to retry; the caller decides retry vs fail) ----------
create function private.handle(j private.jobs, resp jsonb) returns void
language plpgsql security definer set search_path = private as $$
declare
  content text;
  parsed jsonb;
  photos jsonb := coalesce(j.context->'photos', '[]');
  idea jsonb;
  p record;
  i int;
  n_img int;
  prompts jsonb;
  photo_n int;
  src uuid;
  m private.media;
begin
  if j.kind in ('profile', 'ideas', 'localize') then
    content := resp->'choices'->0->'message'->>'content';
    parsed := private.json_loose(content);
    if parsed is null then
      raise exception 'model returned no JSON';
    end if;
  end if;

  if j.kind = 'profile' then
    update private.profiles set auto = parsed, data = case when edited then data else parsed end,
      status = 'ready', error = null, updated_at = now()
    where business_id = j.business_id;

  elsif j.kind = 'ideas' then
    if jsonb_typeof(parsed->'posts') <> 'array' or jsonb_array_length(parsed->'posts') = 0 then
      raise exception 'ideas: no posts array';
    end if;
    i := 0;
    for p in select * from private.posts where batch_id = j.batch_id and status = 'queued' order by created_at, id loop
      idea := parsed->'posts'->i;
      i := i + 1;
      if idea is null or coalesce(idea->>'caption_en', '') = '' then
        update private.posts set status = 'failed', error = 'model wrote fewer posts' where id = p.id;
        perform private.refund(p.account_id, p.quota_month, p.images_reserved, 1);
        continue;
      end if;
      prompts := case when jsonb_typeof(idea->'image_prompts') = 'array' and jsonb_array_length(idea->'image_prompts') > 0
                      then idea->'image_prompts' else jsonb_build_array(idea->>'angle') end;
      n_img := least(jsonb_array_length(prompts), p.images_reserved);
      photo_n := case when jsonb_typeof(idea->'photo') = 'number' then (idea->>'photo')::int end;
      select (e->>'id')::uuid into src from jsonb_array_elements(photos) e where (e->>'n')::int = photo_n;
      if src is null and jsonb_array_length(photos) > 0 and photo_n is not null then
        src := (photos->0->>'id')::uuid;          -- model named a photo that doesn't exist: use the first
      end if;
      update private.posts set idea_en = idea, status = 'writing',
        hashtags = coalesce(array(select jsonb_array_elements_text(idea->'hashtags')), '{}'),
        images_reserved = n_img
      where id = p.id;
      perform private.refund(p.account_id, p.quota_month, p.images_reserved - n_img, 0);
      for k in 1 .. n_img loop
        with ins as (
          insert into private.post_images (post_id, account_id, position, prompt_en, source_media_id)
          values (p.id, p.account_id, k, prompts->>(k - 1), src) returning id)
        insert into private.jobs (kind, account_id, business_id, post_id, post_image_id, priority)
        select 'image', p.account_id, p.business_id, p.id, ins.id, 0 from ins;
      end loop;
      if p.language = 'en' then
        update private.posts set caption = idea->>'caption_en', status = 'rendering' where id = p.id;
      else
        insert into private.jobs (kind, account_id, business_id, post_id, priority)
        values ('localize', p.account_id, p.business_id, p.id, 5);
      end if;
    end loop;

  elsif j.kind = 'localize' then
    if coalesce(parsed->>'caption', '') = '' then
      raise exception 'localize: empty caption';
    end if;
    update private.posts set caption = parsed->>'caption', status = 'rendering',
      hashtags = coalesce(array(select jsonb_array_elements_text(parsed->'hashtags')), hashtags)
    where id = j.post_id;
    perform private.settle_post(j.post_id);

  elsif j.kind = 'image' then
    if coalesce(resp->'data'->0->>'url', '') = '' then
      raise exception 'image: no url in reply';
    end if;
    insert into private.media (account_id, business_id, kind, object_key, content_type, status)
    values (j.account_id, j.business_id, 'generated', j.context->>'out_key', 'image/png', 'ready')
    returning * into m;
    update private.post_images set media_id = m.id, status = 'ready' where id = j.post_image_id;
    perform private.settle_post(j.post_id);
  end if;
end $$;

-- A job that will not be retried: mark it and everything that depended on it, give quota back.
create function private.fail_job(j private.jobs, why text) returns void
language plpgsql security definer set search_path = private as $$
declare p record;
begin
  update private.jobs set status = 'failed', error = why, finished_at = now(), request_id = null where id = j.id;
  if j.kind = 'profile' then
    update private.profiles set status = 'failed', error = why, updated_at = now() where business_id = j.business_id;
  elsif j.kind = 'ideas' then
    for p in select * from private.posts where batch_id = j.batch_id and status = 'queued' loop
      update private.posts set status = 'failed', error = why where id = p.id;
      perform private.refund(p.account_id, p.quota_month, p.images_reserved, 1);
    end loop;
  elsif j.kind = 'localize' then
    -- keep the post usable: fall back to the English caption
    update private.posts set caption = idea_en->>'caption_en', status = 'rendering', error = 'translation failed'
    where id = j.post_id and caption is null;
    perform private.settle_post(j.post_id);
  elsif j.kind = 'image' then
    update private.post_images set status = 'failed', error = why where id = j.post_image_id;
    select account_id, quota_month into p from private.posts where id = j.post_id;
    perform private.refund(p.account_id, p.quota_month, 1, 0);
    perform private.settle_post(j.post_id);
  end if;
end $$;

create function private.retry_or_fail(j private.jobs, why text) returns void
language plpgsql security definer set search_path = private as $$
begin
  if j.attempts >= j.max_attempts then
    perform private.fail_job(j, why);
  else
    update private.jobs set status = 'queued', request_id = null, error = why,
      not_before = now() + make_interval(secs => 15 * power(2, j.attempts - 1))
    where id = j.id;
  end if;
end $$;

-- ---------- the loop ----------
create function private.collect() returns int
language plpgsql security definer set search_path = private, net, public as $$
declare
  j private.jobs;
  r record;
  body jsonb;
  ok boolean;
  n int := 0;
begin
  for r in
    select jb.id as job_id, resp.status_code, resp.content, resp.error_msg, resp.created
    from private.jobs jb join net._http_response resp on resp.id = jb.request_id
    where jb.status = 'running'
    for update of jb skip locked
  loop
    select * into j from private.jobs where id = r.job_id;
    n := n + 1;
    body := case when r.content is not null and left(ltrim(r.content), 1) in ('{', '[')
                 then r.content::jsonb end;
    ok := r.status_code = 200 and body is not null;
    insert into private.gen_trace (account_id, business_id, post_id, job_id, step, prompt_version, model, input,
                                   output_raw, output, ok, http_status, latency_ms)
    values (j.account_id, j.business_id, j.post_id, j.id, j.kind, j.context->>'prompt_version', j.request->>'model',
            j.request, left(coalesce(case when j.kind = 'image' then null else body->'choices'->0->'message'->>'content' end,
                                     r.content, r.error_msg), 100000),
            case when j.kind = 'image' then body->'data' else private.json_loose(body->'choices'->0->'message'->>'content') end,
            ok, r.status_code, (extract(epoch from (r.created - j.started_at)) * 1000)::int);
    begin
      if not ok then
        raise exception 'HTTP %: %', coalesce(r.status_code::text, 'none'),
          left(coalesce(r.error_msg, r.content, ''), 300);
      end if;
      perform private.handle(j, body);
      update private.jobs set status = 'done', finished_at = now(), request_id = null, error = null where id = j.id;
    exception when others then
      update private.gen_trace set ok = false where job_id = j.id and id = (select max(id) from private.gen_trace where job_id = j.id);
      perform private.retry_or_fail(j, sqlerrm);
    end;
  end loop;
  return n;
end $$;

-- running jobs whose response never arrived (pg_net lost it, or the request outlived its timeout)
create function private.expire() returns void
language plpgsql security definer set search_path = private as $$
declare j private.jobs;
begin
  for j in select * from private.jobs where status = 'running'
             -- the request's own timeout + a minute of slack (pg_net reports timeouts itself normally)
             and started_at < now() - make_interval(secs => case kind when 'image' then 660 else 360 end)
           for update skip locked
  loop
    perform private.retry_or_fail(j, 'no response in time');
  end loop;
end $$;

create function private.dispatch() returns int
language plpgsql security definer set search_path = private as $$
declare
  j private.jobs;
  req jsonb;
  started int := 0;
  llm_running int;
  img_running int;
  llm_max int := private.setting('llm_concurrency', '4')::int;
  img_max int := private.setting('image_concurrency', '4')::int;
begin
  select count(*) filter (where kind <> 'image'), count(*) filter (where kind = 'image')
    into llm_running, img_running from private.jobs where status = 'running';
  for j in
    select * from private.jobs q
    where q.status = 'queued' and q.not_before <= now()
      -- ideas wait for the profile (unless it failed: then they go without it)
      and not (q.kind = 'ideas' and exists (select 1 from private.profiles pr where pr.business_id = q.business_id and pr.status = 'analyzing'))
    order by q.priority desc, q.id
    for update skip locked
    limit 50
  loop
    if j.kind = 'image' and img_running >= img_max then continue; end if;
    if j.kind <> 'image' and llm_running >= llm_max then continue; end if;
    begin
      req := private.build_request(j);
      update private.jobs set status = 'running', attempts = attempts + 1, started_at = now(),
        request = req->'body', context = context || coalesce(req->'context', '{}'),
        request_id = private.post_send(req->>'path', req->'body', (req->>'timeout_ms')::int)
      where id = j.id;
      if j.kind = 'image' then
        img_running := img_running + 1;
        update private.post_images set status = 'rendering' where id = j.post_image_id;
      else
        llm_running := llm_running + 1;
      end if;
      started := started + 1;
    exception when others then
      perform private.fail_job(j, 'could not build request: ' || sqlerrm);
    end;
  end loop;
  return started;
end $$;

create function private.tick() returns jsonb
language plpgsql security definer set search_path = private as $$
declare c int; d int;
begin
  if private.setting('inference_url') is null then
    return '{"skipped":"inference not configured"}';
  end if;
  c := private.collect();
  perform private.expire();
  d := private.dispatch();
  return jsonb_build_object('collected', c, 'dispatched', d);
end $$;

select cron.schedule('bc-tick', '3 seconds', 'select private.tick()');
-- keep cron's own log small
select cron.schedule('bc-cron-log-trim', '17 * * * *',
  $$delete from cron.job_run_details where end_time < now() - interval '1 day'$$);

-- migrate:down
select cron.unschedule('bc-tick');
select cron.unschedule('bc-cron-log-trim');
drop function private.tick(), private.dispatch(), private.expire(), private.collect(),
  private.retry_or_fail(private.jobs, text), private.fail_job(private.jobs, text), private.handle(private.jobs, jsonb),
  private.settle_post(uuid), private.build_request(private.jobs), private.photo_list(uuid),
  private.post_send(text, jsonb, int), private.llm_body(text, jsonb, int), private.json_loose(text);
delete from private.prompts where key in ('profile', 'ideas', 'localize');
