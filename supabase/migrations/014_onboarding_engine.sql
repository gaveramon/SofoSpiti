-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 014_ONBOARDING_ENGINGE.SQL
-- =====================================================
--
-- CLEAN DOMAIN STATE / PROGRESS / LIFECYCLE TRACKING
-- NO EXECUTION / NO AUTOMATION / NO SIDE EFFECTS
-- =====================================================
--
-- Wizard state, QR pairing outcomes, room/device mapping input,
-- lifecycle state, and progress tracking only.
-- QR minting and step orchestration → 000.
-- Flow definition → 010 onboarding_blueprints / preconfig_templates.
-- =====================================================


-- =====================================================
-- 1. ONBOARDING LIFECYCLE STATE ENUM
-- =====================================================

do $$
begin
    if not exists (
        select 1
        from pg_type t
        join pg_namespace n on n.oid = t.typnamespace
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
end $$;


-- =====================================================
-- 2. ONBOARDING SESSIONS
-- Per-tenant property onboarding session
-- =====================================================

create table if not exists public.onboarding_sessions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    property_id uuid not null,

    preconfig_template_id uuid references preconfig_templates(id) on delete set null,

    onboarding_blueprint_id uuid references onboarding_blueprints(id) on delete set null,

    status onboarding_status default 'not_started',

    current_step onboarding_step_type,

    created_at timestamptz default now(),

    updated_at timestamptz default now()
);


-- =====================================================
-- 3. ONBOARDING STEP STATE
-- Progress tracking only
-- =====================================================

create table if not exists public.onboarding_step_state (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    session_id uuid not null references onboarding_sessions(id) on delete cascade,

    step_type onboarding_step_type not null,

    status onboarding_step_status not null default 'pending',

    completed_at timestamptz,

    unique (session_id, step_type)
);


-- =====================================================
-- 4. ROOM MAPPING INPUT
-- User-defined room structure during onboarding
-- =====================================================

create table if not exists public.onboarding_room_mapping (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    session_id uuid not null references onboarding_sessions(id) on delete cascade,

    room_name text not null,

    room_type room_type,

    promoted_room_id uuid references rooms(id) on delete set null,

    created_at timestamptz default now(),

    unique (session_id, room_name)
);


-- =====================================================
-- 5. DEVICE PLACEMENT + QR PAIRING STATE
-- No execution
-- =====================================================

create table if not exists public.onboarding_device_mapping (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    session_id uuid not null references onboarding_sessions(id) on delete cascade,

    category_code text references public.device_categories(code),

    room_name text,

    desired_action text,

    device_id uuid references devices(id) on delete set null,

    scan_status onboarding_step_status default 'pending',

    scanned_at timestamptz,

    created_at timestamptz default now(),

    unique (session_id, category_code, room_name)
);


-- =====================================================
-- 6. ONBOARDING CHECKLIST
-- Business validation state
-- =====================================================

create table if not exists public.onboarding_checklist (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    session_id uuid not null references onboarding_sessions(id) on delete cascade,

    checklist_key text not null,
    -- wifi_connected, devices_received, app_installed

    is_completed boolean default false,

    updated_at timestamptz default now(),

    unique (session_id, checklist_key)
);


-- =====================================================
-- 7. ONBOARDING NOTES
-- Support + context only
-- =====================================================

create table if not exists public.onboarding_notes (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    session_id uuid not null references onboarding_sessions(id) on delete cascade,

    author_user_id uuid references platform.profiles(id) on delete set null,

    note text,

    created_at timestamptz default now()
);


-- =====================================================
-- 8. ONBOARDING LIFECYCLE
-- Property-level lifecycle state
-- =====================================================

create table if not exists public.onboarding_lifecycle (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    property_id uuid not null references properties(id) on delete cascade,

    session_id uuid references onboarding_sessions(id) on delete set null,

    current_state public.onboarding_lifecycle_state not null default 'created',

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    unique (property_id)
);


-- =====================================================
-- 9. ONBOARDING LIFECYCLE TRANSITIONS
-- Immutable lifecycle transition history
-- =====================================================

create table if not exists public.onboarding_lifecycle_transitions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    lifecycle_id uuid not null references onboarding_lifecycle(id) on delete cascade,

    from_state public.onboarding_lifecycle_state,

    to_state public.onboarding_lifecycle_state not null,

    metadata jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now()
);


