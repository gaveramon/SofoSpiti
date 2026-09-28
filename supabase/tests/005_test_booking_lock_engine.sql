-- =====================================================
-- 005_BOOKING_LOCK_ENGINE_TEST.SQL
-- REV1 GREENFIELD BASELINE
-- =====================================================
--
-- Purpose:
--   Full automated verification of 005 Booking & Lock.
--
-- IMPORTANT:
--   This script is transactional.
--   All fixtures are rolled back at the end.
--
-- Prerequisites:
--   000 Platform
--   001 Core types
--   002 Core SaaS / tenants
--   003 CRM / properties
--   004 Devices
--   005 Integrations
--   005 Booking & Lock
--
-- This test assumes:
--   - access_credential_status contains 'revoking'
--   - public.device_integration_map exists
--   - public.integration_providers exists
--   - platform.queue_device_command(...) exists
--   - platform.log_audit(...) exists
-- =====================================================

begin;

-- =====================================================
-- 0. TEST RESULT HELPER
-- =====================================================

create temp table _005_test_results (
    test_no     int generated always as identity,
    test_name   text not null,
    result      text not null,
    details     text
) on commit drop;


create or replace function pg_temp.assert_true(
    p_condition boolean,
    p_test_name text,
    p_details text default null
)
returns void
language plpgsql
as $$
begin
    if coalesce(p_condition, false) then

        insert into _005_test_results (
            test_name,
            result,
            details
        )
        values (
            p_test_name,
            'PASS',
            p_details
        );

    else

        insert into _005_test_results (
            test_name,
            result,
            details
        )
        values (
            p_test_name,
            'FAIL',
            p_details
        );

        raise exception
            '005 TEST FAILED: % — %',
            p_test_name,
            coalesce(p_details, 'no details');

    end if;
end;
$$;


create or replace function pg_temp.assert_raises(
    p_sql text,
    p_test_name text,
    p_expected text default null
)
returns void
language plpgsql
as $$
begin

    begin
        execute p_sql;

        insert into _005_test_results (
            test_name,
            result,
            details
        )
        values (
            p_test_name,
            'FAIL',
            'Expected exception but statement succeeded'
        );

        raise exception
            '005 TEST FAILED: % — expected exception',
            p_test_name;

    exception
        when others then

            if sqlerrm = format(
                '005 TEST FAILED: % — expected exception',
                p_test_name
            ) then
                raise;
            end if;

            if p_expected is not null
               and position(lower(p_expected) in lower(sqlerrm)) = 0
            then
                insert into _005_test_results (
                    test_name,
                    result,
                    details
                )
                values (
                    p_test_name,
                    'FAIL',
                    'Unexpected error: ' || sqlerrm
                );

                raise exception
                    '005 TEST FAILED: % — unexpected error: %',
                    p_test_name,
                    sqlerrm;
            end if;

            insert into _005_test_results (
                test_name,
                result,
                details
            )
            values (
                p_test_name,
                'PASS',
                sqlerrm
            );

    end;

end;
$$;


-- =====================================================
-- 1. REQUIRED TABLES
-- =====================================================

select pg_temp.assert_true(
    to_regclass('public.bookings') is not null,
    '01 bookings table exists'
);

select pg_temp.assert_true(
    to_regclass('public.property_access_schedules') is not null,
    '02 property_access_schedules table exists'
);

select pg_temp.assert_true(
    to_regclass('public.booking_access') is not null,
    '03 booking_access table exists'
);

select pg_temp.assert_true(
    to_regclass('public.access_policies') is not null,
    '04 access_policies table exists'
);

select pg_temp.assert_true(
    to_regclass('public.access_rules') is not null,
    '05 access_rules table exists'
);

select pg_temp.assert_true(
    to_regclass('public.lock_devices') is not null,
    '06 lock_devices table exists'
);

select pg_temp.assert_true(
    to_regclass('public.access_credentials') is not null,
    '07 access_credentials table exists'
);


-- =====================================================
-- 2. REQUIRED FUNCTIONS
-- =====================================================

select pg_temp.assert_true(
    to_regprocedure(
        'public.enforce_booking_tenant_consistency()'
    ) is not null,
    '08 booking tenant trigger function exists'
);

select pg_temp.assert_true(
    to_regprocedure(
        'public.enforce_property_tenant_consistency()'
    ) is not null,
    '09 property tenant trigger function exists'
);

select pg_temp.assert_true(
    to_regprocedure(
        'public.enforce_booking_access_consistency()'
    ) is not null,
    '10 booking access trigger function exists'
);

select pg_temp.assert_true(
    to_regprocedure(
        'public.enforce_lock_device_integrity()'
    ) is not null,
    '11 lock device trigger function exists'
);

