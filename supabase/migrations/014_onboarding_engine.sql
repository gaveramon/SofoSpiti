-- =====================================================
-- REV3 GREENFIELD BASELINE
-- 014_ONBOARDING_ENGINE.SQL
-- =====================================================
--
-- CLEAN DOMAIN STATE / PROGRESS / LIFECYCLE TRACKING
-- NO EXECUTION / NO AUTOMATION / NO SIDE EFFECTS
-- =====================================================
--
-- PROCESS DIMENSIONS:
--
-- 1. PRECONFIG
--    Internal SOFO SPITI preparation before shipping.
--
-- 2. CUSTOMER ONBOARDING
--    Customer-facing onboarding wizard and step progress.
--
-- 3. PROPERTY LIFECYCLE
--    Property-level lifecycle from creation to active.
--
-- HISTORICAL:
--    - preconfig transition history
--    - lifecycle transition history
--    - immutable 010 catalog snapshot
--
-- GLOBAL CATALOG SSOT:
--   010
--
-- TENANT ONBOARDING SSOT:
--   014
--
-- EXECUTION / ORCHESTRATION:
--   000 / application layer
--
-- SECURITY GRANTS / REVOKES:
--   022 / 024 only
-- =====================================================


-- =====================================================
-- 1. ONBOARDING LIFECYCLE STATE
-- =====================================================

do $$
begin
    if not exists (
        select 1
        from pg_type t
        join pg_namespace n
            on n.oid = t.typnamespace
        where t.typname = 'onboarding_lifecycle_state'
          and n.nspname = 'public'
    ) then

        create type public.onboarding_lifecycle_state as enum (
            'created',
            'pre_onboarding',
            'configured',
            'devices_assigned',
            'shipped',
            'installed',
            'verified',
            'active'
        );

    end if;
end
$$;


-- =====================================================
-- 2. PRECONFIG STATUS
-- =====================================================
--
-- Internal SOFO SPITI preparation status.
--
-- This is deliberately separate from:
--   onboarding_status
--   onboarding_step_status
--   onboarding_lifecycle_state
--
-- The preconfig process ends at ready_for_shipping.
-- Actual shipping remains part of the property lifecycle.
-- =====================================================

do $$
begin
    if not exists (
        select 1
        from pg_type t
        join pg_namespace n
            on n.oid = t.typnamespace
        where t.typname = 'preconfig_status'
          and n.nspname = 'public'
    ) then

        create type public.preconfig_status as enum (
            'not_started',
            'input_pending',
            'input_received',
            'configuring',
            'testing',
            'failed',
            'passed',
            'ready_for_shipping'
        );

    end if;
end
$$;


-- =====================================================
-- 3. ONBOARDING SESSIONS
-- =====================================================

create table if not exists public.onboarding_sessions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    property_id uuid not null,

    preconfig_template_id uuid
        references public.preconfig_templates(id)
        on delete set null,

    onboarding_blueprint_id uuid
        references public.onboarding_blueprints(id)
        on delete set null,

    status public.onboarding_status
        not null
        default 'not_started',

    current_step public.onboarding_step_type,

    created_at timestamptz
        not null
        default now(),

    updated_at timestamptz
        not null
        default now()
);


-- =====================================================
-- 4. PRECONFIG STATE
-- =====================================================
--
-- One preconfig state per onboarding session.
--
-- This answers:
-- "Waar staat SOFO SPITI nu met deze bestelling?"
-- =====================================================

create table if not exists public.onboarding_preconfig (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    session_id uuid not null
        references public.onboarding_sessions(id)
        on delete cascade,

    status public.preconfig_status
        not null
        default 'not_started',

    failure_reason text,

    created_at timestamptz
        not null
        default now(),

    updated_at timestamptz
        not null
        default now(),

    unique (session_id)
);


-- =====================================================
-- 5. PRECONFIG TRANSITION HISTORY
-- =====================================================

create table if not exists public.onboarding_preconfig_transitions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    preconfig_id uuid not null
        references public.onboarding_preconfig(id)
        on delete cascade,

    from_status public.preconfig_status,

    to_status public.preconfig_status not null,

    metadata jsonb
        not null
        default '{}'::jsonb,

    created_at timestamptz
        not null
        default now()
);


-- =====================================================
-- 6. ONBOARDING STEP STATE
-- =====================================================

create table if not exists public.onboarding_step_state (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    session_id uuid not null
        references public.onboarding_sessions(id)
        on delete cascade,

    step_type public.onboarding_step_type not null,

    status public.onboarding_step_status
        not null
        default 'pending',

    completed_at timestamptz,

    unique (session_id, step_type)
);


-- =====================================================
-- 7. ROOM MAPPING
-- =====================================================

create table if not exists public.onboarding_room_mapping (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    session_id uuid not null
        references public.onboarding_sessions(id)
        on delete cascade,

    room_name text not null,

    room_type public.room_type,

    promoted_room_id uuid
        references public.rooms(id)
        on delete set null,

    created_at timestamptz
        not null
        default now(),

    unique (session_id, room_name)
);


-- =====================================================
-- 8. DEVICE MAPPING
-- =====================================================

create table if not exists public.onboarding_device_mapping (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    session_id uuid not null
        references public.onboarding_sessions(id)
        on delete cascade,

    category_code text
        references public.device_categories(code),

    room_name text,

    desired_action text,

    device_id uuid
        references public.devices(id)
        on delete set null,

    scan_status public.onboarding_step_status
        not null
        default 'pending',

    scanned_at timestamptz,

    created_at timestamptz
        not null
        default now(),

    unique (session_id, category_code, room_name)
);


-- =====================================================
-- 9. CHECKLIST
-- =====================================================

create table if not exists public.onboarding_checklist (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    session_id uuid not null
        references public.onboarding_sessions(id)
        on delete cascade,

    checklist_key text not null,

    is_completed boolean
        not null
        default false,

    updated_at timestamptz
        not null
        default now(),

    unique (session_id, checklist_key)
);


-- =====================================================
-- 10. NOTES
-- =====================================================

create table if not exists public.onboarding_notes (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    session_id uuid not null
        references public.onboarding_sessions(id)
        on delete cascade,

    author_user_id uuid
        references platform.profiles(id)
        on delete set null,

    note text,

    created_at timestamptz
        not null
        default now()
);


-- =====================================================
-- 11. PROPERTY LIFECYCLE
-- =====================================================

create table if not exists public.onboarding_lifecycle (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    property_id uuid not null
        references public.properties(id)
        on delete cascade,

    session_id uuid
        references public.onboarding_sessions(id)
        on delete set null,

    current_state public.onboarding_lifecycle_state
        not null
        default 'created',

    created_at timestamptz
        not null
        default now(),

    updated_at timestamptz
        not null
        default now(),

    unique (property_id)
);


-- =====================================================
-- 12. LIFECYCLE TRANSITIONS
-- =====================================================

create table if not exists public.onboarding_lifecycle_transitions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    lifecycle_id uuid not null
        references public.onboarding_lifecycle(id)
        on delete cascade,

    from_state public.onboarding_lifecycle_state,

    to_state public.onboarding_lifecycle_state not null,

    metadata jsonb
        not null
        default '{}'::jsonb,

    created_at timestamptz
        not null
        default now()
);


-- =====================================================
-- 13. HISTORICAL CATALOG SNAPSHOT
-- =====================================================

create table if not exists public.onboarding_catalog_snapshots (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    session_id uuid not null
        references public.onboarding_sessions(id)
        on delete cascade,

    preconfig_template_id uuid
        references public.preconfig_templates(id)
        on delete set null,

    onboarding_blueprint_id uuid
        references public.onboarding_blueprints(id)
        on delete set null,

    device_bundle_id uuid
        references public.device_bundles(id)
        on delete set null,

    preconfig_template_snapshot jsonb
        not null,

    preconfig_device_map_snapshot jsonb
        not null
        default '[]'::jsonb,

    onboarding_blueprint_snapshot jsonb,

    onboarding_blueprint_steps_snapshot jsonb
        not null
        default '[]'::jsonb,

    device_bundle_snapshot jsonb,

    bundle_devices_snapshot jsonb
        not null
        default '[]'::jsonb,

    created_at timestamptz
        not null
        default now(),

    unique (session_id)
);


-- =====================================================
-- 14. INDEXES
-- =====================================================

create index if not exists idx_onboarding_sessions_tenant_created
on public.onboarding_sessions (tenant_id, created_at desc);

create index if not exists idx_onboarding_sessions_property
on public.onboarding_sessions (property_id);

create unique index if not exists uq_onboarding_sessions_property_active
on public.onboarding_sessions (property_id)
where status in (
    'not_started',
    'in_progress',
    'waiting_user'
);

create index if not exists idx_onboarding_preconfig_tenant_status
on public.onboarding_preconfig (tenant_id, status);

create index if not exists idx_onboarding_preconfig_session
on public.onboarding_preconfig (session_id);

create index if not exists idx_onboarding_preconfig_transitions_preconfig
on public.onboarding_preconfig_transitions (
    preconfig_id,
    created_at desc
);

create index if not exists idx_onboarding_preconfig_transitions_tenant_created
on public.onboarding_preconfig_transitions (
    tenant_id,
    created_at desc
);

