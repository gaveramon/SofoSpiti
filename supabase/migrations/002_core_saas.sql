-- ============================================================
-- REV23 GREENFIELD BASELINE
-- 002_core_saas.sql
--
-- Consolidated Core SaaS SSOT
--
-- REV23 (SSOT split 002 <-> 012):
--   002 owns the PLAN (subscription type) and the SUBSCRIPTION
--   INSTANCE: which plan a tenant has, its status, its term and
--   its lifecycle (trial expiry, end-of-month cancellation).
--   012 owns everything that has a PRICE: plan prices, discount
--   policy, customer-account discount tiers, applied-discount
--   history, invoices.
--   002 never stores a price or a discount; 012 never stores
--   plan identity or subscription state.
--
-- ============================================================
-- ARCHITECTURAL RULES
-- ============================================================
--
-- This migration defines the CORE SaaS SSOT.
--
-- Core SSOT entities:
--
--   public.customer_accounts
--   public.tenants
--   public.tenant_memberships
--   public.service_accounts
--   public.product_plans        (plan / subscription type)
--   public.subscriptions        (subscription instance)
--
-- Customer-account model:
--
--   One customer account represents the commercial owner/account
--   under which one or more tenants can exist.
--
--   customer_accounts.owner_user_id
--          |
--          +---- tenant A
--          +---- tenant B
--          +---- tenant C
--
-- The customer-account owner is NOT a tenant membership role.
--
-- Tenant membership remains responsible for access to an
-- individual tenant:
--
--   tenant_memberships.role
--
-- Therefore the same user can be:
--
--   Owner   in tenant A
--   Manager in tenant B
--   Viewer  in tenant C
--
-- while still being the owner of the customer account containing
-- all three tenants.
--
-- This distinction is intentional:
--
--   CUSTOMER ACCOUNT
--       = commercial ownership / account ownership
--
--   TENANT MEMBERSHIP
--       = access / role inside a tenant
--
--
-- Current tenant resolution authority:
--
--   public.resolve_active_tenant(...)
--
-- Membership state remains authoritative in:
--
--   public.tenant_memberships
--
-- Tenant state remains authoritative in:
--
--   public.tenants
--
-- Customer-account ownership remains authoritative in:
--
--   public.customer_accounts.owner_user_id
--
--
-- IMPORTANT:
--
-- "resolve_active_tenant()" is the sole authority for determining
-- the CURRENT tenant context.
--
-- This does NOT mean that every membership query in the system
-- must be routed through the resolver. Listing, administration,
-- lifecycle management and auditing may legitimately read
-- tenant_memberships directly.
--
-- What is forbidden architecturally is creating another mechanism
-- that independently determines the current tenant.
--
-- auth.users.raw_app_meta_data.tenant_id is therefore NOT an
-- authoritative tenant SSOT.
--
--
-- RLS, policies, grants and security-hardening are intentionally
-- NOT implemented here. Those belong to the dedicated security
-- migrations.
--
-- This migration must not introduce a second source of truth for
-- core business state.
-- ============================================================


-- =====================================================
-- 1. CUSTOMER ACCOUNTS
-- =====================================================
--
-- A customer account represents the commercial owner of one or
-- more tenants.
--
-- This is deliberately NOT the same thing as a tenant.
--
-- A customer may therefore have:
--
--   Customer Account A
--       ├── Tenant A
--       ├── Tenant B
--       └── Tenant C
--
-- The owner_user_id identifies the user who owns/manages the
-- customer account.
--
-- This relationship is used by CRM and Commerce later for:
--
--   - customer ownership
--   - grouping tenants under one customer
--   - subscription aggregation
--   - multi-tenant pricing
--   - volume discounts
--
-- Commerce remains responsible for determining prices.
-- 002 only stores the authoritative account ownership.
--
-- One user owns one core customer account.
--
-- This prevents the same user from accidentally creating multiple
-- commercial identities and thereby circumventing future
-- multi-tenant pricing rules.
-- =====================================================

create table if not exists public.customer_accounts (
    id uuid primary key default gen_random_uuid(),

    owner_user_id uuid not null
        references platform.profiles(id)
        on delete restrict,

    name text not null,

    status text not null default 'active',

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    -- One platform user represents one commercial customer account.
    --
    -- This is deliberately an ownership constraint, not a
    -- membership constraint.
    unique (owner_user_id)
);


-- =====================================================
-- 2. TENANTS (CORE MULTI-TENANCY ENTITY)
-- =====================================================

create table if not exists public.tenants (
    id uuid primary key default gen_random_uuid(),

    -- Every tenant belongs to exactly one customer account.
    --
    -- This is the core commercial ownership relationship.
    --
    -- tenant_memberships remain the authority for access to
    -- the tenant itself.
    customer_account_id uuid not null
        references public.customer_accounts(id)
        on delete restrict,

    name text not null,

    -- Core lifecycle state must never be NULL.
    -- NULL would create a third/undefined state outside the
    -- tenant_status enum.
    status public.tenant_status not null default 'active',

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now()
);


-- =====================================================
-- 3. TENANT MEMBERSHIPS (ACCESS CONTROL LAYER)
-- user_id → platform.profiles
-- =====================================================

create table if not exists public.tenant_memberships (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    user_id uuid not null
        references platform.profiles(id)
        on delete cascade,

    role membership_role not null,

    is_active boolean not null default true,

    revoked_at timestamptz,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    -- One membership record per user/tenant.
    --
    -- This does NOT prevent a user from belonging to multiple
    -- tenants.
    --
    -- It only prevents duplicate membership rows for the same
    -- user inside the same tenant.
    --
    -- Therefore:
    --
    --   User A → Tenant 1 → Owner
    --   User A → Tenant 2 → Manager
    --   User A → Tenant 3 → Viewer
    --
    -- is fully valid.
    unique (tenant_id, user_id)
);


-- =====================================================
-- 4. SERVICE ACCOUNTS (SYSTEM INTEGRATIONS)
-- =====================================================

create table if not exists public.service_accounts (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    name text not null,

    provider_code text,

    is_active boolean not null default true,

    created_at timestamptz not null default now()
);


-- =====================================================
-- 4B. PRODUCT PLANS (PLAN / SUBSCRIPTION TYPE)
-- =====================================================
--
-- A plan is the TYPE of subscription a tenant can have:
-- name, tier, whether it is sellable and which plan is the
-- default for new tenants.
--
-- What a plan COSTS (plan_pricing), which features it grants
-- (feature_entitlements) and upsell rules belong to Commerce
-- (012) and reference this table. 002 does not know prices.
--
-- This is NOT a physical product catalog.
-- =====================================================

create table if not exists public.product_plans (
    id uuid primary key default gen_random_uuid(),

    name text not null,

    description text,

    tier public.subscription_tier not null,

    is_active boolean not null default true,

    is_default boolean not null default false,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    constraint chk_product_plans_name_nonempty
        check (btrim(name) <> '')
);


-- =====================================================
-- 5. SUBSCRIPTIONS (SUBSCRIPTION INSTANCE)
-- =====================================================
--
-- Subscription ownership remains tenant-based.
--
-- Customer-account ownership is deliberately NOT duplicated
-- here.
--
-- The relationship is:
--
--   customer_account
--       |
--   tenant
--       |
--   subscription  --> product_plans (which plan)
--
-- A subscription row is the INSTANCE: which plan the tenant has,
-- its status, its term (current_period_*) and its cancellation
-- state.
--
-- Commerce can aggregate all subscriptions belonging to the same
-- customer account without making the subscription itself
-- responsible for customer ownership.
--
--   Customer A
--       Tenant 1 -> Pro
--       Tenant 2 -> Pro
--       Tenant 3 -> Pro
--
-- 002 does NOT calculate or store prices or discounts.
-- The discount that was actually applied is recorded by
-- Commerce (012: applied_discounts).
--
-- Cancellation is per end of month only:
--   cancel_requested_at  when the customer asked
--   cancel_effective_at  first instant of the next month
--                        (platform.billing_timezone())
--   status stays 'active' until the end-of-month job
--   platform.expire_cancelled_subscriptions() sets 'cancelled'.
-- =====================================================

create table if not exists public.subscriptions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    plan_id uuid
        references public.product_plans(id)
        on delete restrict,

    tier public.subscription_tier not null,

    status public.subscription_status not null default 'trial',

    current_period_start timestamptz,

    current_period_end timestamptz,

    cancel_requested_at timestamptz,

    cancel_effective_at timestamptz,

    cancel_reason text,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    -- The current 002 domain model exposes exactly one
    -- subscription for a tenant.
    --
    -- Without this constraint, get_subscription() and
    -- update_subscription() could operate on multiple rows,
    -- which would violate the SSOT model.
    unique (tenant_id),

    constraint chk_subscriptions_cancellation
        check (
            (cancel_requested_at is null and cancel_effective_at is null)
            or (
                cancel_requested_at is not null
                and cancel_effective_at is not null
                and cancel_effective_at > cancel_requested_at
            )
        )
);