select pg_temp.assert_true(
    to_regprocedure(
        'public.enforce_access_credential_consistency()'
    ) is not null,
    '12 credential trigger function exists'
);

select pg_temp.assert_true(
    to_regprocedure(
        'public.booking_compute_access_window(uuid)'
    ) is not null,
    '13 booking access calculation exists'
);

select pg_temp.assert_true(
    to_regprocedure(
        'public.booking_calculate_access_window(uuid)'
    ) is not null,
    '14 booking access calculation RPC exists'
);

select pg_temp.assert_true(
    to_regprocedure(
        'public.booking_generate_booking_access(uuid)'
    ) is not null,
    '15 booking access generation exists'
);

select pg_temp.assert_true(
    to_regprocedure(
        'public.booking_regenerate_booking_access(uuid)'
    ) is not null,
    '16 booking access regeneration exists'
);

select pg_temp.assert_true(
    to_regprocedure(
        'public.booking_create_booking_access(jsonb)'
    ) is not null,
    '17 booking access create RPC exists'
);

select pg_temp.assert_true(
    to_regprocedure(
        'public.booking_domain(text,jsonb)'
    ) is not null,
    '18 booking domain RPC exists'
);

select pg_temp.assert_true(
    to_regprocedure(
        'public.locks_domain(text,jsonb)'
    ) is not null,
    '19 locks domain RPC exists'
);


-- =====================================================
-- 3. REQUIRED PLATFORM EXECUTION API
-- =====================================================

select pg_temp.assert_true(
    to_regprocedure(
        'platform.queue_device_command(uuid,text,jsonb,text,uuid)'
    ) is not null,
    '20 generic queue_device_command API exists'
);


-- =====================================================
-- 4. REQUIRED VIEW
-- =====================================================

select pg_temp.assert_true(
    to_regclass('public.v_bookings_overview') is not null,
    '21 bookings overview view exists'
);


-- =====================================================
-- 5. REQUIRED ENUM VALUE: revoking
-- =====================================================

select pg_temp.assert_true(
    exists (
        select 1
        from pg_enum e
        join pg_type t
            on t.oid = e.enumtypid
        join pg_namespace n
            on n.oid = t.typnamespace
        where n.nspname = 'public'
          and t.typname = 'access_credential_status'
          and e.enumlabel = 'revoking'
    ),
    '22 access_credential_status contains revoking'
);


-- =====================================================
-- 6. COLUMN STRUCTURE
-- =====================================================

select pg_temp.assert_true(
    exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'access_credentials'
          and column_name = 'booking_access_id'
          and is_nullable = 'NO'
    ),
    '23 booking_access_id is NOT NULL'
);


select pg_temp.assert_true(
    exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'access_credentials'
          and column_name = 'provider_code'
          and is_nullable = 'NO'
    ),
    '24 provider_code is NOT NULL'
);


select pg_temp.assert_true(
    exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'access_credentials'
          and column_name = 'valid_from'
          and is_nullable = 'NO'
    ),
    '25 credential valid_from is NOT NULL'
);


select pg_temp.assert_true(
    exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'access_credentials'
          and column_name = 'valid_until'
          and is_nullable = 'NO'
    ),
    '26 credential valid_until is NOT NULL'
);


-- =====================================================
-- 7. REQUIRED FOREIGN KEYS
-- =====================================================

select pg_temp.assert_true(
    exists (
        select 1
        from pg_constraint c
        join pg_class r
            on r.oid = c.conrelid
        join pg_namespace n
            on n.oid = r.relnamespace
        where n.nspname = 'public'
          and r.relname = 'bookings'
          and c.contype = 'f'
          and c.conname = 'fk_bookings_tenant'
    ),
    '27 bookings tenant FK exists'
);


select pg_temp.assert_true(
    exists (
        select 1
        from pg_constraint c
        join pg_class r
            on r.oid = c.conrelid
        join pg_namespace n
            on n.oid = r.relnamespace
        where n.nspname = 'public'
          and r.relname = 'booking_access'
          and c.contype = 'f'
          and c.conname = 'fk_booking_access_tenant'
    ),
    '28 booking_access tenant FK exists'
);


select pg_temp.assert_true(
    exists (
        select 1
        from pg_constraint c
        join pg_class r
            on r.oid = c.conrelid
        join pg_namespace n
            on n.oid = r.relnamespace
        where n.nspname = 'public'
          and r.relname = 'access_credentials'
          and c.contype = 'f'
          and c.conname = 'fk_access_credentials_tenant'
    ),
    '29 access_credentials tenant FK exists'
);


-- =====================================================
-- 8. UNIQUE CREDENTIAL INDEX
-- =====================================================

select pg_temp.assert_true(
    exists (
        select 1
        from pg_indexes
        where schemaname = 'public'
          and tablename = 'access_credentials'
          and indexname = 'uq_access_credentials_active_booking_lock'
          and indexdef ilike '%revoking%'
    ),
    '30 credential uniqueness includes revoking status'
);


