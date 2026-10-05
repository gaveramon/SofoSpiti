-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 005_BOOKING_LOCK_ENGINE.SQL
-- =====================================================

---------------------------------------------------------
-- CLEAN DOMAIN RULE LAYER
-- NO EXECUTION / NO QUEUES / NO NOTIFICATIONS / NO CODE GENERATION
-- =====================================================

-- ACCESS MODEL (SSOT HIERARCHY)
-- 1. property_access_schedules — property default check-in/out times (guest template)
-- 2. booking_access           — resolved guest window per booking (stored outcome)
-- 3. access_policies          — non-guest grants only (owner, emergency, temporary, scheduled)
-- 4. access_rules             — property exceptions only (override, emergency_access)
-----------------------------------------------------------------------------------------

-- Composition: booking dates + property_access_schedules → booking_access.valid_from/until
-- 5. access_credentials       — issued grant metadata (vault ref, never plaintext codes)
-- Door code generation remains in 000; 005 stores grant records and windows only.
-- =====================================================


-- =====================================================
-- 1 BOOKINGS (CORE RESERVATION MODEL)
-- =====================================================

create table if not exists public.bookings (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    property_id uuid not null references properties(id) on delete cascade,

    guest_name text,

    guest_email text,

    start_date date not null,

    end_date date not null,

    status booking_status default 'pending',

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    constraint chk_bookings_date_range check (start_date <= end_date)
);


-- =====================================================
-- 2 PROPERTY ACCESS SCHEDULE (GUEST WINDOW TEMPLATE — SSOT)
-- One row per property: default check-in/out times for guest stays.
-- =====================================================

create table if not exists public.property_access_schedules (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    property_id uuid not null references properties(id) on delete cascade,

    check_in_time time not null default '15:00',

    check_out_time time not null default '11:00',

    early_check_in_minutes int not null default 0,

    late_checkout_minutes int not null default 0,

    is_active boolean default true,

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    unique (property_id),

    constraint chk_property_access_schedule_buffers check (
        early_check_in_minutes >= 0
        and late_checkout_minutes >= 0
    )
);


-- =====================================================
-- 3 BOOKING ACCESS (RESOLVED GUEST WINDOW PER BOOKING)
-- Populated when a booking is confirmed — not generated here.
-- =====================================================

create table if not exists public.booking_access (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    booking_id uuid not null references bookings(id) on delete cascade,

    access_type access_type not null default 'guest',

    valid_from timestamptz not null,

    valid_until timestamptz not null,

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    unique (booking_id),

    constraint chk_booking_access_guest_only check (access_type = 'guest'),

    constraint chk_booking_access_window check (valid_from < valid_until)
);


-- =====================================================
-- 4 ACCESS POLICIES (NON-GUEST GRANTS ONLY)
-- Owner, emergency, temporary, and scheduled access outside bookings.
-- =====================================================

create table if not exists public.access_policies (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    property_id uuid not null references properties(id) on delete cascade,

    access_type access_type not null,

    valid_from timestamptz not null,

    valid_until timestamptz not null,

    is_active boolean default true,

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    constraint chk_access_policies_non_guest check (access_type <> 'guest'),

    constraint chk_access_policies_window check (valid_from < valid_until)
);


-- =====================================================
-- 5 ACCESS RULES (PROPERTY EXCEPTIONS ONLY)
-- Overrides and emergency rules — not the default guest schedule.
-- =====================================================

create table if not exists public.access_rules (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    property_id uuid not null references properties(id) on delete cascade,

    rule_type access_rule_type not null,

    rule_config jsonb,

    is_active boolean default true,

    created_at timestamptz default now(),

    constraint chk_access_rules_exceptions_only check (
        rule_type in ('override', 'emergency_access')
    )
);


-- =====================================================
-- 6 LOCK DEVICE MAPPING (NO EXECUTION)
-- =====================================================

create table if not exists public.lock_devices (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    device_id uuid not null references devices(id) on delete cascade,

    property_id uuid not null references properties(id) on delete cascade,

    is_primary boolean default false,

    created_at timestamptz default now(),

    unique (device_id)
);


-- =====================================================
-- 7 ACCESS CREDENTIALS (ISSUED GRANT METADATA — NO GENERATION)
-- Records what was issued to which lock for a booking.
-- PIN stored in vault (000).
--
-- Guest credential validity is always derived from booking_access.
-- =====================================================

create table if not exists public.access_credentials (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    booking_id uuid not null references bookings(id) on delete cascade,

    lock_device_id uuid not null references lock_devices(id) on delete restrict,

    booking_access_id uuid not null references booking_access(id) on delete restrict,

    provider_code text not null,

    credential_ref text not null,

    external_credential_id text,

    status access_credential_status not null default 'pending',

    valid_from timestamptz not null,

    valid_until timestamptz not null,

    revoked_at timestamptz,

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    constraint chk_access_credentials_window check (
        valid_from < valid_until
    ),

    constraint chk_access_credentials_revoked check (
        status <> 'revoked' or revoked_at is not null
    )
);


-- =====================================================
-- 8 INDEXES
-- =====================================================

create index if not exists idx_bookings_property
on bookings (property_id);

create index if not exists idx_bookings_tenant
on bookings (tenant_id);

create index if not exists idx_bookings_tenant_created
on bookings (tenant_id, created_at desc);

create index if not exists idx_bookings_property_dates
on bookings (property_id, start_date, end_date);

create index if not exists idx_property_access_schedules_tenant
on property_access_schedules (tenant_id);

create index if not exists idx_property_access_schedules_tenant_created
on property_access_schedules (tenant_id, created_at desc);

create index if not exists idx_booking_access_booking
on booking_access (booking_id);

create index if not exists idx_booking_access_tenant_created
on booking_access (tenant_id, created_at desc);

create index if not exists idx_booking_access_window
on booking_access (valid_from, valid_until);

create index if not exists idx_access_policies_property
on access_policies (property_id);

create index if not exists idx_access_policies_property_active
on access_policies (property_id, is_active)
where is_active = true;

create index if not exists idx_access_policies_tenant_created
on access_policies (tenant_id, created_at desc);

create index if not exists idx_access_rules_property
on access_rules (property_id);

