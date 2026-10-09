-- migrate:up
-- BoostContent core data. Tables live in `private` (never exposed); the client API is the `api` schema
-- (views + functions, see later migrations). Every row belongs to an account = a GoTrue user id.

create schema private;
create schema api;
grant usage on schema api to anon, authenticated;
grant usage on schema private to authenticated;

-- ---------- identity ----------
create function private.uid() returns uuid
language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
$$;

create function private.jwt_claim(k text) returns text
language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> k
$$;

-- ---------- settings (secrets + knobs; written by the deploy's configure step, read by definer functions) ----------
create table private.settings (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
revoke all on private.settings from public, authenticated;

create function private.setting(k text, fallback text default null) returns text
language sql stable security definer set search_path = private as $$
  select coalesce((select value from private.settings where key = k), fallback)
$$;
revoke all on function private.setting(text, text) from public;

-- ---------- plans + accounts + quota ----------
create table private.plans (
  id text primary key,
  images_month int not null check (images_month >= 0),
  posts_month int not null check (posts_month >= 0),
  images_per_post int not null default 3 check (images_per_post between 1 and 3),
  note text
);
insert into private.plans (id, images_month, posts_month, images_per_post, note)
values ('standard', 3000, 1000, 3, 'default for every account (owner, 2026-10-09)');

create table private.accounts (
  id uuid primary key,                       -- = auth.users.id (GoTrue)
  plan text not null default 'standard' references private.plans(id),
  images_month_override int check (images_month_override >= 0),
  posts_month_override int check (posts_month_override >= 0),
  is_anonymous boolean not null default true,
  blocked boolean not null default false,
  note text,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create table private.usage_monthly (
  account_id uuid not null references private.accounts(id) on delete cascade,
  month date not null,                       -- first day of the month, UTC
  images_used int not null default 0 check (images_used >= 0),
  posts_used int not null default 0 check (posts_used >= 0),
  primary key (account_id, month)
);

-- ---------- businesses, profile, media ----------
create table private.businesses (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references private.accounts(id) on delete cascade,
  name text not null check (length(name) between 1 and 120),
  description text not null default '' check (length(description) <= 4000),
  language text not null default 'uk' check (language in ('en', 'uk', 'ru')),
  timezone text not null default 'Europe/Kyiv',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index on private.businesses (account_id) where deleted_at is null;

-- The style profile, in structured English. `auto` = what the model found, `data` = what is used now
-- (the user may edit it; the edit is a training signal).
create table private.profiles (
  business_id uuid primary key references private.businesses(id) on delete cascade,
  account_id uuid not null references private.accounts(id) on delete cascade,
  status text not null default 'none' check (status in ('none', 'analyzing', 'ready', 'failed')),
  auto jsonb,
  data jsonb,
  edited boolean not null default false,
  error text,
  updated_at timestamptz not null default now()
);

create table private.media (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references private.accounts(id) on delete cascade,
  business_id uuid not null references private.businesses(id) on delete cascade,
  kind text not null check (kind in ('photo', 'generated')),
  object_key text not null unique,
  content_type text not null default 'image/png',
  status text not null default 'pending' check (status in ('pending', 'ready', 'failed')),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index on private.media (business_id, kind) where deleted_at is null;

-- ---------- posts ----------
create table private.posts (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references private.accounts(id) on delete cascade,
  business_id uuid not null references private.businesses(id) on delete cascade,
  batch_id uuid not null,                     -- one generate_posts() call
  status text not null default 'queued'
    check (status in ('queued', 'writing', 'rendering', 'ready', 'partial', 'failed')),
  language text not null check (language in ('en', 'uk', 'ru')),
  idea_en jsonb,                              -- structured English from the model (the training target)
  caption text,                               -- in the business language
  hashtags text[] not null default '{}',
  quota_month date not null,
  images_reserved int not null default 0,
  error text,
  created_at timestamptz not null default now(),
  ready_at timestamptz,
  deleted_at timestamptz
);
create index on private.posts (business_id, created_at desc) where deleted_at is null;
create index on private.posts (batch_id);

create table private.post_images (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references private.posts(id) on delete cascade,
  account_id uuid not null references private.accounts(id) on delete cascade,
  position int not null,
  prompt_en text not null,
  source_media_id uuid references private.media(id) on delete set null,
  media_id uuid references private.media(id) on delete set null,
  status text not null default 'queued' check (status in ('queued', 'rendering', 'ready', 'failed')),
  error text,
  unique (post_id, position)
);

-- ---------- the generation queue (driven by pg_cron + pg_net, see the engine migration) ----------
create table private.jobs (
  id bigserial primary key,
  kind text not null check (kind in ('profile', 'ideas', 'localize', 'image')),
  account_id uuid not null references private.accounts(id) on delete cascade,
  business_id uuid not null references private.businesses(id) on delete cascade,
  batch_id uuid,
  post_id uuid references private.posts(id) on delete cascade,
  post_image_id uuid references private.post_images(id) on delete cascade,
  status text not null default 'queued' check (status in ('queued', 'running', 'done', 'failed')),
  priority int not null default 0,
  attempts int not null default 0,
  max_attempts int not null default 3,
  request_id bigint,                          -- pg_net request id while running
  request jsonb,                              -- what was sent (also copied to gen_trace)
  context jsonb not null default '{}',        -- kind-specific bookkeeping (photo id map, …)
  not_before timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  error text,
  created_at timestamptz not null default now()
);
create index on private.jobs (status, priority desc, id) where status in ('queued', 'running');
create index on private.jobs (post_id);

-- ---------- fine-tuning data ----------
create table private.gen_trace (
  id bigserial primary key,
  account_id uuid not null references private.accounts(id) on delete cascade,
  business_id uuid references private.businesses(id) on delete cascade,
  post_id uuid references private.posts(id) on delete set null,
  job_id bigint references private.jobs(id) on delete set null,
  step text not null,                         -- profile | ideas | localize | image
  prompt_version text,
  model text,
  input jsonb,
  output_raw text,
  output jsonb,
  ok boolean not null,
  http_status int,
  latency_ms int,
  created_at timestamptz not null default now()
);
create index on private.gen_trace (step, created_at);

create table private.signals (
  id bigserial primary key,
  account_id uuid not null references private.accounts(id) on delete cascade,
  post_id uuid references private.posts(id) on delete cascade,
  business_id uuid references private.businesses(id) on delete cascade,
  kind text not null check (kind in ('copied', 'downloaded', 'edited', 'deleted', 'regenerated', 'profile_edited')),
  data jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index on private.signals (kind, created_at);

-- ---------- prompts (versioned; the version lands in every trace) ----------
create table private.prompts (
  key text primary key,
  version text not null,
  body text not null,
  updated_at timestamptz not null default now()
);

-- ---------- row level security: a user sees only their own rows ----------
do $$
declare t text;
begin
  foreach t in array array['accounts', 'usage_monthly', 'businesses', 'profiles', 'media', 'posts',
                           'post_images', 'signals']
  loop
    execute format('alter table private.%I enable row level security', t);
    execute format('grant select on private.%I to authenticated', t);
    execute format('create policy own_rows on private.%I for select to authenticated using (%s = private.uid())',
                   t, case t when 'accounts' then 'id' else 'account_id' end);
  end loop;
end $$;
alter table private.jobs enable row level security;          -- no policy: clients never see the queue
alter table private.gen_trace enable row level security;
alter table private.prompts enable row level security;
alter table private.plans enable row level security;
create policy read_plans on private.plans for select to authenticated using (true);
grant select on private.plans to authenticated;

-- migrate:down
drop schema api cascade;
drop schema private cascade;
