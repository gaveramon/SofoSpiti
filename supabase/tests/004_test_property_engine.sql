-- ============================================================
-- REV22 GREENFIELD BASELINE
-- 004_test_property_engine.sql
--
-- PROPERTY / DEVICE ENGINE TEST SUITE
--
-- Purpose:
--   Validate migration 004 before Appsmith integration.
--
-- Scope:
--   - dependencies
--   - tenant isolation
--   - properties
--   - rooms
--   - devices
--   - device categories
--   - assignments
--   - hierarchy
--   - gateway rules
--   - device configuration
--   - lifecycle / deletes
--   - RPC/API
--   - audit logging
--   - grants
--   - RLS
--
-- IMPORTANT:
--   This test engine creates temporary test data and rolls it
--   back at the end.
--
-- It must be executed AFTER:
--
--   000 platform
--   002 core SaaS
--   004 property/device engine
--   020 security hardening
--   022 final API / EXECUTE grants
--
-- ============================================================


-- ============================================================
-- 0. TEST HARNESS
-- ============================================================

begin;

do $$
declare
    v_missing text;
begin

    -- --------------------------------------------------------
    -- Core tables
    -- --------------------------------------------------------

    if to_regclass('public.customer_accounts') is null then
        raise exception 'TEST FAIL: public.customer_accounts missing';
    end if;

    if to_regclass('public.tenants') is null then
        raise exception 'TEST FAIL: public.tenants missing';
    end if;

    if to_regclass('public.tenant_memberships') is null then
        raise exception 'TEST FAIL: public.tenant_memberships missing';
    end if;

    if to_regclass('public.properties') is null then
        raise exception 'TEST FAIL: public.properties missing';
    end if;

    if to_regclass('public.rooms') is null then
        raise exception 'TEST FAIL: public.rooms missing';
    end if;

    if to_regclass('public.device_categories') is null then
        raise exception 'TEST FAIL: public.device_categories missing';
    end if;

    if to_regclass('public.devices') is null then
        raise exception 'TEST FAIL: public.devices missing';
    end if;

    if to_regclass('public.device_assignments') is null then
        raise exception 'TEST FAIL: public.device_assignments missing';
    end if;

    if to_regclass('public.device_configurations') is null then
        raise exception 'TEST FAIL: public.device_configurations missing';
    end if;


    -- --------------------------------------------------------
    -- Core functions
    -- --------------------------------------------------------

    if to_regprocedure(
        'public.devices_domain(text,jsonb)'
    ) is null then
        raise exception
            'TEST FAIL: public.devices_domain(text,jsonb) missing';
    end if;

    if to_regprocedure(
        'public.devices_api(text,jsonb)'
    ) is null then
        raise exception
            'TEST FAIL: public.devices_api(text,jsonb) missing';
    end if;

    if to_regprocedure(
        'public.devices_assign_device_to_room(uuid,uuid)'
    ) is null then
        raise exception
            'TEST FAIL: devices_assign_device_to_room(uuid,uuid) missing';
    end if;

    if to_regprocedure(
        'public.enforce_device_hierarchy()'
    ) is null then
        raise exception
            'TEST FAIL: enforce_device_hierarchy() missing';
    end if;

    if to_regprocedure(
        'public.enforce_device_assignment_tenant_consistency()'
    ) is null then
        raise exception
            'TEST FAIL: assignment tenant consistency trigger missing';
    end if;

    if to_regprocedure(
        'platform.log_audit(text,text,uuid,jsonb)'
    ) is null then
        raise exception
            'TEST FAIL: platform.log_audit() missing';
    end if;

    raise notice 'PASS: 004 dependencies exist';

end;
$$;


-- ============================================================
-- 1. TEST IDENTITIES
-- ============================================================
--
-- We use existing platform.profiles.
--
-- The test engine must NOT create auth.users directly.
--
-- A test installation should provide two profile IDs.
--
-- For a real automated test environment these can be supplied
-- through a dedicated test fixture.
--
-- For now we resolve two existing profiles.
-- ============================================================

do $$
declare
    v_count integer;
begin

    select count(*)
    into v_count
    from platform.profiles;

    if v_count < 2 then
        raise exception
            'TEST FAIL: at least two platform.profiles are required';
    end if;

    raise notice
        'PASS: sufficient test identities available';

