-- =====================================================
-- REV2 GREENFIELD BASELINE
-- 004_PROPERTY_DEVICE_ENGINE.SQL
-- =====================================================
--
-- OWNER:
--   Property & Device Engine
--
-- SSOT:
--   properties
--   product_plans (global catalogue)
--   subscriptions (one optional instance per property)
--   rooms
--   devices
--   device_assignments
--   device_configurations
--   device_categories
--
-- ARCHITECTURAL BOUNDARIES:
--   004 owns the SmartHellas device/domain registry.
--   004 does NOT own provider identity.
--   004 does NOT own telemetry.
--   004 does NOT own runtime device state.
--   004 does NOT contain provider-specific integration logic.
--
-- SECURITY BOUNDARY:
--   022 and 024 = central security/grant boundaries; no grants or policies here
--
-- PUBLIC API:
--   public.devices_api(text,jsonb)
--
-- INTERNAL DOMAIN API:
--   public.devices_domain(text,jsonb)
--
-- IMPORTANT:
--   devices_domain remains an internal SECURITY DEFINER domain function.
--   devices_api is the authenticated-facing API contract expected by 023.
--
-- AUDIT:
--   platform.log_audit() is owned by the Platform/Audit layer 000.
--   004 only invokes the platform audit contract.
--
-- =====================================================


-- =====================================================
-- 1. PROPERTIES (AIRBNB UNITS)
-- =====================================================

create table if not exists public.properties (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    name text not null,

    address text,

    property_type public.property_type not null,

    timezone text default 'UTC',

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    -- Supports composite FK from subscriptions:
    -- property_id + tenant_id must always resolve to
    -- the same property/tenant combination.
    unique (id, tenant_id)
);


-- =====================================================
-- 1A. PROPERTY MEMBERSHIPS (RESOURCE ACCESS)
--
-- Property membership is the resource-level access relationship.
-- It deliberately does not replace tenant_memberships in 002.
--
-- Access model:
--
--   platform.profiles
--          |
--          v
--   property_memberships
--          |
--          v
--       properties
--          |
--          v
--        tenants
--
-- A customer-account owner is automatically made owner of every
-- property created under a tenant belonging to that account.
--
-- Customer-account ownership itself remains authoritative in:
--   customer_accounts.owner_user_id
--
-- Property access is authoritative in:
--   property_memberships
-- =====================================================

create table if not exists public.property_memberships (
    id uuid primary key default gen_random_uuid(),

    property_id uuid not null,

    user_id uuid not null
        references platform.profiles(id)
        on delete cascade,

    role public.membership_role not null,

    is_active boolean not null default true,

    revoked_at timestamptz,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    unique (property_id, user_id),

    -- The property and tenant pair must refer to the same property.
    -- The tenant is derived from the property and is deliberately
    -- not stored as a second independent authority here.
    foreign key (property_id)
        references public.properties(id)
        on delete cascade
);

create unique index if not exists uq_property_memberships_active_owner
on public.property_memberships (property_id)
where role = 'owner' and is_active = true;

create index if not exists idx_property_memberships_user_active
on public.property_memberships (user_id, property_id)
where is_active = true;

create index if not exists idx_property_memberships_property_active
on public.property_memberships (property_id, user_id)
where is_active = true;

comment on table public.property_memberships is
    'Property-level resource access SSOT. A user sees and operates a property through an active membership. Tenant membership remains a separate organizational relationship in 002.';

comment on column public.property_memberships.role is
    'Property-level role. owner is automatically assigned to the customer_accounts.owner_user_id when a property is created.';