create index if not exists idx_onboarding_step_state_session
on public.onboarding_step_state (session_id);

create index if not exists idx_onboarding_step_state_tenant
on public.onboarding_step_state (tenant_id);

create index if not exists idx_onboarding_room_mapping_session
on public.onboarding_room_mapping (session_id);

create index if not exists idx_onboarding_room_mapping_tenant_created
on public.onboarding_room_mapping (
    tenant_id,
    created_at desc
);

create index if not exists idx_onboarding_device_mapping_session
on public.onboarding_device_mapping (session_id);

create index if not exists idx_onboarding_device_mapping_tenant_created
on public.onboarding_device_mapping (
    tenant_id,
    created_at desc
);

create index if not exists idx_onboarding_checklist_session
on public.onboarding_checklist (session_id);

create index if not exists idx_onboarding_checklist_tenant
on public.onboarding_checklist (tenant_id);

create index if not exists idx_onboarding_notes_session
on public.onboarding_notes (session_id);

create index if not exists idx_onboarding_notes_tenant_created
on public.onboarding_notes (
    tenant_id,
    created_at desc
);

create index if not exists idx_onboarding_catalog_snapshots_tenant_created
on public.onboarding_catalog_snapshots (
    tenant_id,
    created_at desc
);

create index if not exists idx_onboarding_catalog_snapshots_template
on public.onboarding_catalog_snapshots (
    preconfig_template_id
);

create index if not exists idx_onboarding_lifecycle_tenant
on public.onboarding_lifecycle (
    tenant_id,
    updated_at desc
);

create index if not exists idx_onboarding_lifecycle_transitions_lifecycle
on public.onboarding_lifecycle_transitions (
    lifecycle_id,
    created_at desc
);

create index if not exists idx_onboarding_lifecycle_transitions_tenant_created
on public.onboarding_lifecycle_transitions (
    tenant_id,
    created_at desc
);


-- =====================================================
-- 15. FOREIGN KEY COMPATIBILITY
-- =====================================================

do $$
begin
    if not exists (
        select 1
        from pg_constraint c
        join pg_class t on t.oid = c.conrelid
        join pg_namespace n on n.oid = t.relnamespace
        where c.conname = 'fk_onboarding_sessions_property'
          and n.nspname = 'public'
          and t.relname = 'onboarding_sessions'
    ) then

        alter table public.onboarding_sessions
            add constraint fk_onboarding_sessions_property
            foreign key (property_id)
            references public.properties(id)
            on delete cascade;

    end if;
end
$$;


-- =====================================================
-- 16. SESSION CONSISTENCY
-- =====================================================

create or replace function public.enforce_onboarding_session_tenant_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_property_tenant uuid;
begin
    select p.tenant_id
    into v_property_tenant
    from public.properties p
    where p.id = new.property_id;

    if not found then
        raise exception 'property not found';
    end if;

    if new.tenant_id is distinct from v_property_tenant then
        raise exception
            'onboarding session property must belong to the same tenant';
    end if;

    return new;
end;
$$;


create or replace function public.enforce_onboarding_session_blueprint_trace()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_template_blueprint uuid;
begin
    if new.preconfig_template_id is null then
        return new;
    end if;

    select pt.onboarding_blueprint_id
    into v_template_blueprint
    from public.preconfig_templates pt
    where pt.id = new.preconfig_template_id;

    if not found then
        raise exception 'preconfig template not found';
    end if;

    if v_template_blueprint is not null
       and new.onboarding_blueprint_id is distinct from v_template_blueprint then

        raise exception
            'onboarding_blueprint_id must match preconfig_templates.onboarding_blueprint_id';

    end if;

    return new;
end;
$$;


-- =====================================================
-- 17. CATALOG IMMUTABILITY PER SESSION
-- =====================================================
--
-- Once a snapshot exists, the selected global catalog
-- references of that onboarding session may not change.
-- =====================================================

create or replace function public.enforce_onboarding_session_catalog_immutability()
returns trigger
language plpgsql
set search_path = ''
as $$
begin

    if tg_op = 'UPDATE'
       and (
            new.preconfig_template_id is distinct from old.preconfig_template_id
            or new.onboarding_blueprint_id is distinct from old.onboarding_blueprint_id
       )
       and exists (
            select 1
            from public.onboarding_catalog_snapshots cs
            where cs.session_id = old.id
       )
    then
        raise exception
            'onboarding catalog selection is immutable after snapshot creation';
    end if;

    return new;
end;
$$;


-- =====================================================
-- 18. CHILD TENANT CONSISTENCY
-- =====================================================

create or replace function public.enforce_onboarding_child_tenant_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_session_tenant uuid;
begin

    select s.tenant_id
    into v_session_tenant
    from public.onboarding_sessions s
    where s.id = new.session_id;

    if not found then
        raise exception 'onboarding session not found';
    end if;

    if tg_op = 'UPDATE'
       and old.session_id = new.session_id
       and old.tenant_id is distinct from v_session_tenant then
        raise exception
            'existing onboarding child row has inconsistent tenant';
    end if;

    new.tenant_id := v_session_tenant;

    return new;
end;
$$;


-- =====================================================
-- 19. ROOM MAPPING CONSISTENCY
-- =====================================================

create or replace function public.enforce_onboarding_room_mapping_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_session record;
begin

    if new.promoted_room_id is null then
        return new;
    end if;

    select
        s.property_id,
        s.tenant_id
    into v_session
    from public.onboarding_sessions s
    where s.id = new.session_id;

    if not found then
        raise exception 'onboarding session not found';
    end if;

    if not exists (
        select 1
        from public.rooms r
        join public.properties p
            on p.id = r.property_id
        where r.id = new.promoted_room_id
          and r.property_id = v_session.property_id
          and p.tenant_id = v_session.tenant_id
    ) then

        raise exception
            'promoted room must belong to the onboarding session property and tenant';

    end if;

    return new;
end;
$$;


-- =====================================================
-- 20. DEVICE MAPPING CONSISTENCY
-- =====================================================

create or replace function public.enforce_onboarding_device_mapping_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_session_tenant uuid;
    v_device_tenant uuid;
begin

    if new.device_id is null then
        return new;
    end if;

    select s.tenant_id
    into v_session_tenant
    from public.onboarding_sessions s
    where s.id = new.session_id;

    if not found then
        raise exception 'onboarding session not found';
    end if;

    select d.tenant_id
    into v_device_tenant
    from public.devices d
    where d.id = new.device_id;

    if not found then
        raise exception 'device not found';
    end if;

    if v_device_tenant is distinct from v_session_tenant then
        raise exception
            'paired device must belong to the onboarding session tenant';
    end if;

    return new;
end;
$$;


-- =====================================================
-- 21. LIFECYCLE CONSISTENCY
-- =====================================================

create or replace function public.enforce_onboarding_lifecycle_tenant_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_property_tenant uuid;
    v_session_tenant uuid;
begin

    select p.tenant_id
    into v_property_tenant
    from public.properties p
    where p.id = new.property_id;

    if not found then
        raise exception 'property not found';
    end if;

    if v_property_tenant is distinct from new.tenant_id then
        raise exception
            'onboarding lifecycle property must belong to the same tenant';
    end if;

    if new.session_id is not null then

        select s.tenant_id
        into v_session_tenant
        from public.onboarding_sessions s
        where s.id = new.session_id;

        if not found then
            raise exception 'onboarding session not found';
        end if;

        if v_session_tenant is distinct from new.tenant_id then
            raise exception
                'onboarding lifecycle session must belong to the same tenant';
        end if;

    end if;

    return new;
end;
$$;


-- =====================================================
-- 22. LIFECYCLE STATE MACHINE
-- =====================================================

create or replace function public.onboarding_lifecycle_allowed_transition(
    p_from public.onboarding_lifecycle_state,
    p_to public.onboarding_lifecycle_state
)
returns boolean
language sql
immutable
set search_path = ''
as $$
    select case
        when p_from is null
             and p_to = 'created'
            then true

        when p_from = 'created'
             and p_to = 'pre_onboarding'
            then true

        when p_from = 'pre_onboarding'
             and p_to = 'configured'
            then true

        when p_from = 'configured'
             and p_to = 'devices_assigned'
            then true

        when p_from = 'devices_assigned'
             and p_to = 'shipped'
            then true

        when p_from = 'shipped'
             and p_to = 'installed'
            then true

        when p_from = 'installed'
             and p_to = 'verified'
            then true

        when p_from = 'verified'
             and p_to = 'active'
            then true

        else false
    end;
$$;


-- =====================================================
-- 23. LIFECYCLE TRANSITION CONSISTENCY
-- =====================================================

create or replace function public.enforce_onboarding_lifecycle_transitions_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_lifecycle_tenant uuid;
    v_previous_state public.onboarding_lifecycle_state;
