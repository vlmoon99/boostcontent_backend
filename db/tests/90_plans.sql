begin;
create extension if not exists pgtap;
select plan(12);

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f9","role":"authenticated","is_anonymous":true}', true);

-- what a new account gets
select is(api.me()->>'plan', 'free', 'a new account is on the free plan');
select is(api.me()->'limits', '{"posts_month":12,"images_month":12,"images_per_post":1}'::jsonb, 'free: 12 options, 12 pictures, 1 picture per option');

-- what the app may show
select is(jsonb_array_length(api.plans()), 2, 'two plans are shown to users');
select is(api.plans()->0->>'id', 'free', 'the free one first');
select is(api.plans()->1, '{"id":"pro","posts_month":150,"images_month":300,"images_per_post":3,"price_cents":2000}'::jsonb, 'pro: 150 options, 300 pictures, 3 per option, $20');
select ok(not (api.plans()::text like '%team%'), 'the owner''s own plan is not shown');

-- the free limit counts what is made
create temp table t as select (api.create_business(name => 'Plans', description => 'Outerwear shop', language => 'en')).id as biz;
create temp table r as select id, batch_id from api.generate_posts((select biz from t), 3, images => 3);
select is((api.me()->'used')::jsonb, '{"posts":3,"images":3}'::jsonb, 'three options with one picture each: more pictures than the plan gives are not reserved');
reset role;
update private.posts set status = 'ready' where id in (select id from r);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f9","role":"authenticated","is_anonymous":true}', true);
select lives_ok(format($$ select api.discard_batch(%L) $$, (select batch_id from r limit 1)), 'the round is discarded after it was made');
select is((api.me()->'left'->>'posts')::int, 9, 'a discarded round stays counted');
select lives_ok(format($$ select count(*) from api.generate_posts(%L, 9) $$, (select biz from t)), 'the rest of the month can be used');
select throws_ok(format($$ select api.generate_posts(%L, 1) $$, (select biz from t)), 'PT402', 'monthly quota reached', 'the thirteenth option is refused');

-- the owner moves an account to pro by hand
reset role;
update private.accounts set plan = 'pro' where id = '00000000-0000-0000-0000-0000000000f9';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f9","role":"authenticated","is_anonymous":true}', true);
select is(api.me()->'limits', '{"posts_month":150,"images_month":300,"images_per_post":3}'::jsonb, 'pro: the limits follow the plan');

select * from finish();
rollback;
