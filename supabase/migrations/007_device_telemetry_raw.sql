-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 007_DEVICE_TELEMETRY_RAW.SQL
-- =====================================================
--
-- Purpose:
--   Raw device telemetry ingestion and immutable storage.
--
-- Authority:
--   004_PROPERTY_DEVICE_ENGINE.SQL = DEVICE SSOT
--
-- SSOT RULE:
--   This module stores RAW DEVICE INPUT only.
--
-- Responsibility:
--   - Store immutable device telemetry exactly as received
--     after integration identity has been resolved.
--   - Provide the single raw telemetry ingest boundary.
--   - Maintain raw telemetry partitioning through pg_partman.
--   - Maintain raw telemetry retention through pg_partman.
--
-- 007 MUST NOT:
--   - resolve providers
--   - resolve tenants
--   - resolve SmartHellas devices
--   - interpret provider payloads
--   - calculate metrics
--   - normalize telemetry
--   - calculate device state
--   - make automation decisions
--
-- 006 Integration Engine resolves:
--   - provider
--   - tenant
--   - device
--   - provider_event_id
--   - observed_at
--
-- 008 Device Telemetry Processing owns:
--   - normalization
--   - metric extraction
--   - validation beyond raw ingest
--   - derived telemetry
--
-- Raw payload is immutable.
--
-- Partitioning:
--   - RANGE partitioning on received_at
--   - Daily partitions
--   - pg_partman owns partition creation
--   - pg_partman owns partition maintenance
--   - pg_partman owns partition retention
--   - Raw telemetry retention: 7 days
--
-- =====================================================

begin;

-- =====================================================
-- 0. PG_PARTMAN PRE-FLIGHT
-- =====================================================
--
-- 000_PLATFORM_BASELINE is responsible for making
-- pg_partman available.
--
-- 007 only consumes that dependency.
--
-- =====================================================

do $$
begin

    if not exists (
        select 1
        from pg_extension e
        where e.extname = 'pg_partman'
    ) then

        raise exception
            '007 requires pg_partman, but the extension is not installed';

    end if;


    if not exists (
        select 1
        from pg_namespace n
        where n.nspname = 'partman'
    ) then

        raise exception
            '007 requires the pg_partman schema "partman"';

    end if;


    if to_regprocedure(
        'partman.create_parent(text,text,text,text,text,integer,text,boolean,text,text[],text,boolean,text,boolean,text,text,bigint)'
    ) is null then

        raise exception
            '007 requires pg_partman create_parent() with the expected API';

    end if;

end;
$$;

-- =====================================================
-- 1. RAW TELEMETRY TABLE
-- =====================================================
--
-- The table is partitioned directly at creation time.
--
-- received_at is the operational partition key because
-- retention is based on ingestion time, not provider
-- event time.
--
-- observed_at may be NULL and must never determine
-- retention or partition placement.
--
-- =====================================================

create table if not exists public.device_telemetry_raw (
    id uuid not null
        default gen_random_uuid(),

    tenant_id uuid not null,

    device_id uuid not null
        references public.devices(id)
        on delete cascade,

    source text not null,

    provider_event_id text not null,

    observed_at timestamptz,

    received_at timestamptz not null
        default now(),

    raw_payload jsonb not null
        default '{}'::jsonb,

    created_at timestamptz not null
        default now()
)
partition by range (received_at);

-- =====================================================
-- 2. RAW TELEMETRY QUERY INDEXES
-- =====================================================
--
-- These indexes are created on the partitioned parent.
-- PostgreSQL creates corresponding partition indexes.
--
-- =====================================================

create index if not exists
idx_device_telemetry_raw_device_observed
on public.device_telemetry_raw (
    device_id,
    observed_at desc
);

create index if not exists
idx_device_telemetry_raw_tenant_received
on public.device_telemetry_raw (
    tenant_id,
    received_at desc
);

create index if not exists
idx_device_telemetry_raw_source_event
on public.device_telemetry_raw (
    source,
    provider_event_id
);

-- =====================================================
-- 3. IDEMPOTENCY REGISTRY
-- =====================================================
--
-- PostgreSQL cannot enforce a UNIQUE constraint across
-- all time partitions unless the partition key is part
-- of the constraint.
--
-- Therefore the global provider-event identity is kept
-- in a small non-partitioned registry.
--
-- This registry is NOT telemetry data.
-- It is an ingestion/idempotency control structure.
--
-- Key:
--   tenant_id
--   source
--   provider_event_id
--
-- =====================================================

create table if not exists public.device_telemetry_raw_idempotency (
    tenant_id uuid not null,

    source text not null,

    provider_event_id text not null,

    telemetry_id uuid not null,

    first_received_at timestamptz not null
        default now(),

    primary key (
        tenant_id,
        source,
        provider_event_id
    )
);

create index if not exists
idx_device_telemetry_raw_idempotency_telemetry
on public.device_telemetry_raw_idempotency (
    telemetry_id
);

-- =====================================================
-- 4. TABLE CONTRACT
-- =====================================================