begin

    select ol.tenant_id
    into v_lifecycle_tenant
    from public.onboarding_lifecycle ol
    where ol.id = new.lifecycle_id;

    if not found then
        raise exception 'onboarding lifecycle not found';
    end if;

    if v_lifecycle_tenant is distinct from new.tenant_id then
        raise exception
            'onboarding lifecycle transition tenant mismatch';
    end if;

    select olt.to_state
    into v_previous_state
    from public.onboarding_lifecycle_transitions olt
    where olt.lifecycle_id = new.lifecycle_id
    order by olt.created_at desc, olt.id desc
    limit 1;

    if not public.onboarding_lifecycle_allowed_transition(
        v_previous_state,
        new.to_state
    ) then
        raise exception
            'invalid onboarding lifecycle transition history: % -> %',
            v_previous_state,
            new.to_state;
    end if;

    if new.from_state is distinct from v_previous_state then
        raise exception
            'onboarding lifecycle transition from_state does not match history';
    end if;

    return new;
end;
$$;


-- =====================================================
-- 24. PRECONFIG STATE MACHINE
-- =====================================================

create or replace function public.preconfig_allowed_transition(
    p_from public.preconfig_status,
    p_to public.preconfig_status
)
returns boolean
language sql
immutable
set search_path = ''
as $$
    select case

        when p_from is null
             and p_to = 'input_pending'
            then true

        when p_from = 'not_started'
             and p_to = 'input_pending'
            then true

        when p_from = 'input_pending'
             and p_to = 'input_received'
            then true

        when p_from = 'input_received'
             and p_to = 'configuring'
            then true

        when p_from = 'configuring'
             and p_to = 'testing'
            then true

        when p_from = 'testing'
             and p_to = 'failed'
            then true

        when p_from = 'testing'
             and p_to = 'passed'
            then true

        when p_from = 'failed'
             and p_to = 'configuring'
            then true

        when p_from = 'passed'
             and p_to = 'ready_for_shipping'
            then true

        else false

    end;
$$;


-- =====================================================
-- 25. PRECONFIG TRANSITION CONSISTENCY
-- =====================================================

create or replace function public.enforce_onboarding_preconfig_transition_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_tenant_id uuid;
    v_previous public.preconfig_status;
begin

    select op.tenant_id
    into v_tenant_id
    from public.onboarding_preconfig op
    where op.id = new.preconfig_id;

    if not found then
        raise exception 'onboarding preconfig not found';
    end if;

    if v_tenant_id is distinct from new.tenant_id then
        raise exception
            'onboarding preconfig transition tenant mismatch';
    end if;

    select opt.to_status
    into v_previous
    from public.onboarding_preconfig_transitions opt
    where opt.preconfig_id = new.preconfig_id
    order by opt.created_at desc, opt.id desc
    limit 1;

    if not public.preconfig_allowed_transition(
        v_previous,
        new.to_status
    ) then

        raise exception
            'invalid preconfig transition history: % -> %',
            v_previous,
            new.to_status;

    end if;

    if new.from_status is distinct from v_previous then
        raise exception
            'preconfig transition from_status does not match history';
    end if;

    return new;
end;
$$;


-- =====================================================
-- 26. PRECONFIG TRANSITION IMMUTABILITY
-- =====================================================

create or replace function public.guard_onboarding_preconfig_transition_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if tg_op = 'UPDATE' then
        raise exception
            'onboarding preconfig transitions are immutable';
    end if;

    if tg_op = 'DELETE' then
        raise exception
            'onboarding preconfig transitions cannot be deleted';
    end if;

    return new;
end;
$$;


-- =====================================================
-- 27. LIFECYCLE TRANSITION IMMUTABILITY
-- =====================================================

create or replace function public.guard_onboarding_lifecycle_transition_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin

    if tg_op = 'UPDATE' then
        raise exception
            'onboarding lifecycle transitions are immutable';
    end if;

    if tg_op = 'DELETE' then
        raise exception
            'onboarding lifecycle transitions cannot be deleted';
    end if;

    return new;
end;
$$;


-- =====================================================
-- 28. CATALOG SNAPSHOT CREATION
-- =====================================================