-- =====================================================
-- 10. CORE ONBOARDING INDEXES
-- =====================================================

create index if not exists idx_onboarding_sessions_tenant_created
on public.onboarding_sessions (tenant_id, created_at desc);

create index if not exists idx_onboarding_sessions_property
on public.onboarding_sessions (property_id);

create unique index if not exists uq_onboarding_sessions_property_active
on public.onboarding_sessions (property_id)
where status in ('not_started', 'in_progress', 'waiting_user');

create index if not exists idx_onboarding_step_state_session
on public.onboarding_step_state (session_id);

create index if not exists idx_onboarding_step_state_tenant
on public.onboarding_step_state (tenant_id);

create index if not exists idx_onboarding_room_mapping_session
on public.onboarding_room_mapping (session_id);

create index if not exists idx_onboarding_room_mapping_tenant_created
on public.onboarding_room_mapping (tenant_id, created_at desc);

create index if not exists idx_onboarding_device_mapping_session
on public.onboarding_device_mapping (session_id);

create index if not exists idx_onboarding_device_mapping_tenant_created
on public.onboarding_device_mapping (tenant_id, created_at desc);

create index if not exists idx_onboarding_checklist_session
on public.onboarding_checklist (session_id);

create index if not exists idx_onboarding_checklist_tenant
on public.onboarding_checklist (tenant_id);

create index if not exists idx_onboarding_notes_session
on public.onboarding_notes (session_id);

create index if not exists idx_onboarding_notes_tenant_created
on public.onboarding_notes (tenant_id, created_at desc);


-- =====================================================
-- 11. LIFECYCLE INDEXES
-- =====================================================

create index if not exists idx_onboarding_lifecycle_tenant
    on public.onboarding_lifecycle (tenant_id, updated_at desc);


create index if not exists idx_onboarding_lifecycle_transitions_lifecycle
    on public.onboarding_lifecycle_transitions (lifecycle_id, created_at desc);


create index if not exists idx_onboarding_lifecycle_transitions_tenant_created
    on public.onboarding_lifecycle_transitions (tenant_id, created_at desc);


-- =====================================================
-- 12. COLUMN COMMENTS / DOMAIN DOCUMENTATION
-- =====================================================

comment on column public.onboarding_sessions.preconfig_template_id is
    'Links wizard to global 010 preconfig_templates / onboarding_blueprints. Tenant selection only — no tenant-owned templates.';


comment on column public.onboarding_sessions.onboarding_blueprint_id is
    'Optional traceability FK to 010 onboarding_blueprints. May mirror preconfig_templates.onboarding_blueprint_id.';


comment on column public.onboarding_sessions.current_step is
    'Denormalized wizard pointer; canonical progress lives in onboarding_step_state.';


comment on column public.onboarding_room_mapping.promoted_room_id is
    'Set after wizard promotes draft mapping into 004 rooms SSOT.';


comment on column public.onboarding_device_mapping.device_id is
    'Populated after QR scan pairs hardware into 004 devices registry.';


comment on column public.onboarding_device_mapping.scan_status is
    'QR pairing outcome only — token generation belongs in 000 / app layer.';


-- =====================================================
-- 13. TENANT FOREIGN KEY CONSTRAINTS
-- =====================================================