-- =====================================================
-- 9. MIGRATION REGISTRATION
-- =====================================================

select pg_temp.assert_true(
    exists (
        select 1
        from platform.schema_migrations
        where migration_name = '005_booking_lock_engine'
    ),
    '31 005 is registered in schema_migrations'
);


-- =====================================================
-- 10. FIXTURES
-- =====================================================

-- -----------------------------------------------------
-- 10A. Tenant
-- -----------------------------------------------------

do $$
declare
    v_tenant uuid;
begin

    select id
    into v_tenant
    from public.tenants
    order by created_at
    limit 1;

    if v_tenant is null then

        insert into public.tenants (
            name
        )
        values (
            'TEST 005 Booking Lock'
        )
        returning id into v_tenant;

    end if;

    perform set_config(
        '005.test_tenant_id',
        v_tenant::text,
        true
    );

end;
$$;


-- -----------------------------------------------------
-- 10B. Property
-- -----------------------------------------------------

do $$
declare
    v_tid uuid;
    v_property uuid;
begin

    v_tid := current_setting(
        '005.test_tenant_id'
    )::uuid;

    select p.id
    into v_property
    from public.properties p
    where p.tenant_id = v_tid
    order by p.created_at
    limit 1;

    if v_property is null then

        insert into public.properties (
            tenant_id,
            name,
            property_type,
            timezone
        )
        values (
            v_tid,
            'TEST 005 Property',
            (
                select enumlabel::public.property_type
                from pg_enum e
                join pg_type t
                    on t.oid = e.enumtypid
                join pg_namespace n
                    on n.oid = t.typnamespace
                where n.nspname = 'public'
                  and t.typname = 'property_type'
                order by e.enumsortorder
                limit 1
            ),
            'Europe/Amsterdam'
        )
        returning id into v_property;

    end if;

    perform set_config(
        '005.test_property_id',
        v_property::text,
        true
    );

end;
$$;


-- -----------------------------------------------------
-- 10C. Lock category
-- -----------------------------------------------------

do $$
declare
    v_category text;
begin

    select code
    into v_category
    from public.device_categories
    where is_lock = true
      and is_active = true
    order by sort_order
    limit 1;

    if v_category is null then
        raise exception
            'No active lock device category exists';
    end if;

    perform set_config(
        '005.test_lock_category',
        v_category,
        true
    );

end;
$$;


-- -----------------------------------------------------
-- 10D. Device
-- -----------------------------------------------------

do $$
declare
    v_tid uuid;
    v_device uuid;
begin

    v_tid := current_setting(
        '005.test_tenant_id'
    )::uuid;

    select d.id
    into v_device
    from public.devices d
    where d.tenant_id = v_tid
      and d.category_code =
          current_setting('005.test_lock_category')
    limit 1;

    if v_device is null then

        insert into public.devices (
            tenant_id,
            device_name,
            category_code,
            protocol,
            model,
            manufacturer,
            is_active
        )
        values (
            v_tid,
            'TEST 005 Lock',
            current_setting('005.test_lock_category'),
            (
                select enumlabel::public.device_protocol
                from pg_enum e
                join pg_type t
                    on t.oid = e.enumtypid
                join pg_namespace n
                    on n.oid = t.typnamespace
                where n.nspname = 'public'
                  and t.typname = 'device_protocol'
                order by e.enumsortorder
                limit 1
            ),
            'TEST',
            'TEST',
            true
        )
        returning id into v_device;

    end if;

    perform set_config(
        '005.test_device_id',
        v_device::text,
        true
    );

end;
$$;


-- -----------------------------------------------------
-- 10E. Integration provider
-- -----------------------------------------------------

select pg_temp.assert_true(
    exists (
        select 1
        from public.integration_providers
        where code = 'ttlock'
    ),
    '32 TTLock integration provider exists'
);


-- -----------------------------------------------------
-- 10F. Device integration mapping
-- -----------------------------------------------------

do $$
declare
    v_tid uuid;
    v_device uuid;
begin

    v_tid := current_setting(
        '005.test_tenant_id'
    )::uuid;

    v_device := current_setting(
        '005.test_device_id'
    )::uuid;

    if not exists (
        select 1
        from public.device_integration_map
        where device_id = v_device
          and provider_code = 'ttlock'
    ) then

        insert into public.device_integration_map (
            tenant_id,
            device_id,
            provider_code,
            external_id,
            config
        )
        values (
            v_tid,
            v_device,
            'ttlock',
            'TEST-005-LOCK',
            '{}'::jsonb
        );

    end if;

end;
$$;


-- =====================================================
-- 11. BOOKING DATE RANGE
-- =====================================================