create or replace function public.create_onboarding_catalog_snapshot(
    p_session_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_session public.onboarding_sessions%rowtype;

    v_template_snapshot jsonb;
    v_blueprint_snapshot jsonb;
    v_bundle_snapshot jsonb;

    v_template_id uuid;
    v_blueprint_id uuid;
    v_bundle_id uuid;

    v_device_map_snapshot jsonb;
    v_blueprint_steps_snapshot jsonb;
    v_bundle_devices_snapshot jsonb;

    v_snapshot_id uuid;
begin

    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    select *
    into v_session
    from public.onboarding_sessions s
    where s.id = p_session_id
      and s.tenant_id = v_tid;

    if not found then
        raise exception 'onboarding session not found';
    end if;

    select s.id
    into v_snapshot_id
    from public.onboarding_catalog_snapshots s
    where s.session_id = p_session_id;

    if found then
        return v_snapshot_id;
    end if;

    v_template_id := v_session.preconfig_template_id;
    v_blueprint_id := v_session.onboarding_blueprint_id;

    if v_template_id is null then
        return null;
    end if;

    select to_jsonb(pt)
    into v_template_snapshot
    from public.preconfig_templates pt
    where pt.id = v_template_id;

    if not found then
        raise exception
            'preconfig template % not found',
            v_template_id;
    end if;

    /*
     * A historical onboarding may only snapshot a published
     * catalog record.
     */
    if coalesce(
        (v_template_snapshot->>'is_published')::boolean,
        false
    ) is not true then
        raise exception
            'preconfig template % is not published',
            v_template_id;
    end if;

    if v_blueprint_id is null
       and v_template_snapshot ? 'onboarding_blueprint_id'
       and v_template_snapshot->>'onboarding_blueprint_id' is not null then

        v_blueprint_id :=
            (v_template_snapshot->>'onboarding_blueprint_id')::uuid;

    end if;

    if v_template_snapshot ? 'device_bundle_id'
       and v_template_snapshot->>'device_bundle_id' is not null then

        v_bundle_id :=
            (v_template_snapshot->>'device_bundle_id')::uuid;

    elsif v_template_snapshot ? 'bundle_id'
          and v_template_snapshot->>'bundle_id' is not null then

        v_bundle_id :=
            (v_template_snapshot->>'bundle_id')::uuid;

    end if;

    select coalesce(
        jsonb_agg(
            to_jsonb(pdm)
            order by pdm.id
        ),
        '[]'::jsonb
    )
    into v_device_map_snapshot
    from public.preconfig_device_map pdm
    where pdm.template_id = v_template_id;

    if v_blueprint_id is not null then

        select to_jsonb(ob)
        into v_blueprint_snapshot
        from public.onboarding_blueprints ob
        where ob.id = v_blueprint_id;

        if not found then
            raise exception
                'onboarding blueprint % not found',
                v_blueprint_id;
        end if;

        if coalesce(
            (v_blueprint_snapshot->>'is_published')::boolean,
            false
        ) is not true then
            raise exception
                'onboarding blueprint % is not published',
                v_blueprint_id;
        end if;

        select coalesce(
            jsonb_agg(
                to_jsonb(obs)
                order by obs.step_order, obs.id
            ),
            '[]'::jsonb
        )
        into v_blueprint_steps_snapshot
        from public.onboarding_blueprint_steps obs
        where obs.blueprint_id = v_blueprint_id;

    else

        v_blueprint_snapshot := null;
        v_blueprint_steps_snapshot := '[]'::jsonb;

    end if;

    if v_bundle_id is not null then

        select to_jsonb(db)
        into v_bundle_snapshot
        from public.device_bundles db
        where db.id = v_bundle_id;

        if not found then
            raise exception
                'device bundle % not found',
                v_bundle_id;
        end if;

        if coalesce(
            (v_bundle_snapshot->>'is_published')::boolean,
            false
        ) is not true then
            raise exception
                'device bundle % is not published',
                v_bundle_id;
        end if;

        select coalesce(
            jsonb_agg(
                to_jsonb(bd)
                order by bd.id
            ),
            '[]'::jsonb
        )
        into v_bundle_devices_snapshot
        from public.bundle_devices bd
        where bd.bundle_id = v_bundle_id;

    else

        v_bundle_snapshot := null;
        v_bundle_devices_snapshot := '[]'::jsonb;

    end if;

    insert into public.onboarding_catalog_snapshots (
        tenant_id,
        session_id,
        preconfig_template_id,
        onboarding_blueprint_id,
        device_bundle_id,
        preconfig_template_snapshot,
        preconfig_device_map_snapshot,
        onboarding_blueprint_snapshot,
        onboarding_blueprint_steps_snapshot,
        device_bundle_snapshot,
        bundle_devices_snapshot
    )
    values (
        v_tid,
        p_session_id,
        v_template_id,
        v_blueprint_id,
        v_bundle_id,
        v_template_snapshot,
        coalesce(v_device_map_snapshot, '[]'::jsonb),
        v_blueprint_snapshot,
        coalesce(v_blueprint_steps_snapshot, '[]'::jsonb),
        v_bundle_snapshot,
        coalesce(v_bundle_devices_snapshot, '[]'::jsonb)
    )
    returning id
    into v_snapshot_id;

    perform platform.log_audit(
        'onboarding_catalog_snapshot.created',
        'onboarding_catalog_snapshot',
        v_snapshot_id,
        (
            select to_jsonb(s)
            from public.onboarding_catalog_snapshots s
            where s.id = v_snapshot_id
        )
    );

    return v_snapshot_id;
end;
$$;


-- =====================================================
-- 29. CATALOG SNAPSHOT IMMUTABILITY
-- =====================================================

create or replace function public.guard_onboarding_catalog_snapshot_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin

    if tg_op = 'UPDATE' then
        raise exception
            'onboarding catalog snapshots are immutable';
    end if;

    if tg_op = 'DELETE' then
        raise exception
            'onboarding catalog snapshots cannot be deleted';
    end if;

    return new;
end;
$$;


-- =====================================================
-- 30. PRECONFIG TRANSITION APPLICATION
-- =====================================================

create or replace function public.onboarding_preconfig_apply_transition(
    p_session_id uuid,
    p_to_status public.preconfig_status,
    p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_row public.onboarding_preconfig%rowtype;
    v_from public.preconfig_status;
    v_metadata jsonb;
begin

    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    v_metadata := coalesce(p_metadata, '{}'::jsonb);

    select *
    into v_row
    from public.onboarding_preconfig op
    where op.session_id = p_session_id
      and op.tenant_id = v_tid
    for update;

    if not found then
        raise exception 'onboarding preconfig not found';
    end if;

    v_from := v_row.status;

    if v_from = p_to_status then
        return to_jsonb(v_row);
    end if;

    if not public.preconfig_allowed_transition(
        v_from,
        p_to_status
    ) then

        raise exception
            'invalid preconfig transition: % -> %',
            v_from,
            p_to_status;

    end if;

    update public.onboarding_preconfig
    set
        status = p_to_status,
        failure_reason =
            case
                when p_to_status = 'failed'
                then p_metadata->>'failure_reason'
                when p_to_status in (
                    'configuring',
                    'testing',
                    'passed',
                    'ready_for_shipping'
                )
                then null
                else failure_reason
            end,
        updated_at = now()
    where id = v_row.id
    returning *
    into v_row;

    insert into public.onboarding_preconfig_transitions (
        tenant_id,
        preconfig_id,
        from_status,
        to_status,
        metadata
    )
    values (
        v_tid,
        v_row.id,
        v_from,
        p_to_status,
        v_metadata
    );

    perform platform.log_audit(
        'onboarding_preconfig.changed',
        'onboarding_preconfig',
        v_row.id,
        jsonb_build_object(
            'row', to_jsonb(v_row),
            'from_status', v_from,
            'to_status', p_to_status,
            'metadata', v_metadata
        )
    );

    return to_jsonb(v_row);
end;
$$;


-- =====================================================
-- 31. LIFECYCLE TRANSITION APPLICATION
-- =====================================================

create or replace function public.onboarding_lifecycle_apply_transition(
    p_property_id uuid,
    p_to_state public.onboarding_lifecycle_state,
    p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_row public.onboarding_lifecycle%rowtype;
    v_from public.onboarding_lifecycle_state;
    v_metadata jsonb;
begin

    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    v_metadata := coalesce(p_metadata, '{}'::jsonb);

    select *
    into v_row
    from public.onboarding_lifecycle ol
    where ol.property_id = p_property_id
      and ol.tenant_id = v_tid
    for update;

    if not found then

        if p_to_state <> 'created' then
            raise exception
                'lifecycle must start at created';
        end if;

        insert into public.onboarding_lifecycle (
            tenant_id,
            property_id,
            current_state
        )
        values (
            v_tid,
            p_property_id,
            'created'
        )
        returning *
        into v_row;

        insert into public.onboarding_lifecycle_transitions (
            tenant_id,
            lifecycle_id,
            from_state,
            to_state,
            metadata
        )
        values (
            v_tid,
            v_row.id,
            null,
            'created',
            v_metadata
        );

        perform platform.log_audit(
            'onboarding_lifecycle.changed',
            'onboarding_lifecycle',
            v_row.id,
            jsonb_build_object(
                'row', to_jsonb(v_row),
                'from_state', null,
                'to_state', 'created',
                'metadata', v_metadata
            )
        );

        return to_jsonb(v_row);

    end if;

    v_from := v_row.current_state;

    if v_from = p_to_state then
        return to_jsonb(v_row);
    end if;

    if not public.onboarding_lifecycle_allowed_transition(
        v_from,
        p_to_state
    ) then

        raise exception
            'invalid onboarding lifecycle transition: % -> %',
            v_from,
            p_to_state;

    end if;

    update public.onboarding_lifecycle
    set
        current_state = p_to_state,
        updated_at = now()
    where id = v_row.id
    returning *
    into v_row;

    insert into public.onboarding_lifecycle_transitions (
        tenant_id,
        lifecycle_id,
        from_state,
        to_state,
        metadata
    )
    values (
        v_tid,
        v_row.id,
        v_from,
        p_to_state,
        v_metadata
    );

    perform platform.log_audit(
        'onboarding_lifecycle.changed',
        'onboarding_lifecycle',
        v_row.id,
        jsonb_build_object(
            'row', to_jsonb(v_row),
            'from_state', v_from,
            'to_state', p_to_state,
            'metadata', v_metadata
        )
    );

    return to_jsonb(v_row);
end;
$$;


-- =====================================================
-- 32. LIFECYCLE READ
-- =====================================================

create or replace function public.onboarding_lifecycle_get(
    p_property_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_result jsonb;
begin

    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    select to_jsonb(t)
    into v_result
    from (
        select
            ol.id,
            ol.tenant_id,
            ol.property_id,
            ol.session_id,
            ol.current_state,
            ol.created_at,
            ol.updated_at
        from public.onboarding_lifecycle ol
        where ol.property_id = p_property_id
          and ol.tenant_id = v_tid
    ) t;

    return coalesce(v_result, 'null'::jsonb);
end;
$$;


create or replace function public.onboarding_lifecycle_list_transitions(
    p_property_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_result jsonb;
begin

    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    select coalesce(
        jsonb_agg(
            to_jsonb(t)
            order by t.created_at desc, t.id desc
        ),
        '[]'::jsonb
    )
    into v_result
    from (
        select
            olt.id,
            olt.lifecycle_id,
            olt.from_state,
            olt.to_state,
            olt.metadata,
            olt.created_at
        from public.onboarding_lifecycle_transitions olt
        join public.onboarding_lifecycle ol
            on ol.id = olt.lifecycle_id
        where ol.property_id = p_property_id
          and olt.tenant_id = v_tid
    ) t;

    return v_result;
end;
$$;


-- =====================================================
-- 33. ONBOARDING DOMAIN API
-- =====================================================

create or replace function public.onboarding_domain(
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
    v_existing uuid;
    v_blueprint_id uuid;
    v_session_id uuid;
    v_deleted jsonb;
    v_snapshot_id uuid;
begin

    p_payload := coalesce(p_payload, '{}'::jsonb);

    v_uid := auth.uid();
    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    case p_op

    -- -------------------------------------------------
    -- LIST SESSIONS
    -- -------------------------------------------------

    when 'list_sessions' then

        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.created_at desc
            ),
            '[]'::jsonb
        )
        into v_result
        from (
            select
                s.id,
                s.tenant_id,
                s.property_id,
                s.preconfig_template_id,
                s.onboarding_blueprint_id,
                s.status,
                s.current_step,
                op.status as preconfig_status,
                op.failure_reason as preconfig_failure_reason,
                s.created_at,
                s.updated_at
            from public.onboarding_sessions s
            left join public.onboarding_preconfig op
                on op.session_id = s.id
            where s.tenant_id = v_tid
              and (
                  p_payload->>'property_id' is null
                  or s.property_id =
                     (p_payload->>'property_id')::uuid
              )
        ) t;


    -- -------------------------------------------------
    -- GET SESSION
    -- -------------------------------------------------

    when 'get_session' then

        v_session_id := (p_payload->>'id')::uuid;

        select jsonb_build_object(

            'session', (
                select to_jsonb(t)
                from (
                    select
                        s.id,
                        s.tenant_id,
                        s.property_id,
                        s.preconfig_template_id,
                        s.onboarding_blueprint_id,
                        s.status,
                        s.current_step,
                        s.created_at,
                        s.updated_at
                    from public.onboarding_sessions s
                    where s.id = v_session_id
                      and s.tenant_id = v_tid
                ) t
            ),

            'preconfig', (
                select to_jsonb(op)
                from public.onboarding_preconfig op
                where op.session_id = v_session_id
                  and op.tenant_id = v_tid
            ),

            'preconfig_transitions', coalesce((
                select jsonb_agg(
                    to_jsonb(pt)
                    order by pt.created_at desc, pt.id desc
                )
                from (
                    select
                        t.id,
                        t.preconfig_id,
                        t.from_status,
                        t.to_status,
                        t.metadata,
                        t.created_at
                    from public.onboarding_preconfig_transitions t
                    join public.onboarding_preconfig op
                        on op.id = t.preconfig_id
                    where op.session_id = v_session_id
                      and t.tenant_id = v_tid
                ) pt
            ), '[]'::jsonb),

            'steps', coalesce((
                select jsonb_agg(
                    to_jsonb(st)
                    order by st.step_type
                )
                from (
                    select
                        ss.id,
                        ss.tenant_id,
                        ss.session_id,
                        ss.step_type,
                        ss.status,
                        ss.completed_at
                    from public.onboarding_step_state ss
                    where ss.session_id = v_session_id
                      and ss.tenant_id = v_tid
                ) st
            ), '[]'::jsonb),

            'room_mappings', coalesce((
                select jsonb_agg(
                    to_jsonb(rm)
                    order by rm.created_at, rm.id
                )
                from (
                    select
                        r.id,
                        r.tenant_id,
                        r.session_id,
                        r.room_name,
                        r.room_type,
                        r.promoted_room_id,
                        r.created_at
                    from public.onboarding_room_mapping r
                    where r.session_id = v_session_id
                      and r.tenant_id = v_tid
                ) rm
            ), '[]'::jsonb),

            'device_mappings', coalesce((
                select jsonb_agg(
                    to_jsonb(dm)
                    order by dm.created_at, dm.id
                )
                from (
                    select
                        d.id,
                        d.tenant_id,
                        d.session_id,
                        d.category_code,
                        d.room_name,
                        d.desired_action,
                        d.device_id,
                        d.scan_status,
                        d.scanned_at,
                        d.created_at
                    from public.onboarding_device_mapping d
                    where d.session_id = v_session_id
                      and d.tenant_id = v_tid
                ) dm
            ), '[]'::jsonb),

            'checklist', coalesce((
                select jsonb_agg(
                    to_jsonb(c)
                    order by c.checklist_key
                )
                from (
                    select
                        c.id,
                        c.tenant_id,
                        c.session_id,
                        c.checklist_key,
                        c.is_completed,
                        c.updated_at
                    from public.onboarding_checklist c
                    where c.session_id = v_session_id
                      and c.tenant_id = v_tid
                ) c
            ), '[]'::jsonb),

            'notes', coalesce((
                select jsonb_agg(
                    to_jsonb(n)
                    order by n.created_at, n.id
                )
                from (
                    select
                        n.id,
                        n.tenant_id,
                        n.session_id,
                        n.author_user_id,
                        n.note,
                        n.created_at
                    from public.onboarding_notes n
                    where n.session_id = v_session_id
                      and n.tenant_id = v_tid
                ) n
            ), '[]'::jsonb),

            'catalog_snapshot', (
                select to_jsonb(cs)
                from (
                    select
                        cs.id,
                        cs.tenant_id,
                        cs.session_id,
                        cs.preconfig_template_id,
                        cs.onboarding_blueprint_id,
                        cs.device_bundle_id,
                        cs.preconfig_template_snapshot,
                        cs.preconfig_device_map_snapshot,
                        cs.onboarding_blueprint_snapshot,
                        cs.onboarding_blueprint_steps_snapshot,
                        cs.device_bundle_snapshot,
                        cs.bundle_devices_snapshot,
                        cs.created_at
                    from public.onboarding_catalog_snapshots cs
                    where cs.session_id = v_session_id
                      and cs.tenant_id = v_tid
                ) cs
            )

        )
        into v_result;

        if v_result->'session' = 'null'::jsonb then
            raise exception 'Onboarding session not found';
        end if;


    -- -------------------------------------------------
    -- CREATE SESSION
    -- -------------------------------------------------

    when 'create_session' then

        v_blueprint_id :=
            case
                when p_payload ? 'onboarding_blueprint_id'
                 and p_payload->>'onboarding_blueprint_id' is not null
                then
                    (p_payload->>'onboarding_blueprint_id')::uuid
                else
                    null
            end;

        if p_payload ? 'preconfig_template_id'
           and p_payload->>'preconfig_template_id' is not null
           and v_blueprint_id is null then

            select pt.onboarding_blueprint_id
            into v_blueprint_id
            from public.preconfig_templates pt
            where pt.id =
                (p_payload->>'preconfig_template_id')::uuid;

            if not found then
                raise exception 'preconfig template not found';
            end if;

        end if;

        insert into public.onboarding_sessions (
            tenant_id,
            property_id,
            preconfig_template_id,
            onboarding_blueprint_id,
            status,
            current_step
        )
        values (
            v_tid,
            (p_payload->>'property_id')::uuid,

            case
                when p_payload ? 'preconfig_template_id'
                then
                    (p_payload->>'preconfig_template_id')::uuid
                else
                    null
            end,

            v_blueprint_id,

            coalesce(
                (p_payload->>'status')::public.onboarding_status,
                'not_started'::public.onboarding_status
            ),

            case
                when p_payload ? 'current_step'
                 and p_payload->>'current_step' is not null
                then
                    (p_payload->>'current_step')::public.onboarding_step_type
                else
                    null
            end
        )
        returning
            id,
            tenant_id,
            property_id,
            preconfig_template_id,
            onboarding_blueprint_id,
            status,
            current_step,
            created_at,
            updated_at
        into v_row;

        v_session_id := v_row.id;

        insert into public.onboarding_preconfig (
            tenant_id,
            session_id,
            status
        )
        values (
            v_tid,
            v_session_id,
            'input_pending'
        )
        returning *
        into v_row;

        insert into public.onboarding_preconfig_transitions (
            tenant_id,
            preconfig_id,
            from_status,
            to_status,
            metadata
        )
        values (
            v_tid,
            v_row.id,
            null,
            'input_pending',
            '{}'::jsonb
        );

        if v_blueprint_id is not null then

            insert into public.onboarding_step_state (
                tenant_id,
                session_id,
                step_type,
                status
            )
            select
                v_tid,
                v_session_id,
                obs.step_type,
                'pending'::public.onboarding_step_status
            from public.onboarding_blueprint_steps obs
            where obs.blueprint_id = v_blueprint_id;

        end if;

        v_snapshot_id :=
            public.create_onboarding_catalog_snapshot(
                v_session_id
            );

        perform platform.log_audit(
            'onboarding_session.created',
            'onboarding_session',
            v_session_id,
            (
                select jsonb_build_object(
                    'session', to_jsonb(s),
                    'preconfig', (
                        select to_jsonb(op)
                        from public.onboarding_preconfig op
                        where op.session_id = s.id
                    ),
                    'catalog_snapshot_id', v_snapshot_id
                )
                from public.onboarding_sessions s
                where s.id = v_session_id
            )
        );

        select jsonb_build_object(
            'session', to_jsonb(s),
            'preconfig', (
                select to_jsonb(op)
                from public.onboarding_preconfig op
                where op.session_id = s.id
            ),
            'catalog_snapshot_id', v_snapshot_id
        )
        into v_result
        from public.onboarding_sessions s
        where s.id = v_session_id;


    -- -------------------------------------------------
    -- UPDATE SESSION
    -- -------------------------------------------------

    when 'update_session' then

        update public.onboarding_sessions s
        set
            preconfig_template_id =
                case
                    when p_payload ? 'preconfig_template_id'
                    then
                        (p_payload->>'preconfig_template_id')::uuid
                    else
                        s.preconfig_template_id
                end,

            onboarding_blueprint_id =
                case
                    when p_payload ? 'onboarding_blueprint_id'
                    then
                        (p_payload->>'onboarding_blueprint_id')::uuid
                    else
                        s.onboarding_blueprint_id
                end,

            status =
                case
                    when p_payload ? 'status'
                    then
                        (p_payload->>'status')::public.onboarding_status
                    else
                        s.status
                end,

            current_step =
                case
                    when p_payload ? 'current_step'
                    then
                        case
                            when p_payload->>'current_step' is null
                            then null
                            else
                                (p_payload->>'current_step')::public.onboarding_step_type
                        end
                    else
                        s.current_step
                end

        where s.id = (p_payload->>'id')::uuid
          and s.tenant_id = v_tid

        returning
            s.id,
            s.tenant_id,
            s.property_id,
            s.preconfig_template_id,
            s.onboarding_blueprint_id,
            s.status,
            s.current_step,
            s.created_at,
            s.updated_at
        into v_row;

        if not found then
            raise exception 'Onboarding session not found';
        end if;

        perform platform.log_audit(
            'onboarding_session.updated',
            'onboarding_session',
            v_row.id,
            to_jsonb(v_row)
        );

        v_result := to_jsonb(v_row);


    -- -------------------------------------------------
    -- DELETE SESSION
    -- -------------------------------------------------

    when 'delete_session' then

        select to_jsonb(s)
        into v_deleted
        from public.onboarding_sessions s
        where s.id = (p_payload->>'id')::uuid
          and s.tenant_id = v_tid;

        if not found then
            raise exception 'Onboarding session not found';
        end if;

        delete from public.onboarding_sessions s
        where s.id = (p_payload->>'id')::uuid
          and s.tenant_id = v_tid;

        perform platform.log_audit(
            'onboarding_session.deleted',
            'onboarding_session',
            (p_payload->>'id')::uuid,
            v_deleted
        );

        v_result := v_deleted;


    -- -------------------------------------------------
    -- PRECONFIG GET
    -- -------------------------------------------------

    when 'get_preconfig' then

        select jsonb_build_object(
            'preconfig', (
                select to_jsonb(op)
                from public.onboarding_preconfig op
                where op.session_id = v_session_id
                  and op.tenant_id = v_tid
            ),
            'transitions', coalesce((
                select jsonb_agg(
                    to_jsonb(t)
                    order by t.created_at desc, t.id desc
                )
                from public.onboarding_preconfig_transitions t
                join public.onboarding_preconfig op
                    on op.id = t.preconfig_id
                where op.session_id = v_session_id
                  and t.tenant_id = v_tid
            ), '[]'::jsonb)
        )
        into v_result
        where v_session_id =
            (p_payload->>'session_id')::uuid;


    -- -------------------------------------------------
    -- PRECONFIG TRANSITION
    -- -------------------------------------------------

    when 'update_preconfig_status' then

        v_result :=
            public.onboarding_preconfig_apply_transition(
                (p_payload->>'session_id')::uuid,
                (p_payload->>'status')::public.preconfig_status,
                coalesce(
                    p_payload->'metadata',
                    '{}'::jsonb
                )
            );


    -- -------------------------------------------------
    -- STEP STATE READ
    -- -------------------------------------------------

    when 'list_step_states' then

        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.step_type
            ),
            '[]'::jsonb
        )
        into v_result
        from (
            select
                ss.id,
                ss.tenant_id,
                ss.session_id,
                ss.step_type,
                ss.status,
                ss.completed_at
            from public.onboarding_step_state ss
            where ss.session_id =
                (p_payload->>'session_id')::uuid
              and ss.tenant_id = v_tid
        ) t;


    -- -------------------------------------------------
    -- STEP STATE UPDATE
    -- -------------------------------------------------

    when 'update_step_state' then

        update public.onboarding_step_state ss
        set
            status =
                case
                    when p_payload ? 'status'
                    then
                        (p_payload->>'status')::public.onboarding_step_status
                    else
                        ss.status
                end,

            completed_at =
                case
                    when p_payload ? 'completed_at'
                    then
                        (p_payload->>'completed_at')::timestamptz

                    when p_payload ? 'status'
                     and p_payload->>'status' = 'completed'
                    then
                        now()

                    else
                        ss.completed_at
                end

        where ss.id = (p_payload->>'id')::uuid
          and ss.tenant_id = v_tid

        returning
            ss.id,
            ss.tenant_id,
            ss.session_id,
            ss.step_type,
            ss.status,
            ss.completed_at
        into v_row;

        if not found then
            raise exception 'Step state not found';
        end if;

        perform platform.log_audit(
            'onboarding_step_state.updated',
            'onboarding_step_state',
            v_row.id,
            to_jsonb(v_row)
        );

        v_result := to_jsonb(v_row);


    -- -------------------------------------------------
    -- ROOM MAPPINGS
    -- -------------------------------------------------

    when 'list_room_mappings' then

        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.created_at, t.id
            ),
            '[]'::jsonb
        )
        into v_result
        from (
            select
                r.id,
                r.tenant_id,
                r.session_id,
                r.room_name,
                r.room_type,
                r.promoted_room_id,
                r.created_at
            from public.onboarding_room_mapping r
            where r.session_id =
                (p_payload->>'session_id')::uuid
              and r.tenant_id = v_tid
        ) t;


    when 'create_room_mapping' then

        insert into public.onboarding_room_mapping (
            tenant_id,
            session_id,
            room_name,
            room_type
        )
        values (
            v_tid,
            (p_payload->>'session_id')::uuid,
            p_payload->>'room_name',
            case
                when p_payload ? 'room_type'
                 and p_payload->>'room_type' is not null
                then
                    (p_payload->>'room_type')::public.room_type
                else null
            end
        )
        returning
            id,
            tenant_id,
            session_id,
            room_name,
            room_type,
            promoted_room_id,
            created_at
        into v_row;

        perform platform.log_audit(
            'onboarding_room_mapping.created',
            'onboarding_room_mapping',
            v_row.id,
            to_jsonb(v_row)
        );

        v_result := to_jsonb(v_row);


    when 'update_room_mapping' then

        update public.onboarding_room_mapping r
        set
            room_name =
                case
                    when p_payload ? 'room_name'
                    then p_payload->>'room_name'
                    else r.room_name
                end,

            room_type =
                case
                    when p_payload ? 'room_type'
                    then
                        case
                            when p_payload->>'room_type' is null
                            then null
                            else
                                (p_payload->>'room_type')::public.room_type
                        end
                    else r.room_type
                end,

            promoted_room_id =
                case
                    when p_payload ? 'promoted_room_id'
                    then
                        (p_payload->>'promoted_room_id')::uuid
                    else r.promoted_room_id
                end

        where r.id = (p_payload->>'id')::uuid
          and r.tenant_id = v_tid

        returning
            r.id,
            r.tenant_id,
            r.session_id,
            r.room_name,
            r.room_type,
            r.promoted_room_id,
            r.created_at
        into v_row;

        if not found then
            raise exception 'Room mapping not found';
        end if;

        perform platform.log_audit(
            'onboarding_room_mapping.updated',
            'onboarding_room_mapping',
            v_row.id,
            to_jsonb(v_row)
        );

        v_result := to_jsonb(v_row);


    when 'delete_room_mapping' then

        select to_jsonb(r)
        into v_deleted
        from public.onboarding_room_mapping r
        where r.id = (p_payload->>'id')::uuid
          and r.tenant_id = v_tid;

        if not found then
            raise exception 'Room mapping not found';
        end if;

        delete from public.onboarding_room_mapping r
        where r.id = (p_payload->>'id')::uuid
          and r.tenant_id = v_tid;

        perform platform.log_audit(
            'onboarding_room_mapping.deleted',
            'onboarding_room_mapping',
            (p_payload->>'id')::uuid,
            v_deleted
        );

        v_result := v_deleted;


    -- -------------------------------------------------
    -- DEVICE MAPPINGS
    -- -------------------------------------------------

    when 'list_device_mappings' then

        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.created_at, t.id
            ),
            '[]'::jsonb
        )
        into v_result
        from (
            select
                d.id,
                d.tenant_id,
                d.session_id,
                d.category_code,
                d.room_name,
                d.desired_action,
                d.device_id,
                d.scan_status,
                d.scanned_at,
                d.created_at
            from public.onboarding_device_mapping d
            where d.session_id =
                (p_payload->>'session_id')::uuid
              and d.tenant_id = v_tid
        ) t;


    when 'create_device_mapping' then

        insert into public.onboarding_device_mapping (
            tenant_id,
            session_id,
            category_code,
            room_name,
            desired_action,
            scan_status
        )
        values (
            v_tid,
            (p_payload->>'session_id')::uuid,
            p_payload->>'category_code',
            p_payload->>'room_name',
            p_payload->>'desired_action',
            coalesce(
                (p_payload->>'scan_status')::public.onboarding_step_status,
                'pending'::public.onboarding_step_status
            )
        )
        returning
            id,
            tenant_id,
            session_id,
            category_code,
            room_name,
            desired_action,
            device_id,
            scan_status,
            scanned_at,
            created_at
        into v_row;

        perform platform.log_audit(
            'onboarding_device_mapping.created',
            'onboarding_device_mapping',
            v_row.id,
            to_jsonb(v_row)
        );

        v_result := to_jsonb(v_row);


    when 'update_device_mapping' then

        update public.onboarding_device_mapping d
        set
            category_code =
                case
                    when p_payload ? 'category_code'
                    then p_payload->>'category_code'
                    else d.category_code
                end,

            room_name =
                case
                    when p_payload ? 'room_name'
                    then p_payload->>'room_name'
                    else d.room_name
                end,

            desired_action =
                case
                    when p_payload ? 'desired_action'
                    then p_payload->>'desired_action'
                    else d.desired_action
                end,

            device_id =
                case
                    when p_payload ? 'device_id'
                    then
                        (p_payload->>'device_id')::uuid
                    else d.device_id
                end,

            scan_status =
                case
                    when p_payload ? 'scan_status'
                    then
                        (p_payload->>'scan_status')::public.onboarding_step_status
                    else d.scan_status
                end,

            scanned_at =
                case
                    when p_payload ? 'scanned_at'
                    then
                        (p_payload->>'scanned_at')::timestamptz
                    when p_payload ? 'device_id'
                     and p_payload->>'device_id' is not null
                    then now()
                    else d.scanned_at
                end

        where d.id = (p_payload->>'id')::uuid
          and d.tenant_id = v_tid

        returning
            d.id,
            d.tenant_id,
            d.session_id,
            d.category_code,
            d.room_name,
            d.desired_action,
            d.device_id,
            d.scan_status,
            d.scanned_at,
            d.created_at
        into v_row;

        if not found then
            raise exception 'Device mapping not found';
        end if;

        perform platform.log_audit(
            'onboarding_device_mapping.updated',
            'onboarding_device_mapping',
            v_row.id,
            to_jsonb(v_row)
        );

        v_result := to_jsonb(v_row);


    when 'delete_device_mapping' then

        select to_jsonb(d)
        into v_deleted
        from public.onboarding_device_mapping d
        where d.id = (p_payload->>'id')::uuid
          and d.tenant_id = v_tid;

        if not found then
            raise exception 'Device mapping not found';
        end if;

        delete from public.onboarding_device_mapping d
        where d.id = (p_payload->>'id')::uuid
          and d.tenant_id = v_tid;

        perform platform.log_audit(
            'onboarding_device_mapping.deleted',
            'onboarding_device_mapping',
            (p_payload->>'id')::uuid,
            v_deleted
        );

        v_result := v_deleted;


    -- -------------------------------------------------
    -- CHECKLIST
    -- -------------------------------------------------

    when 'list_checklist_items' then

        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.checklist_key
            ),
            '[]'::jsonb
        )
        into v_result
        from (
            select
                c.id,
                c.tenant_id,
                c.session_id,
                c.checklist_key,
                c.is_completed,
                c.updated_at
            from public.onboarding_checklist c
            where c.session_id =
                (p_payload->>'session_id')::uuid
              and c.tenant_id = v_tid
        ) t;


    when 'upsert_checklist_item' then

        select c.id
        into v_existing
        from public.onboarding_checklist c
        where c.session_id =
            (p_payload->>'session_id')::uuid
          and c.checklist_key =
            p_payload->>'checklist_key'
          and c.tenant_id = v_tid;

        if found then

            update public.onboarding_checklist c
            set
                is_completed =
                    coalesce(
                        (p_payload->>'is_completed')::boolean,
                        true
                    )
            where c.id = v_existing

            returning
                c.id,
                c.tenant_id,
                c.session_id,
                c.checklist_key,
                c.is_completed,
                c.updated_at
            into v_row;

            perform platform.log_audit(
                'onboarding_checklist.updated',
                'onboarding_checklist',
                v_row.id,
                to_jsonb(v_row)
            );

        else

            insert into public.onboarding_checklist (
                tenant_id,
                session_id,
                checklist_key,
                is_completed
            )
            values (
                v_tid,
                (p_payload->>'session_id')::uuid,
                p_payload->>'checklist_key',
                coalesce(
                    (p_payload->>'is_completed')::boolean,
                    false
                )
            )
            returning
                id,
                tenant_id,
                session_id,
                checklist_key,
                is_completed,
                updated_at
            into v_row;

            perform platform.log_audit(
                'onboarding_checklist.created',
                'onboarding_checklist',
                v_row.id,
                to_jsonb(v_row)
            );

        end if;

        v_result := to_jsonb(v_row);


    when 'update_checklist_item' then

        update public.onboarding_checklist c
        set
            is_completed =
                case
                    when p_payload ? 'is_completed'
                    then
                        (p_payload->>'is_completed')::boolean
                    else c.is_completed
                end
        where c.id = (p_payload->>'id')::uuid
          and c.tenant_id = v_tid

        returning
            c.id,
            c.tenant_id,
            c.session_id,
            c.checklist_key,
            c.is_completed,
            c.updated_at
        into v_row;

        if not found then
            raise exception 'Checklist item not found';
        end if;

        perform platform.log_audit(
            'onboarding_checklist.updated',
            'onboarding_checklist',
            v_row.id,
            to_jsonb(v_row)
        );

        v_result := to_jsonb(v_row);


    when 'delete_checklist_item' then

        select to_jsonb(c)
        into v_deleted
        from public.onboarding_checklist c
        where c.id = (p_payload->>'id')::uuid
          and c.tenant_id = v_tid;

        if not found then
            raise exception 'Checklist item not found';
        end if;

        delete from public.onboarding_checklist c
        where c.id = (p_payload->>'id')::uuid
          and c.tenant_id = v_tid;

        perform platform.log_audit(
            'onboarding_checklist.deleted',
            'onboarding_checklist',
            (p_payload->>'id')::uuid,
            v_deleted
        );

        v_result := v_deleted;


    -- -------------------------------------------------
    -- NOTES
    -- -------------------------------------------------

    when 'list_notes' then

        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.created_at, t.id
            ),
            '[]'::jsonb
        )
        into v_result
        from (
            select
                n.id,
                n.tenant_id,
                n.session_id,
                n.author_user_id,
                n.note,
                n.created_at
            from public.onboarding_notes n
            where n.session_id =
                (p_payload->>'session_id')::uuid
              and n.tenant_id = v_tid
        ) t;


    when 'create_note' then

        insert into public.onboarding_notes (
            tenant_id,
            session_id,
            author_user_id,
            note
        )
        values (
            v_tid,
            (p_payload->>'session_id')::uuid,
            v_uid,
            p_payload->>'note'
        )
        returning
            id,
            tenant_id,
            session_id,
            author_user_id,
            note,
            created_at
        into v_row;

        perform platform.log_audit(
            'onboarding_note.created',
            'onboarding_note',
            v_row.id,
            to_jsonb(v_row)
        );

        v_result := to_jsonb(v_row);


    when 'delete_note' then

        select to_jsonb(n)
        into v_deleted
        from public.onboarding_notes n
        where n.id = (p_payload->>'id')::uuid
          and n.tenant_id = v_tid;

        if not found then
            raise exception 'Note not found';
        end if;

        delete from public.onboarding_notes n
        where n.id = (p_payload->>'id')::uuid
          and n.tenant_id = v_tid;

        perform platform.log_audit(
            'onboarding_note.deleted',
            'onboarding_note',
            (p_payload->>'id')::uuid,
            v_deleted
        );

        v_result := v_deleted;


    -- -------------------------------------------------
    -- CATALOG SNAPSHOT
    -- -------------------------------------------------

    when 'get_catalog_snapshot' then

        select to_jsonb(t)
        into v_result
        from (
            select
                cs.id,
                cs.tenant_id,
                cs.session_id,
                cs.preconfig_template_id,
                cs.onboarding_blueprint_id,
                cs.device_bundle_id,
                cs.preconfig_template_snapshot,
                cs.preconfig_device_map_snapshot,
                cs.onboarding_blueprint_snapshot,
                cs.onboarding_blueprint_steps_snapshot,
                cs.device_bundle_snapshot,
                cs.bundle_devices_snapshot,
                cs.created_at
            from public.onboarding_catalog_snapshots cs
            where cs.session_id =
                (p_payload->>'session_id')::uuid
              and cs.tenant_id = v_tid
        ) t;

        v_result := coalesce(
            v_result,
            'null'::jsonb
        );


    else

        raise exception
            'unknown onboarding_domain operation: %',
            p_op;

    end case;

    return v_result;