comment on table public.device_telemetry_raw is
'Immutable raw device telemetry. Stores provider payloads after Integration Engine (006) has resolved tenant, device and provider event identity. Partitioned daily by received_at and maintained by pg_partman. Raw retention is 7 days. No provider-specific interpretation or processing belongs here.';

comment on table public.device_telemetry_raw_idempotency is
'Global raw telemetry ingestion idempotency registry. Maintains tenant + source + provider_event_id uniqueness independently from raw telemetry partitions. This table contains ingestion identity metadata, not telemetry payloads.';

comment on column public.device_telemetry_raw.tenant_id is
'Authoritative SmartHellas tenant resolved by Integration Engine (006).';

comment on column public.device_telemetry_raw.device_id is
'SmartHellas device resolved by Integration Engine (006).';

comment on column public.device_telemetry_raw.source is
'Provider code resolved by Integration Engine (006).';

comment on column public.device_telemetry_raw.provider_event_id is
'Provider-side event identifier supplied by Integration Engine (006) and used for hard idempotency.';

comment on column public.device_telemetry_raw.observed_at is
'Provider event timestamp resolved by Integration Engine (006). NULL only when the provider event has no usable event timestamp.';

comment on column public.device_telemetry_raw.received_at is
'Timestamp at which the event entered the SmartHellas platform boundary. This is the partition and retention control timestamp.';

comment on column public.device_telemetry_raw.raw_payload is
'Original provider payload. Must not be normalized, transformed or mutated after ingestion.';

-- =====================================================
-- 5. DEVICE ↔ TENANT INVARIANT
-- =====================================================
--
-- 004 is the SSOT for device ownership.
--
-- Telemetry may never be written under a tenant other
-- than the tenant that owns the referenced device.
--
-- This is an integrity boundary, not business logic.
--
-- =====================================================

create or replace function
public.enforce_device_telemetry_tenant_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_device_tenant uuid;
begin

    select d.tenant_id
    into v_device_tenant
    from public.devices d
    where d.id = new.device_id;

    if not found then
        raise exception
            'device not found';
    end if;

    if v_device_tenant <> new.tenant_id then
        raise exception
            'telemetry tenant must match device tenant';
    end if;

    return new;

end;
$$;

drop trigger if exists
trg_device_telemetry_tenant_consistency
on public.device_telemetry_raw;

create trigger
trg_device_telemetry_tenant_consistency
before insert on public.device_telemetry_raw
for each row
execute function
public.enforce_device_telemetry_tenant_consistency();

alter function
public.enforce_device_telemetry_tenant_consistency()
set search_path = '';

-- =====================================================
-- 6. PG_PARTMAN PARTITION SETUP
-- =====================================================
--
-- Daily RANGE partitions on received_at.
--
-- Example:
--
--   p2026_09_29
--   p2026_09_30
--   p2026_10_01
--
-- pg_partman owns:
--   - partition creation
--   - future partition premake
--   - maintenance
--   - retention
--
-- Raw telemetry retention:
--   7 days
--
-- =====================================================

select partman.create_parent(
    p_parent_table          := 'public.device_telemetry_raw',
    p_control               := 'received_at',
    p_interval              := '1 day',
    p_type                  := 'range',
    p_premake               := 7,
    p_default_table         := false,
    p_automatic_maintenance := 'on',
    p_jobmon                := false,
    p_control_not_null      := true,
    p_start_partition       := to_char(
        date_trunc('day', now()),
        'YYYY-MM-DD'
    )
);

-- =====================================================
-- 7. PG_PARTMAN RETENTION CONFIGURATION
-- =====================================================
--
-- Retention is handled by pg_partman by dropping old
-- partitions rather than issuing row-level DELETEs.
--
-- retention_keep_table = false:
--   old partitions are removed completely.
--
-- retention_keep_index = false:
--   indexes belonging to removed partitions are removed
--   with the partition.
--
-- =====================================================

update partman.part_config
set
    retention = '7 days',
    retention_keep_table = false,
    retention_keep_index = false,
    automatic_maintenance = 'on',
    premake = 7,
    infinite_time_partitions = false
where parent_table = 'public.device_telemetry_raw';

-- =====================================================
-- 8. PARTITIONING CONTRACT
-- =====================================================

comment on table public.device_telemetry_raw is
'Immutable raw device telemetry. Stores provider payloads after Integration Engine (006) has resolved tenant, device and provider event identity. Partitioned daily by received_at and maintained by pg_partman. Raw retention is 7 days. No provider-specific interpretation or processing belongs here.';

-- =====================================================
-- 9. RAW TELEMETRY INGEST
-- =====================================================
--
-- This is the ONLY write boundary for raw telemetry.
--
-- Caller:
--   006 Integration Engine
--
-- The function does not know anything about Aqara,
-- TTLock, Shelly, etc.
--
-- =====================================================