-- Re-runnable on a database that already has the pre-REV23 table.
alter table public.subscriptions
    add column if not exists plan_id uuid,
    add column if not exists cancel_requested_at timestamptz,
    add column if not exists cancel_effective_at timestamptz,
    add column if not exists cancel_reason text;

do $$
begin
    alter table public.subscriptions
        add constraint fk_subscriptions_plan
        foreign key (plan_id)
        references public.product_plans(id)
        on delete restrict;
exception
    when duplicate_object then null;
end;
$$;

do $$
begin
    alter table public.subscriptions
        add constraint chk_subscriptions_cancellation
        check (
            (cancel_requested_at is null and cancel_effective_at is null)
            or (
                cancel_requested_at is not null
                and cancel_effective_at is not null
                and cancel_effective_at > cancel_requested_at
            )
        );
exception
    when duplicate_object then null;
end;
$$;


-- =====================================================
-- 6. CORE INDEXES
-- =====================================================

-- -----------------------------------------------------
-- Customer account ownership
-- -----------------------------------------------------
--
-- UNIQUE(owner_user_id) already provides the lookup index
-- required to resolve the customer's account by owner.
--
-- No second owner_user_id index is therefore necessary.
-- -----------------------------------------------------


-- -----------------------------------------------------
-- Tenant lifecycle filtering.
-- -----------------------------------------------------

create index if not exists idx_tenants_status
on public.tenants (status);


-- -----------------------------------------------------
-- Tenant → customer account lookup.
--
-- This supports:
--
--   - listing all tenants of a customer account
--   - CRM customer portfolio queries
--   - Commerce subscription aggregation
-- -----------------------------------------------------

create index if not exists idx_tenants_customer_account
on public.tenants (customer_account_id);


-- -----------------------------------------------------
-- Membership lookup
-- -----------------------------------------------------
--
-- UNIQUE (tenant_id, user_id) already supplies the
-- tenant-first lookup index.
--
-- The resolver's important query is:
--
--   user_id = ?
--   is_active = true
--   ORDER BY created_at DESC
--   LIMIT 1
--
-- This index directly supports that query.
-- INCLUDE avoids making tenant_id/role part of the
-- ordering key while still making them available from
-- the index where PostgreSQL can use an index-only scan.
-- -----------------------------------------------------

create index if not exists idx_memberships_user_active_created
on public.tenant_memberships (
    user_id,
    created_at desc
)
include (tenant_id, role)
where is_active = true;


-- -----------------------------------------------------
-- Service-account tenant listing.
--
-- tenant_id is the leading column, therefore this index
-- also supports tenant-only lookups.
-- -----------------------------------------------------

create index if not exists idx_service_accounts_tenant_created
on public.service_accounts (
    tenant_id,
    created_at desc
);


-- -----------------------------------------------------
-- Plans and subscriptions.
-- -----------------------------------------------------

create unique index if not exists uq_product_plans_name_ci
on public.product_plans (lower(name));

-- At most one default plan (used for new tenants).
create unique index if not exists uq_product_plans_default
on public.product_plans (is_default)
where is_default = true;

create index if not exists idx_subscriptions_plan
on public.subscriptions (plan_id);

-- End-of-month cancellation job.
create index if not exists idx_subscriptions_cancel_effective
on public.subscriptions (cancel_effective_at)
where cancel_effective_at is not null;

-- Trial expiry job.
create index if not exists idx_subscriptions_trial_end
on public.subscriptions (current_period_end)
where status = 'trial';


-- =====================================================
-- 7. CUSTOMER ACCOUNT DOMAIN FUNCTIONS
-- =====================================================


-- -----------------------------------------------------
-- get_customer_account_for_user
--
-- Returns the customer account owned by a user.
--
-- Customer-account ownership is authoritative in:
--
--   public.customer_accounts.owner_user_id
--
-- No tenant membership is used to infer commercial ownership.
-- -----------------------------------------------------