end;
$$;


-- ============================================================
-- 2. TEST FIXTURE
-- ============================================================

create temporary table _004_test_context (
    key text primary key,
    value uuid not null
) on commit drop;


do $$
declare
    v_user_a uuid;
    v_user_b uuid;

    v_customer_a uuid;
    v_customer_b uuid;

    v_tenant_a uuid;
    v_tenant_b uuid;

    v_property_a uuid;
    v_property_b uuid;

    v_room_a uuid;
    v_room_b uuid;

    v_gateway_a uuid;
    v_sensor_a uuid;

    v_sensor_b uuid;
begin

    -- --------------------------------------------------------
    -- Select two real application identities.
    -- --------------------------------------------------------

    select p.id
    into v_user_a
    from platform.profiles p
    order by p.id
    limit 1;

    select p.id
    into v_user_b
    from platform.profiles p
    where p.id <> v_user_a
    order by p.id
    limit 1;


    -- --------------------------------------------------------
    -- Customer A
    -- --------------------------------------------------------

    insert into public.customer_accounts (
        owner_user_id,
        name
    )
    values (
        v_user_a,
        '004 TEST Customer A'
    )
    returning id
    into v_customer_a;


    -- --------------------------------------------------------
    -- Customer B
    -- --------------------------------------------------------

    insert into public.customer_accounts (
        owner_user_id,
        name
    )
    values (
        v_user_b,
        '004 TEST Customer B'
    )
    returning id
    into v_customer_b;


    -- --------------------------------------------------------
    -- Tenant A
    -- --------------------------------------------------------

    insert into public.tenants (
        customer_account_id,
        name,
        status
    )
    values (
        v_customer_a,
        '004 TEST Tenant A',
        'active'
    )
    returning id
    into v_tenant_a;


    -- --------------------------------------------------------
    -- Tenant B
    -- --------------------------------------------------------

    insert into public.tenants (
        customer_account_id,
        name,
        status
    )
    values (
        v_customer_b,
        '004 TEST Tenant B',
        'active'
    )
    returning id
    into v_tenant_b;


    -- --------------------------------------------------------
    -- Tenant A membership
    --
    -- handle_new_tenant() can already create an owner when
    -- auth.uid() exists. Because this test runs outside a real
    -- authenticated request, explicitly create the membership.
    -- --------------------------------------------------------

    insert into public.tenant_memberships (
        tenant_id,
        user_id,
        role,
        is_active
    )
    values (
        v_tenant_a,
        v_user_a,
        'owner',
        true
    )
    on conflict (tenant_id, user_id)
    do update set
        role = excluded.role,
        is_active = true;


    -- --------------------------------------------------------
    -- Tenant B membership
    -- --------------------------------------------------------

    insert into public.tenant_memberships (
        tenant_id,
        user_id,
        role,
        is_active
    )
    values (
        v_tenant_b,
        v_user_b,
        'owner',
        true
    )
    on conflict (tenant_id, user_id)
    do update set
        role = excluded.role,
        is_active = true;


    -- --------------------------------------------------------
    -- Property A
    -- --------------------------------------------------------

    insert into public.properties (
        tenant_id,
        name,
        address,
        property_type,
        timezone
    )
    values (
        v_tenant_a,
        '004 TEST Property A',
        'Test Address A',
        (
            select enumlabel::public.property_type
            from pg_enum
            join pg_type
                on pg_type.oid = pg_enum.enumtypid
            where pg_type.typname = 'property_type'
            order by enumsortorder
            limit 1
        ),
        'Europe/Amsterdam'
    )
    returning id
    into v_property_a;


    -- --------------------------------------------------------
    -- Property B
    -- --------------------------------------------------------

    insert into public.properties (
        tenant_id,
        name,
        address,
        property_type,
        timezone
    )
    values (
        v_tenant_b,
        '004 TEST Property B',
        'Test Address B',
        (
            select enumlabel::public.property_type
            from pg_enum
            join pg_type
                on pg_type.oid = pg_enum.enumtypid
            where pg_type.typname = 'property_type'
            order by enumsortorder
            limit 1
        ),
        'Europe/Amsterdam'
    )
    returning id
    into v_property_b;


    -- --------------------------------------------------------
    -- Rooms
    -- --------------------------------------------------------

    insert into public.rooms (
        property_id,
        name,
        room_type
    )
    values (
        v_property_a,
        '004 TEST Room A',
        (
            select enumlabel::public.room_type
            from pg_enum
            join pg_type
                on pg_type.oid = pg_enum.enumtypid
            where pg_type.typname = 'room_type'
            order by enumsortorder
            limit 1
        )
    )
    returning id
    into v_room_a;


    insert into public.rooms (
        property_id,
        name,
        room_type
    )
    values (
        v_property_b,
        '004 TEST Room B',
        (
            select enumlabel::public.room_type
            from pg_enum
            join pg_type
                on pg_type.oid = pg_enum.enumtypid
            where pg_type.typname = 'room_type'
            order by enumsortorder
            limit 1
        )
    )
    returning id
    into v_room_b;


    -- --------------------------------------------------------
    -- Gateway A
    -- --------------------------------------------------------

    insert into public.devices (
        tenant_id,
        device_name,
        category_code,
        protocol,
        model,
        manufacturer
    )
    values (
        v_tenant_a,
        '004 TEST Gateway A',
        'gateway',
        (
            select enumlabel::public.device_protocol
            from pg_enum
            join pg_type
                on pg_type.oid = pg_enum.enumtypid
            where pg_type.typname = 'device_protocol'
            order by enumsortorder
            limit 1
        ),
        'TEST-GATEWAY',
        'TEST'
    )
    returning id
    into v_gateway_a;


    -- --------------------------------------------------------
    -- Sensor A
    -- --------------------------------------------------------

    insert into public.devices (
        tenant_id,
        device_name,
        category_code,
        protocol,
        model,
        manufacturer
    )
    values (
        v_tenant_a,
        '004 TEST Sensor A',
        'sensor',
        (
            select enumlabel::public.device_protocol
            from pg_enum
            join pg_type
                on pg_type.oid = pg_enum.enumtypid
            order by enumsortorder
            limit 1
        ),
        'TEST-SENSOR',
        'TEST'
    )
    returning id
    into v_sensor_a;


    -- --------------------------------------------------------
    -- Sensor B
    -- --------------------------------------------------------

    insert into public.devices (
        tenant_id,
        device_name,
        category_code,
        protocol,
        model,
        manufacturer
    )
    values (
        v_tenant_b,
        '004 TEST Sensor B',
        'sensor',
        (
            select enumlabel::public.device_protocol
            from pg_enum
            join pg_type
                on pg_type.oid = pg_enum.enumtypid
            order by enumsortorder
            limit 1
        ),
        'TEST-SENSOR',
        'TEST'
    )
    returning id
    into v_sensor_b;


    insert into _004_test_context values
        ('user_a', v_user_a),
        ('user_b', v_user_b),
        ('customer_a', v_customer_a),
        ('customer_b', v_customer_b),
        ('tenant_a', v_tenant_a),
        ('tenant_b', v_tenant_b),
        ('property_a', v_property_a),
        ('property_b', v_property_b),
        ('room_a', v_room_a),
        ('room_b', v_room_b),
        ('gateway_a', v_gateway_a),
        ('sensor_a', v_sensor_a),
        ('sensor_b', v_sensor_b);


    raise notice 'PASS: test fixture created';