-- Resource-level authorization helper. It does not replace the tenant resolver.
create or replace function public.assert_property_access(p_property_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
    if p_property_id is null then raise exception 'property_id is required'; end if;
    if public.is_platform_admin() or coalesce(auth.role(), '') = 'service_role' then return; end if;
    if (select auth.uid()) is null then raise exception 'authentication required'; end if;
    if not exists (
        select 1 from public.property_memberships pm
        where pm.property_id = p_property_id
          and pm.user_id = (select auth.uid())
          and pm.is_active = true
    ) then raise exception 'property access denied'; end if;
end;
$$;

create or replace function public.assert_property_manager(p_property_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
    if public.is_platform_admin() or coalesce(auth.role(), '') = 'service_role' then return; end if;
    if (select auth.uid()) is null then raise exception 'authentication required'; end if;
    if not exists (
        select 1 from public.property_memberships pm
        where pm.property_id = p_property_id
          and pm.user_id = (select auth.uid())
          and pm.is_active = true
          and pm.role::text in ('owner', 'manager')
    ) then raise exception 'property manager access required'; end if;
end;
$$;


-- =====================================================
-- 1A. PRODUCT PLANS (GLOBAL SUBSCRIPTION CATALOGUE)
-- =====================================================
-- Plans are reusable catalogue definitions, not tenant- or property-owned
-- records. Each subscription instance below attaches one plan to exactly
-- one property. Pricing, entitlements and upsell rules remain in Commerce 012.
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
    constraint chk_product_plans_name_nonempty check (btrim(name) <> '')
);

create unique index if not exists uq_product_plans_name_ci
    on public.product_plans (lower(name));

-- At most one global default plan, used as a suggested/default plan in the purchase flow; it does not auto-subscribe a property.
create unique index if not exists uq_product_plans_default
    on public.product_plans (is_default) where is_default = true;

comment on table public.product_plans is
    'Global subscription plan catalogue SSOT (004). Plans are not tenant/property-owned; each property has its own subscription instance. Prices, entitlements and upsell rules belong to Commerce 012.';

-- =====================================================
-- 1B. PROPERTY-SCOPED SUBSCRIPTIONS
--
-- One subscription = one property.
--
-- tenant_id remains the tenant/security boundary.
-- property_id identifies the actual Airbnb/building
-- for which the subscription is purchased.
--
-- Customer-account ownership is NOT duplicated here.
-- It is derived through:
--
--   subscription
--       ↓
--   property
--       ↓
--   tenant
--       ↓
--   customer_account
--
-- Commerce/012 determines pricing and discounts.
-- 004 owns the property subscription relationship because
-- the subscription has a direct dependency on properties.
-- =====================================================

create table if not exists public.subscriptions (
    id uuid primary key default gen_random_uuid(),

    -- tenant_id is a constrained denormalization for existing tenant-level
    -- joins; property_id is the commercial/subscription scope.
    tenant_id uuid not null references public.tenants(id) on delete cascade,
    property_id uuid not null,
    plan_id uuid not null references public.product_plans(id) on delete restrict,

    tier public.subscription_tier not null,
    status public.subscription_status not null default 'trial',
    current_period_start timestamptz,
    current_period_end timestamptz,
    cancel_requested_at timestamptz,
    cancel_effective_at timestamptz,
    cancel_reason text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint uq_subscriptions_property unique (property_id),
    constraint chk_subscription_period check (
        current_period_end is null or current_period_start is null
        or current_period_end >= current_period_start
    ),
    constraint chk_subscription_cancel_fields check (
        (cancel_requested_at is null and cancel_effective_at is null)
        or (cancel_requested_at is not null and cancel_effective_at is not null)
    ),
    foreign key (property_id, tenant_id)
        references public.properties(id, tenant_id) on delete cascade
);


create index if not exists idx_subscriptions_plan on public.subscriptions (plan_id);
create index if not exists idx_subscriptions_cancel_effective
    on public.subscriptions (cancel_effective_at) where cancel_effective_at is not null;
create index if not exists idx_subscriptions_trial_end
    on public.subscriptions (current_period_end) where status = 'trial';
create index if not exists idx_subscriptions_tenant on public.subscriptions (tenant_id);
create index if not exists idx_subscriptions_property_status on public.subscriptions (property_id, status);

comment on table public.subscriptions is
    'One subscription instance per property. tenant_id is constrained to the property and is retained only as a derived tenant-scope key; plan_id references the global plan catalogue.';
comment on column public.subscriptions.plan_id is
    'Global product plan selected for this property subscription. Plan pricing is owned by Commerce 012.';
comment on column public.subscriptions.cancel_effective_at is
    'First instant of the month after cancellation request in platform.billing_timezone(); status becomes cancelled after this instant.';

-- =====================================================
-- 2. ROOMS (LOGICAL STRUCTURE INSIDE PROPERTY)
-- =====================================================

create table if not exists public.rooms (
    id uuid primary key default gen_random_uuid(),

    property_id uuid not null
        references public.properties(id)
        on delete cascade,

    name text not null,

    room_type public.room_type not null,

    floor int,

    created_at timestamptz default now()
);


-- =====================================================
-- 3. DEVICE CATEGORIES (HARDWARE TAXONOMY / SSOT)
-- =====================================================

create table if not exists public.device_categories (
    code text primary key,

    name text not null,

    description text,

    is_gateway boolean not null default false,

    is_lock boolean not null default false,

    is_active boolean not null default true,

    sort_order int not null default 0,

    created_at timestamptz not null default now()
);


-- =====================================================
-- 4. DEVICES (MASTER DEVICE REGISTRY)
--
-- parent_device_id = local device hierarchy.
--
-- Examples:
--   Aqara M3 gateway
--       ├── temperature sensor
--       ├── motion sensor
--       └── smart plug
--
-- 004 owns the local device relationship only.
-- Provider-side identity belongs to the Integration Engine.
-- =====================================================

create table if not exists public.devices (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    -- Explicit resource ownership. The device belongs to one property.
    -- Tenant remains denormalized for existing domain dependencies and is
    -- constrained against the property's tenant below.
    property_id uuid not null,

    parent_device_id uuid
        references public.devices(id)
        on delete set null,

    device_name text not null,

    category_code text not null
        references public.device_categories(code),

    protocol public.device_protocol not null,

    model text,

    manufacturer text,

    is_active boolean not null default true,

    created_at timestamptz default now()
);


-- =====================================================
-- 5. DEVICE ASSIGNMENT (DEVICE ↔ ROOM LINK)
-- =====================================================

create table if not exists public.device_assignments (
    id uuid primary key default gen_random_uuid(),

    device_id uuid not null
        references public.devices(id)
        on delete cascade,

    room_id uuid not null
        references public.rooms(id)
        on delete cascade,

    assigned_at timestamptz default now(),

    unique (device_id)
);


-- =====================================================
-- 6. DEVICE CONFIGURATION (STATIC SETUP ONLY)
-- =====================================================

create table if not exists public.device_configurations (
    id uuid primary key default gen_random_uuid(),

    device_id uuid not null
        references public.devices(id)
        on delete cascade,

    config jsonb not null,

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    unique (device_id)
);


-- =====================================================
-- 7. INDEXES
-- =====================================================

create index if not exists idx_properties_tenant
on public.properties (tenant_id);

create index if not exists idx_properties_tenant_created
on public.properties (tenant_id, created_at desc);

create index if not exists idx_rooms_property
on public.rooms (property_id);

create index if not exists idx_devices_tenant
on public.devices (tenant_id);

create index if not exists idx_devices_property
on public.devices (property_id);

create index if not exists idx_devices_property_created
on public.devices (property_id, created_at desc);

create index if not exists idx_devices_tenant_created
on public.devices (tenant_id, created_at desc);

create index if not exists idx_devices_category
on public.devices (category_code);

create index if not exists idx_devices_parent
on public.devices (parent_device_id)
where parent_device_id is not null;

create index if not exists idx_devices_tenant_parent
on public.devices (tenant_id, parent_device_id)
where parent_device_id is not null;

create index if not exists idx_device_assignments_room
on public.device_assignments (room_id);

create index if not exists idx_device_assignments_device_assigned
on public.device_assignments (device_id, assigned_at desc);

create index if not exists idx_device_configurations_device_created
on public.device_configurations (device_id, created_at desc);


-- =====================================================
-- 8. COMMENTS / SSOT DECLARATIONS
-- =====================================================

comment on table public.device_categories is
    'Hardware device taxonomy. code is the stable FK target for category_code columns. Seed: 004.';

comment on table public.devices is
    'SmartHellas device registry SSOT. Each device belongs to exactly one property. Provider identity belongs to the Integration Engine. Runtime telemetry/state belongs outside 004.';

comment on column public.devices.property_id is
    'Property resource owner of the device. This is immutable after device creation; tenant_id is retained for existing domain dependencies and constrained to the same property.';

comment on table public.device_configurations is
    'Static provisioning configuration only. Do not store runtime telemetry, live state, provider identity, or provider webhook data.';

comment on column public.devices.parent_device_id is
    'Local device hierarchy only. Provider-side device identity is owned by the Integration Engine.';


-- =====================================================
-- 9. PLATFORM EXECUTION BINDING + TENANT FKs
-- =====================================================

do $$
begin

    alter table public.properties
        add constraint fk_properties_tenant
        foreign key (tenant_id)
        references public.tenants(id)
        on delete cascade;

exception
    when duplicate_object then null;
end $$;


do $$
begin

    alter table public.devices
        add constraint fk_devices_tenant
        foreign key (tenant_id)
        references public.tenants(id)
        on delete cascade;

exception
    when duplicate_object then null;
end $$;


do $$
begin

    alter table public.devices
        add constraint fk_devices_property_tenant
        foreign key (property_id, tenant_id)
        references public.properties(id, tenant_id)
        on delete cascade;

exception
    when duplicate_object then null;
end $$;


do $$
begin

    alter table platform.device_commands
        add constraint fk_device_commands_device
        foreign key (device_id)
        references public.devices(id)
        on delete restrict;

exception
    when duplicate_object then null;
end $$;


comment on constraint fk_device_commands_device
on platform.device_commands is
    'Domain device registry (004) is SSOT; restrict delete while commands may exist.';


-- =====================================================
-- 9A. PROPERTY MEMBERSHIP MAINTENANCE
-- =====================================================

drop trigger if exists trg_property_memberships_updated_at
on public.property_memberships;

create trigger trg_property_memberships_updated_at
before update on public.property_memberships
for each row
execute function platform.set_updated_at();


-- -----------------------------------------------------
-- Automatically make the customer-account owner the
-- owner of every newly created property.
-- -----------------------------------------------------

create or replace function public.bootstrap_property_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_owner_user_id uuid;
begin
    select ca.owner_user_id
      into v_owner_user_id
      from public.tenants t
      join public.customer_accounts ca
        on ca.id = t.customer_account_id
     where t.id = new.tenant_id;

    if v_owner_user_id is null then
        raise exception 'Property cannot be created without a customer-account owner';
    end if;

    insert into public.property_memberships (
        property_id,
        user_id,
        role,
        is_active,
        revoked_at
    )
    values (
        new.id,
        v_owner_user_id,
        'owner'::public.membership_role,
        true,
        null
    );

    return new;
end;
$$;


drop trigger if exists trg_property_bootstrap_owner
on public.properties;

create trigger trg_property_bootstrap_owner
after insert on public.properties
for each row
execute function public.bootstrap_property_owner();


-- =====================================================
-- 10. TENANT ID IMMUTABILITY
--
-- tenant_id is part of the security identity of the
-- domain object and may never be moved between tenants.
--
-- This does NOT affect normal create/update operations.
-- Existing domain APIs never modify tenant_id.
-- =====================================================

create or replace function public.prevent_tenant_id_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin

    if tg_op = 'UPDATE'
       and new.tenant_id is distinct from old.tenant_id then

        raise exception 'tenant_id is immutable';

    end if;

    if tg_op = 'UPDATE'
       and new.property_id is distinct from old.property_id then

        raise exception 'property_id is immutable';

    end if;

    return new;

end;
$$;


drop trigger if exists trg_properties_tenant_immutable
on public.properties;

create trigger trg_properties_tenant_immutable
before update on public.properties
for each row
execute function public.prevent_tenant_id_change();


drop trigger if exists trg_devices_tenant_immutable
on public.devices;

create trigger trg_devices_tenant_immutable
before update on public.devices
for each row
execute function public.prevent_tenant_id_change();


-- =====================================================
-- 12. DEVICE OVERVIEW
-- =====================================================

create or replace view public.v_devices_overview
with (security_invoker = true)
as
select
    d.id,
    d.tenant_id,
    d.property_id,
    d.device_name,
    d.category_code,
    dc.name as category_name,
    d.protocol,
    d.model,
    d.manufacturer,
    d.is_active,
    r.id as room_id,
    r.name as room_name,
    r.property_id as room_property_id,
    p.name as property_name,
    d.created_at
from public.devices d
left join public.device_categories dc
    on dc.code = d.category_code
left join public.device_assignments da
    on da.device_id = d.id
left join public.rooms r
    on r.id = da.room_id
left join public.properties p
    on p.id = r.property_id;


-- =====================================================
-- 13. DEVICE ASSIGNMENT WORKFLOW
-- =====================================================

create or replace function public.devices_assign_device_to_room(
    p_device_id uuid,
    p_room_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_row record;
    v_existing uuid;
    v_property_id uuid;
begin

    perform public.edge_require_manager();

    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;


    -- -------------------------------------------------
    -- 1. Device must belong to active tenant
    -- -------------------------------------------------

    if not exists (
        select 1
        from public.devices d
        where d.id = p_device_id
          and d.tenant_id = v_tid
    ) then
        raise exception 'Device not found';
    end if;


    -- -------------------------------------------------
    -- 2. Room must belong to active tenant
    -- -------------------------------------------------

    if not exists (
        select 1
        from public.rooms r
        join public.properties p
          on p.id = r.property_id
        where r.id = p_room_id
          and p.tenant_id = v_tid
    ) then
        raise exception 'Room not found';
    end if;


    if not exists (
        select 1
        from public.devices d
        join public.rooms r
          on r.property_id = d.property_id
        where d.id = p_device_id
          and r.id = p_room_id
          and d.tenant_id = v_tid
    ) then
        raise exception 'Device and room must belong to the same property';
    end if;

    select d.property_id into v_property_id
    from public.devices d
    where d.id = p_device_id;
    perform public.assert_property_manager(v_property_id);


    -- -------------------------------------------------
    -- 3. Existing assignment?
    --    A device may have only one room.
    -- -------------------------------------------------

    select da.id
    into v_existing
    from public.device_assignments da
    where da.device_id = p_device_id;


    if found then

        update public.device_assignments
        set room_id = p_room_id
        where id = v_existing
        returning id, device_id, room_id, assigned_at
        into v_row;

    else

        insert into public.device_assignments
        (
            device_id,
            room_id
        )
        values
        (
            p_device_id,
            p_room_id
        )
        returning id, device_id, room_id, assigned_at
        into v_row;

    end if;


    -- -------------------------------------------------
    -- 4. Successful assignment makes the device active
    -- -------------------------------------------------

    update public.devices
    set is_active = true
    where id = p_device_id
      and tenant_id = v_tid;


    -- -------------------------------------------------
    -- 5. Return actual assignment
    -- -------------------------------------------------

    return jsonb_build_object(
        'assignment_id', v_row.id,
        'device_id', v_row.device_id,
        'room_id', v_row.room_id,
        'assigned_at', v_row.assigned_at
    );

end;
$$;


-- =====================================================
-- 14. DEVICES DOMAIN API
--
-- INTERNAL DOMAIN FUNCTION.
--
-- 023 deliberately revokes authenticated EXECUTE
-- from *_domain functions.
--
-- public.devices_api() below is the approved external
-- API boundary.
-- =====================================================

create or replace function public.devices_domain(
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
    v_result jsonb;
    v_row record;
    v_device_id uuid;
    v_previous_room_id uuid;
    v_property_id uuid;
begin

    p_payload := coalesce(
        p_payload,
        '{}'::jsonb
    );

    -- Resource-level authorization. Tenant context remains an additional
    -- boundary in the existing queries; property_memberships is the SSOT
    -- for whether this user may access or manage the specific Airbnb.
    case p_op
        when 'get_property' then
            perform public.assert_property_access((p_payload->>'id')::uuid);
        when 'update_property', 'delete_property' then
            perform public.assert_property_manager((p_payload->>'id')::uuid);

        when 'list_rooms' then
            if p_payload ? 'property_id' then
                perform public.assert_property_access((p_payload->>'property_id')::uuid);
            end if;
        when 'get_room', 'update_room', 'delete_room' then
            select r.property_id into v_property_id
            from public.rooms r
            where r.id = (p_payload->>'id')::uuid;
            if v_property_id is null then raise exception 'Room not found'; end if;
            if p_op = 'get_room' then
                perform public.assert_property_access(v_property_id);
            else
                perform public.assert_property_manager(v_property_id);
            end if;
        when 'create_room' then
            perform public.assert_property_manager((p_payload->>'property_id')::uuid);

        when 'list_devices' then
            -- The domain query prioritizes room_id when both filters are sent;
            -- authorize that same resource first to prevent filter confusion.
            if p_payload ? 'room_id' then
                select r.property_id into v_property_id
                from public.rooms r
                where r.id = (p_payload->>'room_id')::uuid;
                if v_property_id is null then raise exception 'Room not found'; end if;
                perform public.assert_property_access(v_property_id);
            elsif p_payload ? 'property_id' then
                perform public.assert_property_access((p_payload->>'property_id')::uuid);
            end if;
        when 'get_device', 'update_device', 'delete_device', 'unassign_device',
             'get_device_config', 'upsert_device_config',
             'list_device_metrics', 'get_device_current_state' then
            v_device_id := coalesce(
                nullif(p_payload->>'id', '')::uuid,
                nullif(p_payload->>'device_id', '')::uuid
            );
            select d.property_id into v_property_id
            from public.devices d
            where d.id = v_device_id;
            if v_property_id is null then raise exception 'Device not found'; end if;
            if p_op in ('update_device', 'delete_device', 'unassign_device', 'upsert_device_config') then
                perform public.assert_property_manager(v_property_id);
            else
                perform public.assert_property_access(v_property_id);
            end if;
        when 'create_device' then
            perform public.assert_property_manager((p_payload->>'property_id')::uuid);
        when 'assign_device' then
            v_device_id := (p_payload->>'device_id')::uuid;
            select d.property_id into v_property_id
            from public.devices d
            where d.id = v_device_id;
            if v_property_id is null then raise exception 'Device not found'; end if;
            perform public.assert_property_manager(v_property_id);
        else
            null;
    end case;

    case p_op


    -- =================================================
    -- PROPERTIES
    -- =================================================

    when 'list_properties' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.created_at
            ),
            '[]'::jsonb
        )
        into v_result
        from
        (
            select
                p.id,
                p.tenant_id,
                p.name,
                p.address,
                p.property_type,
                p.timezone,
                p.created_at,
                p.updated_at
            from public.properties p
            where p.tenant_id = v_tid
              and (
                  public.is_platform_admin()
                  or coalesce(auth.role(), '') = 'service_role'
                  or exists (
                      select 1 from public.property_memberships pm
                      where pm.property_id = p.id
                        and pm.user_id = (select auth.uid())
                        and pm.is_active = true
                  )
              )
        ) t;


    when 'get_property' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        select to_jsonb(t)
        into v_result
        from
        (
            select
                p.id,
                p.tenant_id,
                p.name,
                p.address,
                p.property_type,
                p.timezone,
                p.created_at,
                p.updated_at
            from public.properties p
            where p.id = (p_payload->>'id')::uuid
              and p.tenant_id = v_tid
        ) t;


        if v_result is null then
            raise exception 'Property not found';
        end if;


    when 'create_property' then

        perform public.edge_require_manager();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        insert into public.properties
        (
            tenant_id,
            name,
            address,
            property_type,
            timezone
        )
        values
        (
            v_tid,
            p_payload->>'name',
            p_payload->>'address',
            (p_payload->>'property_type')::public.property_type,
            coalesce(
                p_payload->>'timezone',
                'UTC'
            )
        )
        returning
            id,
            tenant_id,
            name,
            address,
            property_type,
            timezone,
            created_at,
            updated_at
        into v_row;


        v_result := to_jsonb(v_row);

        perform platform.log_audit(
            'property.created',
            'property',
            v_row.id
        );


    when 'update_property' then

        perform public.edge_require_manager();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        update public.properties p
        set
            name =
                case
                    when p_payload ? 'name'
                    then p_payload->>'name'
                    else p.name
                end,

            address =
                case
                    when p_payload ? 'address'
                    then p_payload->>'address'
                    else p.address
                end,

            property_type =
                case
                    when p_payload ? 'property_type'
                    then
                        (p_payload->>'property_type')
                        ::public.property_type
                    else p.property_type
                end,

            timezone =
                case
                    when p_payload ? 'timezone'
                    then p_payload->>'timezone'
                    else p.timezone
                end

        where p.id = (p_payload->>'id')::uuid
          and p.tenant_id = v_tid

        returning
            p.id,
            p.tenant_id,
            p.name,
            p.address,
            p.property_type,
            p.timezone,
            p.created_at,
            p.updated_at
        into v_row;


        if not found then
            raise exception 'Property not found';
        end if;


        v_result := to_jsonb(v_row);

        perform platform.log_audit(
            'property.updated',
            'property',
            v_row.id
        );


    when 'delete_property' then

        perform public.edge_require_manager();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        delete from public.properties p
        where p.id = (p_payload->>'id')::uuid
          and p.tenant_id = v_tid;


        if not found then
            raise exception 'Property not found';
        end if;


        v_result := jsonb_build_object(
            'deleted',
            true,
            'id',
            p_payload->>'id'
        );

        perform platform.log_audit(
            'property.deleted',
            'property',
            (p_payload->>'id')::uuid
        );


    -- =================================================
    -- ROOMS
    -- =================================================

    when 'list_rooms' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        if p_payload ? 'property_id' then

            if not exists (
                select 1
                from public.properties p
                where p.id =
                    (p_payload->>'property_id')::uuid
                  and p.tenant_id = v_tid
            ) then
                raise exception 'Property not found';
            end if;


            select coalesce(
                jsonb_agg(
                    to_jsonb(t)
                    order by t.created_at
                ),
                '[]'::jsonb
            )
            into v_result
            from
            (
                select
                    r.id,
                    r.property_id,
                    r.name,
                    r.room_type,
                    r.floor,
                    r.created_at
                from public.rooms r
                join public.properties p
                  on p.id = r.property_id
                where r.property_id =
                    (p_payload->>'property_id')::uuid
                  and p.tenant_id = v_tid
            ) t;


        else

            select coalesce(
                jsonb_agg(
                    to_jsonb(t)
                    order by t.created_at
                ),
                '[]'::jsonb
            )
            into v_result
            from
            (
                select
                    r.id,
                    r.property_id,
                    r.name,
                    r.room_type,
                    r.floor,
                    r.created_at
                from public.rooms r
                join public.properties p
                  on p.id = r.property_id
                where p.tenant_id = v_tid
                  and (
                      public.is_platform_admin()
                      or coalesce(auth.role(), '') = 'service_role'
                      or exists (
                          select 1 from public.property_memberships pm
                          where pm.property_id = p.id
                            and pm.user_id = (select auth.uid())
                            and pm.is_active = true
                      )
                  )
            ) t;

        end if;


    when 'get_room' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        select to_jsonb(t)
        into v_result
        from
        (
            select
                r.id,
                r.property_id,
                r.name,
                r.room_type,
                r.floor,
                r.created_at
            from public.rooms r
            join public.properties p
              on p.id = r.property_id
            where r.id = (p_payload->>'id')::uuid
              and p.tenant_id = v_tid
        ) t;


        if v_result is null then
            raise exception 'Room not found';
        end if;


    when 'create_room' then

        perform public.edge_require_manager();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        if not exists (
            select 1
            from public.properties p
            where p.id =
                (p_payload->>'property_id')::uuid
              and p.tenant_id = v_tid
        ) then
            raise exception 'Property not found';
        end if;


        insert into public.rooms
        (
            property_id,
            name,
            room_type,
            floor
        )
        values
        (
            (p_payload->>'property_id')::uuid,
            p_payload->>'name',
            (p_payload->>'room_type')::public.room_type,
            case
                when p_payload ? 'floor'
                 and p_payload->>'floor' is not null
                then (p_payload->>'floor')::int
                else null
            end
        )
        returning
            id,
            property_id,
            name,
            room_type,
            floor,
            created_at
        into v_row;


        v_result := to_jsonb(v_row);

        perform platform.log_audit(
            'room.created',
            'room',
            v_row.id
        );


    when 'update_room' then

        perform public.edge_require_manager();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        update public.rooms r
        set
            name =
                case
                    when p_payload ? 'name'
                    then p_payload->>'name'
                    else r.name
                end,

            room_type =
                case
                    when p_payload ? 'room_type'
                    then
                        (p_payload->>'room_type')
                        ::public.room_type
                    else r.room_type
                end,

            floor =
                case
                    when p_payload ? 'floor'
                    then
                        case
                            when p_payload->>'floor' is null
                            then null
                            else
                                (p_payload->>'floor')::int
                        end
                    else r.floor
                end

        from public.properties p

        where r.id = (p_payload->>'id')::uuid
          and p.id = r.property_id
          and p.tenant_id = v_tid

        returning
            r.id,
            r.property_id,
            r.name,
            r.room_type,
            r.floor,
            r.created_at
        into v_row;


        if not found then
            raise exception 'Room not found';
        end if;


        v_result := to_jsonb(v_row);

        perform platform.log_audit(
            'room.updated',
            'room',
            v_row.id
        );


    when 'delete_room' then

        perform public.edge_require_manager();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        delete from public.rooms r
        using public.properties p
        where r.id = (p_payload->>'id')::uuid
          and p.id = r.property_id
          and p.tenant_id = v_tid;


        if not found then
            raise exception 'Room not found';
        end if;


        v_result := jsonb_build_object(
            'deleted',
            true,
            'id',
            p_payload->>'id'
        );

        perform platform.log_audit(
            'room.deleted',
            'room',
            (p_payload->>'id')::uuid
        );


    -- =================================================
    -- DEVICE CATEGORIES
    -- =================================================

    when 'list_device_categories' then

        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.sort_order
            ),
            '[]'::jsonb
        )
        into v_result
        from
        (
            select
                dc.code,
                dc.name,
                dc.description,
                dc.is_gateway,
                dc.is_lock,
                dc.is_active,
                dc.sort_order
            from public.device_categories dc
            where dc.is_active = true
        ) t;


    -- =================================================
    -- DEVICES
    -- =================================================

    when 'list_devices' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        if p_payload ? 'room_id' then

            if not exists (
                select 1
                from public.rooms r
                join public.properties p
                  on p.id = r.property_id
                where r.id =
                    (p_payload->>'room_id')::uuid
                  and p.tenant_id = v_tid
            ) then
                raise exception 'Room not found';
            end if;


            select coalesce(
                jsonb_agg(
                    to_jsonb(t)
                    order by t.created_at
                ),
                '[]'::jsonb
            )
            into v_result
            from
            (
                select
                    d.id,
                    d.tenant_id,
                    d.property_id,
                    d.parent_device_id,
                    d.device_name,
                    d.category_code,
                    d.protocol,
                    d.model,
                    d.manufacturer,
                    d.is_active,
                    d.created_at
                from public.devices d
                where d.tenant_id = v_tid
                  and d.id in
                  (
                      select da.device_id
                      from public.device_assignments da
                      where da.room_id =
                          (p_payload->>'room_id')::uuid
                  )
            ) t;


        elsif p_payload ? 'property_id' then

            if not exists (
                select 1
                from public.properties p
                where p.id =
                    (p_payload->>'property_id')::uuid
                  and p.tenant_id = v_tid
            ) then
                raise exception 'Property not found';
            end if;


            select coalesce(
                jsonb_agg(
                    to_jsonb(t)
                    order by t.created_at
                ),
                '[]'::jsonb
            )
            into v_result
            from
            (
                select
                    d.id,
                    d.tenant_id,
                    d.property_id,
                    d.parent_device_id,
                    d.device_name,
                    d.category_code,
                    d.protocol,
                    d.model,
                    d.manufacturer,
                    d.is_active,
                    d.created_at
                from public.devices d
                where d.tenant_id = v_tid
                  and d.property_id =
                      (p_payload->>'property_id')::uuid
            ) t;


        else

            select coalesce(
                jsonb_agg(
                    to_jsonb(t)
                    order by t.created_at
                ),
                '[]'::jsonb
            )
            into v_result
            from
            (
                select
                    d.id,
                    d.tenant_id,
                    d.property_id,
                    d.parent_device_id,
                    d.device_name,
                    d.category_code,
                    d.protocol,
                    d.model,
                    d.manufacturer,
                    d.is_active,
                    d.created_at
                from public.devices d
                where d.tenant_id = v_tid
                  and (
                      public.is_platform_admin()
                      or coalesce(auth.role(), '') = 'service_role'
                      or exists (
                          select 1 from public.property_memberships pm
                          where pm.property_id = d.property_id
                            and pm.user_id = (select auth.uid())
                            and pm.is_active = true
                      )
                  )
            ) t;

        end if;


    when 'get_device' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        v_device_id :=
            (p_payload->>'id')::uuid;


        select jsonb_build_object(

            'id',
            d.id,

            'tenant_id',
            d.tenant_id,

            'property_id',
            d.property_id,

            'parent_device_id',
            d.parent_device_id,

            'device_name',
            d.device_name,

            'category_code',
            d.category_code,

            'protocol',
            d.protocol,

            'model',
            d.model,

            'manufacturer',
            d.manufacturer,

            'is_active',
            d.is_active,

            'created_at',
            d.created_at,

            'assignment',
            case
                when da.device_id is not null
                then jsonb_build_object(

                    'room_id',
                    da.room_id,

                    'assigned_at',
                    da.assigned_at,

                    'room',
                    case
                        when rm.id is not null
                        then jsonb_build_object(
                            'id',
                            rm.id,
                            'name',
                            rm.name,
                            'property_id',
                            rm.property_id
                        )
                        else null
                    end
                )
                else null
            end,

            'config',
            dc.config

        )
        into v_result

        from public.devices d

        left join public.device_assignments da
            on da.device_id = d.id

        left join public.rooms rm
            on rm.id = da.room_id

        left join public.device_configurations dc
            on dc.device_id = d.id

        where d.id = v_device_id
          and d.tenant_id = v_tid;


        if v_result is null then
            raise exception 'Device not found';
        end if;


    when 'create_device' then

        perform public.edge_require_manager();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        if not exists (
            select 1
            from public.properties p
            where p.id = (p_payload->>'property_id')::uuid
              and p.tenant_id = v_tid
        ) then
            raise exception 'Property not found';
        end if;


        if p_payload ? 'parent_device_id'
           and p_payload->>'parent_device_id' is not null
        then

            if not exists (
                select 1
                from public.devices pd
                where pd.id =
                    (p_payload->>'parent_device_id')::uuid
                  and pd.tenant_id = v_tid
                  and pd.property_id = (p_payload->>'property_id')::uuid
            ) then
                raise exception 'Parent device not found in property';
            end if;

        end if;


        insert into public.devices
        (
            tenant_id,
            property_id,
            device_name,
            category_code,
            protocol,
            parent_device_id,
            model,
            manufacturer,
            is_active
        )
        values
        (
            v_tid,
            (p_payload->>'property_id')::uuid,
            p_payload->>'device_name',
            p_payload->>'category_code',
            (p_payload->>'protocol')::public.device_protocol,

            case
                when p_payload ? 'parent_device_id'
                 and p_payload->>'parent_device_id' is not null
                then
                    (p_payload->>'parent_device_id')::uuid
                else null
            end,

            p_payload->>'model',

            p_payload->>'manufacturer',

            coalesce(
                (p_payload->>'is_active')::boolean,
                true
            )
        )
        returning
            id,
            tenant_id,
            property_id,
            parent_device_id,
            device_name,
            category_code,
            protocol,
            model,
            manufacturer,
            is_active,
            created_at
        into v_row;


        v_result := to_jsonb(v_row);

        perform platform.log_audit(
            'device.created',
            'device',
            v_row.id,
            jsonb_build_object(
                'category_code',
                v_row.category_code
            )
        );


    when 'update_device' then

        perform public.edge_require_manager();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        if p_payload ? 'parent_device_id'
           and p_payload->>'parent_device_id' is not null
        then

            if not exists (
                select 1
                from public.devices d
                join public.devices pd
                  on pd.id = (p_payload->>'parent_device_id')::uuid
                where d.id = (p_payload->>'id')::uuid
                  and d.tenant_id = v_tid
                  and pd.tenant_id = v_tid
                  and pd.property_id = d.property_id
            ) then
                raise exception 'Parent device not found in same property';
            end if;

        end if;


        update public.devices d
        set

            device_name =
                case
                    when p_payload ? 'device_name'
                    then p_payload->>'device_name'
                    else d.device_name
                end,

            category_code =
                case
                    when p_payload ? 'category_code'
                    then p_payload->>'category_code'
                    else d.category_code
                end,

            protocol =
                case
                    when p_payload ? 'protocol'
                    then
                        (p_payload->>'protocol')
                        ::public.device_protocol
                    else d.protocol
                end,

            parent_device_id =
                case
                    when p_payload ? 'parent_device_id'
                    then
                        case
                            when p_payload->>'parent_device_id' is null
                            then null
                            else
                                (p_payload->>'parent_device_id')::uuid
                        end
                    else d.parent_device_id
                end,

            model =
                case
                    when p_payload ? 'model'
                    then p_payload->>'model'
                    else d.model
                end,

            manufacturer =
                case
                    when p_payload ? 'manufacturer'
                    then p_payload->>'manufacturer'
                    else d.manufacturer
                end,

            is_active =
                case
                    when p_payload ? 'is_active'
                    then (p_payload->>'is_active')::boolean
                    else d.is_active
                end

        where d.id = (p_payload->>'id')::uuid
          and d.tenant_id = v_tid

        returning
            d.id,
            d.tenant_id,
            d.property_id,
            d.parent_device_id,
            d.device_name,
            d.category_code,
            d.protocol,
            d.model,
            d.manufacturer,
            d.is_active,
            d.created_at
        into v_row;


        if not found then
            raise exception 'Device not found';
        end if;


        v_result := to_jsonb(v_row);

        perform platform.log_audit(
            'device.updated',
            'device',
            v_row.id
        );


    when 'delete_device' then

        perform public.edge_require_manager();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        delete from public.devices d
        where d.id = (p_payload->>'id')::uuid
          and d.tenant_id = v_tid;


        if not found then
            raise exception 'Device not found';
        end if;


        v_result := jsonb_build_object(
            'deleted',
            true,
            'id',
            p_payload->>'id'
        );

        perform platform.log_audit(
            'device.deleted',
            'device',
            (p_payload->>'id')::uuid
        );


    when 'assign_device' then

        perform public.edge_require_manager();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        v_result :=
            public.devices_assign_device_to_room(
                (p_payload->>'device_id')::uuid,
                (p_payload->>'room_id')::uuid
            );


        -- Audit the actual assignment returned by the
        -- assignment workflow, not merely the requested
        -- payload values.

        perform platform.log_audit(
            'device.assigned',
            'device',
            (v_result->>'device_id')::uuid,
            jsonb_build_object(
                'room_id',
                (v_result->>'room_id')::uuid,
                'assignment_id',
                (v_result->>'assignment_id')::uuid
            )
        );


    when 'unassign_device' then

        perform public.edge_require_manager();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        if not exists (
            select 1
            from public.devices d
            where d.id =
                (p_payload->>'device_id')::uuid
              and d.tenant_id = v_tid
        ) then
            raise exception 'Device not found';
        end if;


        -- Capture the existing room before deleting the
        -- assignment. This preserves the historical
        -- context in the audit record.

        select da.room_id
        into v_previous_room_id
        from public.device_assignments da
        where da.device_id =
            (p_payload->>'device_id')::uuid;


        if v_previous_room_id is null then
            raise exception 'Device assignment not found';
        end if;


        delete from public.device_assignments da
        where da.device_id =
            (p_payload->>'device_id')::uuid;


        if not found then
            raise exception 'Device assignment not found';
        end if;


        v_result := jsonb_build_object(
            'unassigned',
            true,
            'device_id',
            p_payload->>'device_id',
            'previous_room_id',
            v_previous_room_id
        );


        perform platform.log_audit(
            'device.unassigned',
            'device',
            (p_payload->>'device_id')::uuid,
            jsonb_build_object(
                'previous_room_id',
                v_previous_room_id
            )
        );


    when 'get_device_config' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        if not exists (
            select 1
            from public.devices d
            where d.id =
                (p_payload->>'device_id')::uuid
              and d.tenant_id = v_tid
        ) then
            raise exception 'Device not found';
        end if;


        select to_jsonb(t)
        into v_result
        from
        (
            select
                dc.id,
                dc.device_id,
                dc.config,
                dc.created_at,
                dc.updated_at
            from public.device_configurations dc
            where dc.device_id =
                (p_payload->>'device_id')::uuid
        ) t;


        if v_result is null then
            v_result := 'null'::jsonb;
        end if;


    when 'upsert_device_config' then

        perform public.edge_require_manager();

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        if not exists (
            select 1
            from public.devices d
            where d.id =
                (p_payload->>'device_id')::uuid
              and d.tenant_id = v_tid
        ) then
            raise exception 'Device not found';
        end if;


        insert into public.device_configurations
        (
            device_id,
            config
        )
        values
        (
            (p_payload->>'device_id')::uuid,
            coalesce(
                p_payload->'config',
                '{}'::jsonb
            )
        )

        on conflict (device_id)
        do update
        set
            config = excluded.config

        returning
            id,
            device_id,
            config,
            created_at,
            updated_at
        into v_row;


        v_result := to_jsonb(v_row);

        perform platform.log_audit(
            'device.config.upserted',
            'device',
            (p_payload->>'device_id')::uuid
        );


    -- =================================================
    -- TELEMETRY (derived data from 008)
    -- =================================================

    when 'list_device_metrics' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        v_device_id :=
            (p_payload->>'device_id')::uuid;


        if not exists (
            select 1
            from public.devices d
            where d.id = v_device_id
              and d.tenant_id = v_tid
        ) then
            raise exception 'Device not found';
        end if;


        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.observed_at desc
            ),
            '[]'::jsonb
        )
        into v_result
        from
        (
            select
                dm.metric_key,
                dm.metric_value,
                dm.metric_value_text,
                dm.unit,
                dm.observed_at
            from public.device_metrics dm
            where dm.device_id = v_device_id
              and dm.tenant_id = v_tid
              and (
                  p_payload->>'metric_key' is null
                  or dm.metric_key = p_payload->>'metric_key'
              )
              and (
                  p_payload->>'since' is null
                  or dm.observed_at >=
                      (p_payload->>'since')::timestamptz
              )
              and (
                  p_payload->>'until' is null
                  or dm.observed_at <=
                      (p_payload->>'until')::timestamptz
              )
            order by dm.observed_at desc
            limit least(
                coalesce((p_payload->>'limit')::int, 500),
                2000
            )
        ) t;


    when 'get_device_current_state' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        v_device_id :=
            (p_payload->>'device_id')::uuid;


        if not exists (
            select 1
            from public.devices d
            where d.id = v_device_id
              and d.tenant_id = v_tid
        ) then
            raise exception 'Device not found';
        end if;


        select coalesce(
            jsonb_object_agg(
                dcs.metric_key,
                jsonb_build_object(
                    'metric_value',
                    dcs.metric_value,
                    'metric_value_text',
                    dcs.metric_value_text,
                    'unit',
                    dcs.unit,
                    'observed_at',
                    dcs.observed_at
                )
            ),
            '{}'::jsonb
        )
        into v_result
        from public.device_current_state dcs
        where dcs.device_id = v_device_id
          and dcs.tenant_id = v_tid;


    when 'list_tenant_device_current_state' then

        v_tid := platform.current_tenant_id();

        if v_tid is null then
            raise exception 'no active tenant';
        end if;


        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.device_name
            ),
            '[]'::jsonb
        )
        into v_result
        from
        (
            select
                d.id as device_id,
                d.device_name,
                d.category_code,
                dcs.metric_key,
                dcs.metric_value,
                dcs.metric_value_text,
                dcs.unit,
                dcs.observed_at
            from public.device_current_state dcs
            join public.devices d
              on d.id = dcs.device_id
            where dcs.tenant_id = v_tid
              and (
                  public.is_platform_admin()
                  or coalesce(auth.role(), '') = 'service_role'
                  or exists (
                      select 1 from public.property_memberships pm
                      where pm.property_id = d.property_id
                        and pm.user_id = (select auth.uid())
                        and pm.is_active = true
                  )
              )
              and (
                  p_payload->>'category_code' is null
                  or d.category_code =
                      p_payload->>'category_code'
              )
        ) t;


    else

        raise exception
            'unknown devices_api operation: %',
            p_op;

    end case;


    return v_result;

