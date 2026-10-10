-- migrate:up
-- The owner stops a round or throws its options away: discard_batch(batch_id).
-- Every option of the round that is neither chosen nor passed becomes passed, so it leaves the list.
--   still queued (the model has not written it): marked failed, its whole reservation is given back, and the
--     ideas reply skips it (handle() only fills `queued` posts); a queued ideas job is cancelled.
--   written or rendering: its queued pictures are cancelled and it is given back, exactly as choose_post
--     does for the options the owner did not keep.
-- A picture that is rendering at that moment still finishes on the inference side; it is simply not shown.
create function api.discard_batch(batch_id uuid) returns void
language plpgsql security definer set search_path = private as $$
declare
  acc uuid := private.current_account();
  o private.posts;
  live int;
begin
  if not exists (select 1 from private.posts x where x.batch_id = discard_batch.batch_id and x.account_id = acc
                 and x.deleted_at is null) then
    raise exception 'round not found' using errcode = 'PT404', detail = 'not_found';
  end if;
  for o in select * from private.posts x
           where x.batch_id = discard_batch.batch_id and x.account_id = acc and x.deleted_at is null
             and x.chosen_at is null and x.passed_at is null
           order by x.created_at, x.id for update loop
    update private.posts set passed_at = now() where id = o.id;
    if o.status = 'queued' then
      update private.posts set status = 'failed', error = 'round discarded' where id = o.id;
      perform private.refund(o.account_id, o.quota_month, o.images_reserved, 1);
    elsif o.status <> 'failed' then
      select count(*) into live from private.post_images i where i.post_id = o.id and i.status <> 'failed';
      update private.jobs set status = 'failed', error = 'round discarded', finished_at = now()
      where jobs.post_id = o.id and kind = 'image' and status = 'queued';
      update private.post_images set status = 'failed', error = 'round discarded'
      where post_images.post_id = o.id and status = 'queued';
      perform private.refund(o.account_id, o.quota_month, live, 1);
      perform private.settle_post(o.id);
    end if;
  end loop;
  update private.jobs set status = 'failed', error = 'round discarded', finished_at = now()
  where jobs.batch_id = discard_batch.batch_id and jobs.account_id = acc and kind = 'ideas' and status = 'queued';
end $$;
grant execute on function api.discard_batch(uuid) to authenticated;

-- migrate:down
drop function api.discard_batch(uuid);