do $$
declare
    v_tid uuid;
    v_property uuid;
    v_booking uuid;
begin

    v_tid := current_setting(
        '005.test_tenant_id'
    )::uuid;

    v_property := current_setting(
        '005.test_property_id'
    )::uuid;

    insert into public.bookings (
        tenant_id,
        property_id,
        guest_name,
        guest_email,
        start_date,
        end_date,
        status
    )
    values (
        v_tid,
        v_property,
        '005 Test Guest',
        '005-test@example.invalid',
        current_date + 10,
        current_date + 13,
        'pending'
    )
    returning id into v_booking;

    perform set_config(
        '005.test_booking_id',
        v_booking::text,
        true
    );

end;
$$;


-- =====================================================
-- 12. PROPERTY ACCESS SCHEDULE
-- =====================================================

insert into public.property_access_schedules (
    tenant_id,
    property_id,
    check_in_time,
    check_out_time,
    early_check_in_minutes,
    late_checkout_minutes,
    is_active
)
values (
    current_setting('005.test_tenant_id')::uuid,
    current_setting('005.test_property_id')::uuid,
    '15:00',
    '11:00',
    30,
    45,
    true
)
on conflict (property_id)
do update set
    check_in_time = excluded.check_in_time,
    check_out_time = excluded.check_out_time,
    early_check_in_minutes = excluded.early_check_in_minutes,
    late_checkout_minutes = excluded.late_checkout_minutes,
    is_active = excluded.is_active;


-- =====================================================
-- 13. ACCESS WINDOW CALCULATION
-- =====================================================

do $$
declare
    v_window record;
    v_expected_from timestamptz;
    v_expected_until timestamptz;
begin

    select *
    into v_window
    from public.booking_compute_access_window(
        current_setting('005.test_booking_id')::uuid
    );

    v_expected_from :=
        (
            (
                current_date + 10
            )::timestamp
            + '15:00'::time
        )
        at time zone 'Europe/Amsterdam'
        - interval '30 minutes';

    v_expected_until :=
        (
            (
                current_date + 13
            )::timestamp
            + '11:00'::time
        )
        at time zone 'Europe/Amsterdam'
        + interval '45 minutes';

    perform pg_temp.assert_true(
        v_window.valid_from = v_expected_from,
        '33 access window valid_from is calculated correctly'
    );

    perform pg_temp.assert_true(
        v_window.valid_until = v_expected_until,
        '34 access window valid_until is calculated correctly'
    );

end;
$$;


-- =====================================================
-- 14. ACCESS RULE EXTENSION
-- =====================================================

insert into public.access_rules (
    tenant_id,
    property_id,
    rule_type,
    rule_config,
    is_active
)
values (
    current_setting('005.test_tenant_id')::uuid,
    current_setting('005.test_property_id')::uuid,
    'override',
    jsonb_build_object(
        'extend_early_minutes', 15,
        'extend_late_minutes', 20
    ),
    true
);


do $$
declare
    v_window record;
begin

    select *
    into v_window
    from public.booking_compute_access_window(
        current_setting('005.test_booking_id')::uuid
    );

    perform pg_temp.assert_true(
        v_window.valid_from =
        (
            (
                current_date + 10
            )::timestamp
            + '15:00'::time
        )
        at time zone 'Europe/Amsterdam'
        - interval '45 minutes',
        '35 access rule extends early access'
    );

    perform pg_temp.assert_true(
        v_window.valid_until =
        (
            (
                current_date + 13
            )::timestamp
            + '11:00'::time
        )
        at time zone 'Europe/Amsterdam'
        + interval '65 minutes',
        '36 access rule extends late access'
    );

end;
$$;


-- =====================================================
-- 15. GENERATE BOOKING ACCESS
-- =====================================================
--
-- Direct function execution is intentionally not used here
-- if edge_require_manager() requires an authenticated
-- Supabase JWT context.
--
-- Instead test the underlying trigger invariants directly.
-- =====================================================

do $$
declare
    v_tid uuid;
    v_booking uuid;
    v_access uuid;
    v_from timestamptz;
    v_until timestamptz;
begin

    v_tid := current_setting(
        '005.test_tenant_id'
    )::uuid;

    v_booking := current_setting(
        '005.test_booking_id'
    )::uuid;

    select valid_from, valid_until
    into v_from, v_until
    from public.booking_compute_access_window(v_booking);

    insert into public.booking_access (
        tenant_id,
        booking_id,
        access_type,
        valid_from,
        valid_until
    )
    values (
        v_tid,
        v_booking,
        'guest',
        v_from,
        v_until
    )
    returning id into v_access;

    perform set_config(
        '005.test_booking_access_id',
        v_access::text,
        true
    );

end;
$$;


