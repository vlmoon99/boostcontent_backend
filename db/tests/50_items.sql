begin;
create extension if not exists pgtap;
select plan(19);

create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', true)::text, true);
$$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');

-- a business with one item and photos: two of the item, one of the business
create temp table t as select (api.create_business(name => 'Coats', description => 'Outerwear shop', language => 'en')).id as biz;
alter table t add column item uuid, add column other uuid;
update t set item = (api.create_item(biz, '  Black puffer  ', 'Quilted, high collar')).id;
select is((select name from api.items where id = (select item from t)), 'Black puffer', 'an item is created with a trimmed name');
select throws_ok($$ select api.create_item((select biz from t), '   ') $$, '23514', null, 'an item needs a name');

reset role;
insert into private.media (account_id, business_id, kind, object_key, content_type, status, created_at)
select b.account_id, b.id, 'photo', 'b/x/' || n || '.jpg', 'image/jpeg', 'ready', now() + n * interval '1 second'
from private.businesses b, generate_series(1, 3) n where b.id = (select biz from t);
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
select api.set_photo_item(m.id, (select item from t)) from private.media m where m.object_key in ('b/x/2.jpg', 'b/x/3.jpg');

select is((select jsonb_array_length(photos) from api.items where id = (select item from t)), 2, 'the item lists its two photos');
select is(jsonb_array_length(private.photo_list((select biz from t), (select item from t))), 2, 'photo_list of an item: only its photos');
select is(private.photo_list((select biz from t), (select item from t))->0->>'key', 'b/x/2.jpg', 'numbered from the item''s first photo');
select is(jsonb_array_length(private.photo_list((select biz from t), null)), 3, 'photo_list without an item: every photo');
select is((api.update_item((select item from t), description => 'Warm and light')).description, 'Warm and light', 'an item is edited');

-- a round about that item and a subject
create temp table r as select * from api.generate_posts((select biz from t), 2, (select item from t), '  Winter sale, 20% off  ');
select is((select count(*)::int from r), 2, 'two options are queued');
reset role;
select is((select distinct about from private.posts where batch_id = (select batch_id from r limit 1)), 'Winter sale, 20% off', 'the posts remember the subject');
select is((select context->>'item_name' from private.jobs where kind = 'ideas' and batch_id = (select batch_id from r limit 1)), 'Black puffer', 'the ideas job carries the item');
select ok((select (private.build_request(j)->'body'->'messages')::text like '%This round is about ONE product: Black puffer. Warm and light%'
                  and (private.build_request(j)->'body'->'messages')::text like '%must be about: Winter sale, 20%% off%'
                  and (private.build_request(j)->'body'->'messages')::text like '%Product photos available: 2%'
           from private.jobs j where kind = 'ideas' and batch_id = (select batch_id from r limit 1)),
          'the request names the item, the subject and only the item''s photos');

-- another account cannot use the item; a round without an item is as before
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
update t set other = (api.create_business(name => 'Other', language => 'en')).id;
select throws_ok($$ select api.generate_posts((select other from t), 1, (select item from t)) $$, 'PT404', null, 'someone else''s item is not found');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1');
select is((select count(*)::int from api.generate_posts((select biz from t), 1)), 1, 'a round without an item still works');
select api.delete_item((select item from t));
select is((select count(*)::int from api.items where id = (select item from t)), 0, 'a deleted item is gone');

-- stopping a round
create temp table d as select * from api.generate_posts((select biz from t), 3);
create temp table used as select (api.me()->'used'->>'posts')::int as posts;
select lives_ok($$ select api.discard_batch((select batch_id from d limit 1)) $$, 'a round is discarded');
select is((select count(*)::int from api.posts where batch_id = (select batch_id from d limit 1) and passed_at is null), 0, 'none of its options is left to pick');
select is((api.me()->'used'->>'posts')::int, (select posts - 3 from used), 'its three posts are given back');
reset role;
select is((select status from private.jobs where kind = 'ideas' and batch_id = (select batch_id from d limit 1)), 'failed', 'the queued ideas job is cancelled');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e2');
select throws_ok($$ select api.discard_batch((select batch_id from d limit 1)) $$, 'PT404', null, 'someone else''s round is not found');

select * from finish();
rollback;