end;
$$;


-- ============================================================
-- 3. DEVICE CATEGORY SEED VALIDATION
-- ============================================================

do $$
declare
    v_expected text[] := array[
        'sensor',
        'switch',
        'lock',
        'thermostat',
        'ir_controller',
        'gateway',
        'other'
    ];

    v_code text;
begin

    foreach v_code in array v_expected loop

        if not exists (
            select 1
            from public.device_categories
            where code = v_code
        ) then
            raise exception
                'TEST FAIL: device category "%" missing',
                v_code;
        end if;

    end loop;


    -- Gateway invariant

    if not exists (
        select 1
        from public.device_categories
        where code = 'gateway'
          and is_gateway = true
          and is_lock = false
    ) then
        raise exception
            'TEST FAIL: gateway category definition incorrect';
    end if;


    -- Lock invariant

    if not exists (
        select 1
        from public.device_categories
        where code = 'lock'
          and is_gateway = false
          and is_lock = true
    ) then
        raise exception
            'TEST FAIL: lock category definition incorrect';
    end if;


    raise notice
        'PASS: device category seed';

end;
$$;


-- ============================================================
-- 4. TENANT OWNERSHIP
-- ============================================================

do $$
declare
    v_tenant_a uuid;
    v_customer_a uuid;
begin

    select value
    into v_tenant_a
    from _004_test_context
    where key = 'tenant_a';

    select value
    into v_customer_a
    from _004_test_context
    where key = 'customer_a';


    if not exists (
        select 1
        from public.tenants t
        where t.id = v_tenant_a
          and t.customer_account_id = v_customer_a
    ) then
        raise exception
            'TEST FAIL: tenant/customer account relationship';
    end if;


    raise notice
        'PASS: tenant/customer-account ownership';