create index if not exists idx_access_rules_property_type
on access_rules (property_id, rule_type);

create index if not exists idx_access_rules_tenant_created
on access_rules (tenant_id, created_at desc);

create index if not exists idx_lock_devices_property
on lock_devices (property_id);

create index if not exists idx_lock_devices_tenant_created
on lock_devices (tenant_id, created_at desc);

create unique index if not exists uq_lock_devices_primary_property
on lock_devices (property_id)
where is_primary = true;

create index if not exists idx_lock_devices_property_created
on lock_devices (property_id, created_at desc);

create index if not exists idx_access_credentials_tenant
on access_credentials (tenant_id);

create index if not exists idx_access_credentials_tenant_created
on access_credentials (tenant_id, created_at desc);

create index if not exists idx_access_credentials_booking
on access_credentials (booking_id);

create index if not exists idx_access_credentials_lock
on access_credentials (lock_device_id);

create index if not exists idx_access_credentials_status
on access_credentials (tenant_id, status);

create unique index if not exists uq_access_credentials_active_booking_lock
on access_credentials (booking_id, lock_device_id)
where status in ('pending', 'active','revoking');


-- =====================================================
-- 9 TABLE & COLUMN COMMENTS
-- =====================================================

comment on table public.property_access_schedules is
'SSOT for guest stay window templates. Compose with booking dates to populate booking_access.';

comment on table public.booking_access is
'Resolved guest access window for a booking. valid_from/until = booking dates + property_access_schedules.';

comment on table public.access_policies is
'Non-guest access grants (owner, emergency, temporary, scheduled). Guest stays use booking_access.';

comment on table public.access_rules is
'Property-level access exceptions. Default guest windows live in property_access_schedules.';

comment on column public.access_rules.rule_config is
'Exception payload. Supports override validity and optional extension settings used by booking access calculation.';

comment on table public.access_credentials is
'Issued door-code grant metadata per booking and lock. Never store plaintext PINs — use credential_ref (vault). Credential validity is derived from booking_access.';

comment on column public.access_credentials.credential_ref is
'Opaque vault secret name or platform handle. Plaintext codes must not be stored here.';

comment on column public.access_credentials.provider_code is
'Derived from device_integration_map via lock device. Must match integration_providers catalog.';

comment on column public.access_credentials.external_credential_id is
'Provider-side credential ID (e.g. TTLock keyboardPwdId) for revoke/sync in 000.';


-- =====================================================
-- 10 TENANT FOREIGN KEYS
-- Deferred — tenants exist from 002.
-- =====================================================

do $$
begin
    alter table public.bookings
    add constraint fk_bookings_tenant
    foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;

do $$
begin
    alter table public.property_access_schedules
    add constraint fk_property_access_schedules_tenant
    foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;

do $$
begin
    alter table public.access_policies
    add constraint fk_access_policies_tenant
    foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;

do $$
begin
    alter table public.access_rules
    add constraint fk_access_rules_tenant
    foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;

do $$
begin
    alter table public.access_credentials
    add constraint fk_access_credentials_tenant
    foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;

do $$
begin
    alter table public.booking_access
    add constraint fk_booking_access_tenant
    foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;

do $$
begin
    alter table public.lock_devices
    add constraint fk_lock_devices_tenant
    foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


-- =====================================================
-- 11 CORE TENANT / PROPERTY / DEVICE CONSISTENCY FUNCTIONS
-- =====================================================

-- =====================================================
-- 11A. BOOKING TENANT CONSISTENCY (PROPERTY ↔ TENANT)
-- =====================================================

create or replace function public.enforce_booking_tenant_consistency()
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

    if new.tenant_id <> v_property_tenant then
        raise exception 'booking tenant_id must match property tenant_id';
    end if;

    return new;
end;
$$;


-- =====================================================
-- 11B. PROPERTY TENANT CONSISTENCY (PROPERTY-SCOPED TABLES)
-- =====================================================

create or replace function public.enforce_property_tenant_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_property_tenant uuid;
begin
    if new.property_id is null then
        return new;
    end if;

    select p.tenant_id
    into v_property_tenant
    from public.properties p
    where p.id = new.property_id;

    if not found then
        raise exception 'property not found';
    end if;

    if new.tenant_id is distinct from v_property_tenant then
        raise exception 'tenant_id must match property tenant_id';
    end if;

    return new;
end;
$$;


-- =====================================================
-- 11C. BOOKING ACCESS CONSISTENCY (GUEST-ONLY)
-- =====================================================

create or replace function public.enforce_booking_access_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_booking record;
begin
    select b.property_id, b.tenant_id, b.status
    into v_booking
    from public.bookings b
    where b.id = new.booking_id;

    if not found then
        raise exception 'booking not found';
    end if;

    if new.access_type <> 'guest' then
        raise exception 'booking_access is guest-only; use access_policies for other access types';
    end if;

    new.tenant_id := v_booking.tenant_id;

    return new;
end;
$$;


-- =====================================================
-- 11D. LOCK DEVICE INTEGRITY (CATEGORY + TENANT + PROPERTY)
-- =====================================================

create or replace function public.enforce_lock_device_integrity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_device record;
    v_property_tenant uuid;
    v_device_property_id uuid;
