begin;

-- =========================================================
-- 002: Tenants and subscriptions
-- Well Management Platform
-- =========================================================

-- =========================================================
-- Tenants
-- Each customer organization or well-management business
-- receives one isolated tenant record.
-- =========================================================

create table core.tenants (
  id uuid primary key
    default extensions.gen_random_uuid(),

  code text not null,

  name text not null,

  legal_name text,

  lifecycle_status text not null
    default 'active',

  default_currency text not null
    default 'YER',

  default_locale text not null
    default 'ar',

  timezone text not null
    default 'Asia/Aden',

  metadata jsonb not null
    default '{}'::jsonb,

  created_at timestamptz not null
    default now(),

  updated_at timestamptz not null
    default now(),

  archived_at timestamptz,

  constraint tenants_code_format_check
    check (
      code = upper(code)
      and code ~ '^[A-Z0-9][A-Z0-9_-]{2,31}$'
    ),

  constraint tenants_name_not_blank_check
    check (btrim(name) <> ''),

  constraint tenants_legal_name_not_blank_check
    check (
      legal_name is null
      or btrim(legal_name) <> ''
    ),

  constraint tenants_lifecycle_status_check
    check (
      lifecycle_status in (
        'active',
        'suspended',
        'archived'
      )
    ),

  constraint tenants_default_currency_check
    check (
      default_currency ~ '^[A-Z]{3}$'
    ),

  constraint tenants_default_locale_check
    check (
      btrim(default_locale) <> ''
      and char_length(default_locale) <= 16
    ),

  constraint tenants_timezone_not_blank_check
    check (btrim(timezone) <> ''),

  constraint tenants_metadata_object_check
    check (
      jsonb_typeof(metadata) = 'object'
    )
);

create unique index tenants_code_unique_idx
  on core.tenants (code);

create index tenants_lifecycle_status_idx
  on core.tenants (lifecycle_status);

comment on table core.tenants is
  'Top-level customer organizations used for strict multi-tenant data isolation.';

comment on column core.tenants.code is
  'Stable human-readable tenant code using English letters and digits.';

comment on column core.tenants.lifecycle_status is
  'Operational tenant status, separate from subscription status.';

comment on column core.tenants.default_currency is
  'ISO-style currency code. The initial product currency is YER.';

comment on column core.tenants.timezone is
  'IANA timezone used when presenting dates and operational reports.';

create trigger tenants_set_updated_at
before update on core.tenants
for each row
execute function core.set_updated_at();

create trigger tenants_prevent_hard_delete
before delete on core.tenants
for each row
execute function audit.prevent_hard_delete();

-- =========================================================
-- Subscription plans
-- Global commercial plans managed by the platform owner.
-- =========================================================

create table billing.subscription_plans (
  id uuid primary key
    default extensions.gen_random_uuid(),

  code text not null,

  name text not null,

  description text,

  billing_interval text not null
    default 'monthly',

  price_minor bigint not null
    default 0,

  currency text not null
    default 'YER',

  trial_days smallint not null
    default 0,

  is_active boolean not null
    default true,

  features jsonb not null
    default '{}'::jsonb,

  limits jsonb not null
    default '{}'::jsonb,

  created_at timestamptz not null
    default now(),

  updated_at timestamptz not null
    default now(),

  constraint subscription_plans_code_format_check
    check (
      code = upper(code)
      and code ~ '^[A-Z0-9][A-Z0-9_-]{2,31}$'
    ),

  constraint subscription_plans_name_not_blank_check
    check (btrim(name) <> ''),

  constraint subscription_plans_billing_interval_check
    check (
      billing_interval in (
        'monthly',
        'annual',
        'one_time',
        'custom'
      )
    ),

  constraint subscription_plans_price_minor_check
    check (price_minor >= 0),

  constraint subscription_plans_currency_check
    check (currency ~ '^[A-Z]{3}$'),

  constraint subscription_plans_trial_days_check
    check (
      trial_days >= 0
      and trial_days <= 365
    ),

  constraint subscription_plans_features_object_check
    check (
      jsonb_typeof(features) = 'object'
    ),

  constraint subscription_plans_limits_object_check
    check (
      jsonb_typeof(limits) = 'object'
    )
);