end;
$$;


-- =====================================================
-- 15. APPROVED PUBLIC DEVICE API BOUNDARY
--
-- 023 grants authenticated EXECUTE to this function.
--
-- devices_domain remains internal.
--
-- This wrapper preserves the existing devices_domain contract.
-- Resource authorization is enforced inside the domain function using
-- property_memberships; tenant scoping remains an additional boundary.
-- =====================================================

create or replace function public.devices_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
    select public.devices_domain(
        p_op,
        coalesce(p_payload, '{}'::jsonb)
    );
$$;


comment on function public.devices_api(text, jsonb) is
    'Approved authenticated API boundary for the Property & Device Engine. Delegates to internal devices_domain().';


comment on function public.devices_domain(text, jsonb) is
    'Internal Property & Device domain function. Not an authenticated API surface. EXECUTE boundary controlled by 023.';


-- =====================================================
-- 16. DEVICE ASSIGNMENT TENANT CONSISTENCY
-- =====================================================

create or replace function public.enforce_device_assignment_tenant_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_device_tenant uuid;
    v_room_tenant uuid;
begin

    select d.tenant_id
    into v_device_tenant
    from public.devices d
    where d.id = new.device_id;


    if not found then
        raise exception 'device not found';
    end if;


    select p.tenant_id
    into v_room_tenant
    from public.rooms r
    join public.properties p
      on p.id = r.property_id
    where r.id = new.room_id;


    if not found then
        raise exception 'room not found';
    end if;


    if v_device_tenant is distinct from v_room_tenant then
        raise exception
            'device and room must belong to the same tenant';
    end if;


    return new;

