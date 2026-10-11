begin;
create extension if not exists pgtap;
select plan(41);
-- these tests were written for the generous limits; the real plans are checked in 90_plans.sql
update private.plans set posts_month = 1000, images_month = 3000, images_per_post = 3 where id = 'free';

create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', true)::text, true);
$$;
create function pg_temp.reply(content text) returns jsonb language sql as $$
  select jsonb_build_object('choices', jsonb_build_array(jsonb_build_object('message', jsonb_build_object('content', content))))
$$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');

-- the plan, what is left, onboarding
select is(api.me()->>'plan', 'free', 'me: the plan is free');
select is((api.me()->'left'->>'posts')::int, (select posts_month from private.plans where id = 'free'), 'me: left = the plan''s limit when nothing is used');
select is(api.me()->>'onboarded_at', null, 'me: not onboarded yet');
select isnt(api.complete_onboarding()->>'onboarded_at', null, 'complete_onboarding sets the time');
select is(api.complete_onboarding()->>'onboarded_at', api.me()->>'onboarded_at', 'a second call keeps the first time');

-- a business without a name, time zones
select is((api.create_business(description => 'Flowers and bouquets', language => 'en', utc_offset => 330)).name, null, 'a business may have no name');
select is((select timezone from private.businesses where description = 'Flowers and bouquets'), '<+05:30>-05:30', 'utc_offset 330 is stored as a POSIX zone');
select is(to_char(timestamptz '2026-01-01 00:00+00' at time zone '<+05:30>-05:30', 'HH24:MI'), '05:30', 'that zone is 5:30 east of UTC');
select is(private.tz(null, -180), '<-03:00>+03:00', 'a negative offset');
select is((api.create_business(name => 'Zone', timezone => 'America/New_York', utc_offset => 0)).timezone, 'America/New_York', 'a zone name wins over the offset');
select throws_ok($$ select api.create_business(name => 'x', timezone => 'Mars/Phobos') $$, 'P0001', 'unknown time zone', 'an unknown zone is refused');
select throws_ok($$ select api.create_business(name => 'x', utc_offset => 900) $$, 'P0001', null, 'an impossible offset is refused');

-- the profile shape
select is(private.profile_shape('{"customers":["students","parents"],"tone":"warm","best_days":"Friday, Saturdays and weekend","brand_colors":["#FFAA00","red","#12345"],"extra":1}'),
          '{"customers":"students, parents","tone":"warm","business_name":"","best_days":["friday","saturday","sunday"],"brand_colors":["#ffaa00"],"extra":1}'::jsonb,
          'profile_shape: lists become strings, days are normalised, bad colors dropped, other keys kept');
select is(private.profile_shape('{}'), '{"customers":"","tone":"","business_name":"","best_days":[],"brand_colors":[]}'::jsonb, 'profile_shape: missing keys appear, empty');
select is(private.profile_shape('{"best_days":["end of month","Mon","daily"]}')->'best_days', '["monday","tuesday","wednesday","thursday","friday","saturday","sunday"]'::jsonb, '"daily" is every day; "month" is not Monday by itself');
select is(private.profile_shape('{"best_days":["end of month","Tue"]}')->'best_days', '["tuesday"]'::jsonb, '"month" does not count as Monday');

-- the analysis names a nameless business; a given name wins
reset role;
insert into private.jobs (kind, account_id, business_id) select 'profile', account_id, id from private.businesses where description = 'Flowers and bouquets';
select private.handle(j, pg_temp.reply('{"business_name":"Bloom Corner","customers":"locals","tone":"warm","best_days":["Friday"]}'))
from private.jobs j where j.kind = 'profile' and j.account_id = '00000000-0000-0000-0000-0000000000d1';
select is((select name from private.businesses where description = 'Flowers and bouquets'), 'Bloom Corner', 'the analysis names the business');
select is((select data from private.profiles p join private.businesses b on b.id = p.business_id where b.name = 'Bloom Corner'),
          '{"business_name":"Bloom Corner","customers":"locals","tone":"warm","best_days":["friday"],"brand_colors":[]}'::jsonb, 'the stored profile has the fixed shape');