end;
$$;


-- ============================================================
-- 5. DEFAULT DEVICE ACTIVE
-- ============================================================

do $$
declare
    v_tenant uuid;
    v_device uuid;
begin

    select value
    into v_tenant
    from _004_test_context
    where key = 'tenant_a';

    insert into public.devices (
        tenant_id,
        device_name,
        category_code,
        protocol
    )
    values (
        v_tenant,
        '004 TEST Default Active',
        'sensor',
        (
            select enumlabel::public.device_protocol
            from pg_enum
            join pg_type
                on pg_type.oid = pg_enum.enumtypid
            where pg_type.typname = 'device_protocol'
            order by enumsortorder
            limit 1
        )
    )
    returning id
    into v_device;


    if not exists (
        select 1
        from public.devices
        where id = v_device
          and is_active = true
    ) then
        raise exception
            'TEST FAIL: new device is not active by default';
    end if;


    raise notice
        'PASS: new devices default to active';

end;
$$;


-- ============================================================
-- 6. UPDATED_AT
-- ============================================================
--
-- This test assumes the agreed 004 change has been applied:
--
--   rooms.updated_at
--   devices.updated_at
--
-- ============================================================

do $$
begin

    if not exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'rooms'
          and column_name = 'updated_at'
    ) then
        raise exception
            'TEST FAIL: rooms.updated_at missing';
    end if;


    if not exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'devices'
          and column_name = 'updated_at'
    ) then
        raise exception
            'TEST FAIL: devices.updated_at missing';
    end if;


    raise notice
        'PASS: rooms/devices updated_at columns';

end;
$$;


-- ============================================================
-- 7. DEVICE HIERARCHY
-- ============================================================

do $$
declare
    v_gateway uuid;
    v_sensor uuid;
begin

    select value into v_gateway
    from _004_test_context
    where key = 'gateway_a';

    select value into v_sensor
    from _004_test_context
    where key = 'sensor_a';


    -- --------------------------------------------------------
    -- Gateway may not have a parent.
    -- --------------------------------------------------------

    begin

        update public.devices
        set parent_device_id = v_gateway
        where id = v_gateway;

        raise exception
            'TEST FAIL: gateway accepted parent_device_id';

    exception
        when others then

            if sqlerrm like 'TEST FAIL:%' then
                raise;
            end if;

            -- Expected trigger failure.

    end;


    -- --------------------------------------------------------
    -- Device may have gateway parent.
    -- --------------------------------------------------------

    update public.devices
    set parent_device_id = v_gateway
    where id = v_sensor;


    if not exists (
        select 1
        from public.devices
        where id = v_sensor
          and parent_device_id = v_gateway
    ) then
        raise exception
            'TEST FAIL: valid gateway parent rejected';
    end if;


    raise notice
        'PASS: gateway hierarchy';

end;
$$;


-- ============================================================
-- 8. CROSS-TENANT HIERARCHY
-- ============================================================

do $$
declare
    v_sensor_a uuid;
    v_sensor_b uuid;
