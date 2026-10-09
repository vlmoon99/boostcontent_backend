begin;
create extension if not exists pgtap;
select plan(8);
delete from private.admin_auth;      -- the test runs as if nobody set a password yet (rolled back)

set local role bc_admin_anon;
select is(admin_api.state()->>'setup_needed', 'true', 'fresh install: setup needed');
select throws_ok($$ select admin_api.setup('short') $$, 'P0001', 'password must be at least 10 characters', 'weak password refused');
select ok((admin_api.setup('correct horse battery')->>'token') like '%.%.%', 'first setup returns a JWT');
select throws_ok($$ select admin_api.setup('another password!') $$, '42501', 'password already set', 'a second setup is refused');
select ok((admin_api.login('correct horse battery')->>'token') is not null, 'login with the password works');
select throws_ok($$ select count(*) from admin_api.accounts $$, '42501', null, 'the anon admin role cannot read data');

reset role;
select set_config('request.jwt.claims', json_build_object('role', 'bc_admin',
  'pv', (select (extract(epoch from set_at) * 1000)::bigint from private.admin_auth))::text, true);
select lives_ok($$ select private.admin_pre_request() $$, 'a token from the current password passes');
select set_config('request.jwt.claims', '{"role":"bc_admin","pv":1}', true);
select throws_ok($$ select private.admin_pre_request() $$, '28000', 'session expired, log in again', 'a token from an older password is refused');

select * from finish();
rollback;
