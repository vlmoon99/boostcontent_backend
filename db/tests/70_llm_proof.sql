begin;
create extension if not exists pgtap;
select plan(9);

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f7","role":"authenticated","is_anonymous":true}', true);
update private.llm_proof set data = '{"tee": false}', checked_at = null, request_id = null;

select is(api.privacy(), '{"llm":{"tee":false}}'::jsonb, 'nothing checked yet: no TEE is claimed');

-- a gateway that proves a TEE
update private.llm_proof set checked_at = now(), data =
  '{"tee":true,"provider":"nearai","model":"Qwen/Qwen3.6-35B-A3B-FP8","signing_address":"0xabc","intel_quote":"0400","has_nvidia_evidence":true,"extra":"dropped"}';
select is(api.privacy()->'llm'->>'tee', 'true', 'a fresh proof is repeated to the app');
select is(api.privacy()->'llm'->>'provider', 'nearai', 'with the provider');
select is(api.privacy()->'llm'->>'intel_quote', '0400', 'the Intel quote');
select is(api.privacy()->'llm'->>'signing_address', '0xabc', 'and the key that signs the answers');
select ok(not (api.privacy()->'llm' ? 'extra'), 'only the fields of the contract are passed on');

-- an old answer is not a proof
update private.llm_proof set checked_at = now() - interval '31 minutes';
select is(api.privacy(), '{"llm":{"tee":false}}'::jsonb, 'a proof older than 30 minutes is not repeated');

-- the gateway answered without a proof (the Sparks' own models: 404)
insert into net._http_response (id, status_code, content) values (-7, 404, '{"detail":"Not Found"}');
update private.llm_proof set request_id = -7, checked_at = now(), data = '{"tee":true}';
select lives_ok('select private.refresh_llm_proof()', 'the answer is collected and the next question is sent');
select is((select data from private.llm_proof), '{"tee": false}'::jsonb, 'an answer without a proof clears the claim');

select * from finish();
rollback;