end;
$$;


-- =====================================================
-- 34. UI READ VIEWS
-- =====================================================

drop view if exists public.v_onboarding_lifecycle;
drop view if exists public.v_onboarding_lifecycle_overview;
drop view if exists public.v_properties_overview;
drop view if exists public.v_onboarding_progress;


-- =====================================================
-- 34A. LIFECYCLE OVERVIEW
-- =====================================================

create or replace view public.v_onboarding_lifecycle_overview
with (security_invoker = true)
as
select
    ol.id,
    ol.tenant_id,
    ol.property_id,
    p.name as property_name,
    ol.session_id,
    os.status as session_status,
    op.status as preconfig_status,
    ol.current_state,

    (
        select count(*)
        from public.onboarding_lifecycle_transitions olt
        where olt.lifecycle_id = ol.id
    ) as transition_count,

    (
        select olt.created_at
        from public.onboarding_lifecycle_transitions olt
        where olt.lifecycle_id = ol.id
        order by olt.created_at desc, olt.id desc
        limit 1
    ) as last_transition_at,

    ol.created_at,
    ol.updated_at

from public.onboarding_lifecycle ol

join public.properties p
    on p.id = ol.property_id

left join public.onboarding_sessions os
    on os.id = ol.session_id

left join public.onboarding_preconfig op
    on op.session_id = ol.session_id;