end;
$$;


-- =====================================================
-- 17. DEVICE HIERARCHY INVARIANT
-- =====================================================

create or replace function public.enforce_device_hierarchy()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_new_is_gateway boolean;
    v_parent_tenant uuid;
    v_parent_is_gateway boolean;
begin

    select dc.is_gateway
    into v_new_is_gateway
    from public.device_categories dc
    where dc.code = new.category_code;


    if not found then
        raise exception 'device category not found';
    end if;


    /*
     * Gateways are root devices.
     */
    if v_new_is_gateway
       and new.parent_device_id is not null
    then
        raise exception
            'gateway devices cannot have a parent device';
    end if;


    /*
     * A device can never be its own parent.
     */
    if new.parent_device_id = new.id then
        raise exception
            'device cannot be its own parent';
    end if;


    /*
     * Root device.
     */
    if new.parent_device_id is null then

        /*
         * A gateway category is valid as root.
         */
        return new;

    end if;


    /*
     * Parent must exist.
     */
    select
        d.tenant_id,
        dc.is_gateway
    into
        v_parent_tenant,
        v_parent_is_gateway
    from public.devices d
    join public.device_categories dc
      on dc.code = d.category_code
    where d.id = new.parent_device_id;


    if not found then
        raise exception
            'parent device not found';
    end if;


    /*
     * Parent must be a gateway.
     */
    if not v_parent_is_gateway then
        raise exception
            'parent device must be a gateway';
    end if;


    /*
     * Parent and child must belong to the same tenant.
     */
    if v_parent_tenant is distinct from new.tenant_id then
        raise exception
            'parent device must belong to the same tenant';
    end if;


    return new;