create unique index subscription_plans_code_unique_idx
  on billing.subscription_plans (code);

create index subscription_plans_active_idx
  on billing.subscription_plans (is_active);

comment on table billing.subscription_plans is
  'Commercial subscription plans and their feature or usage limits.';

comment on column billing.subscription_plans.price_minor is
  'Price stored as an integer in the smallest supported currency unit.';

comment on column billing.subscription_plans.features is
  'Feature entitlement configuration stored as a JSON object.';

comment on column billing.subscription_plans.limits is
  'Usage limits such as users, wells, storage, or reports.';

create trigger subscription_plans_set_updated_at
before update on billing.subscription_plans
for each row
execute function core.set_updated_at();

create trigger subscription_plans_prevent_hard_delete
before delete on billing.subscription_plans
for each row
execute function audit.prevent_hard_delete();

-- =========================================================
-- Tenant subscriptions
-- Historical records are retained. Only one current
-- subscription may exist for a tenant at the same time.
-- =========================================================

create table billing.tenant_subscriptions (
  id uuid primary key
    default extensions.gen_random_uuid(),

  tenant_id uuid not null,

  plan_id uuid not null,

  status text not null
    default 'trialing',

  provider text not null
    default 'manual',

  provider_customer_id text,

  provider_subscription_id text,

  starts_at timestamptz not null
    default now(),

  trial_ends_at timestamptz,

  current_period_start timestamptz,

  current_period_end timestamptz,

  cancel_at_period_end boolean not null
    default false,

  canceled_at timestamptz,

  ended_at timestamptz,

  metadata jsonb not null
    default '{}'::jsonb,

  created_at timestamptz not null
    default now(),

  updated_at timestamptz not null
    default now(),

  constraint tenant_subscriptions_tenant_fk
    foreign key (tenant_id)
    references core.tenants (id),

  constraint tenant_subscriptions_plan_fk
    foreign key (plan_id)
    references billing.subscription_plans (id),

  constraint tenant_subscriptions_status_check
    check (
      status in (
        'trialing',
        'active',
        'grace_period',
        'past_due',
        'suspended',
        'canceled',
        'expired'
      )
    ),

  constraint tenant_subscriptions_provider_not_blank_check
    check (btrim(provider) <> ''),

  constraint tenant_subscriptions_provider_customer_not_blank_check
    check (
      provider_customer_id is null
      or btrim(provider_customer_id) <> ''
    ),

  constraint tenant_subscriptions_provider_subscription_not_blank_check
    check (
      provider_subscription_id is null
      or btrim(provider_subscription_id) <> ''
    ),

  constraint tenant_subscriptions_trial_period_check
    check (
      trial_ends_at is null
      or trial_ends_at >= starts_at
    ),

  constraint tenant_subscriptions_current_period_check
    check (
      current_period_start is null
      or current_period_end is null
      or current_period_end > current_period_start
    ),

  constraint tenant_subscriptions_canceled_at_check
    check (
      canceled_at is null
      or canceled_at >= starts_at
    ),

  constraint tenant_subscriptions_ended_at_check
    check (
      ended_at is null
      or ended_at >= starts_at
    ),

  constraint tenant_subscriptions_metadata_object_check
    check (
      jsonb_typeof(metadata) = 'object'
    ),

  constraint tenant_subscriptions_id_tenant_unique
    unique (id, tenant_id)
);

create unique index tenant_subscriptions_one_current_idx
  on billing.tenant_subscriptions (tenant_id)
  where status in (
    'trialing',
    'active',
    'grace_period',
    'past_due',
    'suspended'
  );

