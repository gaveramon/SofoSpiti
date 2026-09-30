-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 004_PROPERTY_DEVICE_ENGINE.SQL
-- =====================================================
--
-- OWNER:
--   Property & Device Engine
--
-- SSOT:
--   properties
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
--   020 = security hardening
--   022 = EXECUTE/API grant boundary
--
-- PUBLIC API:
--   public.devices_api(text,jsonb)
--
-- INTERNAL DOMAIN API:
--   public.devices_domain(text,jsonb)
--
-- IMPORTANT:
--   devices_domain remains an internal SECURITY DEFINER domain function.
--   devices_api is the authenticated-facing API contract expected by 022.
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

    updated_at timestamptz default now()
);


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
    'SmartHellas device registry SSOT. Provider identity belongs to the Integration Engine. Runtime telemetry/state belongs outside 004.';

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
    d.device_name,
    d.category_code,
    dc.name as category_name,
    d.protocol,
    d.model,
    d.manufacturer,
    d.is_active,
    r.id as room_id,
    r.name as room_name,
    r.property_id,
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
-- 022 deliberately revokes authenticated EXECUTE
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
begin

    p_payload := coalesce(
        p_payload,
        '{}'::jsonb
    );


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
                      where da.room_id in
                      (
                          select r.id
                          from public.rooms r
                          join public.properties p
                            on p.id = r.property_id
                          where r.property_id =
                              (p_payload->>'property_id')::uuid
                            and p.tenant_id = v_tid
                      )
                  )
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


        if p_payload ? 'parent_device_id'
           and p_payload->>'parent_device_id' is not null
        then

            if not exists (
                select 1
                from public.devices pd
                where pd.id =
                    (p_payload->>'parent_device_id')::uuid
                  and pd.tenant_id = v_tid
            ) then
                raise exception 'Parent device not found';
            end if;

        end if;


        insert into public.devices
        (
            tenant_id,
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
                from public.devices pd
                where pd.id =
                    (p_payload->>'parent_device_id')::uuid
                  and pd.tenant_id = v_tid
            ) then
                raise exception 'Parent device not found';
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
-- 022 grants authenticated EXECUTE to this function.
--
-- devices_domain remains internal.
--
-- This wrapper intentionally preserves the existing
-- devices_domain contract and therefore does not break
-- existing internal callers.
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
    'Internal Property & Device domain function. Not an authenticated API surface. EXECUTE boundary controlled by 022.';


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


-- =====================================================
-- 20. TRIGGERS
-- =====================================================

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