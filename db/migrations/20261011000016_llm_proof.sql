-- migrate:up
-- Where the text model runs, for the app's Settings: when the inference gateway sends chat to a provider that
-- runs the model inside a TEE (NEAR AI Cloud), it answers GET /v1/attestation with the proof (who signs the
-- answers, the Intel TDX quote, whether there is NVIDIA GPU evidence). A gateway without that path (the
-- Sparks' own models) answers 404, which is stored as "no TEE". The claim is only repeated to the app while
-- it is fresh: an answer older than 30 minutes counts as "no TEE", so a dead gateway cannot leave it standing.
create table private.llm_proof (
  id boolean primary key default true check (id),
  request_id bigint,
  asked_at timestamptz,
  data jsonb not null default '{"tee": false}',
  checked_at timestamptz
);
insert into private.llm_proof default values;

create function private.refresh_llm_proof() returns void
language plpgsql security definer set search_path = private, net, public as $$
declare
  p private.llm_proof;
  r record;
  body jsonb;
begin
  if pg_is_in_recovery() or private.setting('inference_url') is null then
    return;
  end if;
  select * into p from private.llm_proof for update;
  if p.request_id is not null then
    select status_code, content into r from net._http_response where id = p.request_id;
    if found then
      body := case when r.status_code = 200 and left(ltrim(coalesce(r.content, '')), 1) = '{' then r.content::jsonb end;
      update private.llm_proof set checked_at = now(), request_id = null,
        data = case when coalesce((body->>'tee')::boolean, false) then body else '{"tee": false}' end;
    end if;
  end if;
  update private.llm_proof set asked_at = now(), request_id = net.http_get(
    url := rtrim(private.setting('inference_url'), '/') || '/v1/attestation',
    headers := jsonb_build_object('Authorization', 'Bearer ' || private.setting('inference_key')),
    timeout_milliseconds := 60000);
end $$;
revoke all on function private.refresh_llm_proof() from public;

-- Not `stable`: current_account() notes that the account was seen, and PostgREST runs a stable function in a
-- read-only transaction.
create function api.privacy() returns jsonb
language plpgsql security definer set search_path = private, public as $$
declare
  p private.llm_proof;
  fresh boolean;
begin
  perform private.current_account();
  select * into p from private.llm_proof;
  fresh := p.checked_at > now() - interval '30 minutes' and coalesce((p.data->>'tee')::boolean, false);
  if not fresh then
    return jsonb_build_object('llm', jsonb_build_object('tee', false));
  end if;
  return jsonb_build_object('llm', jsonb_build_object(
    'tee', true,
    'provider', p.data->>'provider',
    'model', p.data->>'model',
    'signing_address', p.data->>'signing_address',
    'intel_quote', p.data->>'intel_quote',
    'has_nvidia_evidence', coalesce((p.data->>'has_nvidia_evidence')::boolean, false),
    'checked_at', p.checked_at));
end $$;
revoke all on function api.privacy() from public;
grant execute on function api.privacy() to authenticated;

select cron.schedule('bc-llm-proof', '*/5 * * * *', 'select private.refresh_llm_proof()');

-- migrate:down
select cron.unschedule('bc-llm-proof');
drop function api.privacy();
drop function private.refresh_llm_proof();
drop table private.llm_proof;