create or replace function public.get_customer_account_for_user(
    p_user_id uuid
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
    select ca.id
    from public.customer_accounts ca
    where ca.owner_user_id = p_user_id
    limit 1;
$$;


-- -----------------------------------------------------
-- current_customer_account_id
--
-- Convenience resolver for the authenticated user.
--
-- This is NOT a tenant resolver.
--
-- It only resolves the customer's commercial account.
-- -----------------------------------------------------

create or replace function public.current_customer_account_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
    select public.get_customer_account_for_user(
        (select auth.uid())
    );
$$;


-- -----------------------------------------------------
-- get_customer_account
--
-- Returns the account owned by the authenticated user.
--
-- This function does not return tenant membership information.
-- Tenant access remains governed by tenant_memberships.
-- -----------------------------------------------------

create or replace function public.get_customer_account()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_uid uuid;
    v_result jsonb;
begin
    v_uid := (select auth.uid());

    if v_uid is null then
        raise exception 'authentication required';
    end if;

    select to_jsonb(t)
    into v_result
    from (
        select
            ca.id,
            ca.owner_user_id,
            ca.name,
            ca.status,
            ca.created_at,
            ca.updated_at
        from public.customer_accounts ca
        where ca.owner_user_id = v_uid
    ) t;

    if v_result is null then
        raise exception 'Customer account not found';
    end if;

    return v_result;
end;
$$;


-- =====================================================
-- 8. TENANT MEMBERSHIP RESOLUTION (SINGLE AUTHORITY)
-- Internal membership resolver + active tenant resolver
-- =====================================================

-- -----------------------------------------------------
-- Internal membership resolution
--
-- This function is the single authority for CURRENT TENANT
-- resolution.
--
-- It is NOT intended to prohibit ordinary membership queries
-- used for listing or administration.
-- -----------------------------------------------------

-- Server-side "selected tenant" pointer.
-- switch_tenant writes it; the resolver only uses it to ORDER the
-- user's valid memberships. Not an authority by itself.
alter table platform.profiles
    add column if not exists active_tenant_id uuid
    references public.tenants(id) on delete set null;

create or replace function platform._rev21_resolve_membership(
    p_user_id uuid,
    p_verify_tenant_id uuid default null
)
returns table(
    tenant_id uuid,
    role text,
    tenant_status text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    if p_user_id is null then
        return;
    end if;

    if (select auth.uid()) is not null
       and p_user_id <> (select auth.uid())
       and not platform.is_platform_admin() then
        raise exception 'unauthorized';
    end if;

    -- -------------------------------------------------
    -- Explicit tenant verification.
    --
    -- Used when the caller needs to verify whether a
    -- specific tenant is an active membership of the
    -- supplied user.
    -- -------------------------------------------------

    if p_verify_tenant_id is not null then

        return query
        select
            tm.tenant_id,
            tm.role::text,
            t.status::text
        from public.tenant_memberships tm
        join public.tenants t
            on t.id = tm.tenant_id
        where tm.user_id = p_user_id
          and tm.tenant_id = p_verify_tenant_id
          and tm.is_active = true
          and t.status not in ('suspended', 'deleted')
        limit 1;

        return;
    end if;


    -- -------------------------------------------------
    -- Current tenant resolution.
    --
    -- There is deliberately ONE deterministic rule:
    --
    --   active membership
    --   +
    --   non-suspended/non-deleted tenant
    --   +
    --   newest membership
    --
    -- The customer account does NOT participate in current
    -- tenant resolution.
    --
    -- This prevents commercial ownership from becoming a
    -- second tenant-context authority.
    -- -------------------------------------------------

    return query
    select
        tm.tenant_id,
        tm.role::text,
        t.status::text
    from public.tenant_memberships tm
    join public.tenants t
        on t.id = tm.tenant_id
    where tm.user_id = p_user_id
      and tm.is_active = true
      and t.status not in ('suspended', 'deleted')
    order by
        -- The tenant picked via switch_tenant wins, but only among
        -- memberships that passed the validity filter above, so a
        -- stale or foreign pointer can never grant access.
        (
            tm.tenant_id is not distinct from (
                select p.active_tenant_id
                from platform.profiles p
                where p.id = p_user_id
            )
        ) desc,
        tm.created_at desc
    limit 1;
end;
$$;


-- -----------------------------------------------------
-- resolve_active_tenant: sole current-tenant authority
-- -----------------------------------------------------

create or replace function public.resolve_active_tenant(
    p_user_id uuid,
    p_verify_tenant_id uuid default null
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
    select m.tenant_id
    from platform._rev21_resolve_membership(
        p_user_id,
        p_verify_tenant_id
    ) m
    limit 1;
$$;


-- =====================================================
-- 9. TENANT CONTEXT AND ROLE FUNCTIONS
-- Derived exclusively from the membership resolver
-- =====================================================

create or replace function platform.current_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
    select m.role
    from platform._rev21_resolve_membership(
        (select auth.uid()),
        null
    ) m
    limit 1;
$$;


create or replace function platform.current_tenant_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
    select public.resolve_active_tenant(
        (select auth.uid())
    );
$$;


create or replace function platform.has_role(required_role text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from platform._rev21_resolve_membership(
            (select auth.uid()),
            null
        ) m
        where m.role = required_role
    );
$$;


-- -----------------------------------------------------
-- Compatibility shim.
--
-- This function does not implement an alternative tenant
-- resolution mechanism. It delegates to the sole resolver.
-- -----------------------------------------------------

create or replace function platform.has_tenant_membership(
    p_user_id uuid,
    p_tenant_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select public.resolve_active_tenant(
        p_user_id,
        p_tenant_id
    ) is not null;
$$;


-- =====================================================
-- 10. USER-TO-TENANT CONTEXT VIEW
-- =====================================================

create or replace view public.tenant_user_context
with (security_invoker = true)
as
select
    tm.user_id,
    tm.tenant_id,
    tm.role,
    tm.is_active,
    t.status as tenant_status
from public.tenant_memberships tm
join public.tenants t
    on t.id = tm.tenant_id;

-- =====================================================
-- 11. TENANT SWITCHING AND AUTH DOMAIN
-- =====================================================


-- -----------------------------------------------------
-- auth_resolve_tenant_switch
--
-- Tenant membership validation is delegated to the
-- authoritative membership resolver.
-- -----------------------------------------------------

create or replace function public.auth_resolve_tenant_switch(
    p_user_id uuid,
    p_target_tid uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_row record;
begin
    if p_user_id is null then
        raise exception 'authentication required';
    end if;

    if p_target_tid is null then
        raise exception 'tenant_id is required';
    end if;

    select
        m.tenant_id,
        m.role,
        m.tenant_status
    into v_row
    from platform._rev21_resolve_membership(
        p_user_id,
        p_target_tid
    ) m
    limit 1;

    if v_row.tenant_id is null then
        raise exception 'No active membership for tenant';
    end if;

    if v_row.tenant_status in ('suspended', 'deleted') then
        raise exception 'Tenant is not available';
    end if;

    return jsonb_build_object(
        'tenant_id', v_row.tenant_id,
        'role', v_row.role,
        'tenant_status', v_row.tenant_status
    );
end;
$$;


-- -----------------------------------------------------
-- auth_domain_ext_031
-- Tenant switching + invitations
-- -----------------------------------------------------

create or replace function public.auth_domain_ext_031(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_uid uuid;
    v_row record;
    v_result jsonb;
    v_target_tid uuid;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);
    v_uid := (select auth.uid());

    case p_op

    when 'validate_tenant_switch' then

        if v_uid is null then
            raise exception 'authentication required';
        end if;

        if p_payload->>'tenant_id' is null then
            raise exception 'tenant_id is required';
        end if;

        v_target_tid := (p_payload->>'tenant_id')::uuid;

        v_result := public.auth_resolve_tenant_switch(
            v_uid,
            v_target_tid
        );


    when 'invite_member' then

        perform public.edge_require_admin();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'NO_ACTIVE_TENANT';
        end if;

        if p_payload->>'user_id' is null then
            raise exception 'user_id is required';
        end if;

        if p_payload->>'role' is null then
            raise exception 'role is required';
        end if;

        if exists (
            select 1
            from public.tenant_memberships tm
            where tm.tenant_id = v_tid
              and tm.user_id = (p_payload->>'user_id')::uuid
              and tm.is_active = true
        ) then
            raise exception
                'User is already an active member of this tenant';
        end if;


        -- -------------------------------------------------
        -- Existing inactive membership:
        --
        -- The membership table is the SSOT and has a
        -- UNIQUE (tenant_id,user_id) constraint.
        --
        -- Therefore an existing inactive membership must
        -- be reactivated rather than inserting a second row.
        -- -------------------------------------------------

        if exists (
            select 1
            from public.tenant_memberships tm
            where tm.tenant_id = v_tid
              and tm.user_id = (p_payload->>'user_id')::uuid
              and tm.is_active = false
        ) then

            update public.tenant_memberships tm
            set
                role = (p_payload->>'role')::membership_role,
                is_active = true,
                revoked_at = null
            where tm.tenant_id = v_tid
              and tm.user_id = (p_payload->>'user_id')::uuid
            returning
                id,
                user_id,
                tenant_id,
                role,
                is_active,
                revoked_at,
                created_at
            into v_row;

        else

            insert into public.tenant_memberships (
                tenant_id,
                user_id,
                role,
                is_active
            )
            values (
                v_tid,
                (p_payload->>'user_id')::uuid,
                (p_payload->>'role')::public.membership_role,
                true
            )
            returning
                id,
                user_id,
                tenant_id,
                role,
                is_active,
                revoked_at,
                created_at
            into v_row;

        end if;

        perform platform.log_audit(
            'membership.created',
            'tenant_membership',
            v_row.id,
            jsonb_build_object(
                'tenant_id', v_tid,
                'user_id', v_row.user_id,
                'role', v_row.role,
                'invited_by', v_uid
            )
        );

        select jsonb_build_object(
            'id', v_row.id,
            'user_id', v_row.user_id,
            'tenant_id', v_row.tenant_id,
            'role', v_row.role,
            'is_active', v_row.is_active,
            'revoked_at', v_row.revoked_at,
            'email', coalesce(
                p_payload->>'email',
                p.email
            ),
            'full_name', p.full_name,
            'created_at', v_row.created_at
        )
        into v_result
        from platform.profiles p
        where p.id = v_row.user_id;


    else

        raise exception
            'unknown auth_domain operation: %',
            p_op;

    end case;

    return v_result;
end;
$$;


-- -----------------------------------------------------
-- auth_domain_ext: extended auth router
-- -----------------------------------------------------

create or replace function public.auth_domain_ext(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_result jsonb;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

    when 'resolve_user_by_email' then

        if p_payload->>'email' is null then
            raise exception 'email is required';
        end if;

        select to_jsonb(t)
        into v_result
        from (
            select
                p.id,
                p.email,
                p.full_name
            from platform.profiles p
            where lower(p.email) =
                  lower(p_payload->>'email')
            limit 1
        ) t;

        return v_result;


    else

        return public.auth_domain_ext_031(
            p_op,
            p_payload
        );

    end case;
end;
$$;


-- -----------------------------------------------------
-- auth_domain: core tenant/member/subscription router
-- -----------------------------------------------------

create or replace function public.auth_domain(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_uid uuid;
    v_customer_account_id uuid;
    v_row record;
    v_result jsonb;
    v_role text;
    v_tenant_status text;
    v_existing record;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);
    v_uid := (select auth.uid());

    case p_op

    -- =================================================
    -- CUSTOMER ACCOUNT
    -- =================================================

    when 'get_customer_account' then

        if v_uid is null then
            raise exception 'authentication required';
        end if;

        v_result := public.get_customer_account();


    -- =================================================
    -- AUTH CONTEXT
    -- =================================================

    when 'get_auth_context' then

        if v_uid is null then
            raise exception 'authentication required';
        end if;

        v_tid := platform.current_tenant_id();
        v_role := platform.current_role();

        v_tenant_status := null;

        if v_tid is not null then
            select t.status::text
            into v_tenant_status
            from public.tenants t
            where t.id = v_tid;
        end if;

        v_customer_account_id :=
            public.current_customer_account_id();

        v_result := jsonb_build_object(
            'user_id', v_uid,
            'email', (
                select p.email
                from platform.profiles p
                where p.id = v_uid
            ),
            'customer_account_id',
                v_customer_account_id,
            'tenant_id',
                v_tid,
            'role',
                v_role,
            'tenant_status',
                v_tenant_status,
            'is_platform_admin',
                platform.is_platform_admin()
        );


    -- =================================================
    -- LIST USER TENANTS
    -- =================================================

    when 'list_user_tenants' then

        if v_uid is null then
            raise exception 'authentication required';
        end if;

        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.created_at
            ),
            '[]'::jsonb
        )
        into v_result
        from (
            select
                tm.tenant_id,
                t.name as tenant_name,
                tm.role,
                tm.is_active,
                t.status as tenant_status,
                t.customer_account_id,
                tm.created_at
            from public.tenant_memberships tm
            join public.tenants t
                on t.id = tm.tenant_id
            where tm.user_id = v_uid
              and tm.is_active = true
        ) t;


    -- =================================================
    -- GET CURRENT TENANT
    -- =================================================

    when 'get_current_tenant' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'NO_ACTIVE_TENANT';
        end if;

        select to_jsonb(t)
        into v_result
        from (
            select
                tn.id,
                tn.customer_account_id,
                tn.name,
                tn.status,
                tn.created_at,
                tn.updated_at
            from public.tenants tn
            where tn.id = v_tid
        ) t;

        if v_result is null then
            raise exception 'Tenant not found';
        end if;


    -- =================================================
    -- CREATE TENANT
    -- =================================================
    --
    -- A user may create MULTIPLE tenants.
    --
    -- The previous restriction that prevented a user from
    -- having more than one active owner membership has been
    -- intentionally removed.
    --
    -- The customer account is the commercial owner.
    --
    -- If the authenticated user does not yet have a customer
    -- account, one is created automatically.
    --
    -- If the user already owns one, the new tenant is attached
    -- to that existing account.
    --
    -- This does not create a new pricing rule. Commerce remains
    -- responsible for subscription pricing and discounts.
    -- =================================================

    when 'create_tenant' then

        if v_uid is null then
            raise exception 'authentication required';
        end if;

        -- Resolve existing customer account.
        select ca.id
        into v_customer_account_id
        from public.customer_accounts ca
        where ca.owner_user_id = v_uid
        limit 1;


        -- -------------------------------------------------
        -- First tenant for this customer:
        --
        -- Create the commercial customer account.
        --
        -- The account is created here because tenant creation
        -- already represents the existing onboarding path.
        -- No separate mandatory customer-account step is
        -- introduced for the caller.
        -- -------------------------------------------------

        if v_customer_account_id is null then

            insert into public.customer_accounts (
                owner_user_id,
                name
            )
            values (
                v_uid,
                coalesce(
                    nullif(trim(p_payload->>'customer_account_name'), ''),
                    nullif(trim(p_payload->>'name'), ''),
                    'Customer'
                )
            )
            returning id
            into v_customer_account_id;

        end if;


        insert into public.tenants (
            customer_account_id,
            name
        )
        values (
            v_customer_account_id,
            p_payload->>'name'
        )
        returning
            id,
            customer_account_id,
            name,
            status,
            created_at,
            updated_at
        into v_row;


        perform platform.log_audit(
            'tenant.created',
            'tenant',
            v_row.id,
            jsonb_build_object(
                'name',
                    p_payload->>'name',
                'customer_account_id',
                    v_customer_account_id,
                'created_by',
                    v_uid
            )
        );

        v_result := to_jsonb(v_row);


    -- =================================================
    -- UPDATE TENANT
    -- =================================================

    when 'update_tenant' then

        perform public.edge_require_admin();

        v_tid := platform.current_tenant_id();

        update public.tenants tn
        set
            name = case
                when p_payload ? 'name'
                then p_payload->>'name'
                else tn.name
            end,

            status = case
                when p_payload ? 'status'
                then (p_payload->>'status')::public.tenant_status
                else tn.status
            end

        where tn.id = v_tid

        returning
            tn.id,
            tn.customer_account_id,
            tn.name,
            tn.status,
            tn.created_at,
            tn.updated_at
        into v_row;

        if not found then
            raise exception 'Tenant not found';
        end if;

        perform platform.log_audit(
            'tenant.updated',
            'tenant',
            v_tid,
            p_payload
        );

        v_result := to_jsonb(v_row);


    -- =================================================
    -- LIST MEMBERSHIPS
    -- =================================================

    when 'list_memberships' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'NO_ACTIVE_TENANT';
        end if;

        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.created_at
            ),
            '[]'::jsonb
        )
        into v_result
        from (
            select
                tm.id,
                tm.user_id,
                tm.tenant_id,
                tm.role,
                tm.is_active,
                tm.revoked_at,
                p.email,
                p.full_name,
                tm.created_at
            from public.tenant_memberships tm
            left join platform.profiles p
                on p.id = tm.user_id
            where tm.tenant_id = v_tid
        ) t;


    -- =================================================
    -- UPDATE MEMBERSHIP
    -- =================================================

    when 'update_membership' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'NO_ACTIVE_TENANT';
        end if;

        select
            tm.id,
            tm.user_id,
            tm.tenant_id
        into v_existing
        from public.tenant_memberships tm
        where tm.id =
              (p_payload->>'membership_id')::uuid
          and tm.tenant_id = v_tid;

        if not found then
            raise exception 'Membership not found';
        end if;

        if v_existing.user_id = v_uid then

            if p_payload ? 'role' then
                raise exception
                    'Cannot change your own role via this endpoint';
            end if;

        else

            perform public.edge_require_admin();

        end if;

        update public.tenant_memberships tm
        set
            role = case
                when p_payload ? 'role'
                then (p_payload->>'role')::public.membership_role
                else tm.role
            end,

            is_active = case
                when p_payload ? 'is_active'
                then (p_payload->>'is_active')::boolean
                else tm.is_active
            end,

            revoked_at = case
                when p_payload ? 'is_active'
                     and not (p_payload->>'is_active')::boolean
                then now()

                when p_payload ? 'is_active'
                     and (p_payload->>'is_active')::boolean
                then null

                else tm.revoked_at
            end

        where tm.id =
              (p_payload->>'membership_id')::uuid
          and tm.tenant_id = v_tid

        returning
            tm.id,
            tm.user_id,
            tm.tenant_id,
            tm.role,
            tm.is_active,
            tm.revoked_at,
            tm.created_at
        into v_row;

        if not found then
            raise exception 'Membership not found';
        end if;

        perform platform.log_audit(
            'membership.updated',
            'tenant_membership',
            v_row.id,
            p_payload
        );

        select jsonb_build_object(
            'id', v_row.id,
            'user_id', v_row.user_id,
            'tenant_id', v_row.tenant_id,
            'role', v_row.role,
            'is_active', v_row.is_active,
            'revoked_at', v_row.revoked_at,
            'email', p.email,
            'full_name', p.full_name,
            'created_at', v_row.created_at
        )
        into v_result
        from platform.profiles p
        where p.id = v_row.user_id;


    -- =================================================
    -- REVOKE MEMBERSHIP
    -- =================================================

    when 'revoke_membership' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'NO_ACTIVE_TENANT';
        end if;

        select
            tm.id,
            tm.user_id
        into v_existing
        from public.tenant_memberships tm
        where tm.id =
              (p_payload->>'membership_id')::uuid
          and tm.tenant_id = v_tid;

        if not found then
            raise exception 'Membership not found';
        end if;

        if v_existing.user_id <> v_uid then
            perform public.edge_require_admin();
        end if;

        -- Existing domain behaviour intentionally preserved.
        delete from public.tenant_memberships tm
        where tm.id =
              (p_payload->>'membership_id')::uuid
          and tm.tenant_id = v_tid;

        perform platform.log_audit(
            'membership.revoked',
            'tenant_membership',
            (p_payload->>'membership_id')::uuid,
            jsonb_build_object(
                'tenant_id', v_tid,
                'revoked_by', v_uid
            )
        );

        v_result := jsonb_build_object(
            'revoked', true,
            'membership_id',
                p_payload->>'membership_id'
        );


    -- =================================================
    -- GET SUBSCRIPTION
    -- =================================================

    when 'get_subscription' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'NO_ACTIVE_TENANT';
        end if;

        select to_jsonb(t)
        into v_result
        from (
            select
                s.id,
                s.tenant_id,
                s.plan_id,
                s.tier,
                s.status,
                s.current_period_start,
                s.current_period_end,
                s.cancel_requested_at,
                s.cancel_effective_at,
                s.cancel_reason,
                s.created_at,
                s.updated_at
            from public.subscriptions s
            where s.tenant_id = v_tid
        ) t;


    -- =================================================
    -- UPDATE SUBSCRIPTION
    -- =================================================

    when 'update_subscription' then

        perform public.edge_require_admin();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'NO_ACTIVE_TENANT';
        end if;

        if not exists (
            select 1
            from public.subscriptions s
            where s.tenant_id = v_tid
        ) then
            raise exception
                'Subscription not found for tenant';
        end if;

        update public.subscriptions s
        set
            status = case
                when p_payload ? 'status'
                then (p_payload->>'status')::public.subscription_status
                else s.status
            end,

            current_period_start = case
                when p_payload ? 'current_period_start'
                then (p_payload->>'current_period_start')::timestamptz
                else s.current_period_start
            end,

            current_period_end = case
                when p_payload ? 'current_period_end'
                then (p_payload->>'current_period_end')::timestamptz
                else s.current_period_end
            end

        where s.tenant_id = v_tid

        returning
            s.id,
            s.tenant_id,
            s.plan_id,
            s.tier,
            s.status,
            s.current_period_start,
            s.current_period_end,
            s.cancel_requested_at,
            s.cancel_effective_at,
            s.cancel_reason,
            s.created_at,
            s.updated_at
        into v_row;

        perform platform.log_audit(
            'subscription.updated',
            'subscription',
            v_row.id,
            p_payload
        );

        v_result := to_jsonb(v_row);


    -- =================================================
    -- SERVICE ACCOUNTS
    -- =================================================

    when 'list_service_accounts' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'NO_ACTIVE_TENANT';
        end if;

        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.created_at
            ),
            '[]'::jsonb
        )
        into v_result
        from (
            select
                sa.id,
                sa.tenant_id,
                sa.name,
                sa.provider_code,
                sa.is_active,
                sa.created_at
            from public.service_accounts sa
            where sa.tenant_id = v_tid
        ) t;


    when 'create_service_account' then

        perform public.edge_require_admin();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'NO_ACTIVE_TENANT';
        end if;

        insert into public.service_accounts (
            tenant_id,
            name,
            provider_code,
            is_active
        )
        values (
            v_tid,
            p_payload->>'name',
            p_payload->>'provider_code',
            coalesce(
                (p_payload->>'is_active')::boolean,
                true
            )
        )
        returning
            id,
            tenant_id,
            name,
            provider_code,
            is_active,
            created_at
        into v_row;

        perform platform.log_audit(
            'service_account.created',
            'service_account',
            v_row.id,
            jsonb_build_object(
                'name', p_payload->>'name',
                'provider_code',
                    p_payload->>'provider_code'
            )
        );

        v_result := to_jsonb(v_row);


    when 'update_service_account' then

        perform public.edge_require_admin();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'NO_ACTIVE_TENANT';
        end if;

        update public.service_accounts sa
        set
            name = case
                when p_payload ? 'name'
                then p_payload->>'name'
                else sa.name
            end,

            provider_code = case
                when p_payload ? 'provider_code'
                then p_payload->>'provider_code'
                else sa.provider_code
            end,

            is_active = case
                when p_payload ? 'is_active'
                then (p_payload->>'is_active')::boolean
                else sa.is_active
            end

        where sa.id =
              (p_payload->>'service_account_id')::uuid
          and sa.tenant_id = v_tid

        returning
            sa.id,
            sa.tenant_id,
            sa.name,
            sa.provider_code,
            sa.is_active,
            sa.created_at
        into v_row;

        if not found then
            raise exception 'Service account not found';
        end if;

        perform platform.log_audit(
            'service_account.updated',
            'service_account',
            v_row.id,
            p_payload
        );

        v_result := to_jsonb(v_row);


    when 'delete_service_account' then

        perform public.edge_require_admin();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'NO_ACTIVE_TENANT';
        end if;

        delete from public.service_accounts sa
        where sa.id =
              (p_payload->>'service_account_id')::uuid
          and sa.tenant_id = v_tid;

        if not found then
            raise exception 'Service account not found';
        end if;

        perform platform.log_audit(
            'service_account.deleted',
            'service_account',
            (p_payload->>'service_account_id')::uuid
        );

        v_result := jsonb_build_object(
            'deleted', true,
            'service_account_id',
                p_payload->>'service_account_id'
        );


    else

        return public.auth_domain_ext(
            p_op,
            p_payload
        );

    end case;

    return v_result;