end;
$$;


-- =====================================================
-- 18. DEVICE HIERARCHY CHILD INVARIANT
--
-- Prevent a gateway from being converted into a
-- non-gateway while child devices still reference it.
--
-- Without this invariant:
--
-- gateway
--    └── sensor
--
-- could become:
--
-- sensor
--    └── sensor
--
-- which violates the hierarchy contract.
-- =====================================================

create or replace function public.prevent_gateway_demotion_with_children()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_old_is_gateway boolean;
    v_new_is_gateway boolean;
begin

    if tg_op <> 'UPDATE' then
        return new;
    end if;


    select dc.is_gateway
    into v_old_is_gateway
    from public.device_categories dc
    where dc.code = old.category_code;


    select dc.is_gateway
    into v_new_is_gateway
    from public.device_categories dc
    where dc.code = new.category_code;


    if coalesce(v_old_is_gateway, false)
       and not coalesce(v_new_is_gateway, false)
    then

        if exists (
            select 1
            from public.devices child
            where child.parent_device_id = new.id
        ) then

            raise exception
                'gateway cannot be demoted while child devices exist';

        end if;

    end if;


    return new;

end;
$$;


-- =====================================================
-- 19. DEVICE DEACTIVATION
-- Whenever a room gets deleted, the unassigned devices
-- must become inactive.
-- =====================================================