select pg_temp.assert_true(
    exists (
        select 1
        from public.booking_access
        where id = current_setting('005.test_booking_access_id')::uuid
          and booking_id =
              current_setting('005.test_booking_id')::uuid
    ),
    '37 booking_access created for booking'
);


-- =====================================================
-- 16. BOOKING ACCESS TENANT IS DERIVED FROM BOOKING
-- =====================================================

do $$
declare
    v_access uuid;
    v_actual uuid;
begin

    v_access := gen_random_uuid();

    insert into public.booking_access (
        id,
        tenant_id,
        booking_id,
        access_type,
        valid_from,
        valid_until
    )
    values (
        v_access,
        gen_random_uuid(),
        current_setting('005.test_booking_id')::uuid,
        'guest',
        now(),
        now() + interval '1 hour'
    );

    select tenant_id
    into v_actual
    from public.booking_access
    where id = v_access;

    perform pg_temp.assert_true(
        v_actual =
        current_setting('005.test_tenant_id')::uuid,
        '38 booking_access tenant is forced to booking tenant'
    );

end;
$$;


-- =====================================================
-- 17. BOOKING ACCESS MUST BE GUEST ONLY
-- =====================================================

select pg_temp.assert_raises(
    format(
        $sql$
        insert into public.booking_access (
            tenant_id,
            booking_id,
            access_type,
            valid_from,
            valid_until
        )
        values (
            '%s'::uuid,
            '%s'::uuid,
            'owner',
            now(),
            now() + interval '1 hour'
        )
        $sql$,
        current_setting('005.test_tenant_id'),
        current_setting('005.test_booking_id')
    ),
    '39 booking_access rejects non-guest access',
    'guest-only'
);


-- =====================================================
-- 18. LOCK DEVICE CREATION
-- =====================================================

do $$
declare
    v_lock uuid;
begin

    insert into public.lock_devices (
        tenant_id,
        device_id,
        property_id,
        is_primary
    )
    values (
        current_setting('005.test_tenant_id')::uuid,
        current_setting('005.test_device_id')::uuid,
        current_setting('005.test_property_id')::uuid,
        true
    )
    returning id into v_lock;

    perform set_config(
        '005.test_lock_device_id',
        v_lock::text,
        true
    );

end;
$$;


select pg_temp.assert_true(
    exists (
        select 1
        from public.lock_devices
        where id = current_setting('005.test_lock_device_id')::uuid
          and device_id =
              current_setting('005.test_device_id')::uuid
          and property_id =
              current_setting('005.test_property_id')::uuid
    ),
    '40 valid lock device mapping is accepted'
);


-- =====================================================
-- 19. LOCK DEVICE PROPERTY INTEGRITY
-- =====================================================

do $$
declare
    v_other_property uuid;
begin

    insert into public.properties (
        tenant_id,
        name,
        property_type,
        timezone
    )
    values (
        current_setting('005.test_tenant_id')::uuid,
        'TEST 005 Other Property',
        (
            select enumlabel::public.property_type
            from pg_enum e
            join pg_type t
                on t.oid = e.enumtypid
            join pg_namespace n
                on n.oid = t.typnamespace
            where n.nspname = 'public'
              and t.typname = 'property_type'
            order by e.enumsortorder
            limit 1
        ),
        'Europe/Amsterdam'
    )
    returning id into v_other_property;

    perform pg_temp.assert_raises(
        format(
            $sql$
            insert into public.lock_devices (
                tenant_id,
                device_id,
                property_id,
                is_primary
            )
            values (
                '%s'::uuid,
                '%s'::uuid,
                '%s'::uuid,
                false
            )
            $sql$,
            current_setting('005.test_tenant_id'),
            current_setting('005.test_device_id'),
            v_other_property
        ),
        '41 lock device cannot belong to another property',
        'must match'
    );

end;
$$;


-- =====================================================
-- 20. CREDENTIAL CREATION
-- =====================================================

do $$
declare
    v_credential uuid;
begin

    insert into public.access_credentials (
        tenant_id,
        booking_id,
        lock_device_id,
        booking_access_id,
        provider_code,
        credential_ref,
        status
    )
    values (
        current_setting('005.test_tenant_id')::uuid,
        current_setting('005.test_booking_id')::uuid,
        current_setting('005.test_lock_device_id')::uuid,
        current_setting('005.test_booking_access_id')::uuid,
        'wrong-provider',
        'vault:test/005/credential',
        'pending'
    )
    returning id into v_credential;

    perform set_config(
        '005.test_credential_id',
        v_credential::text,
        true
    );

end;
$$;


-- =====================================================
-- 21. PROVIDER IS SNAPSHOTTED
-- =====================================================

select pg_temp.assert_true(
    exists (
        select 1
        from public.access_credentials
        where id = current_setting('005.test_credential_id')::uuid
          and provider_code = 'ttlock'
    ),
    '42 provider_code is resolved from device integration mapping'
);