do $$
begin
    alter table public.onboarding_sessions
        add constraint fk_onboarding_sessions_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table public.onboarding_sessions
        add constraint fk_onboarding_sessions_property
        foreign key (property_id) references public.properties(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table public.onboarding_step_state
        add constraint fk_onboarding_step_state_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table public.onboarding_room_mapping
        add constraint fk_onboarding_room_mapping_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table public.onboarding_device_mapping
        add constraint fk_onboarding_device_mapping_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table public.onboarding_checklist
        add constraint fk_onboarding_checklist_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table public.onboarding_notes
        add constraint fk_onboarding_notes_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table public.onboarding_lifecycle
        add constraint fk_onboarding_lifecycle_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table public.onboarding_lifecycle_transitions
        add constraint fk_onboarding_lifecycle_transitions_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


-- =====================================================
-- 14. ONBOARDING DOMAIN CONSISTENCY FUNCTIONS
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

    if v_property_tenant <> new.tenant_id then
        raise exception 'onboarding session property must belong to the same tenant';
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
    if new.onboarding_blueprint_id is null or new.preconfig_template_id is null then
        return new;
    end if;

    select pt.onboarding_blueprint_id
    into v_template_blueprint
    from public.preconfig_templates pt
    where pt.id = new.preconfig_template_id;

    if v_template_blueprint is not null
       and v_template_blueprint is distinct from new.onboarding_blueprint_id then
        raise exception 'onboarding_blueprint_id must match preconfig_templates.onboarding_blueprint_id';
    end if;

    return new;
end;
$$;


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

    new.tenant_id := v_session_tenant;

    return new;
end;
$$;


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

    select s.property_id, s.tenant_id
    into v_session
    from public.onboarding_sessions s
    where s.id = new.session_id;

    if not found then
        raise exception 'onboarding session not found';
    end if;

    if not exists (
        select 1
        from public.rooms r
        join public.properties p on p.id = r.property_id
        where r.id = new.promoted_room_id
          and r.property_id = v_session.property_id
          and p.tenant_id = v_session.tenant_id
    ) then
        raise exception 'promoted room must belong to the onboarding session property and tenant';
    end if;

    return new;
end;
$$;


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

    if v_device_tenant <> v_session_tenant then
        raise exception 'paired device must belong to the onboarding session tenant';
    end if;

    return new;
end;
$$;


-- =====================================================
-- 15. LIFECYCLE CONSISTENCY FUNCTIONS
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
    select p.tenant_id into v_property_tenant
    from public.properties p
    where p.id = new.property_id;

    if not found then
        raise exception 'property not found';
    end if;

    if v_property_tenant is distinct from new.tenant_id then
        raise exception 'onboarding lifecycle property must belong to the same tenant';
    end if;

    if new.session_id is not null then
        select s.tenant_id into v_session_tenant
        from public.onboarding_sessions s
        where s.id = new.session_id;

        if not found then
            raise exception 'onboarding session not found';
        end if;

        if v_session_tenant is distinct from new.tenant_id then
            raise exception 'onboarding lifecycle session must belong to the same tenant';
        end if;
    end if;

    return new;
end;
$$;


create or replace function public.enforce_onboarding_lifecycle_transitions_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_lifecycle_tenant uuid;
begin
    select ol.tenant_id into v_lifecycle_tenant
    from public.onboarding_lifecycle ol
    where ol.id = new.lifecycle_id;

    if not found then
        raise exception 'onboarding lifecycle not found';
    end if;

    if v_lifecycle_tenant is distinct from new.tenant_id then
        raise exception 'onboarding lifecycle transition tenant mismatch';
    end if;

    return new;
end;
$$;


-- =====================================================
-- 16. LIFECYCLE STATE MACHINE FUNCTIONS
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
        when p_from is null and p_to = 'created' then true
        when p_from = 'created' and p_to = 'pre_onboarding' then true
        when p_from = 'pre_onboarding' and p_to = 'configured' then true
        when p_from = 'configured' and p_to = 'devices_assigned' then true
        when p_from = 'devices_assigned' and p_to = 'shipped' then true
        when p_from = 'shipped' and p_to = 'installed' then true
        when p_from = 'installed' and p_to = 'verified' then true
        when p_from = 'verified' and p_to = 'active' then true
        else false
    end;
$$;


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
begin
    v_tid := platform.current_tenant_id();
    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    select * into v_row
    from public.onboarding_lifecycle ol
    where ol.property_id = p_property_id and ol.tenant_id = v_tid
    for update;

    if not found then
        if p_to_state <> 'created' then
            raise exception 'lifecycle must start at created';
        end if;

        insert into public.onboarding_lifecycle (tenant_id, property_id, current_state)
        values (v_tid, p_property_id, 'created')
        returning * into v_row;

        v_from := null;
    else
        v_from := v_row.current_state;
    end if;

    if v_from = p_to_state then
        return to_jsonb(v_row);
    end if;

    if not public.onboarding_lifecycle_allowed_transition(v_from, p_to_state) then
        raise exception 'invalid onboarding lifecycle transition: % -> %', v_from, p_to_state;
    end if;

    update public.onboarding_lifecycle ol set
        current_state = p_to_state,
        updated_at = now()
    where ol.id = v_row.id
    returning * into v_row;

    insert into public.onboarding_lifecycle_transitions (
        tenant_id, lifecycle_id, from_state, to_state, metadata
    )
    values (v_tid, v_row.id, v_from, p_to_state, coalesce(p_metadata, '{}'::jsonb));

    perform public.insert_event(
        'onboarding.lifecycle.changed',
        jsonb_build_object(
            'property_id', p_property_id,
            'from_state', v_from,
            'to_state', p_to_state
        ) || coalesce(p_metadata, '{}'::jsonb)
    );

    return to_jsonb(v_row);
end;
$$;


-- =====================================================
-- 17. DOMAIN READ FUNCTIONS
-- 014 — no Edge guards
-- =====================================================

create or replace function public.onboarding_lifecycle_get(p_property_id uuid)
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

    select to_jsonb(t) into v_result
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


create or replace function public.onboarding_lifecycle_list_transitions(p_property_id uuid)
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

    select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb)
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
        join public.onboarding_lifecycle ol on ol.id = olt.lifecycle_id
        where ol.property_id = p_property_id
          and olt.tenant_id = v_tid
    ) t;

    return v_result;