select private.handle(j, pg_temp.reply('{"business_name":"Other Name"}'))
from private.jobs j where j.kind = 'profile' and j.account_id = '00000000-0000-0000-0000-0000000000d1';
select is((select name from private.businesses where description = 'Flowers and bouquets'), 'Bloom Corner', 'a name that exists is not replaced');
select is((api.update_profile((select id from private.businesses where name = 'Bloom Corner'), '{"tone":["calm","kind"]}')).data->>'tone', 'calm, kind', 'update_profile stores the fixed shape too');

-- download links
insert into private.media (account_id, business_id, kind, object_key, status)
select account_id, id, 'photo', 'b/t/photo/abc.jpg', 'ready' from private.businesses where name = 'Bloom Corner';
select alike((select download_url from api.photos where business_id = (select id from private.businesses where name = 'Bloom Corner')),
             '%&response-content-disposition=attachment%3B%20filename%3D%22photo-%.jpg%22&X-Amz-Signature=%', 'photos have a signed download link');

-- options: three posts, the owner keeps one and pays for one
select count(*) from api.generate_posts((select id from private.businesses where name = 'Bloom Corner'), 3);
update private.jobs j set context = j.context || (private.build_request(j)->'context')
where kind = 'ideas' and account_id = '00000000-0000-0000-0000-0000000000d1';
select private.handle(j, pg_temp.reply('{"posts":[{"angle":"offer","caption_en":"Tulips today.","hashtags":["a"],"image_prompts":["p1","p2"]},
  {"angle":"story","caption_en":"How we started.","hashtags":["b"],"image_prompts":["p3"]},
  {"angle":"tip","caption_en":"Keep flowers fresh.","hashtags":["c"],"image_prompts":["p4","p5"]}]}'))
from private.jobs j where j.kind = 'ideas' and j.account_id = '00000000-0000-0000-0000-0000000000d1';
update private.jobs set status = 'done' where kind = 'ideas' and account_id = '00000000-0000-0000-0000-0000000000d1';
select is((api.me()->'used'->>'images')::int, 5, 'three options hold 3 posts and 5 pictures while they render');
select throws_ok(format($$ select api.choose_post(%L) $$, (select id from private.posts where idea_en->>'angle' = 'story')), 'PT409', 'this option is not finished yet', 'an unfinished option cannot be chosen');
-- "story" finishes (its one picture); "offer" has one picture running; "tip" has not started
update private.jobs j set context = j.context || (private.build_request(j)->'context') where kind = 'image' and account_id = '00000000-0000-0000-0000-0000000000d1';
select private.handle(j, '{"data":[{"url":"http://x/y.png"}]}') from private.jobs j join private.posts p on p.id = j.post_id where j.kind = 'image' and p.idea_en->>'angle' = 'story';
update private.jobs j set status = 'done' from private.posts p where p.id = j.post_id and j.kind = 'image' and p.idea_en->>'angle' = 'story';
update private.jobs set status = 'running' where id = (select min(j.id) from private.jobs j join private.posts p on p.id = j.post_id where j.kind = 'image' and p.idea_en->>'angle' = 'offer');
update private.post_images set status = 'rendering' where id = (select post_image_id from private.jobs where status = 'running' and kind = 'image' and account_id = '00000000-0000-0000-0000-0000000000d1');
select isnt((api.choose_post((select id from private.posts where idea_en->>'angle' = 'story'))).chosen_at, null, 'the finished option is chosen');
select is((select count(*)::int from private.posts where passed_at is not null and account_id = '00000000-0000-0000-0000-0000000000d1'), 2, 'the other two are passed');
select is((api.me()->'used'->>'posts')::int, 3, 'every option that was written stays counted, kept or not');
select is((api.me()->'used'->>'images')::int, 2, 'pictures that were made or are being made stay counted; the three that had not started are given back');
select is((select count(*)::int from private.jobs where kind = 'image' and status = 'queued' and account_id = '00000000-0000-0000-0000-0000000000d1'), 0, 'pictures that had not started are stopped');
select is((select string_agg(kind, ',' order by kind) from private.signals where account_id = '00000000-0000-0000-0000-0000000000d1' and kind in ('chosen', 'passed')), 'chosen,passed,passed', 'the choice and the passes are recorded');
select throws_ok(format($$ select api.choose_post(%L) $$, (select id from private.posts where idea_en->>'angle' = 'tip')), 'PT409', 'another option of this round was already chosen', 'one choice per round');
select lives_ok(format($$ select api.choose_post(%L) $$, (select id from private.posts where idea_en->>'angle' = 'story')), 'choosing the same option again changes nothing');
-- the picture of a passed option fails later: a failed picture is never counted
select private.fail_job(j, 'test') from private.jobs j where j.kind = 'image' and j.status = 'running' and j.account_id = '00000000-0000-0000-0000-0000000000d1';
select is((api.me()->'used'->>'images')::int, 1, 'a passed option''s picture that fails is given back');

