begin;

-- =========================================================
-- 001: Extensions and foundational schemas
-- Well Management Platform
-- =========================================================

-- Supabase convention: third-party PostgreSQL extensions live here.
create schema if not exists extensions;

-- UUID generation and cryptographic helpers.
create extension if not exists pgcrypto
with schema extensions;

-- Case-insensitive text, useful for emails and normalized identifiers.
create extension if not exists citext
with schema extensions;

-- Required later for exclusion constraints and historical date ranges.
create extension if not exists btree_gist
with schema extensions;

-- Efficient similarity and partial-text searching.
create extension if not exists pg_trgm
with schema extensions;

-- =========================================================
-- Application schemas
-- =========================================================

create schema if not exists iam;
create schema if not exists core;
create schema if not exists ops;
create schema if not exists inventory;
create schema if not exists billing;
create schema if not exists finance;
create schema if not exists audit;
create schema if not exists sync;
create schema if not exists reporting;

comment on schema iam is
  'Users, memberships, roles, permissions, and authentication links.';

comment on schema core is
  'Tenants, people, locations, wells, lands, and shared master data.';

comment on schema ops is
  'Irrigation turns, operating sessions, shifts, pauses, and resource usage.';

comment on schema inventory is
  'Fuel tanks, fuel movements, stock balances, and inventory valuation.';

comment on schema billing is
  'Rates, invoices, invoice lines, charges, debts, and customer balances.';

comment on schema finance is
  'Cashboxes, receipts, payments, expenses, journals, and partner settlements.';

comment on schema audit is
  'Immutable audit events, corrections, reversals, and sensitive activity logs.';

comment on schema sync is
  'Offline synchronization metadata, idempotency, and conflict handling.';

comment on schema reporting is
  'Reporting views, aggregates, and read-optimized database objects.';

-- =========================================================
-- Shared trigger functions
-- =========================================================

create or replace function core.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog
as $function$
begin
  new.updated_at := now();
  return new;
end;
$function$;

comment on function core.set_updated_at() is
  'Sets the updated_at column automatically before an update.';

create or replace function audit.prevent_hard_delete()
returns trigger
language plpgsql
security invoker
set search_path = pg_catalog
as $function$
begin
  raise exception
    using
      errcode = 'P0001',
      message = format(
        'Hard deletion is not allowed on %I.%I',
        tg_table_schema,
        tg_table_name
      ),
      hint = 'Use a reversal, correction, cancellation, or archival operation instead.';
end;
$function$;

comment on function audit.prevent_hard_delete() is
  'Reusable trigger function that blocks hard deletion from protected tables.';

commit;