create or replace function public.deactivate_unassigned_device()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin

    if not exists (
        select 1
        from public.device_assignments da
        where da.device_id = old.device_id
    ) then

        update public.devices
        set is_active = false
        where id = old.device_id;

    end if;

    return old;
end;
$$;

-- Billing calendar used by subscription cancellation and Commerce 012.
create or replace function platform.billing_timezone()
returns text language sql immutable set search_path = ''
as $$ select 'Europe/Athens'::text; $$;

-- -----------------------------------------------------
-- 9b. Subscription functions
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
    p_property_id uuid,
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

    perform public.assert_property_manager(p_property_id);

    if not exists (select 1 from public.properties p where p.id = p_property_id) then
        raise exception 'property not found';
    end if;

    select *
    into v_plan
    from public.product_plans pp
    where pp.id = p_plan_id
      and pp.is_active = true;

    if not found then
        raise exception 'active product plan not found';
    end if;

    -- Exactly one subscription per property.
    if exists (select 1 from public.subscriptions s where s.property_id = p_property_id) then
        raise exception 'property already has a subscription; use subscription_change_plan';
    end if;

    insert into public.subscriptions (
        tenant_id, property_id, plan_id, tier, status
    )
    select p.tenant_id, p.id, v_plan.id, v_plan.tier, p_status::public.subscription_status
    from public.properties p where p.id = p_property_id
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