-- the memory: a learn job reads the signals, its reply is stored, the next options are written from it
select is((select count(*)::int from private.jobs where kind = 'learn' and status = 'queued' and account_id = '00000000-0000-0000-0000-0000000000d1'), 1, 'a learn job is queued');
select ok((select private.build_request(j)->'body'->'messages'->1->>'content' from private.jobs j where j.kind = 'learn' and j.account_id = '00000000-0000-0000-0000-0000000000d1')
          like '%How we started.%"event": "chosen"%', 'the learn request carries what the owner chose');
update private.jobs j set context = j.context || (private.build_request(j)->'context') where kind = 'learn' and account_id = '00000000-0000-0000-0000-0000000000d1';
select private.handle(j, pg_temp.reply('{"likes":["personal stories"],"dislikes":"discount offers","voice":"warm","junk":1}'))
from private.jobs j where j.kind = 'learn' and j.account_id = '00000000-0000-0000-0000-0000000000d1';
select is((select learned from api.profiles where business_id = (select id from private.businesses where name = 'Bloom Corner')),
          '{"likes":["personal stories"],"dislikes":["discount offers"],"topics":[],"voice":"warm","notes":[]}'::jsonb, 'the memory is stored in a fixed shape and the app can read it');
select count(*) from api.generate_posts((select id from private.businesses where name = 'Bloom Corner'), 2);
select ok((select private.build_request(j)->'body'->'messages'->1->>'content' from private.jobs j where j.kind = 'ideas' and j.status = 'queued' and j.account_id = '00000000-0000-0000-0000-0000000000d1')
          ~ 'Memory of the owner''s taste.*personal stories.*Options the owner chose.*story.*Angles the owner passed on.*(offer|tip)', 'the next options are written from the memory, the picks and the passes');

-- the owner lowers the plan below what is used: nothing breaks, no more posts
update private.plans set posts_month = 1 where id = 'free';
select throws_ok(format($$ select api.generate_posts(%L, 1) $$, (select id from private.businesses where name = 'Bloom Corner')), 'PT402', 'monthly quota reached', 'over a lowered limit: no more posts');
select is((api.me()->'left'->>'posts')::int, 0, 'left never goes below zero');

-- delete the account
reset role;
insert into private.settings (key, value) values ('s3_node_endpoints', 'http://10.0.0.1:3900,http://10.0.0.2:3900')
on conflict (key) do update set value = excluded.value;
select set_config('test.before', (select count(*)::text from net.http_request_queue), true);
set local role authenticated;
select api.delete_account();
reset role;
select is((select count(*)::int from net.http_request_queue) - current_setting('test.before')::int, 4, 'one DELETE per picture and per node (a photo and a generated picture × 2 nodes)');
select is((select count(*)::int from private.accounts a full join private.businesses b on b.account_id = a.id
           where coalesce(a.id, b.account_id) = '00000000-0000-0000-0000-0000000000d1'), 0, 'delete_account removes the account and its rows');
select throws_ok($$ select api.me() $$, 'PT401', 'sign in first', 'its token no longer opens an account');

select * from finish();
rollback;
