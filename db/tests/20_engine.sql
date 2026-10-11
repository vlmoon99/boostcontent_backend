begin;
create extension if not exists pgtap;
select plan(12);
-- these tests were written for the generous limits; the real plans are checked in 90_plans.sql
update private.plans set posts_month = 1000, images_month = 3000, images_per_post = 3 where id = 'free';

select is(private.json_loose('```json
{"a": 1}
```'), '{"a": 1}'::jsonb, 'json_loose strips code fences');
select is(private.json_loose('no json here'), null, 'json_loose: garbage → null');

-- a business with one photo and a 2-post batch
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000c1","role":"authenticated"}', true);
select api.create_business('Engine test', 'flowers', 'uk');
insert into private.media (account_id, business_id, kind, object_key, status)
values ('00000000-0000-0000-0000-0000000000c1', (select id from private.businesses where name = 'Engine test'), 'photo', 'b/t/photo/1.jpg', 'ready');
select count(*) from api.generate_posts((select id from private.businesses where name = 'Engine test'), 2);

-- what dispatch() records: the photo-number → media map the model saw
update private.jobs j set context = j.context || (private.build_request(j)->'context')
where kind = 'ideas' and account_id = '00000000-0000-0000-0000-0000000000c1';
-- the ideas reply: post 1 restyles photo 1 with 2 prompts, post 2 has no photo and 1 prompt
select lives_ok($$
  select private.handle(j, jsonb_build_object('choices', jsonb_build_array(jsonb_build_object('message', jsonb_build_object('content',
    '{"posts":[{"angle":"a","photo":1,"caption_en":"Fresh tulips today.","hashtags":["tulips","kyiv"],"image_prompts":["on a windowsill","in a vase"]},
               {"angle":"b","photo":null,"caption_en":"We are open on Sunday.","hashtags":["open"],"image_prompts":["a shop front"]}]}')))))
  from private.jobs j where j.kind = 'ideas' and j.account_id = '00000000-0000-0000-0000-0000000000c1'
$$, 'ideas reply is handled');
select is((select count(*)::int from private.post_images i join private.posts p on p.id = i.post_id where p.business_id = (select id from private.businesses where name = 'Engine test')), 3, '3 images planned (2 + 1)');
select is((select count(*)::int from private.jobs where kind = 'image' and account_id = '00000000-0000-0000-0000-0000000000c1'), 3, '3 image jobs queued');
select is((select count(*)::int from private.jobs where kind = 'localize' and account_id = '00000000-0000-0000-0000-0000000000c1'), 2, 'uk business → 2 localize jobs');
select is((select count(*)::int from private.post_images where source_media_id is not null and account_id = '00000000-0000-0000-0000-0000000000c1'), 2, 'post 1 images restyle the photo');
select is((select images_used from private.usage_monthly where account_id = '00000000-0000-0000-0000-0000000000c1'), 3, 'unused image quota refunded (6 reserved → 3)');

-- what dispatch() records for image jobs: the output object key
update private.jobs j set context = j.context || (private.build_request(j)->'context')
where kind = 'image' and account_id = '00000000-0000-0000-0000-0000000000c1';
-- localize post 1, render its 2 images → ready; one image fails → partial + refund
select private.handle(j, '{"choices":[{"message":{"content":"{\"caption\":\"Свіжі тюльпани.\",\"hashtags\":[\"тюльпани\"]}"}}]}')
from private.jobs j join private.posts p on p.id = j.post_id where j.kind = 'localize' and p.idea_en->>'angle' = 'a' and j.account_id = '00000000-0000-0000-0000-0000000000c1';
select private.handle(j, '{"data":[{"url":"http://x/y.png"}]}')
from private.jobs j join private.post_images i on i.id = j.post_image_id where j.kind = 'image' and i.position = 1 and i.source_media_id is not null and j.account_id = '00000000-0000-0000-0000-0000000000c1';
select is((select status from private.posts where idea_en->>'angle' = 'a' and account_id = '00000000-0000-0000-0000-0000000000c1'), 'rendering', 'one of two images done → still rendering');
select private.fail_job(j, 'test') from private.jobs j join private.post_images i on i.id = j.post_image_id
where j.kind = 'image' and i.position = 2 and i.source_media_id is not null and j.account_id = '00000000-0000-0000-0000-0000000000c1';
select is((select status from private.posts where idea_en->>'angle' = 'a' and account_id = '00000000-0000-0000-0000-0000000000c1'), 'partial', 'second image failed → partial');
select is((select caption from private.posts where idea_en->>'angle' = 'a' and account_id = '00000000-0000-0000-0000-0000000000c1'), 'Свіжі тюльпани.', 'caption localized');
select is((select images_used from private.usage_monthly where account_id = '00000000-0000-0000-0000-0000000000c1'), 2, 'failed image refunded');

select * from finish();
rollback;
