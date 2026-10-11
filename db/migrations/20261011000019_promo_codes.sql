-- migrate:up
-- Promo codes: the owner hands a code to a tester, the tester types it in the app and gets a plan (pro by
-- default) for a number of days (30 by default) without paying. The owner makes and stops codes in the admin
-- console; each code can be limited in how many accounts may use it and until when it can be entered.
--
-- A plan can now end: accounts.plan_until. After that moment the account counts as `free` again without
-- anything having to run (private.plan_of). A plan the owner sets by hand in the console has no end.
alter table private.accounts add column plan_until timestamptz;

create function private.plan_of(a private.accounts) returns text
language sql stable as $$
  select case when a.plan_until is not null and a.plan_until <= now() then 'free' else a.plan end
$$;

create or replace function private.limits(acc uuid, out images_month integer, out posts_month integer, out images_per_post integer)
returns record language sql stable security definer set search_path = private as $$
  select coalesce(a.images_month_override, p.images_month), coalesce(a.posts_month_override, p.posts_month),
         p.images_per_post
  from private.accounts a join private.plans p on p.id = private.plan_of(a) where a.id = acc
$$;

do $$
declare
  def text := pg_get_functiondef('api.me()'::regprocedure);
  old text := '''plan'', a.plan,';
  new text := '''plan'', private.plan_of(a),
    ''plan_until'', case when a.plan_until > now() then a.plan_until end,';
begin
  if position(old in def) = 0 then
    raise exception 'api.me() does not look as expected: not patched';
  end if;
  execute replace(def, old, new);
end $$;

create table private.promo_codes (
  code text primary key check (code ~ '^[A-Z0-9-]{4,32}$'),
  plan text not null default 'pro' references private.plans(id),
  days int not null default 30 check (days between 1 and 366),
  max_uses int check (max_uses is null or max_uses >= 1),      -- null: any number of accounts
  expires_at timestamptz,                                       -- null: can be entered at any time
  disabled boolean not null default false,
  note text,
  created_at timestamptz not null default now()
);
create table private.promo_redemptions (
  code text not null references private.promo_codes(code) on delete cascade,
  account_id uuid not null references private.accounts(id) on delete cascade,
  plan text not null,
  plan_until timestamptz not null,
  redeemed_at timestamptz not null default now(),
  primary key (code, account_id)
);
alter table private.promo_codes enable row level security;
alter table private.promo_redemptions enable row level security;

-- The app: enter a code. Answers like me(), so the app shows the new plan at once.
create function api.redeem_promo(code text) returns jsonb
language plpgsql security definer set search_path = private as $$
declare
  acc uuid := private.current_account();
  wanted text := upper(btrim(coalesce(redeem_promo.code, '')));
  p private.promo_codes;
  a private.accounts;
  now_plan text;
  until timestamptz;
