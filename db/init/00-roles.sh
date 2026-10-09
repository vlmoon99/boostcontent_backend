#!/bin/bash
# First boot only (docker-entrypoint-initdb.d). Roles + extensions + the schemas other services own.
# Passwords come from the environment, never from the repo.
set -euo pipefail
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
create extension if not exists pgcrypto;
create extension if not exists pg_net;
create extension if not exists pg_cron;
create extension if not exists vector;

-- PostgREST (public): logs in as authenticator, switches to anon or authenticated from the GoTrue JWT
create role anon nologin noinherit;
create role authenticated nologin noinherit;
create role service_role nologin noinherit bypassrls;
create role authenticator login noinherit password '${AUTHENTICATOR_PASSWORD}';
grant anon, authenticated, service_role to authenticator;

-- GoTrue: owns and migrates the auth schema
create role supabase_auth_admin login createrole noinherit password '${AUTH_DB_PASSWORD}';
create schema auth authorization supabase_auth_admin;
grant usage on schema auth to anon, authenticated, service_role;
alter role supabase_auth_admin set search_path = auth;

-- PostgREST (admin, tailnet only): its own login, its own roles
create role bc_admin_anon nologin noinherit;
create role bc_admin nologin noinherit bypassrls;
create role admin_authenticator login noinherit password '${ADMIN_AUTHENTICATOR_PASSWORD}';
grant bc_admin_anon, bc_admin to admin_authenticator;
SQL