create or replace function public.ingest_device_telemetry_raw(
    p_tenant_id uuid,
    p_device_id uuid,
    p_source text,
    p_provider_event_id text,
    p_observed_at timestamptz,
    p_received_at timestamptz,
    p_raw_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_id uuid;
    v_source text;
    v_event_id text;
    v_received_at timestamptz;
begin

    -- =================================================
    -- 1. INPUT VALIDATION
    -- =================================================

    if p_tenant_id is null then
        raise exception
            'tenant_id is required';
    end if;

    if p_device_id is null then
        raise exception
            'device_id is required';
    end if;

    if p_source is null
       or btrim(p_source) = '' then
        raise exception
            'source is required';
    end if;

    if p_provider_event_id is null
       or btrim(p_provider_event_id) = '' then
        raise exception
            'provider_event_id is required';
    end if;

    v_source :=
        lower(btrim(p_source));

    v_event_id :=
        btrim(p_provider_event_id);

    v_received_at :=
        coalesce(
            p_received_at,
            now()
        );

    -- =================================================
    -- 2. DEVICE / TENANT CONSISTENCY
    -- =================================================

    if not exists (
        select 1
        from public.devices d
        where d.id = p_device_id
          and d.tenant_id = p_tenant_id
    ) then

        raise exception
            'Device % does not belong to tenant %',
            p_device_id,
            p_tenant_id;

    end if;

    -- =================================================
    -- 3. GLOBAL IDEMPOTENCY CLAIM
    -- =================================================

    v_id := gen_random_uuid();

    insert into public.device_telemetry_raw_idempotency (
        tenant_id,
        source,
        provider_event_id,
        telemetry_id,
        first_received_at
    )
    values (
        p_tenant_id,
        v_source,
        v_event_id,
        v_id,
        v_received_at
    )
    on conflict (
        tenant_id,
        source,
        provider_event_id
    )
    do nothing;

    -- =================================================
    -- 4. DUPLICATE EVENT
    -- =================================================

    if not exists (
        select 1
        from public.device_telemetry_raw_idempotency r
        where r.tenant_id = p_tenant_id
          and r.source = v_source
          and r.provider_event_id = v_event_id
          and r.telemetry_id = v_id
    ) then

        select r.telemetry_id
        into v_id
        from public.device_telemetry_raw_idempotency r
        where r.tenant_id = p_tenant_id
          and r.source = v_source
          and r.provider_event_id = v_event_id;

        if v_id is null then
            raise exception
                'Telemetry idempotency registry lookup failed';
        end if;

        return jsonb_build_object(
            'ingested', false,
            'duplicate', true,
            'telemetry_id', v_id
        );

    end if;

    -- =================================================
    -- 5. IMMUTABLE RAW INSERT
    -- =================================================

    insert into public.device_telemetry_raw (
        id,
        tenant_id,
        device_id,
        source,
        provider_event_id,
        observed_at,
        received_at,
        raw_payload
    )
    values (
        v_id,
        p_tenant_id,
        p_device_id,
        v_source,
        v_event_id,
        p_observed_at,
        v_received_at,
        coalesce(
            p_raw_payload,
            '{}'::jsonb
        )
    );

    -- =================================================
    -- 6. SUCCESS
    -- =================================================

    return jsonb_build_object(
        'ingested', true,
        'duplicate', false,
        'telemetry_id', v_id
    );

end;
$$;

comment on function public.ingest_device_telemetry_raw(
    uuid,
    uuid,
    text,
    text,
    timestamptz,
    timestamptz,
    jsonb
)
is
'Single raw telemetry ingest boundary. Stores immutable provider payloads after Integration Engine (006) resolves tenant, device, provider event identity and observed timestamp. Idempotent on tenant + source + provider_event_id through the raw telemetry idempotency registry.';

-- =====================================================
-- 10. FUNCTION SECURITY HARDENING
-- =====================================================

alter function public.ingest_device_telemetry_raw(
    uuid,
    uuid,
    text,
    text,
    timestamptz,
    timestamptz,
    jsonb
)
set search_path = '';

revoke all
on function public.ingest_device_telemetry_raw(
    uuid,
    uuid,
    text,
    text,
    timestamptz,
    timestamptz,
    jsonb
)
from public, anon, authenticated;

-- =====================================================
-- 11. SCHEMA MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (
    migration_name,
    version,
    rollback_available
)
values (
    '007_device_telemetry_raw',
    'REV1',
    false
)
on conflict (migration_name)
do nothing;

commit;

-- =====================================================
-- END 007 DEVICE TELEMETRY RAW
-- =====================================================
--
-- SSOT BOUNDARY:
--
-- 004 = Device/domain registry SSOT
-- 007 = Raw telemetry input SSOT
--
-- Partitioning:
--   pg_partman owns partition creation,
--   premake, maintenance and retention.
--
-- Future modules may derive:
--   - normalized measurements
--   - current device state
--   - usage scores
--   - energy metrics
--   - anomaly detection
--   - automation signals
--   - monetization metrics
--
-- Such derived data MUST NOT be written into
-- device_telemetry_raw.
--
-- =====================================================