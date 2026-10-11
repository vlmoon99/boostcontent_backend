-- migrate:up
-- Plans the owner can afford now that every option and picture is paid for at a cloud (2026-10-11):
--   free  12 options and 12 pictures a month, 1 picture per option
--   pro   150 options and 300 pictures a month, up to 3 pictures per option, $20 a month
--   team  the old generous limits, for the owner's own accounts; never shown to users
-- `pro` cannot be bought yet: there are no payments. It exists so the app can show what it would give, and
-- so an account can be moved to it by hand (update private.accounts set plan = 'pro' where id = …).
--
-- The quota now counts what was MADE, not what was kept. An option the owner passes on (choose_post,
-- choose_posts, discard_batch after it was written) stays counted, because the text and the pictures were
-- paid for. Still given back: pictures that had not started (they are cancelled), an option the model never
-- wrote, and anything that failed.
alter table private.plans
  add column price_cents int not null default 0 check (price_cents >= 0),
  add column is_public boolean not null default false;

update private.plans set posts_month = 12, images_month = 12, images_per_post = 1, is_public = true,
  note = 'free: enough to judge the product' where id = 'free';
insert into private.plans (id, images_month, posts_month, images_per_post, price_cents, is_public, note)
values ('pro', 300, 150, 3, 2000, true, '$20 a month; not sold yet'),
       ('team', 3000, 1000, 3, 0, false, 'the owner''s own accounts')
on conflict (id) do nothing;

-- The plans a user may see, cheapest first.
create function api.plans() returns jsonb
language sql stable security definer set search_path = private as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'posts_month', posts_month, 'images_month', images_month, 'images_per_post', images_per_post,
    'price_cents', price_cents) order by price_cents, id), '[]')
  from private.plans where is_public
$$;
revoke all on function api.plans() from public;
grant execute on function api.plans() to authenticated;

do $$
declare
  f regprocedure;
  def text;
  count_old text := 'select count(*) into live from private.post_images i where i.post_id = o.id and i.status <> ''failed'';';
  count_new text := 'select count(*) into live from private.jobs q where q.post_id = o.id and q.kind = ''image'' and q.status = ''queued'';';
  back_old text := 'perform private.refund(o.account_id, o.quota_month, live, 1);';
  back_new text := 'perform private.refund(o.account_id, o.quota_month, live, 0);';
  fail_old text := 'if p.passed_at is null then             -- a passed option was given back whole when the owner chose
      perform private.refund(p.account_id, p.quota_month, 1, 0);
    end if;';
  fail_new text := 'perform private.refund(p.account_id, p.quota_month, 1, 0);   -- a failed picture is never counted';
begin
  foreach f in array array['api.choose_post(uuid)', 'api.choose_posts(uuid[])', 'api.discard_batch(uuid)']::regprocedure[] loop
    def := pg_get_functiondef(f);
    if position(count_old in def) = 0 or position(back_old in def) = 0 then
      raise exception '% does not look as expected: not patched', f;
    end if;
    execute replace(replace(def, count_old, count_new), back_old, back_new);
  end loop;
  def := pg_get_functiondef('private.fail_job(private.jobs, text)'::regprocedure);
  if position(fail_old in def) = 0 then
    raise exception 'fail_job does not look as expected: not patched';
  end if;
  execute replace(def, fail_old, fail_new);
end $$;

-- migrate:down
do $$
declare
  f regprocedure;
  def text;
  count_old text := 'select count(*) into live from private.post_images i where i.post_id = o.id and i.status <> ''failed'';';
  count_new text := 'select count(*) into live from private.jobs q where q.post_id = o.id and q.kind = ''image'' and q.status = ''queued'';';
  back_old text := 'perform private.refund(o.account_id, o.quota_month, live, 1);';
  back_new text := 'perform private.refund(o.account_id, o.quota_month, live, 0);';
  fail_old text := 'if p.passed_at is null then             -- a passed option was given back whole when the owner chose
      perform private.refund(p.account_id, p.quota_month, 1, 0);
    end if;';
  fail_new text := 'perform private.refund(p.account_id, p.quota_month, 1, 0);   -- a failed picture is never counted';
begin
  foreach f in array array['api.choose_post(uuid)', 'api.choose_posts(uuid[])', 'api.discard_batch(uuid)']::regprocedure[] loop
    def := pg_get_functiondef(f);
    execute replace(replace(def, count_new, count_old), back_new, back_old);
  end loop;
  execute replace(pg_get_functiondef('private.fail_job(private.jobs, text)'::regprocedure), fail_new, fail_old);
end $$;
drop function api.plans();
update private.accounts set plan = 'free' where plan in ('pro', 'team');
delete from private.plans where id in ('pro', 'team');
update private.plans set posts_month = 1000, images_month = 3000, images_per_post = 3 where id = 'free';
alter table private.plans drop column price_cents, drop column is_public;
