begin;
create extension if not exists pgtap;
select plan(14);
-- these tests were written for the generous limits; the real plans are checked in 90_plans.sql
update private.plans set posts_month = 1000, images_month = 3000, images_per_post = 3 where id = 'free';

create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', true)::text, true);
$$;
set local role authenticated;

-- user A creates a business
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select lives_ok($$ select api.create_business('A bakery', 'cakes', 'uk') $$, 'user A creates a business');
select is((select count(*)::int from api.businesses), 1, 'A sees one business');
select is((api.me()->'limits'->>'images_month')::int, 3000, 'default plan: 3000 images / month');

-- user B sees nothing of A
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from api.businesses), 0, 'B does not see A''s business');
select throws_ok(format($$ select api.update_business(%L, 'stolen') $$, (select id from private.businesses where name = 'A bakery')),
                 'PT404', 'business not found', 'B cannot modify A''s business');
select throws_ok(format($$ select api.generate_posts(%L, 1) $$, (select id from private.businesses where name = 'A bakery')),
                 'PT404', 'business not found', 'B cannot generate on A''s business');

-- no token → nothing
select set_config('request.jwt.claims', '', true);
select throws_ok($$ select api.me() $$, 'PT401', 'sign in first', 'no JWT → not authenticated');

-- quota: A has 1000 posts; ask beyond the limit
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
reset role;
update private.accounts set posts_month_override = 2 where id = '00000000-0000-0000-0000-00000000000a';
set local role authenticated;
select throws_ok(format($$ select api.generate_posts(%L, 11) $$, (select id from private.businesses where name = 'A bakery')),
                 'P0001', 'n must be 1..10', 'n is bounded');
select lives_ok(format($$ select api.generate_posts(%L, 2) $$, (select id from private.businesses where name = 'A bakery')),
                'A generates 2 posts (exactly the override)');
select is((api.me()->'used'->>'posts')::int, 2, 'posts used = 2');
select is((api.me()->'used'->>'images')::int, 6, 'images reserved = 2 × 3');
select throws_ok(format($$ select api.generate_posts(%L, 1) $$, (select id from private.businesses where name = 'A bakery')),
                 'PT402', 'monthly quota reached', 'the 3rd post is over quota');

-- a failed ideas job gives everything back
reset role;
select private.fail_job(j, 'test') from private.jobs j where kind = 'ideas' and account_id = '00000000-0000-0000-0000-00000000000a';
select is((select posts_used from private.usage_monthly where account_id = '00000000-0000-0000-0000-00000000000a'), 0, 'failed batch refunds posts');
select is((select images_used from private.usage_monthly where account_id = '00000000-0000-0000-0000-00000000000a'), 0, 'failed batch refunds images');

select * from finish();
rollback;