end;
$$;


-- =====================================================
-- 18. ONBOARDING DOMAIN API
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
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);
    v_uid := (select auth.uid());

    case p_op
    when 'list_sessions' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb) into v_result
        from (
            select s.id, s.tenant_id, s.property_id, s.preconfig_template_id, s.onboarding_blueprint_id,
                   s.status, s.current_step, s.created_at, s.updated_at
            from public.onboarding_sessions s
            where s.tenant_id = v_tid
              and (p_payload->>'property_id' is null or s.property_id = (p_payload->>'property_id')::uuid)
        ) t;

    when 'get_session' then
        v_tid := platform.current_tenant_id();
        v_session_id := (p_payload->>'id')::uuid;
        select jsonb_build_object(
            'session', (
                select to_jsonb(t) from (
                    select s.id, s.tenant_id, s.property_id, s.preconfig_template_id, s.onboarding_blueprint_id,
                           s.status, s.current_step, s.created_at, s.updated_at
                    from public.onboarding_sessions s
                    where s.id = v_session_id and s.tenant_id = v_tid
                ) t
            ),
            'steps', coalesce((
                select jsonb_agg(to_jsonb(st) order by st.step_type)
                from (
                    select ss.id, ss.tenant_id, ss.session_id, ss.step_type, ss.status, ss.completed_at
                    from public.onboarding_step_state ss where ss.session_id = v_session_id
                ) st
            ), '[]'::jsonb),
            'room_mappings', coalesce((
                select jsonb_agg(to_jsonb(rm) order by rm.created_at)
                from (
                    select r.id, r.tenant_id, r.session_id, r.room_name, r.room_type, r.promoted_room_id, r.created_at
                    from public.onboarding_room_mapping r where r.session_id = v_session_id
                ) rm
            ), '[]'::jsonb),
            'device_mappings', coalesce((
                select jsonb_agg(to_jsonb(dm) order by dm.created_at)
                from (
                    select d.id, d.tenant_id, d.session_id, d.category_code, d.room_name, d.desired_action,
                           d.device_id, d.scan_status, d.scanned_at, d.created_at
                    from public.onboarding_device_mapping d where d.session_id = v_session_id
                ) dm
            ), '[]'::jsonb),
            'checklist', coalesce((
                select jsonb_agg(to_jsonb(c))
                from (
                    select c.id, c.tenant_id, c.session_id, c.checklist_key, c.is_completed, c.updated_at
                    from public.onboarding_checklist c where c.session_id = v_session_id
                ) c
            ), '[]'::jsonb),
            'notes', coalesce((
                select jsonb_agg(to_jsonb(n) order by n.created_at)
                from (
                    select n.id, n.tenant_id, n.session_id, n.author_user_id, n.note, n.created_at
                    from public.onboarding_notes n where n.session_id = v_session_id
                ) n
            ), '[]'::jsonb)
        ) into v_result;
        if v_result->'session' = 'null'::jsonb then raise exception 'Onboarding session not found'; end if;

    when 'create_session' then
        v_tid := platform.current_tenant_id();
        v_blueprint_id := case when p_payload ? 'onboarding_blueprint_id' and p_payload->>'onboarding_blueprint_id' is not null
            then (p_payload->>'onboarding_blueprint_id')::uuid else null end;
        if p_payload ? 'preconfig_template_id' and p_payload->>'preconfig_template_id' is not null and v_blueprint_id is null then
            select pt.onboarding_blueprint_id into v_blueprint_id
            from public.preconfig_templates pt
            where pt.id = (p_payload->>'preconfig_template_id')::uuid;
        end if;
        insert into public.onboarding_sessions (
            tenant_id, property_id, preconfig_template_id, onboarding_blueprint_id, status, current_step
        )
        values (
            v_tid,
            (p_payload->>'property_id')::uuid,
            case when p_payload ? 'preconfig_template_id' then (p_payload->>'preconfig_template_id')::uuid else null end,
            v_blueprint_id,
            coalesce((p_payload->>'status')::public.onboarding_status, 'not_started'::public.onboarding_status),
            case when p_payload ? 'current_step' and p_payload->>'current_step' is not null
                then (p_payload->>'current_step')::public.onboarding_step_type else null end
        )
        returning id, tenant_id, property_id, preconfig_template_id, onboarding_blueprint_id,
                  status, current_step, created_at, updated_at into v_row;
        v_session_id := v_row.id;
        if v_blueprint_id is not null then
            insert into public.onboarding_step_state (session_id, step_type, status)
            select v_session_id, obs.step_type, 'pending'::public.onboarding_step_status
            from public.onboarding_blueprint_steps obs
            where obs.blueprint_id = v_blueprint_id
            order by obs.step_order;
        end if;
        perform platform.log_audit('onboarding_session.created', 'onboarding_session', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_session' then
        v_tid := platform.current_tenant_id();
        update public.onboarding_sessions s set
            preconfig_template_id = case when p_payload ? 'preconfig_template_id'
                then (p_payload->>'preconfig_template_id')::uuid else s.preconfig_template_id end,
            onboarding_blueprint_id = case when p_payload ? 'onboarding_blueprint_id'
                then (p_payload->>'onboarding_blueprint_id')::uuid else s.onboarding_blueprint_id end,
            status = case when p_payload ? 'status'
                then (p_payload->>'status')::public.onboarding_status else s.status end,
            current_step = case when p_payload ? 'current_step'
                then case when p_payload->>'current_step' is null then null
                     else (p_payload->>'current_step')::public.onboarding_step_type end
                else s.current_step end
        where s.id = (p_payload->>'id')::uuid and s.tenant_id = v_tid
        returning s.id, s.tenant_id, s.property_id, s.preconfig_template_id, s.onboarding_blueprint_id,
                  s.status, s.current_step, s.created_at, s.updated_at into v_row;
        if not found then raise exception 'Onboarding session not found'; end if;
        perform platform.log_audit('onboarding_session.updated', 'onboarding_session', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_session' then
        v_tid := platform.current_tenant_id();
        delete from public.onboarding_sessions s
        where s.id = (p_payload->>'id')::uuid and s.tenant_id = v_tid;
        if not found then raise exception 'Onboarding session not found'; end if;
        perform platform.log_audit('onboarding_session.deleted', 'onboarding_session', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_step_states' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) into v_result
        from (
            select ss.id, ss.tenant_id, ss.session_id, ss.step_type, ss.status, ss.completed_at
            from public.onboarding_step_state ss
            where ss.session_id = (p_payload->>'session_id')::uuid and ss.tenant_id = v_tid
        ) t;

    when 'update_step_state' then
        v_tid := platform.current_tenant_id();
        update public.onboarding_step_state ss set
            status = case when p_payload ? 'status'
                then (p_payload->>'status')::public.onboarding_step_status else ss.status end,
            completed_at = case
                when p_payload ? 'completed_at' then (p_payload->>'completed_at')::timestamptz
                when p_payload ? 'status' and p_payload->>'status' = 'completed' then now()
                else ss.completed_at
            end
        where ss.id = (p_payload->>'id')::uuid and ss.tenant_id = v_tid
        returning ss.id, ss.tenant_id, ss.session_id, ss.step_type, ss.status, ss.completed_at into v_row;
        if not found then raise exception 'Step state not found'; end if;
        perform platform.log_audit('onboarding_step_state.updated', 'onboarding_step_state', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'list_room_mappings' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb) into v_result
        from (
            select r.id, r.tenant_id, r.session_id, r.room_name, r.room_type, r.promoted_room_id, r.created_at
            from public.onboarding_room_mapping r
            where r.session_id = (p_payload->>'session_id')::uuid and r.tenant_id = v_tid
        ) t;

    when 'create_room_mapping' then
        v_tid := platform.current_tenant_id();
        insert into public.onboarding_room_mapping (session_id, room_name, room_type)
        values (
            (p_payload->>'session_id')::uuid,
            p_payload->>'room_name',
            case when p_payload ? 'room_type' and p_payload->>'room_type' is not null
                then (p_payload->>'room_type')::public.room_type else null end
        )
        returning id, tenant_id, session_id, room_name, room_type, promoted_room_id, created_at into v_row;
        perform platform.log_audit('onboarding_room_mapping.created', 'onboarding_room_mapping', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_room_mapping' then
        v_tid := platform.current_tenant_id();
        update public.onboarding_room_mapping r set
            room_name = case when p_payload ? 'room_name' then p_payload->>'room_name' else r.room_name end,
            room_type = case when p_payload ? 'room_type'
                then case when p_payload->>'room_type' is null then null else (p_payload->>'room_type')::public.room_type end
                else r.room_type end,
            promoted_room_id = case when p_payload ? 'promoted_room_id'
                then (p_payload->>'promoted_room_id')::uuid else r.promoted_room_id end
        where r.id = (p_payload->>'id')::uuid and r.tenant_id = v_tid
        returning r.id, r.tenant_id, r.session_id, r.room_name, r.room_type, r.promoted_room_id, r.created_at into v_row;
        if not found then raise exception 'Room mapping not found'; end if;
        perform platform.log_audit('onboarding_room_mapping.updated', 'onboarding_room_mapping', v_row.id);
        v_result := to_jsonb(v_row);

    when 'delete_room_mapping' then
        v_tid := platform.current_tenant_id();
        delete from public.onboarding_room_mapping r
        where r.id = (p_payload->>'id')::uuid and r.tenant_id = v_tid;
        if not found then raise exception 'Room mapping not found'; end if;
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_device_mappings' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb) into v_result
        from (
            select d.id, d.tenant_id, d.session_id, d.category_code, d.room_name, d.desired_action,
                   d.device_id, d.scan_status, d.scanned_at, d.created_at
            from public.onboarding_device_mapping d
            where d.session_id = (p_payload->>'session_id')::uuid and d.tenant_id = v_tid
        ) t;

    when 'create_device_mapping' then
        v_tid := platform.current_tenant_id();
        insert into public.onboarding_device_mapping (
            session_id, category_code, room_name, desired_action, scan_status
        )
        values (
            (p_payload->>'session_id')::uuid,
            p_payload->>'category_code',
            p_payload->>'room_name',
            p_payload->>'desired_action',
            coalesce((p_payload->>'scan_status')::public.onboarding_step_status, 'pending'::public.onboarding_step_status)
        )
        returning id, tenant_id, session_id, category_code, room_name, desired_action,
                  device_id, scan_status, scanned_at, created_at into v_row;
        perform platform.log_audit('onboarding_device_mapping.created', 'onboarding_device_mapping', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_device_mapping' then
        v_tid := platform.current_tenant_id();
        update public.onboarding_device_mapping d set
            category_code = case when p_payload ? 'category_code' then p_payload->>'category_code' else d.category_code end,
            room_name = case when p_payload ? 'room_name' then p_payload->>'room_name' else d.room_name end,
            desired_action = case when p_payload ? 'desired_action' then p_payload->>'desired_action' else d.desired_action end,
            device_id = case when p_payload ? 'device_id'
                then (p_payload->>'device_id')::uuid else d.device_id end,
            scan_status = case when p_payload ? 'scan_status'
                then (p_payload->>'scan_status')::public.onboarding_step_status else d.scan_status end,
            scanned_at = case
                when p_payload ? 'scanned_at' then (p_payload->>'scanned_at')::timestamptz
                when p_payload ? 'device_id' and p_payload->>'device_id' is not null then now()
                else d.scanned_at
            end
        where d.id = (p_payload->>'id')::uuid and d.tenant_id = v_tid
        returning d.id, d.tenant_id, d.session_id, d.category_code, d.room_name, d.desired_action,
                  d.device_id, d.scan_status, d.scanned_at, d.created_at into v_row;
        if not found then raise exception 'Device mapping not found'; end if;
        perform platform.log_audit('onboarding_device_mapping.updated', 'onboarding_device_mapping', v_row.id);
        v_result := to_jsonb(v_row);

    when 'delete_device_mapping' then
        v_tid := platform.current_tenant_id();
        delete from public.onboarding_device_mapping d
        where d.id = (p_payload->>'id')::uuid and d.tenant_id = v_tid;
        if not found then raise exception 'Device mapping not found'; end if;
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_checklist_items' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) into v_result
        from (
            select c.id, c.tenant_id, c.session_id, c.checklist_key, c.is_completed, c.updated_at
            from public.onboarding_checklist c
            where c.session_id = (p_payload->>'session_id')::uuid and c.tenant_id = v_tid
        ) t;

    when 'upsert_checklist_item' then
        v_tid := platform.current_tenant_id();
        select c.id into v_existing from public.onboarding_checklist c
        where c.session_id = (p_payload->>'session_id')::uuid
          and c.checklist_key = p_payload->>'checklist_key';
        if found then
            update public.onboarding_checklist c set
                is_completed = coalesce((p_payload->>'is_completed')::boolean, true)
            where c.id = v_existing
            returning c.id, c.tenant_id, c.session_id, c.checklist_key, c.is_completed, c.updated_at into v_row;
        else
            insert into public.onboarding_checklist (session_id, checklist_key, is_completed)
            values (
                (p_payload->>'session_id')::uuid,
                p_payload->>'checklist_key',
                coalesce((p_payload->>'is_completed')::boolean, false)
            )
            returning id, tenant_id, session_id, checklist_key, is_completed, updated_at into v_row;
            perform platform.log_audit('onboarding_checklist.created', 'onboarding_checklist', v_row.id);
        end if;
        v_result := to_jsonb(v_row);

    when 'update_checklist_item' then
        v_tid := platform.current_tenant_id();
        update public.onboarding_checklist c set
            is_completed = case when p_payload ? 'is_completed'
                then (p_payload->>'is_completed')::boolean else c.is_completed end
        where c.id = (p_payload->>'id')::uuid and c.tenant_id = v_tid
        returning c.id, c.tenant_id, c.session_id, c.checklist_key, c.is_completed, c.updated_at into v_row;
        if not found then raise exception 'Checklist item not found'; end if;
        v_result := to_jsonb(v_row);

    when 'delete_checklist_item' then
        v_tid := platform.current_tenant_id();
        delete from public.onboarding_checklist c
        where c.id = (p_payload->>'id')::uuid and c.tenant_id = v_tid;
        if not found then raise exception 'Checklist item not found'; end if;
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_notes' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb) into v_result
        from (
            select n.id, n.tenant_id, n.session_id, n.author_user_id, n.note, n.created_at
            from public.onboarding_notes n
            where n.session_id = (p_payload->>'session_id')::uuid and n.tenant_id = v_tid
        ) t;

    when 'create_note' then
        v_tid := platform.current_tenant_id();
        insert into public.onboarding_notes (session_id, author_user_id, note)
        values ((p_payload->>'session_id')::uuid, v_uid, p_payload->>'note')
        returning id, tenant_id, session_id, author_user_id, note, created_at into v_row;
        perform platform.log_audit('onboarding_note.created', 'onboarding_note', v_row.id);
        v_result := to_jsonb(v_row);

    when 'delete_note' then
        v_tid := platform.current_tenant_id();
        delete from public.onboarding_notes n
        where n.id = (p_payload->>'id')::uuid and n.tenant_id = v_tid;
        if not found then raise exception 'Note not found'; end if;
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    else
        raise exception 'unknown onboarding_api operation: %', p_op;
    end case;

    return v_result;
end;
$$;


-- =====================================================
-- 19. UI READ VIEWS
-- Appsmith read contract
-- =====================================================

drop view if exists public.v_onboarding_lifecycle;


drop view if exists public.v_properties_overview;


drop view if exists public.v_onboarding_progress;


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
        order by olt.created_at desc
        limit 1
    ) as last_transition_at,
    ol.created_at,
    ol.updated_at
from public.onboarding_lifecycle ol
join public.properties p on p.id = ol.property_id
left join public.onboarding_sessions os on os.id = ol.session_id;


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
    ol.current_state as lifecycle_state,
    count(*) filter (where ss.status = 'completed') as completed_steps,
    count(*) as total_steps,
    os.created_at,
    os.updated_at
from public.onboarding_sessions os
join public.properties p on p.id = os.property_id
left join public.onboarding_lifecycle ol on ol.property_id = os.property_id
left join public.onboarding_step_state ss on ss.session_id = os.id
group by os.id, p.name, ol.current_state;


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
left join public.rooms r on r.property_id = p.id
left join public.device_assignments da on da.room_id = r.id
left join public.devices d on d.id = da.device_id and d.is_active = true
left join public.onboarding_lifecycle ol on ol.property_id = p.id
group by p.id, ol.current_state;



-- =====================================================
-- 22. TIMESTAMP + DOMAIN CONSISTENCY TRIGGERS
-- =====================================================

create trigger trg_onboarding_sessions_updated_at
before update on onboarding_sessions
for each row execute function platform.set_updated_at();

create trigger trg_onboarding_checklist_updated_at
before update on onboarding_checklist
for each row execute function platform.set_updated_at();

create trigger trg_onboarding_lifecycle_updated_at
before update on onboarding_lifecycle
for each row execute function platform.set_updated_at();

create trigger trg_onboarding_sessions_tenant_consistency
before insert or update on public.onboarding_sessions
for each row execute function public.enforce_onboarding_session_tenant_consistency();

create trigger trg_onboarding_sessions_blueprint_trace
before insert or update on public.onboarding_sessions
for each row execute function public.enforce_onboarding_session_blueprint_trace();

create trigger trg_onboarding_step_state_tenant_consistency
before insert or update on public.onboarding_step_state
for each row execute function public.enforce_onboarding_child_tenant_consistency();

create trigger trg_onboarding_room_mapping_consistency
before insert or update on public.onboarding_room_mapping
for each row execute function public.enforce_onboarding_room_mapping_consistency();

create trigger trg_onboarding_room_mapping_tenant_consistency
before insert or update on public.onboarding_room_mapping
for each row execute function public.enforce_onboarding_child_tenant_consistency();

create trigger trg_onboarding_device_mapping_consistency
before insert or update on public.onboarding_device_mapping
for each row execute function public.enforce_onboarding_device_mapping_consistency();

create trigger trg_onboarding_device_mapping_tenant_consistency
before insert or update on public.onboarding_device_mapping
for each row execute function public.enforce_onboarding_child_tenant_consistency();

create trigger trg_onboarding_checklist_tenant_consistency
before insert or update on public.onboarding_checklist
for each row execute function public.enforce_onboarding_child_tenant_consistency();

create trigger trg_onboarding_notes_tenant_consistency
before insert or update on public.onboarding_notes
for each row execute function public.enforce_onboarding_child_tenant_consistency();

create trigger trg_onboarding_lifecycle_tenant_consistency
before insert or update on public.onboarding_lifecycle
for each row execute function public.enforce_onboarding_lifecycle_tenant_consistency();

create trigger trg_onboarding_lifecycle_transitions_consistency
before insert or update on public.onboarding_lifecycle_transitions
for each row execute function public.enforce_onboarding_lifecycle_transitions_consistency();

-- =====================================================
-- 23. LEGACY / EXTENSION TRIGGER CLEANUP
-- =====================================================

drop trigger if exists trg_onboarding_lifecycle_tenant_consistency on public.onboarding_lifecycle;


drop trigger if exists trg_onboarding_lifecycle_transitions_consistency on public.onboarding_lifecycle_transitions;


-- =====================================================
-- 24. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('014_onboarding_engine', 'REV1', false)
on conflict (migration_name) do nothing;


-- =====================================================
-- END 014 ONBOARDING ENGINE
-- =====================================================