-- Subscription is created explicitly when the customer purchases/activates
-- a subscription. A property without a subscription remains a valid state.


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
    for update;

    if not found then
        raise exception 'subscription not found';
    end if;

    perform public.assert_property_manager(v_subscription.property_id);

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
    p_property_id uuid,
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

    perform public.assert_property_manager(p_property_id);

    select * into v_sub
    from public.subscriptions s
    where s.property_id = p_property_id
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


create or replace function public.subscription_undo_cancel(p_property_id uuid)
returns public.subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_sub public.subscriptions%rowtype;
begin

    perform public.assert_property_manager(p_property_id);

    select * into v_sub
    from public.subscriptions s
    where s.property_id = p_property_id
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


comment on table public.product_plans is
    'Global plan catalogue SSOT (004). Each property has its own subscription instance; prices, entitlements and upsell rules belong to Commerce 012.';

comment on column public.subscriptions.plan_id is
    'Global plan selected for this property subscription (SSOT 004). Price of the plan is owned by Commerce 012.';

comment on column public.subscriptions.cancel_effective_at is
    'First instant of the month after the cancellation request (platform.billing_timezone()). Status becomes cancelled then.';

comment on function platform.expire_cancelled_subscriptions() is
    'Sets status cancelled once cancel_effective_at has passed. Called hourly by the cron engine (027).';

