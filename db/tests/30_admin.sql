begin;
create extension if not exists pgtap;
select plan(6);
delete from private.admin_auth;      -- the test runs as if nobody set a password yet (rolled back)

set local role bc_admin_anon;
select is(admin_api.state()->>'setup_needed', 'true', 'fresh install: setup needed');
select throws_ok($$ select admin_api.setup('short') $$, 'P0001', 'password must be at least 10 characters', 'weak password refused');
select ok((admin_api.setup('correct horse battery')->>'token') like '%.%.%', 'first setup returns a JWT');
select throws_ok($$ select admin_api.setup('another password!') $$, '42501', 'password already set', 'a second setup is refused');
select ok((admin_api.login('correct horse battery')->>'token') is not null, 'login with the password works');
select throws_ok($$ select count(*) from admin_api.accounts $$, '42501', null, 'the anon admin role cannot read data');

select * from finish();
rollback;