-- =====================================================
-- 22. CREDENTIAL VALIDITY COMES FROM BOOKING ACCESS
-- =====================================================

select pg_temp.assert_true(
    exists (
        select 1
        from public.access_credentials ac
        join public.booking_access ba
            on ba.id = ac.booking_access_id
        where ac.id =
              current_setting('005.test_credential_id')::uuid
          and ac.valid_from = ba.valid_from
          and ac.valid_until = ba.valid_until
    ),
    '43 credential validity equals booking_access validity'
);


-- =====================================================
-- 23. PROVIDER SNAPSHOT IS IMMUTABLE
-- =====================================================

select pg_temp.assert_raises(
    format(
        $sql$
        update public.access_credentials
        set provider_code = 'aqara'
        where id = '%s'::uuid
        $sql$,
        current_setting('005.test_credential_id')
    ),
    '44 credential provider snapshot is immutable',
    'provider_code is immutable'
);


-- =====================================================
-- 24. BOOKING ACCESS LINK CANNOT BE NULL
-- =====================================================

select pg_temp.assert_raises(
    format(
        $sql$
        insert into public.access_credentials (
            tenant_id,
            booking_id,
            lock_device_id,
            booking_access_id,
            provider_code,
            credential_ref,
            status
        )
        values (
            '%s'::uuid,
            '%s'::uuid,
            '%s'::uuid,
            null,
            'ttlock',
            'vault:test/005/null',
            'pending'
        )
        $sql$,
        current_setting('005.test_tenant_id'),
        current_setting('005.test_booking_id'),
        current_setting('005.test_lock_device_id')
    ),
    '45 credential requires booking_access_id',
    'null'
);


-- =====================================================
-- 25. CREDENTIAL CANNOT HAVE DIFFERENT VALIDITY
-- =====================================================

do $$
declare
    v_id uuid;
begin

    insert into public.access_credentials (
        tenant_id,
        booking_id,
        lock_device_id,
        booking_access_id,
        provider_code,
        credential_ref,
        status,
        valid_from,
        valid_until
    )
    values (
        current_setting('005.test_tenant_id')::uuid,
        current_setting('005.test_booking_id')::uuid,
        current_setting('005.test_lock_device_id')::uuid,
        current_setting('005.test_booking_access_id')::uuid,
        'ttlock',
        'vault:test/005/validity',
        'pending',
        now() - interval '100 days',
        now() + interval '100 days'
    )
    returning id into v_id;

    perform pg_temp.assert_true(
        exists (
            select 1
            from public.access_credentials ac
            join public.booking_access ba
                on ba.id = ac.booking_access_id
            where ac.id = v_id
              and ac.valid_from = ba.valid_from
              and ac.valid_until = ba.valid_until
        ),
        '46 supplied credential validity is overwritten by booking_access'
    );

end;
$$;


-- =====================================================
-- 26. UNIQUE ACTIVE/REVOCATION LIFECYCLE
-- =====================================================

select pg_temp.assert_raises(
    format(
        $sql$
        insert into public.access_credentials (
            tenant_id,
            booking_id,
            lock_device_id,
            booking_access_id,
            provider_code,
            credential_ref,
            status
        )
        values (
            '%s'::uuid,
            '%s'::uuid,
            '%s'::uuid,
            '%s'::uuid,
            'ttlock',
            'vault:test/005/duplicate',
            'pending'
        )
        $sql$,
        current_setting('005.test_tenant_id'),
        current_setting('005.test_booking_id'),
        current_setting('005.test_lock_device_id'),
        current_setting('005.test_booking_access_id')
    ),
    '47 duplicate pending credential is rejected',
    'uq_access_credentials_active_booking_lock'
);


-- =====================================================
-- 27. REVOCATION STATUS
-- =====================================================

update public.access_credentials
set status = 'revoking'
where id =
      current_setting('005.test_credential_id')::uuid;

select pg_temp.assert_true(
    exists (
        select 1
        from public.access_credentials
        where id =
              current_setting('005.test_credential_id')::uuid
          and status = 'revoking'
    ),
    '48 credential supports revoking lifecycle state'
);


-- =====================================================
-- 28. SECOND CREDENTIAL IS STILL BLOCKED WHILE REVOKING
-- =====================================================

select pg_temp.assert_raises(
    format(
        $sql$
        insert into public.access_credentials (
            tenant_id,
            booking_id,
            lock_device_id,
            booking_access_id,
            provider_code,
            credential_ref,
            status
        )
        values (
            '%s'::uuid,
            '%s'::uuid,
            '%s'::uuid,
            '%s'::uuid,
            'ttlock',
            'vault:test/005/revoking-block',
            'pending'
        )
        $sql$,
        current_setting('005.test_tenant_id'),
        current_setting('005.test_booking_id'),
        current_setting('005.test_lock_device_id'),
        current_setting('005.test_booking_access_id')
    ),
    '49 revoking credential blocks replacement credential',
    'uq_access_credentials_active_booking_lock'
);


