begin;
create extension if not exists pgtap;
select plan(13);

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f8","role":"authenticated","is_anonymous":true}', true);
create temp table t as select (api.create_business(name => 'Several', description => 'Outerwear shop', language => 'en')).id as biz;
create temp table before as select coalesce((api.me()->'used'->>'posts')::int, 0) as posts;
create temp table r as select id, batch_id, row_number() over (order by created_at, id) as n from api.generate_posts((select biz from t), 3);
create temp table other as select id from api.generate_posts((select biz from t), 1);
select is((api.me()->'used'->>'posts')::int, (select posts from before) + 4, 'four options are reserved');

select throws_ok($$ select api.choose_posts('{}') $$, 'P0001', 'no options given', 'an empty list is refused');
select throws_ok($$ select api.choose_posts(array['00000000-0000-0000-0000-00000000dead']::uuid[]) $$, 'PT404', 'post not found', 'someone else''s or a missing option is refused');
select throws_ok(format($$ select api.choose_posts(array[%L, %L]::uuid[]) $$, (select id from r where n = 1), (select id from other)),
                 'P0001', 'the options belong to different rounds', 'options of two rounds cannot be kept together');
select throws_ok(format($$ select api.choose_posts(array[%L]::uuid[]) $$, (select id from r where n = 1)),
                 'PT409', 'an option is not finished yet', 'an unfinished option cannot be kept');

reset role;
update private.posts set status = 'ready' where id in (select id from r);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f8","role":"authenticated","is_anonymous":true}', true);

create temp table kept as select * from api.choose_posts(array[(select id from r where n = 1), (select id from r where n = 3), (select id from r where n = 1)]);
select is((select count(*)::int from kept), 2, 'both options come back, a repeated id counts once');
reset role;
select is((select count(*)::int from private.posts where id in (select id from r where n in (1, 3)) and chosen_at is not null and passed_at is null), 2, 'both are kept');
select isnt((select passed_at from private.posts where id = (select id from r where n = 2)), null, 'the one that was not listed is passed');
select is((select count(*)::int from private.signals where post_id in (select id from r) and kind = 'chosen'), 2, 'each kept option is a signal the backend learns from');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f8","role":"authenticated","is_anonymous":true}', true);
select is((api.me()->'used'->>'posts')::int, (select posts from before) + 3, 'two kept options cost two posts: the passed one is given back');

select is((select count(*)::int from api.choose_posts(array[(select id from r where n = 3)])), 1, 'keeping a kept option again changes nothing');
select throws_ok(format($$ select api.choose_posts(array[%L]::uuid[]) $$, (select id from r where n = 2)),
                 'PT409', 'this round was already decided', 'a passed option cannot be kept afterwards');
select is((select count(*)::int from api.posts where batch_id = (select batch_id from r limit 1) and chosen_at is not null), 2, 'the list shows both kept options');

select * from finish();
rollback;