begin
    -- -------------------------------------------------
    -- 1. DEVICE MUST EXIST AND BE A LOCK CATEGORY
    -- -------------------------------------------------

    select
        d.tenant_id,
        dc.is_lock
    into v_device
    from public.devices d
    join public.device_categories dc
        on dc.code = d.category_code
    where d.id = new.device_id;

    if not found then
        raise exception 'device not found';
    end if;

    if not v_device.is_lock then
        raise exception
            'lock_devices requires device category with is_lock';
    end if;


    -- -------------------------------------------------
    -- 2. PROPERTY MUST EXIST
    -- -------------------------------------------------

    select p.tenant_id
    into v_property_tenant
    from public.properties p
    where p.id = new.property_id;

    if not found then
        raise exception 'property not found';
    end if;


    -- -------------------------------------------------
    -- 3. DEVICE AND PROPERTY MUST BELONG TO SAME TENANT
    -- -------------------------------------------------

    if v_device.tenant_id <> v_property_tenant then
        raise exception
            'lock device and property must belong to the same tenant';
    end if;


    -- -------------------------------------------------
    -- 4. DEVICE MUST BE ASSIGNED TO A ROOM
    --    WITHIN THE SAME PROPERTY
    -- -------------------------------------------------

    select r.property_id
    into v_device_property_id
    from public.device_assignments da
    join public.rooms r
        on r.id = da.room_id
    where da.device_id = new.device_id;

    if not found then
        raise exception
            'lock device must be assigned to a room within a property';
    end if;

    if v_device_property_id <> new.property_id then
        raise exception
            'lock device must belong to the lock property through its room assignment';
    end if;


    -- -------------------------------------------------
    -- 5. DEVICE MUST HAVE A PROVIDER MAPPING
    -- -------------------------------------------------

    if not exists (
        select 1
        from public.device_integration_map dim
        where dim.device_id = new.device_id
    ) then
        raise exception
            'lock device must have a provider mapping in device_integration_map';
    end if;


    -- -------------------------------------------------
    -- 6. TENANT IS DERIVED FROM THE PROPERTY
    -- -------------------------------------------------

    new.tenant_id := v_property_tenant;

    return new;
end;
$$;


-- =====================================================
-- 11E. ACCESS CREDENTIAL CONSISTENCY (BOOKING ↔ ACCESS ↔ LOCK)
-- =====================================================

create or replace function public.enforce_access_credential_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_booking record;
    v_lock record;
    v_access record;
    v_map_provider text;
begin
    select
        b.tenant_id,
        b.property_id
    into v_booking
    from public.bookings b
    where b.id = new.booking_id;

    if not found then
        raise exception 'booking not found';
    end if;

    if new.tenant_id <> v_booking.tenant_id then
        raise exception 'credential tenant_id must match booking tenant_id';
    end if;

    select
        ld.property_id,
        ld.device_id
    into v_lock
    from public.lock_devices ld
    where ld.id = new.lock_device_id;

    if not found then
        raise exception 'lock device not found';
    end if;

    if v_lock.property_id <> v_booking.property_id then
        raise exception 'lock device must belong to the booking property';
    end if;

    if new.booking_access_id is null then
        raise exception 'access credential requires booking_access_id';
    end if;

    select
        ba.booking_id,
        ba.tenant_id,
        ba.valid_from,
        ba.valid_until
    into v_access
    from public.booking_access ba
    where ba.id = new.booking_access_id;

    if not found then
        raise exception 'booking_access not found';
    end if;

    if v_access.booking_id <> new.booking_id then
        raise exception 'booking_access must belong to the same booking';
    end if;

    if v_access.tenant_id <> v_booking.tenant_id then
        raise exception 'booking_access tenant must match booking tenant';
    end if;

    -- Credential validity is always derived from booking_access.
    new.valid_from := v_access.valid_from;
    new.valid_until := v_access.valid_until;

    -- Provider is resolved only when the credential is created.
    -- provider_code is an immutable snapshot of the provider used
    -- for this credential and must not change when the device mapping changes.

    if tg_op = 'INSERT' then

        select dim.provider_code
        into v_map_provider
        from public.device_integration_map dim
        where dim.device_id = v_lock.device_id
        order by dim.created_at
        limit 1;

        if v_map_provider is null then
            raise exception
                'lock device must have provider mapping in device_integration_map';
        end if;

        new.provider_code := v_map_provider;

    else

        if new.provider_code is distinct from old.provider_code then
            raise exception
                'credential provider_code is immutable';
        end if;

    end if;

    if new.status = 'revoked' and new.revoked_at is null then
        new.revoked_at := now();
    end if;

    return new;
end;
$$;


-- =====================================================
-- 12 BOOKING ACCESS CALCULATION
-- =====================================================

-- =====================================================
-- 12A. CORE CALCULATION (005 SSOT)
-- =====================================================