-- =====================================================
-- 34B. ONBOARDING PROGRESS
-- =====================================================

create or replace view public.v_onboarding_progress
with (security_invoker = true)
as
select
    os.id as session_id,
    os.tenant_id,
    os.property_id,
    p.name as property_name,

    os.status as session_status,
    os.current_step,

    op.status as preconfig_status,
    op.failure_reason as preconfig_failure_reason,

    ol.current_state as lifecycle_state,

    count(ss.id)
        filter (
            where ss.status = 'completed'
        ) as completed_steps,

    count(ss.id) as total_steps,

    case
        when count(ss.id) = 0 then 0::numeric
        else round(
            (
                100.0
                * count(ss.id)
                    filter (
                        where ss.status = 'completed'
                    )
                / count(ss.id)
            )::numeric,
            2
        )
    end as progress_percent,

    os.created_at,
    os.updated_at

from public.onboarding_sessions os

join public.properties p
    on p.id = os.property_id

left join public.onboarding_preconfig op
    on op.session_id = os.id

left join public.onboarding_lifecycle ol
    on ol.property_id = os.property_id

left join public.onboarding_step_state ss
    on ss.session_id = os.id

group by
    os.id,
    os.tenant_id,
    os.property_id,
    p.name,
    os.status,
    os.current_step,
    op.status,
    op.failure_reason,
    ol.current_state,
    os.created_at,
    os.updated_at;