create unique index tenant_subscriptions_provider_reference_idx
  on billing.tenant_subscriptions (
    provider,
    provider_subscription_id
  )
  where provider_subscription_id is not null;

create index tenant_subscriptions_tenant_history_idx
  on billing.tenant_subscriptions (
    tenant_id,
    starts_at desc
  );

create index tenant_subscriptions_plan_idx
  on billing.tenant_subscriptions (plan_id);

create index tenant_subscriptions_status_idx
  on billing.tenant_subscriptions (status);

comment on table billing.tenant_subscriptions is
  'Effective and historical subscription records for each tenant.';

comment on column billing.tenant_subscriptions.status is
  'Commercial subscription state; customer data is retained after expiration.';

comment on column billing.tenant_subscriptions.provider is
  'Subscription source such as manual administration or Google Play Billing.';

create trigger tenant_subscriptions_set_updated_at
before update on billing.tenant_subscriptions
for each row
execute function core.set_updated_at();

create trigger tenant_subscriptions_prevent_hard_delete
before delete on billing.tenant_subscriptions
for each row
execute function audit.prevent_hard_delete();

-- =========================================================
-- Immutable subscription event log
-- =========================================================

create table billing.subscription_events (
  id uuid primary key
    default extensions.gen_random_uuid(),

  tenant_id uuid not null,

  subscription_id uuid not null,

  event_type text not null,

  source text not null
    default 'system',

  external_event_id text,

  idempotency_key text,

  occurred_at timestamptz not null
    default now(),

  effective_at timestamptz,

  payload jsonb not null
    default '{}'::jsonb,

  recorded_at timestamptz not null
    default now(),

  constraint subscription_events_subscription_tenant_fk
    foreign key (subscription_id, tenant_id)
    references billing.tenant_subscriptions (id, tenant_id),

  constraint subscription_events_event_type_not_blank_check
    check (btrim(event_type) <> ''),

  constraint subscription_events_source_not_blank_check
    check (btrim(source) <> ''),

  constraint subscription_events_external_event_not_blank_check
    check (
      external_event_id is null
      or btrim(external_event_id) <> ''
    ),

  constraint subscription_events_idempotency_not_blank_check
    check (
      idempotency_key is null
      or btrim(idempotency_key) <> ''
    ),

  constraint subscription_events_payload_object_check
    check (
      jsonb_typeof(payload) = 'object'
    )
);

create unique index subscription_events_external_reference_idx
  on billing.subscription_events (
    source,
    external_event_id
  )
  where external_event_id is not null;

create unique index subscription_events_idempotency_key_idx
  on billing.subscription_events (idempotency_key)
  where idempotency_key is not null;

create index subscription_events_subscription_time_idx
  on billing.subscription_events (
    subscription_id,
    occurred_at desc
  );

create index subscription_events_tenant_time_idx
  on billing.subscription_events (
    tenant_id,
    occurred_at desc
  );

comment on table billing.subscription_events is
  'Append-only event history for subscription lifecycle and provider notifications.';

-- Subscription events must remain immutable.
create or replace function audit.prevent_row_mutation()
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
        'Mutation is not allowed on immutable table %I.%I',
        tg_table_schema,
        tg_table_name
      ),
      hint = 'Insert a new event instead of updating or deleting an existing event.';
end;
$function$;

comment on function audit.prevent_row_mutation() is
  'Blocks both updates and deletions on immutable append-only tables.';

create trigger subscription_events_prevent_mutation
before update or delete on billing.subscription_events
for each row
execute function audit.prevent_row_mutation();

-- =========================================================
-- Row Level Security
-- Policies will be added after users and memberships exist.
-- Until then, API clients receive no access to these tables.
-- =========================================================

alter table core.tenants
  enable row level security;

alter table billing.subscription_plans
  enable row level security;

alter table billing.tenant_subscriptions
  enable row level security;

alter table billing.subscription_events
  enable row level security;

commit;