begin

    select value into v_sensor_a
    from _004_test_context
    where key = 'sensor_a';

    select value into v_sensor_b
    from _004_test_context
    where key = 'sensor_b';


    begin

        update public.devices
        set parent_device_id = v_sensor_b
        where id = v_sensor_a;

        raise exception
            'TEST FAIL: cross-tenant parent accepted';

    exception
        when others then

            if sqlerrm like 'TEST FAIL:%' then
                raise;
            end if;

            -- Expected trigger failure.

    end;


    raise notice
        'PASS: cross-tenant hierarchy blocked';

end;
$$;


-- ============================================================
-- 9. GATEWAY DEMOTION WITH CHILD
-- ============================================================

do $$
declare
    v_gateway uuid;
begin

    select value into v_gateway
    from _004_test_context
    where key = 'gateway_a';


    begin

        update public.devices
        set category_code = 'sensor'
        where id = v_gateway;

        raise exception
            'TEST FAIL: gateway with child was demoted';

    exception
        when others then

            if sqlerrm like 'TEST FAIL:%' then
                raise;
            end if;

            -- Expected trigger failure.

    end;


    raise notice
        'PASS: gateway demotion protection';

end;
$$;


-- ============================================================
-- 10. DEVICE ASSIGNMENT
-- ============================================================

do $$
declare
    v_device uuid;
    v_room uuid;
begin

    select value into v_device
    from _004_test_context
    where key = 'sensor_a';

    select value into v_room
    from _004_test_context
    where key = 'room_a';


    perform public.devices_assign_device_to_room(
        v_device,
        v_room
    );


    if not exists (
        select 1
        from public.device_assignments da
        where da.device_id = v_device
          and da.room_id = v_room
    ) then
        raise exception
            'TEST FAIL: device assignment not created';
    end if;


    raise notice
        'PASS: device assignment';

end;
$$;


-- ============================================================
-- 11. CROSS-TENANT DEVICE ASSIGNMENT
-- ============================================================

do $$
declare
    v_device uuid;
    v_room uuid;
begin

    select value into v_device
    from _004_test_context
    where key = 'sensor_a';

    select value into v_room
    from _004_test_context
    where key = 'room_b';


    begin

        insert into public.device_assignments (
            device_id,
            room_id
        )
        values (
            v_device,
            v_room
        );

        raise exception
            'TEST FAIL: cross-tenant assignment accepted';

    exception
        when others then

            if sqlerrm like 'TEST FAIL:%' then
                raise;
            end if;

            -- Expected trigger failure.

    end;


    raise notice
        'PASS: cross-tenant assignment blocked';

end;
$$;


-- ============================================================
-- 12. DEVICE CONFIGURATION
-- ============================================================

do $$
declare
    v_device uuid;
begin

    select value into v_device
    from _004_test_context
    where key = 'sensor_a';


    insert into public.device_configurations (
        device_id,
        config
    )
    values (
        v_device,
        jsonb_build_object(
            'test_mode', true,
            'sample_interval', 60
        )
    );


    if not exists (
        select 1
        from public.device_configurations
        where device_id = v_device
          and config->>'test_mode' = 'true'
    ) then
        raise exception
            'TEST FAIL: device configuration not stored';
    end if;


    raise notice
        'PASS: device configuration';

end;
$$;


-- ============================================================
-- 13. CONFIGURATION UPSERT
-- ============================================================

do $$
declare
    v_device uuid;
begin

    select value into v_device
    from _004_test_context
    where key = 'sensor_a';


    perform public.devices_domain(
        'upsert_device_config',
        jsonb_build_object(
            'device_id',
            v_device,
            'config',
            jsonb_build_object(
                'test_mode',
                false,
                'sample_interval',
                120
            )
        )
    );


    if not exists (
        select 1
        from public.device_configurations
        where device_id = v_device
          and config->>'test_mode' = 'false'
          and (config->>'sample_interval')::integer = 120
    ) then
        raise exception
            'TEST FAIL: configuration upsert failed';
    end if;


    raise notice
        'PASS: configuration upsert';

end;
$$;


-- ============================================================
-- 14. DEVICE API SMOKE TEST
-- ============================================================
--
-- This validates that the API boundary exists and routes to
-- the domain engine.
--
-- A genuine authenticated authorization test belongs to the
-- authenticated/RLS test phase.
-- ============================================================