end;
$$;


-- =====================================================
-- 12. ADMIN INVITATION WRAPPER
-- =====================================================

create or replace function public.auth_invite_member(
    p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_uid uuid;
    v_payload jsonb;
begin
    perform public.edge_require_admin();

    p_payload := coalesce(p_payload, '{}'::jsonb);
    v_payload := p_payload;

    if v_payload->>'user_id' is null then

        if v_payload->>'email' is null then
            raise exception 'email or user_id is required';
        end if;

        select p.id
        into v_uid
        from platform.profiles p
        where lower(p.email) =
              lower(v_payload->>'email')
        limit 1;

        if v_uid is null then
            raise exception
                'User not found for email. User must register before invite.';
        end if;

        v_payload :=
            v_payload ||
            jsonb_build_object(
                'user_id',
                v_uid::text
            );
    end if;

    return public.auth_domain(
        'invite_member',
        v_payload
    );
end;
$$;


-- =====================================================
-- 13. TENANT SWITCHING
-- =====================================================
--
-- Existing application behaviour is preserved.
--
-- IMPORTANT:
--
-- raw_app_meta_data.tenant_id is NOT the tenant SSOT.
--
-- It is merely application state used by the existing tenant
-- switching mechanism.
--
-- Membership authorization is ALWAYS performed first through:
--
--   public.auth_resolve_tenant_switch(...)
--
-- Therefore a value in raw_app_meta_data cannot independently
-- grant access to a tenant.
--
-- Current tenant authority remains:
--
--   public.resolve_active_tenant(...)
--
-- =====================================================

create or replace function public.auth_switch_tenant(
    p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_uid uuid;
    v_target_tid uuid;
    v_result jsonb;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    v_uid := auth.uid();

    if v_uid is null then
        raise exception 'authentication required';
    end if;

    if p_payload->>'tenant_id' is null then
        raise exception 'tenant_id is required';
    end if;

    v_target_tid :=
        (p_payload->>'tenant_id')::uuid;

    v_result :=
        public.auth_resolve_tenant_switch(
            v_uid,
            v_target_tid
        );

    update platform.profiles
    set active_tenant_id = v_target_tid
    where id = v_uid;

    update auth.users
    set raw_app_meta_data =
        coalesce(
            raw_app_meta_data,
            '{}'::jsonb
        )
        ||
        jsonb_build_object(
            'tenant_id',
            v_target_tid::text
        )
    where id = v_uid;

    return v_result;
end;
$$;


-- =====================================================
-- 14. TENANT PROVISIONING AND OWNER INVARIANT
-- =====================================================


-- -----------------------------------------------------
-- Tenant provisioning: creator becomes owner.
--
-- IMPORTANT:
--
-- A customer-account owner may own multiple tenants.
--
-- Therefore this trigger does NOT enforce any
-- "one tenant per owner" rule.
-- -----------------------------------------------------

create or replace function public.handle_new_tenant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if (select auth.uid()) is not null then

        insert into public.tenant_memberships (
            tenant_id,
            user_id,
            role,
            is_active
        )
        values (
            new.id,
            (select auth.uid()),
            'owner',
            true
        );

        update platform.profiles
        set active_tenant_id = new.id
        where id = (select auth.uid());

    end if;

    return new;
end;
$$;


-- -----------------------------------------------------
-- Owner invariant
--
-- At least one active owner must remain for the tenant.
--
-- IMPORTANT:
--
-- This invariant is PER TENANT.
--
-- It does NOT prevent the same user from being owner of
-- multiple tenants.
--
-- The customer account has its own separate ownership
-- concept through customer_accounts.owner_user_id.
--
-- The tenant row is locked before counting owners.
-- This serializes competing owner-removal operations for
-- the same tenant.
-- -----------------------------------------------------

create or replace function public.enforce_tenant_owner_invariant()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_owner_count integer;
begin

    if tg_op = 'DELETE' then

        if old.role = 'owner'
           and old.is_active then

            perform 1
            from public.tenants t
            where t.id = old.tenant_id
            for update;

            select count(*)
            into v_owner_count
            from public.tenant_memberships tm
            where tm.tenant_id = old.tenant_id
              and tm.role = 'owner'
              and tm.is_active = true
              and tm.id <> old.id;

            if v_owner_count = 0 then
                raise exception
                    'cannot remove last active owner from tenant';
            end if;

        end if;

        return old;
    end if;


    if tg_op = 'UPDATE' then

        if old.role = 'owner'
           and old.is_active
           and (
               new.role <> 'owner'
               or not new.is_active
           ) then

            perform 1
            from public.tenants t
            where t.id = old.tenant_id
            for update;

            select count(*)
            into v_owner_count
            from public.tenant_memberships tm
            where tm.tenant_id = old.tenant_id
              and tm.role = 'owner'
              and tm.is_active = true
              and tm.id <> old.id;

            if v_owner_count = 0 then
                raise exception
                    'cannot demote or deactivate last active owner';
            end if;

        end if;

        return new;
    end if;


    return new;
end;
$$;

-- =====================================================
-- 014B. Trial expiry ending
-- =====================================================
-- Trial subscription expiry: move subscriptions from 
-- 'trial' to 'trial_expired' when the trial period ends.
--
-- The trial period is inferred from:
-- - current_period_end = the trial end date
-- - status = 'trial'
--
-- A trial upgrade (change_plan to paid) leaves status as-is, so we
-- never overwrite it.
--
-- This function is idempotent: re-running touches nothing.
-- =====================================================

create or replace function platform.expire_trial_subscriptions()
returns table (
    subscriptions_expired bigint,
    seconds_elapsed numeric
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_start timestamptz;
    v_rows bigint;
begin
    v_start := now();

    update public.subscriptions
    set status = 'trial_expired'::public.subscription_status,
        updated_at = now()
    where status = 'trial'
      and current_period_end < now();

    get diagnostics v_rows = row_count;

    return query select
        v_rows,
        extract(epoch from (now() - v_start))::numeric;
end;
$$;

comment on function platform.expire_trial_subscriptions() is
    'Move subscriptions from "trial" to "trial_expired" when their trial period ends. Called by the daily maintenance job.';


-- =====================================================
-- 14C. PLAN AND SUBSCRIPTION LIFECYCLE (002 SSOT)
-- =====================================================
--
-- Everything that creates or changes a plan or a subscription
-- instance lives here. Commerce (012) calls these functions
-- from commerce_domain and from the invoice generator; it does
-- not write public.product_plans or public.subscriptions itself.
--
-- These are internal functions: execution is revoked from
-- public/anon/authenticated at the end of this section. They are
-- reached through the API layer (commerce_api / auth_api wrappers),
-- which performs the role check.
-- =====================================================

-- Month boundaries of the cancellation are evaluated here.
create or replace function platform.billing_timezone()
returns text
language sql
immutable
set search_path = ''
as $$
    select 'Europe/Athens'::text;
$$;


-- -----------------------------------------------------
-- Invariants
-- -----------------------------------------------------

-- Active subscription states require a plan.
create or replace function public.enforce_subscription_plan_required()
returns trigger
language plpgsql
set search_path = ''
as $$
begin

    -- subscription_status enum: trial (not 'trialing').
    if new.status in ('active', 'trial', 'past_due')
       and new.plan_id is null then

        raise exception
            'subscription plan_id is required for status %',
            new.status;

    end if;

    return new;

end;
$$;


-- The tier follows the plan.
create or replace function public.sync_subscription_tier_from_plan()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_tier public.subscription_tier;
begin

    if new.plan_id is null then
        return new;
    end if;

    select pp.tier
    into v_tier
    from public.product_plans pp
    where pp.id = new.plan_id;

    if not found then
        raise exception
            'subscription plan % not found',
            new.plan_id;
    end if;

    new.tier := v_tier;

    return new;

end;
$$;


create or replace function public.prevent_subscription_tier_drift()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_tier public.subscription_tier;
begin

    if new.plan_id is null then
        return new;
    end if;

    select pp.tier
    into v_tier
    from public.product_plans pp
    where pp.id = new.plan_id;

    if not found then
        raise exception
            'subscription plan % not found',
            new.plan_id;
    end if;

    if new.tier <> v_tier then
        raise exception
            'subscription tier must match product plan tier';
    end if;

    return new;

end;
$$;


-- Once a plan is used by subscriptions its tier is immutable.
-- Create a new plan instead.
create or replace function public.prevent_product_plan_tier_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin

    if new.tier is distinct from old.tier
       and exists (
            select 1
            from public.subscriptions s
            where s.plan_id = old.id
       )
    then

        raise exception
            'product plan tier cannot change after the plan has been used by subscriptions';

    end if;

    return new;

end;
$$;


drop trigger if exists trg_product_plan_tier_immutable
on public.product_plans;

create trigger trg_product_plan_tier_immutable
before update on public.product_plans
for each row
execute function public.prevent_product_plan_tier_change();


-- Trigger order matters (BEFORE triggers fire alphabetically):
-- the tier is first derived from the plan (01), then checked (02).
-- The pre-REV23 names are dropped so they cannot fire in the wrong order.
drop trigger if exists trg_subscriptions_sync_tier_from_plan
on public.subscriptions;

drop trigger if exists trg_subscriptions_prevent_tier_drift
on public.subscriptions;

drop trigger if exists trg_subscriptions_plan_required
on public.subscriptions;

drop trigger if exists trg_subscriptions_01_sync_tier_from_plan
on public.subscriptions;

create trigger trg_subscriptions_01_sync_tier_from_plan
before insert or update of plan_id
on public.subscriptions
for each row
execute function public.sync_subscription_tier_from_plan();


drop trigger if exists trg_subscriptions_02_prevent_tier_drift
on public.subscriptions;

create trigger trg_subscriptions_02_prevent_tier_drift
before insert or update
on public.subscriptions
for each row
execute function public.prevent_subscription_tier_drift();


drop trigger if exists trg_subscriptions_03_plan_required
on public.subscriptions;

create trigger trg_subscriptions_03_plan_required
before insert or update
on public.subscriptions
for each row
execute function public.enforce_subscription_plan_required();


-- -----------------------------------------------------
-- Plan administration (platform admin)
-- -----------------------------------------------------

create or replace function public.subscription_plan_create(
    p_payload jsonb
)
returns public.product_plans
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_plan public.product_plans%rowtype;
    v_default boolean;
begin

    if (select auth.uid()) is null then
        raise exception 'authentication required';
    end if;

    if not public.is_platform_admin() then
        raise exception 'platform admin role required';
    end if;

    v_default := coalesce((p_payload->>'is_default')::boolean, false);

    -- Only one default plan: release the old one first.
    if v_default then
        update public.product_plans
        set is_default = false
        where is_default = true;
    end if;

    insert into public.product_plans (
        name,
        description,
        tier,
        is_active,
        is_default
    )
    values (
        btrim(p_payload->>'name'),
        p_payload->>'description',
        (p_payload->>'tier')::public.subscription_tier,
        coalesce((p_payload->>'is_active')::boolean, true),
        v_default
    )
    returning *
    into v_plan;

    perform platform.log_audit(
        'product_plan.created',
        'product_plan',
        v_plan.id
    );

    return v_plan;

end;
$$;


create or replace function public.subscription_plan_update(
    p_payload jsonb
)
returns public.product_plans
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_id uuid;
    v_plan public.product_plans%rowtype;
begin

    if (select auth.uid()) is null then
        raise exception 'authentication required';
    end if;

    if not public.is_platform_admin() then
        raise exception 'platform admin role required';
    end if;

    v_id := (p_payload->>'id')::uuid;

    if p_payload ? 'is_default'
       and coalesce((p_payload->>'is_default')::boolean, false) then

        update public.product_plans
        set is_default = false
        where is_default = true
          and id <> v_id;

    end if;

    update public.product_plans pp
    set
        name = case
            when p_payload ? 'name' then btrim(p_payload->>'name')
            else pp.name
        end,

        description = case
            when p_payload ? 'description' then p_payload->>'description'
            else pp.description
        end,

        tier = case
            when p_payload ? 'tier'
                then (p_payload->>'tier')::public.subscription_tier
            else pp.tier
        end,

        is_active = case
            when p_payload ? 'is_active'
                then (p_payload->>'is_active')::boolean
            else pp.is_active
        end,

        is_default = case
            when p_payload ? 'is_default'
                then (p_payload->>'is_default')::boolean
            else pp.is_default
        end

    where pp.id = v_id
    returning *
    into v_plan;

    if not found then
        raise exception 'product plan not found';
    end if;

    perform platform.log_audit(
        'product_plan.updated',
        'product_plan',
        v_plan.id,
        p_payload - 'id'
    );

    return v_plan;

end;
$$;


-- A plan that is still referenced anywhere (subscriptions here;
-- invoice lines, upsell rules, discount codes in 012) cannot be
-- deleted: the foreign keys are ON DELETE RESTRICT. Deactivate it.
create or replace function public.subscription_plan_delete(
    p_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_name text;
begin

    if (select auth.uid()) is null then
        raise exception 'authentication required';
    end if;

    if not public.is_platform_admin() then
        raise exception 'platform admin role required';
    end if;

    begin

        delete from public.product_plans pp
        where pp.id = p_id
        returning pp.name
        into v_name;

    exception
        when foreign_key_violation then
            raise exception
                'plan is still in use (subscriptions, invoice lines, upsell rules or discount codes); deactivate it instead';
    end;

    if not found then
        raise exception 'product plan not found';
    end if;

    perform platform.log_audit(
        'product_plan.deleted',
        'product_plan',
        p_id,
        jsonb_build_object('name', v_name)
    );

    return jsonb_build_object('id', p_id, 'deleted', true);

end;
$$;


-- -----------------------------------------------------
-- Subscription creation and provisioning
-- -----------------------------------------------------

create or replace function public.subscription_create(
    p_tenant_id uuid,
    p_plan_id uuid,
    p_status text default 'active'
)
returns public.subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_plan public.product_plans%rowtype;
    v_subscription public.subscriptions%rowtype;
begin

    if not public.is_platform_admin()
       and platform.current_tenant_id() is distinct from p_tenant_id then
        raise exception 'tenant context mismatch';
    end if;

    select *
    into v_plan
    from public.product_plans pp
    where pp.id = p_plan_id
      and pp.is_active = true;

    if not found then
        raise exception 'active product plan not found';
    end if;

    -- Exactly one subscription per tenant (provisioned when the
    -- tenant is created). Use subscription_change_plan to switch.
    if exists (
        select 1
        from public.subscriptions s
        where s.tenant_id = p_tenant_id
    ) then
        raise exception
            'tenant already has a subscription; use change_subscription_plan';
    end if;

    insert into public.subscriptions (
        tenant_id,
        plan_id,
        tier,
        status
    )
    values (
        p_tenant_id,
        v_plan.id,
        v_plan.tier,
        p_status::public.subscription_status
    )
    returning *
    into v_subscription;

    perform platform.log_audit(
        'subscription.created',
        'subscription',
        v_subscription.id,
        jsonb_build_object(
            'plan_id', v_plan.id,
            'tier', v_plan.tier
        )
    );

    return v_subscription;

end;
$$;


-- Every tenant gets its subscription when it is created.
-- The default plan must already exist (seed it before the first tenant).
create or replace function public.provision_default_subscription()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_plan public.product_plans%rowtype;
begin

    select *
    into v_plan
    from public.product_plans
    where is_default = true
      and is_active = true
    limit 1;

    if not found then
        raise exception
            'cannot provision tenant subscription: no active default product plan exists';
    end if;

    insert into public.subscriptions (
        tenant_id,
        plan_id,
        tier,
        status
    )
    values (
        new.id,
        v_plan.id,
        v_plan.tier,
        'active'
    );

    return new;

end;
$$;


drop trigger if exists trg_tenants_provision_default_subscription
on public.tenants;

create trigger trg_tenants_provision_default_subscription
after insert on public.tenants
for each row
execute function public.provision_default_subscription();


-- -----------------------------------------------------
-- Plan change
-- -----------------------------------------------------

create or replace function public.subscription_change_plan(
    p_subscription_id uuid,
    p_plan_id uuid
)
returns public.subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_plan public.product_plans%rowtype;
    v_subscription public.subscriptions%rowtype;
begin

    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    select *
    into v_plan
    from public.product_plans pp
    where pp.id = p_plan_id
      and pp.is_active = true;

    if not found then
        raise exception 'active product plan not found';
    end if;

    select *
    into v_subscription
    from public.subscriptions s
    where s.id = p_subscription_id
      and s.tenant_id = v_tid
    for update;

    if not found then
        raise exception 'subscription not found';
    end if;

    -- tier follows the plan (trigger).
    update public.subscriptions
    set plan_id = v_plan.id
    where id = v_subscription.id
    returning *
    into v_subscription;

    perform platform.log_audit(
        'subscription.plan_changed',
        'subscription',
        v_subscription.id,
        jsonb_build_object(
            'plan_id', v_plan.id,
            'tier', v_plan.tier
        )
    );

    return v_subscription;

end;
$$;


-- -----------------------------------------------------
-- Cancellation per end of month
-- -----------------------------------------------------
--
-- The subscription stays 'active' (features and invoicing continue)
-- until cancel_effective_at; then the job sets 'cancelled'.
-- There is no mid-month cancellation.
--
-- Invoices are NOT touched here: 012 reacts to the state change
-- (it cancels draft invoices past the end date and refuses to bill
-- beyond it).
-- -----------------------------------------------------

create or replace function public.subscription_cancel(
    p_reason text default null
)
returns public.subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_sub public.subscriptions%rowtype;
    v_effective timestamptz;
begin

    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    select *
    into v_sub
    from public.subscriptions s
    where s.tenant_id = v_tid
    for update;

    if not found then
        raise exception 'subscription not found';
    end if;

    if v_sub.status not in ('active', 'trial', 'past_due') then
        raise exception
            'only an active, trial or past_due subscription can be cancelled (status: %)',
            v_sub.status;
    end if;

    if v_sub.cancel_requested_at is not null then
        raise exception
            'cancellation was already requested (effective %)',
            v_sub.cancel_effective_at;
    end if;

    -- First instant of next month in the billing time zone.
    v_effective := (
        date_trunc('month', timezone(platform.billing_timezone(), now()))
        + interval '1 month'
    ) at time zone platform.billing_timezone();

    update public.subscriptions
    set
        cancel_requested_at = now(),
        cancel_effective_at = v_effective,
        cancel_reason = nullif(btrim(coalesce(p_reason, '')), '')
    where id = v_sub.id
    returning *
    into v_sub;

    perform platform.log_audit(
        'subscription.cancellation_requested',
        'subscription',
        v_sub.id,
        jsonb_build_object('effective_at', v_effective)
    );

    return v_sub;

end;
$$;


create or replace function public.subscription_undo_cancel()
returns public.subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_sub public.subscriptions%rowtype;
begin

    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    select *
    into v_sub
    from public.subscriptions s
    where s.tenant_id = v_tid
    for update;

    if not found then
        raise exception 'subscription not found';
    end if;

    if v_sub.cancel_requested_at is null
       or v_sub.cancel_effective_at <= now() then
        raise exception 'there is no pending cancellation to undo';
    end if;

    update public.subscriptions
    set
        cancel_requested_at = null,
        cancel_effective_at = null,
        cancel_reason = null
    where id = v_sub.id
    returning *
    into v_sub;

    perform platform.log_audit(
        'subscription.cancellation_undone',
        'subscription',
        v_sub.id
    );

    return v_sub;

end;
$$;


-- Hourly job (027): the end-of-month moment has passed.
create or replace function platform.expire_cancelled_subscriptions()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_n int;
begin

    update public.subscriptions s
    set status = 'cancelled'
    where s.cancel_effective_at is not null
      and s.cancel_effective_at <= now()
      and s.status in ('active', 'trial', 'past_due');

    get diagnostics v_n = row_count;

    return v_n;

end;
$$;


-- Subscriptions that may be billed for a service period: the
-- single list the invoice generator must use.
create or replace function platform.billable_subscriptions(
    p_period_start date,
    p_period_end date
)
returns setof public.subscriptions
language sql
stable
security definer
set search_path = ''
as $$
    select s.*
    from public.subscriptions s
    where s.status in ('active', 'past_due')
      and (
          s.cancel_effective_at is null
          or p_period_end < (
              s.cancel_effective_at at time zone platform.billing_timezone()
          )::date
      );
$$;


-- -----------------------------------------------------
-- Internal functions: no direct execution by API roles.
-- -----------------------------------------------------

revoke all on function public.subscription_plan_create(jsonb)
from public, anon, authenticated;

revoke all on function public.subscription_plan_update(jsonb)
from public, anon, authenticated;

revoke all on function public.subscription_plan_delete(uuid)
from public, anon, authenticated;

revoke all on function public.subscription_create(uuid, uuid, text)
from public, anon, authenticated;

revoke all on function public.subscription_change_plan(uuid, uuid)
from public, anon, authenticated;

revoke all on function public.subscription_cancel(text)
from public, anon, authenticated;

revoke all on function public.subscription_undo_cancel()
from public, anon, authenticated;

revoke all on function platform.expire_cancelled_subscriptions()
from public, anon, authenticated;

revoke all on function platform.billable_subscriptions(date, date)
from public, anon, authenticated;

comment on table public.product_plans is
    'Plan / subscription type (SSOT 002). Prices, entitlements and upsell rules belong to Commerce 012.';

comment on column public.subscriptions.plan_id is
    'Plan of this subscription instance (SSOT 002). Price of the plan is owned by Commerce 012.';

comment on column public.subscriptions.cancel_effective_at is
    'First instant of the month after the cancellation request (platform.billing_timezone()). Status becomes cancelled then.';

comment on function platform.expire_cancelled_subscriptions() is
    'Sets status cancelled once cancel_effective_at has passed. Called hourly by the cron engine (027).';

comment on function platform.billable_subscriptions(date, date) is
    'Subscriptions that may be invoiced for the period; excludes periods beyond cancel_effective_at.';


-- =====================================================
-- 15. INTEGRATIONS API AND EXTENSIONS
-- =====================================================
--
-- EXISTING CROSS-MODULE DEPENDENCY
--
-- These wrappers are retained in this baseline so that
-- existing migration/function contracts are not removed.
--
-- The authoritative integration objects remain owned by
-- the integration module.
--
-- 002 does NOT become the SSOT for integration state.
-- =====================================================

create or replace function public.integrations_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when
            'list_providers',
            'get_provider',
            'list_capabilities',
            'list_tenant_integrations',
            'get_tenant_integration',
            'list_webhook_definitions',
            'list_device_maps'
        then
            perform public.edge_require_tenant();

        when
            'connect_integration',
            'update_integration',
            'disconnect_integration',
            'create_webhook_definition',
            'update_webhook_definition',
            'delete_webhook_definition',
            'create_device_map',
            'update_device_map',
            'delete_device_map',
            'register_oauth_state',
            'request_sync'
        then
            perform public.edge_require_manager();

        when
            'resolve_oauth_state',
            'complete_oauth'
        then
            null;

        else
            raise exception
                'unknown integrations_api operation: %',
                p_op;

    end case;

    return public.integrations_domain(
        p_op,
        p_payload
    );
end;
$$;


-- -----------------------------------------------------
-- Integration OAuth state and synchronization extension
-- -----------------------------------------------------

create or replace function public.integrations_domain_ext(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_uid uuid;
    v_result jsonb;
    v_state_token text;
    v_expires_at timestamptz;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

    when 'register_oauth_state' then

        v_tid := platform.current_tenant_id();
        v_uid := auth.uid();

        if v_tid is null then
            raise exception 'NO_ACTIVE_TENANT';
        end if;

        if v_uid is null then
            raise exception 'authentication required';
        end if;

        if p_payload->>'provider_code' is null then
            raise exception 'provider_code is required';
        end if;

        if not exists (
            select 1
            from public.integration_providers ip
            where ip.code =
                  p_payload->>'provider_code'
              and ip.supports_oauth = true
              and ip.is_active = true
        ) then
            raise exception
                'Integration provider not found or does not support OAuth';
        end if;

        v_state_token :=
            encode(
                extensions.gen_random_bytes(32),
                'hex'
            );

        v_expires_at :=
            now() + interval '10 minutes';

        insert into public.integration_oauth_states (
            tenant_id,
            user_id,
            provider_code,
            state_token,
            expires_at
        )
        values (
            v_tid,
            v_uid,
            p_payload->>'provider_code',
            v_state_token,
            v_expires_at
        );

        v_result := jsonb_build_object(
            'state_token',
            v_state_token,
            'expires_at',
            v_expires_at,
            'provider_code',
            p_payload->>'provider_code'
        );


    when 'request_sync' then

        v_tid := platform.current_tenant_id();
        v_uid := auth.uid();

        if v_tid is null then
            raise exception 'NO_ACTIVE_TENANT';
        end if;

        if v_uid is null then
            raise exception 'authentication required';
        end if;

        if p_payload->>'provider_code' is null then
            raise exception 'provider_code is required';
        end if;

        if not exists (
            select 1
            from public.tenant_integrations ti
            where ti.tenant_id = v_tid
              and ti.provider_code =
                  p_payload->>'provider_code'
              and ti.is_enabled = true
        ) then
            raise exception
                'Integration not connected or disabled';
        end if;

        perform platform.push_integration_event(
            p_payload->>'provider_code',
            'sync_state',
            jsonb_build_object(
                'tenant_id', v_tid,
                'triggered_by', v_uid,
                'scope',
                    coalesce(
                        p_payload->'scope',
                        '{}'::jsonb
                    )
            )
        );

        perform platform.log_audit(
            'integration.sync_requested',
            'tenant_integration',
            (
                select ti.id
                from public.tenant_integrations ti
                where ti.tenant_id = v_tid
                  and ti.provider_code =
                      p_payload->>'provider_code'
            ),
            jsonb_build_object(
                'provider_code',
                p_payload->>'provider_code'
            )
        );

        v_result := jsonb_build_object(
            'queued',
            true,
            'provider_code',
            p_payload->>'provider_code'
        );


    when 'resolve_oauth_state' then

        if p_payload->>'state_token' is null
           or length(
                trim(p_payload->>'state_token')
              ) = 0 then
            raise exception 'state_token is required';
        end if;

        return public.integrations_resolve_oauth_state(
            p_payload->>'state_token'
        );


    when 'complete_oauth' then

        if p_payload->>'state_token' is null
           or length(
                trim(p_payload->>'state_token')
              ) = 0 then
            raise exception 'state_token is required';
        end if;

        return public.integrations_complete_oauth(
            (p_payload->>'tenant_id')::uuid,
            p_payload->>'provider_code',
            p_payload->>'credentials_ref',
            p_payload->>'state_token'
        );


    else

        raise exception
            'unknown integrations_domain operation: %',
            p_op;

    end case;

    return v_result;
end;
$$;


-- =====================================================
-- 16. CORE UPDATED_AT AND PROVISIONING TRIGGERS
-- =====================================================

create trigger trg_customer_accounts_updated_at
before update on public.customer_accounts
for each row
execute function platform.set_updated_at();


create trigger trg_tenants_updated_at
before update on public.tenants
for each row
execute function platform.set_updated_at();


create trigger trg_memberships_updated_at
before update on public.tenant_memberships
for each row
execute function platform.set_updated_at();


create trigger trg_tenant_bootstrap_owner
after insert on public.tenants
for each row
execute function public.handle_new_tenant();


create trigger trg_memberships_owner_invariant
before update or delete on public.tenant_memberships
for each row
execute function public.enforce_tenant_owner_invariant();


create trigger trg_subscriptions_updated_at
before update on public.subscriptions
for each row
execute function platform.set_updated_at();


drop trigger if exists trg_product_plans_updated_at
on public.product_plans;

create trigger trg_product_plans_updated_at
before update on public.product_plans
for each row
execute function platform.set_updated_at();


-- =====================================================
-- 17. FINAL FUNCTION SECURITY ATTRIBUTES
--
-- These are function execution attributes only.
-- RLS, grants and policies remain outside this migration.
-- =====================================================

comment on function public.resolve_active_tenant(uuid, uuid)
is
    'REV22 core tenant authority. Current tenant resolution is derived exclusively from the authoritative membership resolver.';


alter function public.resolve_active_tenant(uuid, uuid)
set search_path = '';


alter function platform._rev21_resolve_membership(uuid, uuid)
set search_path = '';


alter function platform.current_role()
set search_path = '';


alter function platform.has_role(text)
set search_path = '';


comment on function platform.has_tenant_membership(uuid, uuid)
is
    'Compatibility shim. Delegates tenant membership verification to resolve_active_tenant(user_id, tenant_id).';


comment on function platform.current_tenant_id()
is
    'Non-authoritative domain context reader. Delegates current tenant resolution to resolve_active_tenant(auth.uid()).';


alter function platform.current_tenant_id()
set search_path = '';


comment on function public.current_customer_account_id()
is
    'Core customer-account context resolver. Returns the customer account owned by the authenticated user.';


comment on function public.get_customer_account_for_user(uuid)
is
    'Core customer-account ownership resolver. Customer ownership is authoritative in customer_accounts.owner_user_id.';


-- =====================================================
-- 18. REV22 TENANT AUTHORITY FREEZE
-- =====================================================
--
-- SINGLE SOURCE OF TRUTH
--
-- Current tenant resolution MUST ONLY occur through:
--
--     public.resolve_active_tenant(...)
--
-- The resolver delegates to:
--
--     platform._rev21_resolve_membership(...)
--
-- Membership SSOT:
--
--     public.tenant_memberships
--
-- Tenant SSOT:
--
--     public.tenants
--
-- Customer-account ownership SSOT:
--
--     public.customer_accounts
--
-- Customer-account ownership does NOT determine the current
-- tenant.
--
-- The following are NOT alternative tenant authorities:
--
--   - JWT tenant claims
--   - auth.users.raw_app_meta_data.tenant_id
--   - frontend state
--   - cached tenant context
--   - provider state
--   - integration state
--   - customer-account state
--
-- Direct membership queries are permitted for ordinary domain
-- operations such as listing and administration. They must not
-- independently determine the current tenant.
--
-- Any future alternative current-tenant resolution mechanism
-- constitutes architecture drift and requires an explicit
-- architecture decision.
-- =====================================================


-- =====================================================
-- 19. CUSTOMER ACCOUNT / TENANT OWNERSHIP CONTRACT
-- =====================================================
--
-- The core relationship is:
--
--   customer_accounts
--          │
--          │ owner_user_id
--          ▼
--       profiles
--          │
--          │ 1:N
--          ▼
--       tenants
--
-- Every tenant belongs to exactly one customer account.
--
-- Every customer account has exactly one owner user.
--
-- One owner user has exactly one customer account.
--
-- This gives Commerce a stable grouping boundary:
--
--   customer_account
--       ├── tenant 1
--       ├── tenant 2
--       └── tenant 3
--
-- Commerce may use this grouping for pricing and volume
-- discounts, but the pricing result is NOT stored in 002.
--
-- 002 therefore remains the SSOT for:
--
--   - customer ownership
--   - tenant ownership relationship
--   - tenant access
--   - tenant lifecycle
--   - plan / subscription type (product_plans)
--   - subscription instance: which plan a tenant has, status,
--     term (current_period_*), trial expiry, end-of-month
--     cancellation state and its expiry job
--
-- 012 Commerce remains responsible for:
--
--   - normal plan prices (plan_pricing)
--   - discount policy (discount codes)
--   - customer-account discount tiers (tenant-count based)
--   - the applied-discount history (applied_discounts)
--   - feature entitlements, upsell rules
--   - invoices, billing, e-invoicing
--   - effective price calculation
-- =====================================================


-- =====================================================
-- 20. 002 DEPENDENCY CONTRACT
-- =====================================================
--
-- 002 expects the following pre-existing core dependencies:
--
--   platform.profiles
--   platform.schema_migrations
--
--   platform.set_updated_at(...)
--   platform.log_audit(...)
--   platform.is_platform_admin(...)
--   public.is_platform_admin(...)
--
--   public.edge_require_admin(...)
--   public.edge_require_manager(...)
--   public.edge_require_tenant(...)
--
--   auth.uid()
--
--   public.tenant_status
--   public.membership_role
--   public.subscription_tier
--   public.subscription_status
--
--   gen_random_uuid()
--   extensions.gen_random_bytes(...)
--
--
-- Integration objects referenced by the retained integration
-- wrappers are owned by the integration module:
--
--   public.integration_providers
--   public.tenant_integrations
--   public.integration_oauth_states
--   public.integrations_domain(...)
--   public.integrations_resolve_oauth_state(...)
--   public.integrations_complete_oauth(...)
--
-- 002 does NOT own the SSOT of those integration objects.
--
-- Security hardening, RLS, policies and grants are deliberately
-- excluded from this migration.
-- =====================================================


-- =====================================================
-- 21. MIGRATION MARKER
-- =====================================================

insert into platform.schema_migrations ( migration_name, version, rollback_available)
values ( '002_core_saas', 'REV1', false)
on conflict (migration_name)
do update
set
    version = excluded.version,
    rollback_available = excluded.rollback_available;


-- =====================================================
-- END 002 CORE SAAS
-- =====================================================