comment on function platform.billable_subscriptions(date, date) is
    'Subscriptions that may be invoiced for the period; excludes periods beyond cancel_effective_at.';



-- =====================================================
-- 20. TRIGGERS
-- =====================================================

drop trigger if exists trg_product_plans_updated_at on public.product_plans;
create trigger trg_product_plans_updated_at before update on public.product_plans for each row execute function platform.set_updated_at();

drop trigger if exists trg_subscriptions_updated_at
on public.subscriptions;

create trigger trg_subscriptions_updated_at
before update on public.subscriptions
for each row
execute function platform.set_updated_at();

drop trigger if exists trg_product_plan_tier_immutable
on public.product_plans;

create trigger trg_product_plan_tier_immutable
before update on public.product_plans
for each row
execute function public.prevent_product_plan_tier_change();

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

drop trigger if exists trg_properties_updated_at
on public.properties;

create trigger trg_properties_updated_at
before update on public.properties
for each row
execute function platform.set_updated_at();


drop trigger if exists trg_devices_hierarchy
on public.devices;

create trigger trg_devices_hierarchy
before insert or update
on public.devices
for each row
execute function public.enforce_device_hierarchy();


drop trigger if exists trg_devices_gateway_demotion
on public.devices;

create trigger trg_devices_gateway_demotion
before update
on public.devices
for each row
execute function public.prevent_gateway_demotion_with_children();


drop trigger if exists trg_device_assignment_tenant_consistency
on public.device_assignments;

create trigger trg_device_assignment_tenant_consistency
before insert or update
on public.device_assignments
for each row
execute function public.enforce_device_assignment_tenant_consistency();


drop trigger if exists trg_device_configurations_updated_at
on public.device_configurations;

create trigger trg_device_configurations_updated_at
before update
on public.device_configurations
for each row
execute function platform.set_updated_at();


drop trigger if exists trg_deactivate_unassigned_device
on public.device_assignments;

create trigger trg_deactivate_unassigned_device
after delete on public.device_assignments
for each row
execute function public.deactivate_unassigned_device();


-- =====================================================
-- 21. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (migration_name,version,rollback_available)
values ('004_property_device_engine','REV1',false)
on conflict (migration_name) do nothing;


-- =====================================================
-- END 004 PROPERTY & DEVICE ENGINE
-- =====================================================