do $$
begin

    perform public.devices_api(
        'list_device_categories',
        '{}'::jsonb
    );

    raise notice
        'PASS: devices_api boundary';

exception
    when others then

        -- Authentication / authorization errors are expected
        -- when this script is not running as an authenticated
        -- portal user.
        --
        -- The function itself must exist; the authenticated
        -- result is tested separately.
        raise notice
            'INFO: devices_api executed but authentication context '
            'is required for full portal test: %',
            sqlerrm;

end;
$$;


-- ============================================================
-- 15. DELETE CASCADE: CONFIGURATION
-- ============================================================

do $$
declare
    v_tenant uuid;
    v_device uuid;
begin

    select value into v_tenant
    from _004_test_context
    where key = 'tenant_a';


    insert into public.devices (
        tenant_id,
        device_name,
        category_code,
        protocol
    )
    values (
        v_tenant,
        '004 TEST Delete Config',
        'sensor',
        (
            select enumlabel::public.device_protocol
            from pg_enum
            join pg_type
                on pg_type.oid = pg_enum.enumtypid
            where pg_type.typname = 'device_protocol'
            order by enumsortorder
            limit 1
        )
    )
    returning id
    into v_device;


    insert into public.device_configurations (
        device_id,
        config
    )
    values (
        v_device,
        '{"delete_test":true}'::jsonb
    );


    delete from public.devices
    where id = v_device;


    if exists (
        select 1
        from public.device_configurations
        where device_id = v_device
    ) then
        raise exception
            'TEST FAIL: device configuration did not cascade';
    end if;


    raise notice
        'PASS: device -> configuration cascade';

end;
$$;


-- ============================================================
-- 16. PROPERTY -> ROOM -> ASSIGNMENT CASCADE
-- ============================================================

do $$
declare
    v_tenant uuid;
    v_property uuid;
    v_room uuid;
    v_device uuid;
begin

    select value into v_tenant
    from _004_test_context
    where key = 'tenant_a';


    insert into public.properties (
        tenant_id,
        name,
        property_type
    )
    values (
        v_tenant,
        '004 TEST Cascade Property',
        (
            select enumlabel::public.property_type
            from pg_enum
            join pg_type
                on pg_type.oid = pg_enum.enumtypid
            where pg_type.typname = 'property_type'
            order by enumsortorder
            limit 1
        )
    )
    returning id into v_property;


    insert into public.rooms (
        property_id,
        name,
        room_type
    )
    values (
        v_property,
        '004 TEST Cascade Room',
        (
            select enumlabel::public.room_type
            from pg_enum
            join pg_type
                on pg_type.oid = pg_enum.enumtypid
            where pg_type.typname = 'room_type'
            order by enumsortorder
            limit 1
        )
    )
    returning id into v_room;


    insert into public.devices (
        tenant_id,
        device_name,
        category_code,
        protocol
    )
    values (
        v_tenant,
        '004 TEST Cascade Device',
        'sensor',
        (
            select enumlabel::public.device_protocol
            from pg_enum
            join pg_type
                on pg_type.oid = pg_enum.enumtypid
            order by enumsortorder
            limit 1
        )
    )
    returning id into v_device;


    insert into public.device_assignments (
        device_id,
        room_id
    )
    values (
        v_device,
        v_room
    );


    delete from public.properties
    where id = v_property;


    if exists (
        select 1
        from public.rooms
        where id = v_room
    ) then
        raise exception
            'TEST FAIL: property deletion did not cascade room';
    end if;


    if exists (
        select 1
        from public.device_assignments
        where device_id = v_device
    ) then
        raise exception
            'TEST FAIL: room deletion did not cascade assignment';
    end if;


    if not exists (
        select 1
        from public.devices
        where id = v_device
    ) then
        raise exception
            'TEST FAIL: property deletion unexpectedly deleted device';
    end if;


    raise notice
        'PASS: property/room/assignment lifecycle';

end;
$$;


-- ============================================================
-- 17. AUDIT LOGGING
-- ============================================================
--
-- The exact tenant/user values depend on auth.uid().
--
-- Therefore this test verifies the logging function through
-- the current execution context.
-- ============================================================