create or replace function public.booking_compute_access_window(
    p_booking_id uuid
)
returns table (
    valid_from timestamptz,
    valid_until timestamptz,
    property_id uuid,
    timezone text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_booking record;
    v_schedule record;
    v_tz text;
    v_from timestamptz;
    v_until timestamptz;
    v_rule record;
    v_extend_early int := 0;
    v_extend_late int := 0;
begin
    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    select
        bk.id,
        bk.tenant_id,
        bk.property_id,
        bk.start_date,
        bk.end_date,
        bk.status
    into v_booking
    from public.bookings bk
    where bk.id = p_booking_id
      and bk.tenant_id = v_tid;

    if not found then
        raise exception 'Booking not found';
    end if;

    select coalesce(p.timezone, 'UTC')
    into v_tz
    from public.properties p
    where p.id = v_booking.property_id
      and p.tenant_id = v_tid;

    select
        coalesce(pas.check_in_time, '15:00'::time) as check_in_time,
        coalesce(pas.check_out_time, '11:00'::time) as check_out_time,
        coalesce(pas.early_check_in_minutes, 0) as early_check_in_minutes,
        coalesce(pas.late_checkout_minutes, 0) as late_checkout_minutes,
        coalesce(pas.is_active, true) as is_active
    into v_schedule
    from public.property_access_schedules pas
    where pas.property_id = v_booking.property_id
      and pas.tenant_id = v_tid;

    if v_schedule is null or v_schedule.is_active = true then
        v_from :=
            (
                v_booking.start_date::timestamp
                + coalesce(v_schedule.check_in_time, '15:00'::time)
            )
            at time zone coalesce(v_tz, 'UTC')
            - make_interval(
                mins => coalesce(v_schedule.early_check_in_minutes, 0)
            );

        v_until :=
            (
                v_booking.end_date::timestamp
                + coalesce(v_schedule.check_out_time, '11:00'::time)
            )
            at time zone coalesce(v_tz, 'UTC')
            + make_interval(
                mins => coalesce(v_schedule.late_checkout_minutes, 0)
            );
    else
        v_from :=
            (
                v_booking.start_date::timestamp
                + '15:00'::time
            )
            at time zone coalesce(v_tz, 'UTC');

        v_until :=
            (
                v_booking.end_date::timestamp
                + '11:00'::time
            )
            at time zone coalesce(v_tz, 'UTC');
    end if;

    for v_rule in
        select
            ar.rule_type,
            ar.rule_config
        from public.access_rules ar
        where ar.property_id = v_booking.property_id
          and ar.tenant_id = v_tid
          and ar.is_active = true
    loop
        if v_rule.rule_config ? 'extend_early_minutes' then
            v_extend_early :=
                v_extend_early
                + coalesce(
                    (v_rule.rule_config->>'extend_early_minutes')::int,
                    0
                );
        end if;

        if v_rule.rule_config ? 'extend_late_minutes' then
            v_extend_late :=
                v_extend_late
                + coalesce(
                    (v_rule.rule_config->>'extend_late_minutes')::int,
                    0
                );
        end if;

        if v_rule.rule_type = 'override'::public.access_rule_type
           and v_rule.rule_config ? 'valid_from'
           and v_rule.rule_config ? 'valid_until'
        then
            v_from :=
                least(
                    v_from,
                    (v_rule.rule_config->>'valid_from')::timestamptz
                );

            v_until :=
                greatest(
                    v_until,
                    (v_rule.rule_config->>'valid_until')::timestamptz
                );
        end if;
    end loop;

    v_from :=
        v_from - make_interval(mins => v_extend_early);

    v_until :=
        v_until + make_interval(mins => v_extend_late);

    for v_rule in
        select
            ap.valid_from as pf,
            ap.valid_until as pu
        from public.access_policies ap
        where ap.property_id = v_booking.property_id
          and ap.tenant_id = v_tid
          and ap.is_active = true
          and ap.access_type = 'scheduled'::public.access_type
          and tstzrange(ap.valid_from, ap.valid_until)
              && tstzrange(v_from, v_until)
    loop
        v_from := least(v_from, v_rule.pf);
        v_until := greatest(v_until, v_rule.pu);
    end loop;

    if v_from >= v_until then
        raise exception
            'Computed access window is invalid for booking %',
            p_booking_id;
    end if;

    return query
    select
        v_from,
        v_until,
        v_booking.property_id,
        coalesce(v_tz, 'UTC');
end;
$$;


-- =====================================================
-- 12B. ACCESS WINDOW CALCULATION RPC HELPER
-- =====================================================

create or replace function public.booking_calculate_access_window(
    p_booking_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_tenant();

    return (
        select jsonb_build_object(
            'booking_id', p_booking_id,
            'valid_from', w.valid_from,
            'valid_until', w.valid_until,
            'property_id', w.property_id,
            'timezone', w.timezone
        )
        from public.booking_compute_access_window(p_booking_id) w
    );
end;
$$;


-- =====================================================
-- 12C. BOOKING ACCESS GENERATION
-- =====================================================

create or replace function public.booking_generate_booking_access(
    p_booking_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_window record;
    v_row record;
begin
    perform public.edge_require_manager();

    v_tid := platform.current_tenant_id();

    select *
    into v_window
    from public.booking_compute_access_window(p_booking_id);

    insert into public.booking_access (
        tenant_id,
        booking_id,
        access_type,
        valid_from,
        valid_until
    )
    values (
        v_tid,
        p_booking_id,
        'guest'::public.access_type,
        v_window.valid_from,
        v_window.valid_until
    )
    on conflict (booking_id) do nothing
    returning
        id,
        tenant_id,
        booking_id,
        access_type,
        valid_from,
        valid_until,
        created_at,
        updated_at
    into v_row;

    if not found then
        select
            ba.id,
            ba.tenant_id,
            ba.booking_id,
            ba.access_type,
            ba.valid_from,
            ba.valid_until,
            ba.created_at,
            ba.updated_at
        into v_row
        from public.booking_access ba
        where ba.booking_id = p_booking_id
          and ba.tenant_id = v_tid;
    else
        perform platform.log_audit(
            'booking_access.generated',
            'booking_access',
            v_row.id
        );
    end if;

    return to_jsonb(v_row);
end;
$$;


-- =====================================================
-- 12D. BOOKING ACCESS REGENERATION
-- =====================================================

create or replace function public.booking_regenerate_booking_access(
    p_booking_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_window record;
    v_row record;
begin
    perform public.edge_require_manager();

    v_tid := platform.current_tenant_id();

    select *
    into v_window
    from public.booking_compute_access_window(p_booking_id);

    update public.booking_access ba
    set
        valid_from = v_window.valid_from,
        valid_until = v_window.valid_until,
        updated_at = now()
    where ba.booking_id = p_booking_id
      and ba.tenant_id = v_tid
    returning
        ba.id,
        ba.tenant_id,
        ba.booking_id,
        ba.access_type,
        ba.valid_from,
        ba.valid_until,
        ba.created_at,
        ba.updated_at
    into v_row;

    if not found then
        insert into public.booking_access (
            tenant_id,
            booking_id,
            access_type,
            valid_from,
            valid_until
        )
        values (
            v_tid,
            p_booking_id,
            'guest'::public.access_type,
            v_window.valid_from,
            v_window.valid_until
        )
        returning
            id,
            tenant_id,
            booking_id,
            access_type,
            valid_from,
            valid_until,
            created_at,
            updated_at
        into v_row;
    end if;

    perform platform.log_audit(
        'booking_access.regenerated',
        'booking_access',
        v_row.id,
        jsonb_build_object('booking_id', p_booking_id)
    );

    return to_jsonb(v_row);
end;
$$;


-- =====================================================
-- 12E. MANUAL BOOKING ACCESS CREATION
-- =====================================================

create or replace function public.booking_create_booking_access(
    p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_manager();

    p_payload := coalesce(p_payload, '{}'::jsonb);

    if not (p_payload ? 'booking_id')
       or nullif(p_payload->>'booking_id', '') is null
    then
        raise exception 'booking_id is required';
    end if;

    if p_payload ? 'valid_from'
       or p_payload ? 'valid_until'
    then
        raise exception
            'booking_access validity is calculated from booking, property schedule and access rules; use access_rules for overrides';
    end if;

    return public.booking_generate_booking_access(
        (p_payload->>'booking_id')::uuid
    );
end;
$$;

-- =====================================================
-- 13 BOOKING DOMAIN RPC
-- =====================================================

create or replace function public.booking_domain(
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
    v_row record;
    v_result jsonb;
    v_existing uuid;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when 'list_bookings' then
            v_tid := platform.current_tenant_id();

            select coalesce(
                jsonb_agg(to_jsonb(b) order by b.start_date desc),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    bk.id,
                    bk.tenant_id,
                    bk.property_id,
                    bk.guest_name,
                    bk.guest_email,
                    bk.start_date,
                    bk.end_date,
                    bk.status,
                    bk.created_at,
                    bk.updated_at
                from public.bookings bk
                where bk.tenant_id = v_tid
                  and (
                      p_payload->>'property_id' is null
                      or bk.property_id = (p_payload->>'property_id')::uuid
                  )
            ) b;

            return v_result;


        when 'get_booking' then
            v_tid := platform.current_tenant_id();

            select
                bk.id,
                bk.tenant_id,
                bk.property_id,
                bk.guest_name,
                bk.guest_email,
                bk.start_date,
                bk.end_date,
                bk.status,
                bk.created_at,
                bk.updated_at
            into v_row
            from public.bookings bk
            where bk.id = (p_payload->>'id')::uuid
              and bk.tenant_id = v_tid;

            if not found then
                raise exception 'Booking not found';
            end if;

            return to_jsonb(v_row);


        when 'create_booking' then
            v_tid := platform.current_tenant_id();

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
                (p_payload->>'property_id')::uuid,
                p_payload->>'guest_name',
                p_payload->>'guest_email',
                (p_payload->>'start_date')::date,
                (p_payload->>'end_date')::date,
                coalesce(
                    (p_payload->>'status')::public.booking_status,
                    'pending'::public.booking_status
                )
            )
            returning
                id,
                tenant_id,
                property_id,
                guest_name,
                guest_email,
                start_date,
                end_date,
                status,
                created_at,
                updated_at
            into v_row;

            perform platform.log_audit(
                'booking.created',
                'booking',
                v_row.id,
                jsonb_build_object('property_id', v_row.property_id)
            );

            return to_jsonb(v_row);


        when 'update_booking' then
            v_tid := platform.current_tenant_id();

            update public.bookings bk
            set
                guest_name = case
                    when p_payload ? 'guest_name'
                        then p_payload->>'guest_name'
                    else bk.guest_name
                end,
                guest_email = case
                    when p_payload ? 'guest_email'
                        then p_payload->>'guest_email'
                    else bk.guest_email
                end,
                start_date = case
                    when p_payload ? 'start_date'
                        then (p_payload->>'start_date')::date
                    else bk.start_date
                end,
                end_date = case
                    when p_payload ? 'end_date'
                        then (p_payload->>'end_date')::date
                    else bk.end_date
                end,
                status = case
                    when p_payload ? 'status'
                        then (p_payload->>'status')::public.booking_status
                    else bk.status
                end
            where bk.id = (p_payload->>'id')::uuid
              and bk.tenant_id = v_tid
            returning
                bk.id,
                bk.tenant_id,
                bk.property_id,
                bk.guest_name,
                bk.guest_email,
                bk.start_date,
                bk.end_date,
                bk.status,
                bk.created_at,
                bk.updated_at
            into v_row;

            if not found then
                raise exception 'Booking not found';
            end if;

            perform platform.log_audit(
                'booking.updated',
                'booking',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);


        when 'delete_booking' then
            v_tid := platform.current_tenant_id();

            delete from public.bookings bk
            where bk.id = (p_payload->>'id')::uuid
              and bk.tenant_id = v_tid;

            if not found then
                raise exception 'Booking not found';
            end if;

            perform platform.log_audit(
                'booking.deleted',
                'booking',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );


        when 'get_access_schedule' then
            v_tid := platform.current_tenant_id();

            select to_jsonb(pas)
            into v_result
            from public.property_access_schedules pas
            where pas.property_id = (p_payload->>'property_id')::uuid
              and pas.tenant_id = v_tid;

            return v_result;


        when 'upsert_access_schedule' then
            v_tid := platform.current_tenant_id();

            select pas.id
            into v_existing
            from public.property_access_schedules pas
            where pas.property_id = (p_payload->>'property_id')::uuid
              and pas.tenant_id = v_tid;

            if v_existing is not null then

                update public.property_access_schedules pas
                set
                    check_in_time = coalesce(
                        (p_payload->>'check_in_time')::time,
                        pas.check_in_time
                    ),
                    check_out_time = coalesce(
                        (p_payload->>'check_out_time')::time,
                        pas.check_out_time
                    ),
                    early_check_in_minutes = coalesce(
                        (p_payload->>'early_check_in_minutes')::int,
                        pas.early_check_in_minutes
                    ),
                    late_checkout_minutes = coalesce(
                        (p_payload->>'late_checkout_minutes')::int,
                        pas.late_checkout_minutes
                    ),
                    is_active = coalesce(
                        (p_payload->>'is_active')::boolean,
                        pas.is_active
                    )
                where pas.property_id = (p_payload->>'property_id')::uuid
                  and pas.tenant_id = v_tid
                returning
                    pas.id,
                    pas.tenant_id,
                    pas.property_id,
                    pas.check_in_time,
                    pas.check_out_time,
                    pas.early_check_in_minutes,
                    pas.late_checkout_minutes,
                    pas.is_active,
                    pas.created_at,
                    pas.updated_at
                into v_row;

                perform platform.log_audit(
                    'access_schedule.updated',
                    'property_access_schedule',
                    v_row.id
                );

            else

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
                    v_tid,
                    (p_payload->>'property_id')::uuid,
                    coalesce(
                        (p_payload->>'check_in_time')::time,
                        '15:00'::time
                    ),
                    coalesce(
                        (p_payload->>'check_out_time')::time,
                        '11:00'::time
                    ),
                    coalesce(
                        (p_payload->>'early_check_in_minutes')::int,
                        0
                    ),
                    coalesce(
                        (p_payload->>'late_checkout_minutes')::int,
                        0
                    ),
                    coalesce(
                        (p_payload->>'is_active')::boolean,
                        true
                    )
                )
                returning
                    id,
                    tenant_id,
                    property_id,
                    check_in_time,
                    check_out_time,
                    early_check_in_minutes,
                    late_checkout_minutes,
                    is_active,
                    created_at,
                    updated_at
                into v_row;

                perform platform.log_audit(
                    'access_schedule.created',
                    'property_access_schedule',
                    v_row.id
                );

            end if;

            return to_jsonb(v_row);


        when 'get_booking_access' then
            v_tid := platform.current_tenant_id();

            select to_jsonb(ba)
            into v_result
            from public.booking_access ba
            where ba.booking_id = (p_payload->>'booking_id')::uuid
              and ba.tenant_id = v_tid;

            return v_result;


        when 'create_booking_access' then
            return public.booking_create_booking_access(p_payload);


        when 'delete_booking_access' then
            v_tid := platform.current_tenant_id();

            delete from public.booking_access ba
            where ba.booking_id = (p_payload->>'booking_id')::uuid
              and ba.tenant_id = v_tid;

            if not found then
                raise exception 'Booking access not found';
            end if;

            perform platform.log_audit(
                'booking_access.deleted',
                'booking',
                (p_payload->>'booking_id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'booking_id', p_payload->>'booking_id'
            );


        when 'list_access_policies' then
            v_tid := platform.current_tenant_id();

            select coalesce(
                jsonb_agg(to_jsonb(ap) order by ap.created_at),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    p.id,
                    p.tenant_id,
                    p.property_id,
                    p.access_type,
                    p.valid_from,
                    p.valid_until,
                    p.is_active,
                    p.created_at,
                    p.updated_at
                from public.access_policies p
                where p.tenant_id = v_tid
                  and (
                      p_payload->>'property_id' is null
                      or p.property_id = (p_payload->>'property_id')::uuid
                  )
            ) ap;

            return v_result;


        when 'create_access_policy' then
            v_tid := platform.current_tenant_id();

            insert into public.access_policies (
                tenant_id,
                property_id,
                access_type,
                valid_from,
                valid_until,
                is_active
            )
            values (
                v_tid,
                (p_payload->>'property_id')::uuid,
                (p_payload->>'access_type')::public.access_type,
                (p_payload->>'valid_from')::timestamptz,
                (p_payload->>'valid_until')::timestamptz,
                coalesce((p_payload->>'is_active')::boolean, true)
            )
            returning
                id,
                tenant_id,
                property_id,
                access_type,
                valid_from,
                valid_until,
                is_active,
                created_at,
                updated_at
            into v_row;

            perform platform.log_audit(
                'access_policy.created',
                'access_policy',
                v_row.id
            );

            return to_jsonb(v_row);


        when 'update_access_policy' then
            v_tid := platform.current_tenant_id();

            update public.access_policies ap
            set
                access_type = case
                    when p_payload ? 'access_type'
                        then (p_payload->>'access_type')::public.access_type
                    else ap.access_type
                end,
                valid_from = case
                    when p_payload ? 'valid_from'
                        then (p_payload->>'valid_from')::timestamptz
                    else ap.valid_from
                end,
                valid_until = case
                    when p_payload ? 'valid_until'
                        then (p_payload->>'valid_until')::timestamptz
                    else ap.valid_until
                end,
                is_active = case
                    when p_payload ? 'is_active'
                        then (p_payload->>'is_active')::boolean
                    else ap.is_active
                end
            where ap.id = (p_payload->>'id')::uuid
              and ap.tenant_id = v_tid
            returning
                ap.id,
                ap.tenant_id,
                ap.property_id,
                ap.access_type,
                ap.valid_from,
                ap.valid_until,
                ap.is_active,
                ap.created_at,
                ap.updated_at
            into v_row;

            if not found then
                raise exception 'Access policy not found';
            end if;

            perform platform.log_audit(
                'access_policy.updated',
                'access_policy',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);


        when 'delete_access_policy' then
            v_tid := platform.current_tenant_id();

            delete from public.access_policies ap
            where ap.id = (p_payload->>'id')::uuid
              and ap.tenant_id = v_tid;

            if not found then
                raise exception 'Access policy not found';
            end if;

            perform platform.log_audit(
                'access_policy.deleted',
                'access_policy',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );


        when 'list_access_rules' then
            v_tid := platform.current_tenant_id();

            select coalesce(
                jsonb_agg(to_jsonb(ar) order by ar.created_at),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    r.id,
                    r.tenant_id,
                    r.property_id,
                    r.rule_type,
                    r.rule_config,
                    r.is_active,
                    r.created_at
                from public.access_rules r
                where r.tenant_id = v_tid
                  and (
                      p_payload->>'property_id' is null
                      or r.property_id = (p_payload->>'property_id')::uuid
                  )
            ) ar;

            return v_result;


        when 'create_access_rule' then
            v_tid := platform.current_tenant_id();

            insert into public.access_rules (
                tenant_id,
                property_id,
                rule_type,
                rule_config,
                is_active
            )
            values (
                v_tid,
                (p_payload->>'property_id')::uuid,
                (p_payload->>'rule_type')::public.access_rule_type,
                p_payload->'rule_config',
                coalesce((p_payload->>'is_active')::boolean, true)
            )
            returning
                id,
                tenant_id,
                property_id,
                rule_type,
                rule_config,
                is_active,
                created_at
            into v_row;

            perform platform.log_audit(
                'access_rule.created',
                'access_rule',
                v_row.id
            );

            return to_jsonb(v_row);


        when 'update_access_rule' then
            v_tid := platform.current_tenant_id();

            update public.access_rules ar
            set
                rule_type = case
                    when p_payload ? 'rule_type'
                        then (p_payload->>'rule_type')::public.access_rule_type
                    else ar.rule_type
                end,
                rule_config = case
                    when p_payload ? 'rule_config'
                        then p_payload->'rule_config'
                    else ar.rule_config
                end,
                is_active = case
                    when p_payload ? 'is_active'
                        then (p_payload->>'is_active')::boolean
                    else ar.is_active
                end
            where ar.id = (p_payload->>'id')::uuid
              and ar.tenant_id = v_tid
            returning
                ar.id,
                ar.tenant_id,
                ar.property_id,
                ar.rule_type,
                ar.rule_config,
                ar.is_active,
                ar.created_at
            into v_row;

            if not found then
                raise exception 'Access rule not found';
            end if;

            perform platform.log_audit(
                'access_rule.updated',
                'access_rule',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);


        when 'delete_access_rule' then
            v_tid := platform.current_tenant_id();

            delete from public.access_rules ar
            where ar.id = (p_payload->>'id')::uuid
              and ar.tenant_id = v_tid;

            if not found then
                raise exception 'Access rule not found';
            end if;

            perform platform.log_audit(
                'access_rule.deleted',
                'access_rule',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );


        else
            raise exception 'unknown booking operation: %', p_op;

    end case;
end;
$$;


-- =====================================================
-- 14 LOCKS DOMAIN RPC
-- =====================================================

create or replace function public.locks_domain(
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
    v_row record;
    v_result jsonb;
    v_lock record;
    v_existing record;
    v_command_id uuid;
    v_correlation_id uuid;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when 'list_lock_devices' then
            v_tid := platform.current_tenant_id();

            select coalesce(
                jsonb_agg(to_jsonb(ld) order by ld.created_at),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    l.id,
                    l.tenant_id,
                    l.device_id,
                    l.property_id,
                    l.is_primary,
                    l.created_at
                from public.lock_devices l
                where l.tenant_id = v_tid
                  and (
                      p_payload->>'property_id' is null
                      or l.property_id = (p_payload->>'property_id')::uuid
                  )
            ) ld;

            return v_result;


        when 'get_lock_device' then
            v_tid := platform.current_tenant_id();

            select
                l.id,
                l.tenant_id,
                l.device_id,
                l.property_id,
                l.is_primary,
                l.created_at
            into v_row
            from public.lock_devices l
            where l.id = (p_payload->>'id')::uuid
              and l.tenant_id = v_tid;

            if not found then
                raise exception 'Lock device not found';
            end if;

            return to_jsonb(v_row);


        when 'create_lock_device' then
            v_tid := platform.current_tenant_id();

            insert into public.lock_devices (
                tenant_id,
                device_id,
                property_id,
                is_primary
            )
            values (
                v_tid,
                (p_payload->>'device_id')::uuid,
                (p_payload->>'property_id')::uuid,
                coalesce((p_payload->>'is_primary')::boolean, false)
            )
            returning
                id,
                tenant_id,
                device_id,
                property_id,
                is_primary,
                created_at
            into v_row;

            perform platform.log_audit(
                'lock_device.created',
                'lock_device',
                v_row.id,
                p_payload
            );

            return to_jsonb(v_row);


        when 'update_lock_device' then
            v_tid := platform.current_tenant_id();

            update public.lock_devices ld
            set
                is_primary = case
                    when p_payload ? 'is_primary'
                        then (p_payload->>'is_primary')::boolean
                    else ld.is_primary
                end
            where ld.id = (p_payload->>'id')::uuid
              and ld.tenant_id = v_tid
            returning
                ld.id,
                ld.tenant_id,
                ld.device_id,
                ld.property_id,
                ld.is_primary,
                ld.created_at
            into v_row;

            if not found then
                raise exception 'Lock device not found';
            end if;

            perform platform.log_audit(
                'lock_device.updated',
                'lock_device',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);


        when 'delete_lock_device' then
            v_tid := platform.current_tenant_id();

            delete from public.lock_devices ld
            where ld.id = (p_payload->>'id')::uuid
              and ld.tenant_id = v_tid;

            if not found then
                raise exception 'Lock device not found';
            end if;

            perform platform.log_audit(
                'lock_device.deleted',
                'lock_device',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );


        when 'list_credentials' then
            v_tid := platform.current_tenant_id();

            select coalesce(
                jsonb_agg(to_jsonb(ac) order by ac.created_at),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    c.id,
                    c.tenant_id,
                    c.booking_id,
                    c.lock_device_id,
                    c.booking_access_id,
                    c.provider_code,
                    c.credential_ref,
                    c.external_credential_id,
                    c.status,
                    c.valid_from,
                    c.valid_until,
                    c.revoked_at,
                    c.created_at,
                    c.updated_at
                from public.access_credentials c
                where c.tenant_id = v_tid
                  and (
                      p_payload->>'booking_id' is null
                      or c.booking_id = (p_payload->>'booking_id')::uuid
                  )
            ) ac;

            return v_result;


        when 'get_credential' then
            v_tid := platform.current_tenant_id();

            select
                c.id,
                c.tenant_id,
                c.booking_id,
                c.lock_device_id,
                c.booking_access_id,
                c.provider_code,
                c.credential_ref,
                c.external_credential_id,
                c.status,
                c.valid_from,
                c.valid_until,
                c.revoked_at,
                c.created_at,
                c.updated_at
            into v_row
            from public.access_credentials c
            where c.id = (p_payload->>'id')::uuid
              and c.tenant_id = v_tid;

            if not found then
                raise exception 'Credential not found';
            end if;

            return to_jsonb(v_row);


        -- =================================================
        -- ISSUE CREDENTIAL
        -- Domain creates the grant.
        -- Generic platform queue owns command execution.
        -- =================================================

        when 'issue_credential' then

            v_tid := platform.current_tenant_id();

            select
                ld.id,
                ld.tenant_id,
                ld.device_id,
                ld.property_id
            into v_lock
            from public.lock_devices ld
            where ld.id = (p_payload->>'lock_device_id')::uuid
              and ld.tenant_id = v_tid;

            if not found then
                raise exception 'Lock device not found for tenant';
            end if;

            if not (p_payload ? 'booking_access_id')
               or nullif(p_payload->>'booking_access_id', '') is null
            then
                raise exception
                    'booking_access_id is required when issuing a credential';
            end if;

            insert into public.access_credentials (
                tenant_id,
                booking_id,
                lock_device_id,
                booking_access_id,
                credential_ref,
                status
            )
            values (
                v_tid,
                (p_payload->>'booking_id')::uuid,
                (p_payload->>'lock_device_id')::uuid,
                (p_payload->>'booking_access_id')::uuid,
                p_payload->>'credential_ref',
                'pending'::public.access_credential_status
            )
            returning
                id,
                tenant_id,
                booking_id,
                lock_device_id,
                booking_access_id,
                provider_code,
                credential_ref,
                external_credential_id,
                status,
                valid_from,
                valid_until,
                revoked_at,
                created_at,
                updated_at
            into v_row;

            v_correlation_id := gen_random_uuid();

            v_command_id := platform.queue_device_command(
                v_lock.device_id,
                'issue_credential',
                jsonb_build_object(
                    'credential_id', v_row.id,
                    'booking_id', v_row.booking_id,
                    'lock_device_id', v_row.lock_device_id,
                    'credential_ref', v_row.credential_ref
                ),
                coalesce(
                    p_payload->>'idempotency_key',
                    'credential-issue-' || v_row.id::text
                ),
                v_correlation_id
            );

            perform platform.log_audit(
                'credential.issue_requested',
                'access_credential',
                v_row.id,
                jsonb_build_object(
                    'command_id', v_command_id
                )
            );

            return jsonb_build_object(
                'credential', to_jsonb(v_row),
                'command_id', v_command_id,
                'correlation_id', v_correlation_id
            );


        -- =================================================
        -- REVOKE CREDENTIAL
        -- Domain requests revocation.
        -- Generic platform queue owns command execution.
        -- Credential is not marked revoked until execution succeeds.
        -- =================================================

        when 'revoke_credential' then

            v_tid := platform.current_tenant_id();

            select
                c.id,
                c.tenant_id,
                c.booking_id,
                c.lock_device_id,
                c.booking_access_id,
                c.provider_code,
                c.credential_ref,
                c.external_credential_id,
                c.status,
                c.valid_from,
                c.valid_until,
                c.revoked_at,
                c.created_at,
                c.updated_at
            into v_existing
            from public.access_credentials c
            where c.id = (p_payload->>'credential_id')::uuid
              and c.tenant_id = v_tid;

            if not found then
                raise exception 'Credential not found';
            end if;

            select
                ld.id,
                ld.device_id
            into v_lock
            from public.lock_devices ld
            where ld.id = v_existing.lock_device_id
              and ld.tenant_id = v_tid;

            if not found then
                raise exception 'Lock device not found';
            end if;

            update public.access_credentials
            set
                status = 'revoking'::public.access_credential_status,
                updated_at = now()
            where id = v_existing.id
            and tenant_id = v_tid
            and status in (
                'pending'::public.access_credential_status,
                'active'::public.access_credential_status
            )
            returning
                id,
                tenant_id,
                booking_id,
                lock_device_id,
                booking_access_id,
                provider_code,
                credential_ref,
                external_credential_id,
                status,
                valid_from,
                valid_until,
                revoked_at,
                created_at,
                updated_at
            into v_existing;

            if not found then
                raise exception
                    'Credential cannot be revoked from its current status';
            end if;

            v_correlation_id := gen_random_uuid();

            v_command_id := platform.queue_device_command(
                v_lock.device_id,
                'revoke_credential',
                jsonb_build_object(
                    'credential_id', v_existing.id,
                    'external_credential_id', v_existing.external_credential_id
                ),
                coalesce(
                    p_payload->>'idempotency_key',
                    'credential-revoke-' || v_existing.id::text
                ),
                v_correlation_id
            );

            perform platform.log_audit(
                'credential.revoke_requested',
                'access_credential',
                v_existing.id,
                jsonb_build_object(
                    'command_id', v_command_id
                )
            );

            return jsonb_build_object(
                'credential', to_jsonb(v_existing),
                'command_id', v_command_id,
                'correlation_id', v_correlation_id
            );


        else
            raise exception 'unknown locks operation: %', p_op;

    end case;
end;
$$;


-- =====================================================
-- 15 BOOKING OVERVIEW VIEW
-- =====================================================

create or replace view public.v_bookings_overview
with (security_invoker = true)
as
select
    b.id,
    b.tenant_id,
    b.property_id,
    p.name as property_name,
    b.guest_name,
    b.guest_email,
    b.start_date,
    b.end_date,
    b.status,
    ba.valid_from,
    ba.valid_until,
    ac.status as credential_status,
    b.created_at,
    b.updated_at
from public.bookings b
join public.properties p
    on p.id = b.property_id
left join public.booking_access ba
    on ba.booking_id = b.id
left join public.access_credentials ac
    on ac.booking_id = b.id;


-- =====================================================
-- 18 TRIGGERS
-- =====================================================

create trigger trg_bookings_updated_at
before update on bookings
for each row execute function platform.set_updated_at();

create trigger trg_bookings_tenant_consistency
before insert or update on public.bookings
for each row execute function public.enforce_booking_tenant_consistency();

create trigger trg_property_access_schedules_updated_at
before update on property_access_schedules
for each row execute function platform.set_updated_at();

create trigger trg_booking_access_consistency
before insert or update on public.booking_access
for each row execute function public.enforce_booking_access_consistency();

create trigger trg_booking_access_updated_at
before update on booking_access
for each row execute function platform.set_updated_at();

create trigger trg_access_policies_updated_at
before update on access_policies
for each row execute function platform.set_updated_at();

create trigger trg_lock_devices_integrity
before insert or update on public.lock_devices
for each row execute function public.enforce_lock_device_integrity();

create trigger trg_access_credentials_updated_at
before update on access_credentials
for each row execute function platform.set_updated_at();

create trigger trg_access_credentials_consistency
before insert or update on public.access_credentials
for each row execute function public.enforce_access_credential_consistency();

create trigger trg_property_access_schedules_tenant_consistency
before insert or update on public.property_access_schedules
for each row execute function public.enforce_property_tenant_consistency();

create trigger trg_access_policies_tenant_consistency
before insert or update on public.access_policies
for each row execute function public.enforce_property_tenant_consistency();

create trigger trg_access_rules_tenant_consistency
before insert or update on public.access_rules
for each row execute function public.enforce_property_tenant_consistency();


-- =====================================================
-- 19 END 005 BOOKING & LOCK ENGINE
-- =====================================================

insert into platform.schema_migrations ( migration_name, version, rollback_available)
values ( '005_booking_lock_engine', 'REV1', false)
on conflict (migration_name) do nothing;