begin
  select * into p from private.promo_codes c where c.code = wanted for update;
  if not found then
    raise exception 'no such code' using errcode = 'PT404', detail = 'promo_not_found';
  end if;
  if p.disabled or (p.expires_at is not null and p.expires_at <= now()) then
    raise exception 'this code is no longer valid' using errcode = 'PT409', detail = 'promo_expired';
  end if;
  if exists (select 1 from private.promo_redemptions r where r.code = p.code and r.account_id = acc) then
    raise exception 'this account already used the code' using errcode = 'PT409', detail = 'promo_already_used';
  end if;
  if p.max_uses is not null and (select count(*) from private.promo_redemptions r where r.code = p.code) >= p.max_uses then
    raise exception 'this code was used by everyone it was made for' using errcode = 'PT409', detail = 'promo_used_up';
  end if;
  select * into a from private.accounts where id = acc for update;
  now_plan := private.plan_of(a);
  -- a plan without an end (the owner's own, or one that was bought) is not replaced by a month of a promo
  if now_plan <> 'free' and (now_plan <> p.plan or a.plan_until is null) then
    raise exception 'this account already has a plan' using errcode = 'PT409', detail = 'promo_not_needed';
  end if;
  until := (case when now_plan = p.plan then a.plan_until else now() end) + make_interval(days => p.days);
  update private.accounts set plan = p.plan, plan_until = until where id = acc;
  insert into private.promo_redemptions (code, account_id, plan, plan_until) values (p.code, acc, p.plan, until);
  return api.me();
end $$;
revoke all on function api.redeem_promo(text) from public;
grant execute on function api.redeem_promo(text) to authenticated;

-- ---------- the owner's console ----------
create view admin_api.promo_codes as
  select c.code, c.plan, c.days, c.max_uses, c.expires_at, c.disabled, c.note, c.created_at,
         (select count(*) from private.promo_redemptions r where r.code = c.code) as used,
         (not c.disabled and (c.expires_at is null or c.expires_at > now())
          and (c.max_uses is null or (select count(*) from private.promo_redemptions r where r.code = c.code) < c.max_uses)) as active
  from private.promo_codes c;

create view admin_api.promo_redemptions as
  select r.code, r.account_id, r.plan, r.plan_until, r.redeemed_at from private.promo_redemptions r;

create or replace view admin_api.accounts as
  select a.id, a.created_at, a.last_seen_at, a.is_anonymous, a.blocked, a.plan, a.note,
         l.images_month, l.posts_month, l.images_per_post,
         a.images_month_override, a.posts_month_override,
         coalesce(u.images_used, 0) as images_used_month, coalesce(u.posts_used, 0) as posts_used_month,
         (select count(*) from private.businesses b where b.account_id = a.id and b.deleted_at is null) as businesses,
         (select count(*) from private.posts p where p.account_id = a.id and p.deleted_at is null) as posts_total,
         a.plan_until, private.plan_of(a) as plan_now
  from private.accounts a
  cross join lateral private.limits(a.id) l
  left join private.usage_monthly u on u.account_id = a.id and u.month = private.month_start();

-- A new code. Without `code` one is made up (BOOST-XXXXXXXX). Letters are stored in capitals.
create function admin_api.create_promo(plan text default 'pro', days int default 30, max_uses int default null,
                                       expires_at timestamptz default null, note text default null, code text default null)
returns setof admin_api.promo_codes
language plpgsql security definer set search_path = private as $$
declare
  c text := upper(btrim(coalesce(create_promo.code, '')));
begin
  if c = '' then
    c := 'BOOST-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  end if;
  if c !~ '^[A-Z0-9-]{4,32}$' then
    raise exception 'a code is 4 to 32 letters, digits or dashes' using errcode = 'P0001';
  end if;
  if not exists (select 1 from private.plans p where p.id = create_promo.plan) then
    raise exception 'no such plan' using errcode = 'P0001';
  end if;
  if create_promo.days is null or create_promo.days not between 1 and 366 then
    raise exception 'days must be 1 to 366' using errcode = 'P0001';
  end if;
  if create_promo.max_uses is not null and create_promo.max_uses < 1 then
    raise exception 'max uses must be at least 1, or empty for no limit' using errcode = 'P0001';
  end if;
  if exists (select 1 from private.promo_codes x where x.code = c) then
    raise exception 'this code already exists' using errcode = 'P0001';
  end if;
  insert into private.promo_codes (code, plan, days, max_uses, expires_at, note)
  values (c, create_promo.plan, create_promo.days, create_promo.max_uses, create_promo.expires_at, nullif(btrim(create_promo.note), ''));
  return query select * from admin_api.promo_codes x where x.code = c;
end $$;

-- Stop a code (nobody new can enter it; those who did keep their month) or let it work again.
create function admin_api.set_promo_disabled(code text, disabled boolean) returns setof admin_api.promo_codes
language plpgsql security definer set search_path = private as $$
begin
  update private.promo_codes c set disabled = set_promo_disabled.disabled where c.code = upper(btrim(set_promo_disabled.code));
  if not found then raise exception 'code not found' using errcode = 'P0002'; end if;
  return query select * from admin_api.promo_codes x where x.code = upper(btrim(set_promo_disabled.code));
end $$;

-- A plan the owner sets by hand has no end.
create or replace function admin_api.set_quota(account_id uuid, images_month int default null, posts_month int default null,
                                               plan text default null) returns setof admin_api.accounts
language plpgsql security definer set search_path = private as $$
begin
  update private.accounts a set
    images_month_override = set_quota.images_month,
    posts_month_override = set_quota.posts_month,
    plan = coalesce(set_quota.plan, a.plan),
    plan_until = case when set_quota.plan is null then a.plan_until end
  where a.id = set_quota.account_id;
  if not found then raise exception 'account not found' using errcode = 'P0002'; end if;
  return query select * from admin_api.accounts where id = set_quota.account_id;
end $$;

revoke execute on function admin_api.create_promo(text, int, int, timestamptz, text, text),
  admin_api.set_promo_disabled(text, boolean) from public;
grant execute on function admin_api.create_promo(text, int, int, timestamptz, text, text),
  admin_api.set_promo_disabled(text, boolean) to bc_admin;
grant select on admin_api.promo_codes, admin_api.promo_redemptions, admin_api.accounts to bc_admin;

-- migrate:down
drop function admin_api.set_promo_disabled(text, boolean);
drop function admin_api.create_promo(text, int, int, timestamptz, text, text);
drop view admin_api.promo_redemptions;
drop view admin_api.promo_codes;
drop function api.redeem_promo(text);
drop table private.promo_redemptions;
drop table private.promo_codes;
do $$
begin
  execute replace(pg_get_functiondef('api.me()'::regprocedure), '''plan'', private.plan_of(a),
    ''plan_until'', case when a.plan_until > now() then a.plan_until end,', '''plan'', a.plan,');
end $$;
create or replace function private.limits(acc uuid, out images_month integer, out posts_month integer, out images_per_post integer)
returns record language sql stable security definer set search_path = private as $$
  select coalesce(a.images_month_override, p.images_month), coalesce(a.posts_month_override, p.posts_month),
         p.images_per_post
  from private.accounts a join private.plans p on p.id = a.plan where a.id = acc
$$;
drop view admin_api.accounts;
create view admin_api.accounts as
  select a.id, a.created_at, a.last_seen_at, a.is_anonymous, a.blocked, a.plan, a.note,
         l.images_month, l.posts_month, l.images_per_post,
         a.images_month_override, a.posts_month_override,
         coalesce(u.images_used, 0) as images_used_month, coalesce(u.posts_used, 0) as posts_used_month,
         (select count(*) from private.businesses b where b.account_id = a.id and b.deleted_at is null) as businesses,
         (select count(*) from private.posts p where p.account_id = a.id and p.deleted_at is null) as posts_total
  from private.accounts a
  cross join lateral private.limits(a.id) l
  left join private.usage_monthly u on u.account_id = a.id and u.month = private.month_start();
grant select on admin_api.accounts to bc_admin;
create or replace function admin_api.set_quota(account_id uuid, images_month int default null, posts_month int default null,
                                               plan text default null) returns setof admin_api.accounts
language plpgsql security definer set search_path = private as $$
begin
  update private.accounts a set
    images_month_override = set_quota.images_month,
    posts_month_override = set_quota.posts_month,
    plan = coalesce(set_quota.plan, a.plan)
  where a.id = set_quota.account_id;
  if not found then raise exception 'account not found' using errcode = 'P0002'; end if;
  return query select * from admin_api.accounts where id = set_quota.account_id;
end $$;
drop function private.plan_of(private.accounts);
alter table private.accounts drop column plan_until;
