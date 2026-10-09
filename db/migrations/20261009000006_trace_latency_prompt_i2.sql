-- migrate:up
-- 1) gen_trace.latency_ms measured at collect time (pg_net's `created` is the request time, not the reply).
-- 2) ideas prompt i2: restyle the business's real photos whenever a product fits (i1 painted generic food).

create or replace function private.collect() returns int
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
            ok, r.status_code, (extract(epoch from (clock_timestamp() - j.started_at)) * 1000)::int);   -- ≈ wall time incl. ≤ 1 tick
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

update private.prompts set version = 'i2', updated_at = now(), body = replace(body,
  $o$"photo" is the 1-based photo number to restyle, or null for a post without a product photo; then each
image prompt describes a full picture to paint from nothing.$o$,
  $n$"photo" is the 1-based photo number to restyle. Strongly prefer the business's real photos: at least
two out of three posts must restyle one of them. Use null only for a post that is really not about a
product (opening hours, hiring, a holiday greeting); then each image prompt describes a full picture.$n$)
where key = 'ideas';

-- migrate:down
update private.prompts set version = 'i1' where key = 'ideas';
