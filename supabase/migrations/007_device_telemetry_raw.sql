-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 007_DEVICE_TELEMETRY_RAW.SQL
-- =====================================================
--
-- Purpose:
-- Raw device telemetry ingestion and immutable storage
--
-- Authority:
-- 004_property_device_engine.sql = DEVICE SSOT
--
-- SSOT RULE:
-- This module stores RAW DEVICE INPUT only.
--
-- Responsibility:
-- - Store immutable device telemetry exactly as received
--   after integration identity has been resolved.
-- - Provide the single raw telemetry ingest boundary.
--
-- 007 MUST NOT:
-- - resolve providers
-- - resolve tenants
-- - resolve SmartHellas devices
-- - interpret provider payloads
-- - calculate metrics
-- - normalize telemetry
-- - calculate device state
-- - make automation decisions
--
-- 006 Integration Engine resolves:
-- - provider
-- - tenant
-- - device
-- - provider_event_id
-- - observed_at
--
-- 008 Device Telemetry Processing owns:
-- - normalization
-- - metric extraction
-- - validation beyond raw ingest
-- - derived telemetry
--
-- Raw payload is immutable.
-- =====================================================

begin;

-- =====================================================
-- 1. RAW TELEMETRY TABLE
-- =====================================================

create table if not exists public.device_telemetry_raw (

    id uuid primary key default gen_random_uuid(),

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
);


-- =====================================================
-- 2. IDEMPOTENCY
--
-- One provider event may only be stored once for a
-- tenant/provider combination.
--
-- provider_event_id is supplied by 006.
-- =====================================================

create unique index if not exists
    uq_device_telemetry_raw_event
on public.device_telemetry_raw (
    tenant_id,
    source,
    provider_event_id
);


-- =====================================================
-- 3. QUERY INDEXES
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
-- 4. TABLE CONTRACT
-- =====================================================

comment on table public.device_telemetry_raw is
'Immutable raw device telemetry. Stores provider payloads after Integration Engine (006) has resolved tenant, device and provider event identity. No provider-specific interpretation or processing belongs here.';


comment on column public.device_telemetry_raw.tenant_id is
'Authoritative SmartHellas tenant resolved by Integration Engine (006).';


comment on column public.device_telemetry_raw.device_id is
'SmartHellas device resolved by Integration Engine (006).';


comment on column public.device_telemetry_raw.source is
'Provider code resolved by Integration Engine (006).';


comment on column public.device_telemetry_raw.provider_event_id is
'Provider-side event identifier used for hard idempotency.';


comment on column public.device_telemetry_raw.observed_at is
'Provider event timestamp resolved by Integration Engine (006). NULL only when the provider event has no usable event timestamp.';


comment on column public.device_telemetry_raw.received_at is
'Timestamp at which the event entered the SmartHellas platform boundary.';


comment on column public.device_telemetry_raw.raw_payload is
'Original provider payload. Must not be normalized, transformed or mutated after ingestion.';



-- =====================================================
-- 3. DEVICE ↔ TENANT INVARIANT
--
-- 004 is the SSOT for device ownership.
--
-- Telemetry may never be written under a tenant other
-- than the tenant that owns the referenced device.
--
-- This is an integrity boundary, not business logic.
-- =====================================================

create or replace function public.enforce_device_telemetry_tenant_consistency()
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
        raise exception 'device not found';
    end if;

    if v_device_tenant <> new.tenant_id then
        raise exception
            'telemetry tenant must match device tenant';
    end if;

    return new;
end;
$$;

drop trigger if exists trg_device_telemetry_tenant_consistency
on public.device_telemetry_raw;

create trigger trg_device_telemetry_tenant_consistency
before insert on public.device_telemetry_raw
for each row
execute function public.enforce_device_telemetry_tenant_consistency();

-- =====================================================
-- 7. FUNCTION SECURITY HARDENING
--
-- The integrity trigger must never depend on an unsafe
-- caller-controlled search_path.
-- =====================================================

alter function public.enforce_device_telemetry_tenant_consistency()
set search_path = '';


-- =====================================================
-- 5. RAW TELEMETRY INGEST
-- =====================================================
--
-- This is the ONLY write boundary for raw telemetry.
--
-- Caller:
--   006 Integration Engine
--
-- The function does not know anything about Aqara,
-- TTLock, Shelly, etc.
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
    v_inserted boolean := false;
begin

    -- =====================================================
    -- 1. INPUT VALIDATION
    -- =====================================================

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


    -- =====================================================
    -- 2. DEVICE / TENANT CONSISTENCY
    --
    -- The device must belong to the supplied tenant.
    -- =====================================================

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


    -- =====================================================
    -- 3. IMMUTABLE RAW INSERT
    --
    -- ON CONFLICT makes ingestion idempotent.
    -- =====================================================

    insert into public.device_telemetry_raw (
        tenant_id,
        device_id,
        source,
        provider_event_id,
        observed_at,
        received_at,
        raw_payload
    )
    values (
        p_tenant_id,
        p_device_id,
        lower(trim(p_source)),
        trim(p_provider_event_id),
        p_observed_at,
        coalesce(
            p_received_at,
            now()
        ),
        coalesce(
            p_raw_payload,
            '{}'::jsonb
        )
    )
    on conflict (
        tenant_id,
        source,
        provider_event_id
    )
    do nothing
    returning id
    into v_id;


    -- =====================================================
    -- 4. IDEMPOTENT RESULT
    -- =====================================================

    if v_id is not null then

        v_inserted := true;

        return jsonb_build_object(
            'ingested', true,
            'duplicate', false,
            'telemetry_id', v_id
        );

    end if;


    -- =====================================================
    -- 5. EXISTING EVENT
    -- =====================================================

    select dtr.id
    into v_id
    from public.device_telemetry_raw dtr
    where dtr.tenant_id = p_tenant_id
      and dtr.source = lower(trim(p_source))
      and dtr.provider_event_id = trim(p_provider_event_id);

    if v_id is null then
        raise exception
            'Telemetry ingest failed without insert or existing event';
    end if;


    return jsonb_build_object(
        'ingested', false,
        'duplicate', true,
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
'Single raw telemetry ingest boundary. Stores immutable provider payloads after Integration Engine (006) resolves tenant, device, provider event identity and observed timestamp. Idempotent on tenant + source + provider_event_id.';


-- =====================================================
-- 9. SCHEMA MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('007_device_telemetry_raw','REV1', false)
on conflict (migration_name) do nothing;


commit;


-- =====================================================
-- END 007 DEVICE TELEMETRY RAW
--
-- SSOT BOUNDARY:
--
-- 004 = Device/domain registry SSOT
-- 007 = Raw telemetry input SSOT
--
-- Future modules may derive:
-- - normalized measurements
-- - current device state
-- - usage scores
-- - energy metrics
-- - anomaly detection
-- - automation signals
-- - monetization metrics
--
-- Such derived data MUST NOT be written into
-- device_telemetry_raw.
-- =====================================================