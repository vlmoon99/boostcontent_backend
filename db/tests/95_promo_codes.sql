begin;
create extension if not exists pgtap;
select plan(24);

-- the owner makes codes in the console
select set_config('request.jwt.claims', json_build_object('role', 'bc_admin')::text, true);
set local role bc_admin;
create temp table made as select * from admin_api.create_promo();
select matches((select code from made), '^BOOST-[A-Z0-9]{8}$', 'a code is made up when none is given');
select is((select row(plan, days, max_uses, used, active)::text from made), '(pro,30,,0,t)', 'by default: pro for 30 days, any number of accounts');
select lives_ok($$ select admin_api.create_promo(days => 7, max_uses => 1, note => 'one tester', code => ' friends-7 ') $$, 'a chosen code with its own length and limit');
select is((select row(code, days, max_uses, note)::text from admin_api.promo_codes where code = 'FRIENDS-7'), '(FRIENDS-7,7,1,"one tester")', 'the code is stored in capitals');
select throws_ok($$ select admin_api.create_promo(code => 'friends-7') $$, 'P0001', 'this code already exists', 'the same code twice is refused');
select throws_ok($$ select admin_api.create_promo(code => 'a b') $$, 'P0001', 'a code is 4 to 32 letters, digits or dashes', 'a code with a space is refused');
select throws_ok($$ select admin_api.create_promo(plan => 'gold') $$, 'P0001', 'no such plan', 'an unknown plan is refused');
select throws_ok($$ select admin_api.create_promo(days => 0) $$, 'P0001', 'days must be 1 to 366', 'zero days is refused');
select lives_ok($$ select admin_api.create_promo(code => 'OLD-CODE', expires_at => now() - interval '1 day') $$, 'a code that can no longer be entered');
select is((select active from admin_api.promo_codes where code = 'OLD-CODE'), false, 'it is shown as not active');
reset role;

-- a tester enters a code
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated","is_anonymous":true}', true);
set local role authenticated;
select is(api.me()->>'plan', 'free', 'the tester starts on the free plan');
select throws_ok($$ select api.redeem_promo('nope-0000') $$, 'PT404', 'no such code', 'an unknown code is refused');
select throws_ok($$ select api.redeem_promo('old-code') $$, 'PT409', 'this code is no longer valid', 'a code past its date is refused');
create temp table mine as select api.redeem_promo('  friends-7 ') as me;
select is((select me->>'plan' from mine), 'pro', 'the code gives the plan at once, whatever the capitals and spaces');
select is((select me->'limits' from mine), '{"posts_month":150,"images_month":300,"images_per_post":3}'::jsonb, 'with the plan''s limits');
select ok((select (me->>'plan_until')::timestamptz between now() + interval '6 days 23 hours' and now() + interval '7 days 1 hour' from mine), 'for the number of days of the code');
select throws_ok($$ select api.redeem_promo('FRIENDS-7') $$, 'PT409', 'this account already used the code', 'the same account cannot enter it twice');
reset role;

-- a second tester: the code was for one account
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a6","role":"authenticated","is_anonymous":true}', true);
set local role authenticated;
create temp table second as select api.me() as me;
select throws_ok($$ select api.redeem_promo('FRIENDS-7') $$, 'PT409', 'this code was used by everyone it was made for', 'one account only');
reset role;

-- the month ends: the account is free again without anything running
update private.accounts set plan_until = now() - interval '1 minute' where id = '00000000-0000-0000-0000-0000000000a5';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a5","role":"authenticated","is_anonymous":true}', true);
set local role authenticated;
select is(api.me()->>'plan', 'free', 'after the end the account is free again');
select is(api.me()->'limits'->>'posts_month', '12', 'with the free limits');
select is(api.me()->>'plan_until', null, 'and no end date is shown');
reset role;

-- the owner stops a code, and a plan set by hand is not replaced by a promo
select set_config('request.jwt.claims', json_build_object('role', 'bc_admin')::text, true);
set local role bc_admin;
select is((select active from admin_api.set_promo_disabled((select code from made), true)), false, 'a stopped code is not active');
select is((select row(plan, plan_until)::text from admin_api.set_quota('00000000-0000-0000-0000-0000000000a6', plan => 'team')), '(team,)', 'a plan set by hand has no end');
reset role;
update private.promo_codes set disabled = false;
select set_config('test.made', (select code from made), true);
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a6","role":"authenticated","is_anonymous":true}', true);
set local role authenticated;
select throws_ok($$ select api.redeem_promo(current_setting('test.made')) $$, 'PT409', 'this account already has a plan', 'an account with its own plan keeps it');

select * from finish();
rollback;
