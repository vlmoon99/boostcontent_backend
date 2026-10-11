-- migrate:up
-- The owner keeps SEVERAL options of a round ("these two of the three"), so finished work is not thrown away.
-- choose_post(id) keeps exactly one and stays as it is; this keeps every option that is listed and passes the
-- rest of the round: each kept option costs one post, each passed one is given back, as before.
-- All of the listed options must belong to one open round and be finished. Calling it again with options that
-- were already kept returns them and changes nothing.
create function api.choose_posts(post_ids uuid[]) returns setof api.posts
language plpgsql security definer set search_path = private as $$
declare
  me uuid := private.current_account();
  ids uuid[] := array(select distinct x from unnest(coalesce(post_ids, '{}')) x where x is not null);
  batch uuid;
  biz uuid;
  p private.posts;
  o private.posts;
  live int;
  fresh int := 0;
begin
  if cardinality(ids) = 0 then
    raise exception 'no options given' using errcode = 'P0001', detail = 'bad_ids';
  end if;
  if (select count(*) from private.posts where id = any(ids) and account_id = me and deleted_at is null) <> cardinality(ids) then
    raise exception 'post not found' using errcode = 'PT404', detail = 'not_found';
  end if;
  if (select count(distinct batch_id) from private.posts where id = any(ids)) <> 1 then
    raise exception 'the options belong to different rounds' using errcode = 'P0001', detail = 'bad_ids';
  end if;
  select batch_id, business_id into batch, biz from private.posts where id = ids[1];
  perform 1 from private.posts where batch_id = batch order by created_at, id for update;

  if not exists (select 1 from private.posts where id = any(ids) and chosen_at is null) then
    return query select * from api.posts a where a.id = any(ids) order by a.created_at, a.id;
    return;
  end if;
  if exists (select 1 from private.posts where id = any(ids) and passed_at is not null)
     or exists (select 1 from private.posts where batch_id = batch and chosen_at is not null) then
    raise exception 'this round was already decided' using errcode = 'PT409', detail = 'already_chosen';
  end if;
  if exists (select 1 from private.posts where id = any(ids) and status not in ('ready', 'partial')) then
    raise exception 'an option is not finished yet' using errcode = 'PT409', detail = 'not_ready';
  end if;

  for p in select * from private.posts where id = any(ids) order by created_at, id loop
    update private.posts set chosen_at = now() where id = p.id;
    insert into private.signals (account_id, post_id, business_id, kind, data)
    values (p.account_id, p.id, p.business_id, 'chosen', jsonb_build_object('batch_id', p.batch_id, 'idea_en', p.idea_en));
    fresh := fresh + 1;
  end loop;
  for o in select * from private.posts x where x.batch_id = batch and x.id <> all(ids) and x.passed_at is null
           order by x.created_at, x.id loop
    update private.posts set passed_at = now() where id = o.id;
    insert into private.signals (account_id, post_id, business_id, kind, data)
    values (o.account_id, o.id, o.business_id, 'passed', jsonb_build_object('batch_id', o.batch_id, 'idea_en', o.idea_en));
    if o.status <> 'failed' then            -- a failed post was given back when it failed
      select count(*) into live from private.post_images i where i.post_id = o.id and i.status <> 'failed';
      update private.jobs set status = 'failed', error = 'option not chosen', finished_at = now()
      where jobs.post_id = o.id and kind = 'image' and status = 'queued';
      update private.post_images set status = 'failed', error = 'option not chosen'
      where post_images.post_id = o.id and status = 'queued';
      perform private.refund(o.account_id, o.quota_month, live, 1);
      perform private.settle_post(o.id);
    end if;
  end loop;
  perform private.queue_learn(biz);
  return query select * from api.posts a where a.id = any(ids) order by a.created_at, a.id;
end $$;
revoke all on function api.choose_posts(uuid[]) from public;
grant execute on function api.choose_posts(uuid[]) to authenticated;

-- migrate:down
drop function api.choose_posts(uuid[]);