-- =====================================================
-- 29. REVOKED REQUIRES revoked_at
-- =====================================================

select pg_temp.assert_raises(
    format(
        $sql$
        update public.access_credentials
        set status = 'revoked',
            revoked_at = null
        where id =
              '%s'::uuid
        $sql$,
        current_setting('005.test_credential_id')
    ),
    '50 revoked credential requires revoked_at',
    'revoked_at'
);


-- =====================================================
-- 30. REVOKED WITH revoked_at IS VALID
-- =====================================================

update public.access_credentials
set
    status = 'revoked',
    revoked_at = now()
where id =
      current_setting('005.test_credential_id')::uuid;

select pg_temp.assert_true(
    exists (
        select 1
        from public.access_credentials
        where id =
              current_setting('005.test_credential_id')::uuid
          and status = 'revoked'
          and revoked_at is not null
    ),
    '51 revoked credential with revoked_at is accepted'
);


-- =====================================================
-- 31. BOOKING ACCESS DELETE PROTECTION
-- =====================================================

select pg_temp.assert_raises(
    format(
        $sql$
        delete from public.booking_access
        where id =
              '%s'::uuid
        $sql$,
        current_setting('005.test_booking_access_id')
    ),
    '52 booking_access cannot be deleted while credential references it',
    'access_credentials'
);


-- =====================================================
-- 32. PROVIDER MAPPING IS REQUIRED FOR LOCK DEVICE
-- =====================================================

do $$
declare
    v_device uuid;
    v_mapping uuid;
begin

    insert into public.devices (
        tenant_id,
        device_name,
        category_code,
        protocol,
        model,
        manufacturer,
        is_active
    )
    values (
        current_setting('005.test_tenant_id')::uuid,
        'TEST 005 Unmapped Lock',
        current_setting('005.test_lock_category'),
        (
            select enumlabel::public.device_protocol
            from pg_enum e
            join pg_type t
                on t.oid = e.enumtypid
            join pg_namespace n
                on n.oid = t.typnamespace
            where n.nspname = 'public'
              and t.typname = 'device_protocol'
            order by e.enumsortorder
            limit 1
        ),
        'TEST',
        'TEST',
        true
    )
    returning id into v_device;

    perform pg_temp.assert_raises(
        format(
            $sql$
            insert into public.lock_devices (
                tenant_id,
                device_id,
                property_id,
                is_primary
            )
            values (
                '%s'::uuid,
                '%s'::uuid,
                '%s'::uuid,
                false
            )
            $sql$,
            current_setting('005.test_tenant_id'),
            v_device,
            current_setting('005.test_property_id')
        ),
        '53 lock device requires integration mapping',
        'provider mapping'
    );

end;
$$;


-- =====================================================
-- 33. BOOKING ACCESS WINDOW OVERRIDE
-- =====================================================

insert into public.access_rules (
    tenant_id,
    property_id,
    rule_type,
    rule_config,
    is_active
)
values (
    current_setting('005.test_tenant_id')::uuid,
    current_setting('005.test_property_id')::uuid,
    'override',
    jsonb_build_object(
        'valid_from',
        (
            (
                current_date + 10
            )::timestamp
            + '14:00'::time
        ) at time zone 'Europe/Amsterdam',
        'valid_until',
        (
            (
                current_date + 13
            )::timestamp
            + '12:00'::time
        ) at time zone 'Europe/Amsterdam'
    ),
    true
);


do $$
declare
    v_window record;
begin

    select *
    into v_window
    from public.booking_compute_access_window(
        current_setting('005.test_booking_id')::uuid
    );

    perform pg_temp.assert_true(
        v_window.valid_from <
        (
            (
                current_date + 10
            )::timestamp
            + '15:00'::time
        ) at time zone 'Europe/Amsterdam',
        '54 access rule override can extend valid_from'
    );

    perform pg_temp.assert_true(
        v_window.valid_until >
        (
            (
                current_date + 13
            )::timestamp
            + '11:00'::time
        ) at time zone 'Europe/Amsterdam',
        '55 access rule override can extend valid_until'
    );

end;
$$;


-- =====================================================
-- 34. OVERVIEW VIEW
-- =====================================================

select pg_temp.assert_true(
    exists (
        select 1
        from public.v_bookings_overview
        where id =
              current_setting('005.test_booking_id')::uuid
    ),
    '56 booking appears in v_bookings_overview'
);


-- =====================================================
-- 35. QUEUE API CONTRACT
-- =====================================================

