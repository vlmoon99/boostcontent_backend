begin;
create extension if not exists pgtap;
select plan(11);

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f1","role":"authenticated","is_anonymous":true}', true);
create temp table t as select (api.create_business(name => 'Pictures', description => 'Outerwear shop', language => 'en')).id as biz;
create temp table lim as select (api.me()->'limits'->>'images_per_post')::int as top;
create temp table want as select least(2, top) as pics from lim;

-- the owner asks for a number of pictures
create temp table before as select coalesce((api.me()->'used'->>'images')::int, 0) as images;
create temp table r as select * from api.generate_posts((select biz from t), 2, images => (select pics from want));
select is((api.me()->'used'->>'images')::int, (select images from before) + 2 * (select pics from want), 'that many pictures are reserved for every option');
reset role;
select is((select (context->>'images_per_post')::int from private.jobs where kind = 'ideas' and batch_id = (select batch_id from r limit 1)), (select pics from want), 'the ideas job carries the number');
select ok((select context ? 'images_exact' from private.jobs where kind = 'ideas' and batch_id = (select batch_id from r limit 1)), 'and that the owner chose it');
select matches((select private.build_request(j)->'body'->'messages'->1->>'content' from private.jobs j where j.kind = 'ideas' and j.batch_id = (select batch_id from r limit 1)),
               format('Each post gets exactly %s image prompt', (select pics from want)), 'the model is told to write exactly that many');

-- the model writes one prompt for both options: it is repeated up to the number that was asked for
select lives_ok($$
  select private.handle(j, jsonb_build_object('choices', jsonb_build_array(jsonb_build_object('message', jsonb_build_object('content',
    '{"posts":[{"angle":"a","photo":null,"caption_en":"Warm coats are here.","hashtags":["coats"],"image_prompts":["on a snowy street"]},
               {"angle":"b","photo":null,"caption_en":"New season.","hashtags":["new"],"image_prompts":["in a studio"]}]}')))))
  from private.jobs j where j.kind = 'ideas' and j.batch_id = (select batch_id from r limit 1)
$$, 'the ideas reply is handled');
select is((select count(*)::int from private.post_images i join private.posts p on p.id = i.post_id where p.batch_id = (select batch_id from r limit 1)),
          2 * (select pics from want), 'every option gets the number of pictures that was asked for');
select is((select count(distinct prompt_en)::int from private.post_images i join private.posts p on p.id = i.post_id where p.batch_id = (select batch_id from r limit 1)),
          2, 'by repeating the prompts the model wrote');

-- out of range: clamped to 1 .. the plan's number
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f1","role":"authenticated","is_anonymous":true}', true);
create temp table big as select * from api.generate_posts((select biz from t), 1, images => 99);
create temp table small as select * from api.generate_posts((select biz from t), 1, images => 0);
select is((select images_reserved from private.posts where batch_id = (select batch_id from big)), (select top from lim),
          'more than the plan allows becomes the plan''s number');
select is((select images_reserved from private.posts where batch_id = (select batch_id from small)), 1, 'less than one becomes one');

-- without the number nothing changes
create temp table plain as select * from api.generate_posts((select biz from t), 1);
reset role;
select ok(not (select context ? 'images_exact' from private.jobs where kind = 'ideas' and batch_id = (select batch_id from plain limit 1)), 'a round without the number is not exact');
select matches((select private.build_request(j)->'body'->'messages'->1->>'content' from private.jobs j where j.kind = 'ideas' and j.batch_id = (select batch_id from plain limit 1)),
               format('Each post gets %s image prompt\(s\) at most', (select top from lim)), 'and the model gets the plan''s number as a maximum');

select * from finish();
rollback;