-- =====================================================
-- 34C. PROPERTY OVERVIEW
-- =====================================================

create or replace view public.v_properties_overview
with (security_invoker = true)
as
select
    p.id,
    p.tenant_id,
    p.name,
    p.address,
    p.property_type,
    p.timezone,

    count(distinct r.id) as room_count,

    count(distinct d.id) as device_count,

    ol.current_state as onboarding_lifecycle_state,

    p.created_at,
    p.updated_at

from public.properties p

left join public.rooms r
    on r.property_id = p.id

left join public.device_assignments da
    on da.room_id = r.id

left join public.devices d
    on d.id = da.device_id
   and d.is_active = true

left join public.onboarding_lifecycle ol
    on ol.property_id = p.id

group by
    p.id,
    p.tenant_id,
    p.name,
    p.address,
    p.property_type,
    p.timezone,
    ol.current_state,
    p.created_at,
    p.updated_at;


-- =====================================================
-- 35. TIMESTAMP TRIGGERS
-- =====================================================

drop trigger if exists trg_onboarding_sessions_updated_at
on public.onboarding_sessions;

create trigger trg_onboarding_sessions_updated_at
before update
on public.onboarding_sessions
for each row
execute function platform.set_updated_at();


drop trigger if exists trg_onboarding_preconfig_updated_at
on public.onboarding_preconfig;