select pg_temp.assert_true(
    pg_get_functiondef(
        to_regprocedure(
            'platform.queue_device_command(uuid,text,jsonb,text,uuid)'
        )
    ) ilike '%device_commands%'
    or
    pg_get_functiondef(
        to_regprocedure(
            'platform.queue_device_command(uuid,text,jsonb,text,uuid)'
        )
    ) ilike '%queue%',
    '57 queue_device_command is implemented as platform execution API'
);


-- =====================================================
-- 36. 005 MUST NOT OWN EXECUTION TABLE
-- =====================================================
--
-- This is an architectural test.
-- The locks_domain function must call the queue API,
-- not directly insert into platform.device_commands.
--

select pg_temp.assert_true(
    pg_get_functiondef(
        to_regprocedure(
            'public.locks_domain(text,jsonb)'
        )
    ) not ilike '%insert into platform.device_commands%',
    '58 locks_domain does not directly insert device_commands'
);


-- =====================================================
-- 37. CREDENTIAL PROVIDER MUST NOT BE WRITABLE VIA
--     LOCK DOMAIN PAYLOAD
-- =====================================================
--
-- The domain function only accepts credential_ref,
-- booking and lock identifiers.
--

select pg_temp.assert_true(
    pg_get_functiondef(
        to_regprocedure(
            'public.locks_domain(text,jsonb)'
        )
    ) not ilike '%p_payload->>%''provider_code''%',
    '59 locks_domain cannot supply provider_code directly'
);


-- =====================================================
-- 38. CREDENTIAL VALIDITY MUST NOT BE ACCEPTED FROM
--     LOCK DOMAIN PAYLOAD
-- =====================================================

select pg_temp.assert_true(
    pg_get_functiondef(
        to_regprocedure(
            'public.locks_domain(text,jsonb)'
        )
    ) not ilike '%p_payload->>%''valid_from''%',
    '60 locks_domain cannot supply valid_from directly'
);


select pg_temp.assert_true(
    pg_get_functiondef(
        to_regprocedure(
            'public.locks_domain(text,jsonb)'
        )
    ) not ilike '%p_payload->>%''valid_until''%',
    '61 locks_domain cannot supply valid_until directly'
);


-- =====================================================
-- 39. ACCESS CREDENTIALS MUST USE VAULT REFERENCE
-- =====================================================

select pg_temp.assert_true(
    exists (
        select 1
        from pg_description d
        join pg_attribute a
            on a.attrelid = d.objoid
           and a.attnum = d.objsubid
        join pg_class c
            on c.oid = a.attrelid
        where c.relname = 'access_credentials'
          and a.attname = 'credential_ref'
          and d.description ilike '%Plaintext%'
    ),
    '62 credential_ref documentation prohibits plaintext'
);


-- =====================================================
-- 40. ACCESS RULE DOCUMENTATION
-- =====================================================

select pg_temp.assert_true(
    exists (
        select 1
        from pg_description d
        join pg_class c
            on c.oid = d.objoid
        where c.relname = 'access_rules'
          and d.description ilike '%exception%'
    ),
    '63 access_rules documentation describes exception layer'
);


-- =====================================================
-- 41. TENANT CONSISTENCY ON PROPERTY-SCOPED TABLES
-- =====================================================

do $$
declare
    v_other_tenant uuid;
begin

    select id
    into v_other_tenant
    from public.tenants
    where id <>
          current_setting('005.test_tenant_id')::uuid
    limit 1;

    if v_other_tenant is not null then

        perform pg_temp.assert_raises(
            format(
                $sql$
                insert into public.access_rules (
                    tenant_id,
                    property_id,
                    rule_type,
                    rule_config
                )
                values (
                    '%s'::uuid,
                    '%s'::uuid,
                    'override',
                    '{}'::jsonb
                )
                $sql$,
                v_other_tenant,
                current_setting('005.test_property_id')
            ),
            '64 property scoped table rejects cross tenant write',
            'tenant_id must match property'
        );

    end if;

end;
$$;


-- =====================================================
-- 42. FINAL TEST REPORT
-- =====================================================

select
    test_no,
    test_name,
    result,
    details
from _005_test_results
order by test_no;


-- =====================================================
-- 43. TEST SUMMARY
-- =====================================================

do $$
declare
    v_total int;
    v_failed int;
begin

    select count(*)
    into v_total
    from _005_test_results;

    select count(*)
    into v_failed
    from _005_test_results
    where result = 'FAIL';

    raise notice
        '005 Booking & Lock tests: % total, % failed',
        v_total,
        v_failed;

    if v_failed > 0 then
        raise exception
            '005 Booking & Lock test suite FAILED';
    end if;

end;
$$;


-- =====================================================
-- IMPORTANT
-- =====================================================
--
-- The test transaction is deliberately rolled back.
--
-- No test fixtures remain in the database.
--
-- =====================================================

rollback;