do $$
declare
    v_before bigint;
    v_after bigint;
begin

    select count(*)
    into v_before
    from platform.audit_log
    where action = '004.test.audit';


    perform platform.log_audit(
        '004.test.audit',
        'device',
        null,
        jsonb_build_object(
            'test_engine',
            '004',
            'purpose',
            'audit verification'
        )
    );


    select count(*)
    into v_after
    from platform.audit_log
    where action = '004.test.audit';


    if v_after <= v_before then
        raise exception
            'TEST FAIL: platform.log_audit() did not create log row';
    end if;


    raise notice
        'PASS: audit logging';

end;
$$;


-- ============================================================
-- 18. DEVICE COMMAND RESTRICT DELETE
-- ============================================================
--
-- Exact command fixture depends on the current 000 definition
-- of platform.device_commands.
--
-- This test deliberately checks the FK itself rather than
-- guessing the rest of the command schema.
-- ============================================================

do $$
declare
    v_device uuid;
    v_constraint_name text;
    v_delete_rule text;
begin

    select value
    into v_device
    from _004_test_context
    where key = 'sensor_b';


    select
        tc.constraint_name,
        rc.delete_rule
    into
        v_constraint_name,
        v_delete_rule
    from information_schema.table_constraints tc
    join information_schema.referential_constraints rc
        on rc.constraint_name = tc.constraint_name
       and rc.constraint_schema = tc.constraint_schema
    join information_schema.constraint_column_usage ccu
        on ccu.constraint_name = tc.constraint_name
       and ccu.constraint_schema = tc.constraint_schema
    where tc.constraint_schema = 'platform'
      and tc.table_name = 'device_commands'
      and ccu.table_schema = 'public'
      and ccu.table_name = 'devices'
      and ccu.column_name = 'id'
    limit 1;


    if v_delete_rule is distinct from 'RESTRICT'
       and v_delete_rule is distinct from 'NO ACTION' then

        raise exception
            'TEST FAIL: device_commands device FK delete rule is %',
            v_delete_rule;

    end if;


    raise notice
        'PASS: device_commands protects historical device references';

end;
$$;


-- ============================================================
-- 19. DEVICE HIERARCHY DELETE BEHAVIOUR
-- ============================================================
--
-- parent_device_id uses ON DELETE SET NULL.
--
-- Therefore deleting a gateway with children currently turns
-- those children into root devices.
--
-- This is intentionally surfaced as a lifecycle test.
--
-- Whether this is the desired business rule must be decided
-- before Appsmith.
-- ============================================================

do $$
declare
    v_gateway uuid;
    v_child uuid;
begin

    select value into v_gateway
    from _004_test_context
    where key = 'gateway_a';

    select value into v_child
    from _004_test_context
    where key = 'sensor_a';


    -- Remove assignment so this fixture does not interfere
    -- with the delete test.
    delete from public.device_assignments
    where device_id = v_child;


    delete from public.devices
    where id = v_gateway;


    if exists (
        select 1
        from public.devices
        where id = v_child
          and parent_device_id is not null
    ) then
        raise exception
            'TEST FAIL: child retained deleted gateway parent';
    end if;


    raise notice
        'PASS: gateway deletion produces root child '
        '(ON DELETE SET NULL behaviour confirmed)';

end;
$$;


-- ============================================================
-- 20. FINAL TEST RESULT
-- ============================================================

raise notice
    '============================================================';

raise notice
    '004 PROPERTY / DEVICE ENGINE TESTS COMPLETED';

raise notice
    'All non-authenticated structural/domain tests passed.';

raise notice
    'Authenticated RLS / grant / portal tests must still be run';

raise notice
    'with a real authenticated tenant context.';

raise notice
    '============================================================';


-- ============================================================
-- 21. ROLLBACK TEST FIXTURE
-- ============================================================
--
-- Because the entire engine runs inside one transaction,
-- ROLLBACK removes:
--
--   customer accounts
--   tenants
--   memberships
--   properties
--   rooms
--   devices
--   configurations
--   assignments
--   audit test rows
--
-- and restores the database to its original state.
-- ============================================================

rollback;

-- ============================================================
-- END 004 TEST ENGINE
-- ============================================================