create trigger trg_onboarding_preconfig_updated_at
before update
on public.onboarding_preconfig
for each row
execute function platform.set_updated_at();


drop trigger if exists trg_onboarding_checklist_updated_at
on public.onboarding_checklist;

create trigger trg_onboarding_checklist_updated_at
before update
on public.onboarding_checklist
for each row
execute function platform.set_updated_at();


drop trigger if exists trg_onboarding_lifecycle_updated_at
on public.onboarding_lifecycle;

create trigger trg_onboarding_lifecycle_updated_at
before update
on public.onboarding_lifecycle
for each row
execute function platform.set_updated_at();


-- =====================================================
-- 36. SESSION TRIGGERS
-- =====================================================

drop trigger if exists trg_onboarding_sessions_tenant_consistency
on public.onboarding_sessions;

create trigger trg_onboarding_sessions_tenant_consistency
before insert or update
on public.onboarding_sessions
for each row
execute function public.enforce_onboarding_session_tenant_consistency();


drop trigger if exists trg_onboarding_sessions_blueprint_trace
on public.onboarding_sessions;

create trigger trg_onboarding_sessions_blueprint_trace
before insert or update
on public.onboarding_sessions
for each row
execute function public.enforce_onboarding_session_blueprint_trace();


drop trigger if exists trg_onboarding_sessions_catalog_immutability
on public.onboarding_sessions;

create trigger trg_onboarding_sessions_catalog_immutability
before update
on public.onboarding_sessions
for each row
execute function public.enforce_onboarding_session_catalog_immutability();


-- =====================================================
-- 37. PRECONFIG TRIGGERS
-- =====================================================

drop trigger if exists trg_onboarding_preconfig_tenant_consistency
on public.onboarding_preconfig;

create trigger trg_onboarding_preconfig_tenant_consistency
before insert or update
on public.onboarding_preconfig
for each row
execute function public.enforce_onboarding_child_tenant_consistency();


drop trigger if exists trg_onboarding_preconfig_transitions_consistency
on public.onboarding_preconfig_transitions;

create trigger trg_onboarding_preconfig_transitions_consistency
before insert
on public.onboarding_preconfig_transitions
for each row
execute function public.enforce_onboarding_preconfig_transition_consistency();


drop trigger if exists trg_onboarding_preconfig_transitions_immutable
on public.onboarding_preconfig_transitions;

create trigger trg_onboarding_preconfig_transitions_immutable
before update or delete
on public.onboarding_preconfig_transitions
for each row
execute function public.guard_onboarding_preconfig_transition_mutation();


-- =====================================================
-- 38. CHILD TENANT TRIGGERS
-- =====================================================

drop trigger if exists trg_onboarding_step_state_tenant_consistency
on public.onboarding_step_state;

create trigger trg_onboarding_step_state_tenant_consistency
before insert or update
on public.onboarding_step_state
for each row
execute function public.enforce_onboarding_child_tenant_consistency();


drop trigger if exists trg_onboarding_room_mapping_tenant_consistency
on public.onboarding_room_mapping;

create trigger trg_onboarding_room_mapping_tenant_consistency
before insert or update
on public.onboarding_room_mapping
for each row
execute function public.enforce_onboarding_child_tenant_consistency();


drop trigger if exists trg_onboarding_device_mapping_tenant_consistency
on public.onboarding_device_mapping;

create trigger trg_onboarding_device_mapping_tenant_consistency
before insert or update
on public.onboarding_device_mapping
for each row
execute function public.enforce_onboarding_child_tenant_consistency();


drop trigger if exists trg_onboarding_checklist_tenant_consistency
on public.onboarding_checklist;

create trigger trg_onboarding_checklist_tenant_consistency
before insert or update
on public.onboarding_checklist
for each row
execute function public.enforce_onboarding_child_tenant_consistency();


drop trigger if exists trg_onboarding_notes_tenant_consistency
on public.onboarding_notes;

create trigger trg_onboarding_notes_tenant_consistency
before insert or update
on public.onboarding_notes
for each row
execute function public.enforce_onboarding_child_tenant_consistency();


-- =====================================================
-- 39. ROOM / DEVICE CONSISTENCY
-- =====================================================

drop trigger if exists trg_onboarding_room_mapping_consistency
on public.onboarding_room_mapping;

create trigger trg_onboarding_room_mapping_consistency
before insert or update
on public.onboarding_room_mapping
for each row
execute function public.enforce_onboarding_room_mapping_consistency();


drop trigger if exists trg_onboarding_device_mapping_consistency
on public.onboarding_device_mapping;

create trigger trg_onboarding_device_mapping_consistency
before insert or update
on public.onboarding_device_mapping
for each row
execute function public.enforce_onboarding_device_mapping_consistency();


-- =====================================================
-- 40. LIFECYCLE TRIGGERS
-- =====================================================

drop trigger if exists trg_onboarding_lifecycle_tenant_consistency
on public.onboarding_lifecycle;

create trigger trg_onboarding_lifecycle_tenant_consistency
before insert or update
on public.onboarding_lifecycle
for each row
execute function public.enforce_onboarding_lifecycle_tenant_consistency();


drop trigger if exists trg_onboarding_lifecycle_transitions_consistency
on public.onboarding_lifecycle_transitions;

create trigger trg_onboarding_lifecycle_transitions_consistency
before insert
on public.onboarding_lifecycle_transitions
for each row
execute function public.enforce_onboarding_lifecycle_transitions_consistency();


drop trigger if exists trg_onboarding_lifecycle_transitions_immutable
on public.onboarding_lifecycle_transitions;

create trigger trg_onboarding_lifecycle_transitions_immutable
before update or delete
on public.onboarding_lifecycle_transitions
for each row
execute function public.guard_onboarding_lifecycle_transition_mutation();


-- =====================================================
-- 41. CATALOG SNAPSHOT TRIGGER
-- =====================================================

drop trigger if exists trg_onboarding_catalog_snapshot_immutable
on public.onboarding_catalog_snapshots;

create trigger trg_onboarding_catalog_snapshot_immutable
before update or delete
on public.onboarding_catalog_snapshots
for each row
execute function public.guard_onboarding_catalog_snapshot_mutation();


-- =====================================================
-- 42. COMMENTS
-- =====================================================

comment on table public.onboarding_preconfig is
    'Internal SOFO SPITI preconfig state for one onboarding session. Tracks preparation before shipping.';

comment on column public.onboarding_preconfig.status is
    'Current internal preconfig state. The preconfig process ends at ready_for_shipping; shipping itself belongs to onboarding_lifecycle.';

comment on column public.onboarding_preconfig.failure_reason is
    'Current failure reason when preconfig status is failed.';

comment on table public.onboarding_preconfig_transitions is
    'Immutable historical state transitions of the internal SOFO SPITI preconfig process.';

comment on column public.onboarding_sessions.current_step is
    'Denormalized customer wizard pointer. Canonical customer progress lives in onboarding_step_state.';

comment on column public.onboarding_sessions.preconfig_template_id is
    'Selected global 010 preconfig template. Historical catalog state is stored in onboarding_catalog_snapshots.';

comment on column public.onboarding_sessions.onboarding_blueprint_id is
    'Selected global 010 onboarding blueprint. Historical catalog state is stored in onboarding_catalog_snapshots.';

comment on column public.onboarding_device_mapping.device_id is
    'Populated after QR pairing associates hardware with the 004 devices registry.';

comment on column public.onboarding_device_mapping.scan_status is
    'QR pairing outcome state only. QR minting and execution belong outside 014.';

comment on table public.onboarding_catalog_snapshots is
    'Immutable historical snapshot of the selected 010 catalog configuration used by an onboarding session.';


-- =====================================================
-- 43. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (
    migration_name,
    version,
    rollback_available
)
values (
    '014_onboarding_engine',
    'REV3',
    false
)
on conflict (migration_name)
do update
set
    version = excluded.version,
    rollback_available = excluded.rollback_available;


-- =====================================================
-- END 014 ONBOARDING ENGINE REV3
-- =====================================================