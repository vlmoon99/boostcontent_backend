#!/bin/bash
# Give a device that has just signed up as a new guest an OLDER account of this database.
# Why: the account is the device's refresh token. A phone that last talked to another server (the Sparks) has
# a token this database has never seen, so it is signed out and starts as a new guest, while its account,
# as this database last knew it, sits here unreachable. This moves the new guest's sign-in onto the old account.
#
#   deploy/mac/adopt.sh list                 # accounts, newest activity first
#   deploy/mac/adopt.sh <new-id> <old-id>    # the device signed in as <new-id> becomes <old-id>
#
# What it does, in one transaction: the new guest's sessions and refresh tokens are moved to the old account,
# and the new guest is deleted and marked as deleted. The device's current access token then answers 401,
# the app refreshes it, and the refreshed token is the old account's. Reopen the app afterwards.
# It refuses when the new account already owns a business (it is not "just signed up": nothing is thrown away
# silently) or when the old account does not exist. Only the owner of the server may decide whose phone gets
# which account: this is a way into an account without its token.
set -euo pipefail
sql() { docker exec -i "${DB_CONTAINER:-bc-db}" psql -X -U postgres -d boostcontent -v ON_ERROR_STOP=1 "$@"; }
uuid='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
case "${1:-}" in
  list)
    sql -c "select a.id, a.created_at::timestamp(0) as created, a.last_seen_at::timestamp(0) as last_seen,
              (select count(*) from private.businesses b where b.account_id = a.id) as projects,
              (select count(*) from private.posts p join private.businesses b on b.id = p.business_id
                where b.account_id = a.id) as posts,
              (select string_agg(left(coalesce(b.name, '?'), 24), ', ') from private.businesses b
                where b.account_id = a.id) as names
            from private.accounts a order by a.last_seen_at desc limit ${2:-20}" ;;
  *)
    new=${1:-}; old=${2:-}
    [[ "$new" =~ $uuid && "$old" =~ $uuid && "$new" != "$old" ]] || { echo "usage: $0 list | <new-id> <old-id>"; exit 1; }
    sql -q <<SQL
begin;
do \$\$
declare n uuid := '$new'; o uuid := '$old'; moved int;
begin
  if not exists (select 1 from auth.users where id = o) or not exists (select 1 from private.accounts where id = o) then
    raise exception 'the old account % does not exist here', o;
  end if;
  if exists (select 1 from private.deleted_accounts where id = o) then
    raise exception 'the old account % was deleted', o;
  end if;
  if not exists (select 1 from auth.users where id = n) then
    raise exception 'the new account % does not exist here', n;
  end if;
  if exists (select 1 from private.businesses where account_id = n) then
    raise exception 'the new account % already owns a project: it is not a fresh sign-up', n;
  end if;
  update auth.sessions set user_id = o where user_id = n;
  get diagnostics moved = row_count;
  if moved = 0 then
    raise exception 'the new account % has no session to move', n;
  end if;
  update auth.refresh_tokens set user_id = o::text where user_id = n::text;
  delete from private.accounts where id = n;
  delete from auth.users where id = n;
  insert into private.deleted_accounts (id) values (n) on conflict do nothing;
  raise notice 'moved % session(s): the device of % is now %', moved, n, o;
end \$\$;
commit;
SQL
    ;;
esac
