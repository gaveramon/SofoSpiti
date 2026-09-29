-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 008_DEVICE_TELEMETRY_PROCESSING.SQL
-- =====================================================
--
-- Purpose:
-- Turn immutable raw telemetry (007) into typed,
-- queryable data that a portal (Appsmith) can chart and
-- display directly, without ever reading raw_payload.
--
-- Authority:
-- 007_device_telemetry_raw.sql = RAW TELEMETRY SSOT
-- 004_property_device_engine.sql = DEVICE SSOT
--
-- SSOT RULE:
-- This module owns DERIVED telemetry only.
-- It never rewrites or deletes raw_payload (007 stays
-- immutable) - it only reads it and produces new rows in
-- its own tables.
--
-- Responsibility:
-- - Claim pending rows from public.device_telemetry_raw
-- - Normalize provider payloads into typed metrics
--   (device_metrics: time series, for charts)
-- - Maintain a latest-value snapshot per device/metric
--   (device_current_state: for dashboards/lists)
-- - Expose both through devices_domain()/devices_api()
--   read operations so Appsmith never queries these
--   tables directly (RPC-only, same as every other
--   governed table in this schema)
--
-- 008 MUST NOT:
-- - mutate public.device_telemetry_raw.raw_payload
-- - resolve providers/tenants/devices (006 already did)
-- - make automation decisions (017 owns that)
-- - be read directly by the portal (public.devices_api
--   is the only sanctioned read path)
--
-- =====================================================

begin;

-- =====================================================
-- 1. PROCESSING BOOKKEEPING ON THE RAW TABLE
-- =====================================================
-- Adds processing metadata to 007's table. This does not
-- touch raw_payload and does not violate 007's raw-payload
-- immutability rule. It tracks processing state, attempts and
-- retry timing for the derived telemetry worker.
-- =====================================================

alter table public.device_telemetry_raw
    add column if not exists processing_status text
        not null default 'pending';

alter table public.device_telemetry_raw
    drop constraint if exists chk_device_telemetry_raw_processing_status;

alter table public.device_telemetry_raw
    add constraint chk_device_telemetry_raw_processing_status
    check (
        processing_status in (
            'pending',
            'processing',
            'processed',
            'failed'
        )
    );

alter table public.device_telemetry_raw
    add column if not exists processing_error text;

alter table public.device_telemetry_raw
    add column if not exists processed_at timestamptz;

alter table public.device_telemetry_raw
    add column if not exists processing_attempts integer
        not null default 0;

alter table public.device_telemetry_raw
    add column if not exists last_processing_at timestamptz;

alter table public.device_telemetry_raw
    add column if not exists next_processing_at timestamptz;

alter table public.device_telemetry_raw
    drop constraint if exists chk_device_telemetry_raw_processing_attempts;

alter table public.device_telemetry_raw
    add constraint chk_device_telemetry_raw_processing_attempts
    check (processing_attempts >= 0);

create index if not exists
    idx_device_telemetry_raw_pending
on public.device_telemetry_raw (received_at)
where processing_status in ('pending', 'failed');


-- =====================================================
-- 2. DEVICE METRICS (NORMALIZED TIME SERIES)
-- =====================================================
-- One row per extracted metric value. This is what
-- powers Appsmith line/bar charts over time.
-- =====================================================

create table if not exists public.device_metrics (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    device_id uuid not null
        references public.devices(id)
        on delete cascade,

    -- Source telemetry identifier is retained for provenance only.
    -- Intentionally NOT an FK: derived metrics have their own retention
    -- lifecycle and must survive deletion/retention of raw telemetry (007).
    telemetry_id uuid not null,

    metric_key text not null,

    metric_value numeric,
    metric_value_text text,

    unit text,

    observed_at timestamptz not null,

    created_at timestamptz not null default now(),

    constraint chk_device_metrics_value_present
        check (
            metric_value is not null
            or metric_value_text is not null
        ),

    unique (telemetry_id, metric_key)
);


create index if not exists
    idx_device_metrics_device_key_observed
on public.device_metrics (
    device_id,
    metric_key,
    observed_at desc
);


create index if not exists
    idx_device_metrics_tenant_observed
on public.device_metrics (
    tenant_id,
    observed_at desc
);


comment on table public.device_metrics is
'Normalized, typed telemetry time series derived from public.device_telemetry_raw. One row per metric per raw event. Portal access exclusively through devices_api()/devices_domain() read operations.';


-- =====================================================
-- 3. DEVICE CURRENT STATE (LATEST SNAPSHOT)
-- =====================================================
-- One row per device/metric_key, always holding the most
-- recent observed value. This is what powers Appsmith
-- device lists and dashboard tiles without scanning the
-- time series.
-- =====================================================

create table if not exists public.device_current_state (
    device_id uuid not null
        references public.devices(id)
        on delete cascade,

    metric_key text not null,

    -- Last source event used for deterministic tie-breaking.
    -- Provenance only; intentionally no FK to 007.
    telemetry_id uuid not null,

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    metric_value numeric,
    metric_value_text text,

    unit text,

    observed_at timestamptz not null,

    updated_at timestamptz not null default now(),

    primary key (device_id, metric_key)
);


create index if not exists
    idx_device_current_state_tenant
on public.device_current_state (
    tenant_id,
    device_id
);


comment on table public.device_current_state is
'Latest known value per device/metric_key, upserted by process_device_telemetry_batch(). Portal access exclusively through devices_api()/devices_domain() read operations.';


-- =====================================================
-- 4. DEVICE ↔ TENANT INVARIANT
-- Same integrity boundary as 007, applied to the two
-- new tables.
-- =====================================================

create or replace function public.enforce_device_metrics_tenant_consistency()
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
            'metric tenant must match device tenant';
    end if;

    return new;
end;
$$;

alter function public.enforce_device_metrics_tenant_consistency()
set search_path = '';

drop trigger if exists trg_device_metrics_tenant_consistency
on public.device_metrics;

create trigger trg_device_metrics_tenant_consistency
before insert on public.device_metrics
for each row
execute function public.enforce_device_metrics_tenant_consistency();

drop trigger if exists trg_device_current_state_tenant_consistency
on public.device_current_state;

create trigger trg_device_current_state_tenant_consistency
before insert or update on public.device_current_state
for each row
execute function public.enforce_device_metrics_tenant_consistency();


-- =====================================================
-- 5. PAYLOAD NORMALIZATION (PURE FUNCTION)
-- =====================================================
-- Maps a raw provider payload to typed metrics, aware of
-- the device category (public.device_categories: sensor,
-- switch, lock, thermostat, ir_controller, gateway, other).
--
-- Providers use different key names for the same concept.
-- This function is intentionally a single, explicit place
-- to extend: as real provider payload shapes are
-- confirmed (Aqara, TTLock, Shelly, ...), add the extra
-- key aliases here rather than in the processing function.
--
-- Pure/deterministic: no table access, safe to test in
-- isolation with `select * from
-- normalize_device_telemetry_payload(...)`.
-- =====================================================

create or replace function public.normalize_device_telemetry_payload(
    p_category_code text,
    p_raw_payload jsonb
)
returns table (
    metric_key text,
    metric_value numeric,
    metric_value_text text,
    unit text
)
language plpgsql
immutable
set search_path = ''
as $$
declare
    v_payload jsonb := coalesce(p_raw_payload, '{}'::jsonb);
    v_raw_temp text;
    v_raw_target_temp text;
    v_raw_humidity text;
    v_raw_battery text;
    v_raw_power text;
    v_raw_energy text;
    v_raw_state text;
    v_raw_online text;
    v_raw_command text;
begin

    -- -----------------------------------------------
    -- Common numeric aliases (apply to any category
    -- that happens to report them)
    -- -----------------------------------------------

    v_raw_temp := coalesce(
        v_payload->>'temperature',
        v_payload->>'temp'
    );

    v_raw_target_temp := coalesce(
        v_payload->>'target_temperature',
        v_payload->>'target_temp',
        v_payload->>'set_point'
    );

    v_raw_humidity := coalesce(
        v_payload->>'humidity',
        v_payload->>'hum'
    );

    v_raw_battery := coalesce(
        v_payload->>'battery_pct',
        v_payload->>'battery_level',
        v_payload->>'battery'
    );

    v_raw_power := coalesce(
        v_payload->>'power_w',
        v_payload->>'power',
        v_payload->>'watt'
    );

    v_raw_energy := coalesce(
        v_payload->>'energy_kwh',
        v_payload->>'energy'
    );

    if v_raw_temp is not null and v_raw_temp ~ '^-?[0-9]+(\.[0-9]+)?$' then
        metric_key := 'temperature';
        metric_value := v_raw_temp::numeric;
        metric_value_text := null;
        unit := '°C';
        return next;
    end if;

    if v_raw_target_temp is not null and v_raw_target_temp ~ '^-?[0-9]+(\.[0-9]+)?$' then
        metric_key := 'target_temperature';
        metric_value := v_raw_target_temp::numeric;
        metric_value_text := null;
        unit := '°C';
        return next;
    end if;

    if v_raw_humidity is not null and v_raw_humidity ~ '^[0-9]+(\.[0-9]+)?$' then
        metric_key := 'humidity';
        metric_value := v_raw_humidity::numeric;
        metric_value_text := null;
        unit := '%';
        return next;
    end if;

    if v_raw_battery is not null and v_raw_battery ~ '^[0-9]+(\.[0-9]+)?$' then
        metric_key := 'battery_pct';
        metric_value := v_raw_battery::numeric;
        metric_value_text := null;
        unit := '%';
        return next;
    end if;

    if v_raw_power is not null and v_raw_power ~ '^[0-9]+(\.[0-9]+)?$' then
        metric_key := 'power_w';
        metric_value := v_raw_power::numeric;
        metric_value_text := null;
        unit := 'W';
        return next;
    end if;

    if v_raw_energy is not null and v_raw_energy ~ '^[0-9]+(\.[0-9]+)?$' then
        metric_key := 'energy_kwh';
        metric_value := v_raw_energy::numeric;
        metric_value_text := null;
        unit := 'kWh';
        return next;
    end if;


    -- -----------------------------------------------
    -- Category-specific state / text metrics
    -- -----------------------------------------------

    case p_category_code

        when 'lock' then

            v_raw_state := coalesce(
                v_payload->>'lock_state',
                v_payload->>'state'
            );

            if v_raw_state is not null then
                metric_key := 'lock_state';
                metric_value := null;
                metric_value_text :=
                    case lower(v_raw_state)
                        when 'locked' then 'locked'
                        when 'lock' then 'locked'
                        when 'unlocked' then 'unlocked'
                        when 'unlock' then 'unlocked'
                        else lower(v_raw_state)
                    end;
                unit := null;
                return next;
            end if;

        when 'switch' then

            v_raw_state := coalesce(
                v_payload->>'switch_state',
                v_payload->>'power_state',
                v_payload->>'state'
            );

            if v_raw_state is not null then
                metric_key := 'switch_state';
                metric_value := null;
                metric_value_text :=
                    case lower(v_raw_state)
                        when 'on' then 'on'
                        when 'true' then 'on'
                        when '1' then 'on'
                        when 'off' then 'off'
                        when 'false' then 'off'
                        when '0' then 'off'
                        else lower(v_raw_state)
                    end;
                unit := null;
                return next;
            end if;

        when 'gateway' then

            v_raw_online := coalesce(
                v_payload->>'online',
                v_payload->>'is_online',
                v_payload->>'status'
            );

            if v_raw_online is not null then
                metric_key := 'online';
                metric_value := null;
                metric_value_text :=
                    case lower(v_raw_online)
                        when 'true' then 'true'
                        when 'online' then 'true'
                        when '1' then 'true'
                        else 'false'
                    end;
                unit := null;
                return next;
            end if;

        when 'ir_controller' then

            v_raw_command := coalesce(
                v_payload->>'last_command',
                v_payload->>'command'
            );

            if v_raw_command is not null then
                metric_key := 'last_command';
                metric_value := null;
                metric_value_text := v_raw_command;
                unit := null;
                return next;
            end if;

        else

            -- 'sensor', 'thermostat', 'other': the common
            -- numeric block above already covers their
            -- known metrics. No extra category-specific
            -- state metric today.
            null;

    end case;

    return;
end;
$$;

alter function public.normalize_device_telemetry_payload(text, jsonb)
set search_path = '';

comment on function public.normalize_device_telemetry_payload(text, jsonb) is
'Pure mapping from a raw provider payload to typed metrics, aware of device_categories.code. Extend here as real provider payload shapes (Aqara, TTLock, Shelly, ...) are confirmed.';


-- =====================================================
-- 6. BATCH PROCESSOR
-- =====================================================
-- Claims a batch of pending raw rows, normalizes them,
-- writes device_metrics + device_current_state, and marks
-- each row processed/failed. Designed to be called
-- repeatedly by an external scheduler (pg_cron or an edge
-- function cron - out of scope here, see
-- platform.scheduled_jobs registration below).
--
-- Idempotent: device_metrics is unique on
-- (telemetry_id, metric_key), so retries are safe for metrics
-- already written. Failed rows are retried with bounded backoff.
-- Current-state updates use observed_at + telemetry_id as a
-- deterministic latest-value ordering.
-- =====================================================

create or replace function public.process_device_telemetry_batch(
    p_batch_size int default 200
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_row record;
    v_metric record;
    v_processed int := 0;
    v_failed int := 0;
begin

    for v_row in

        select
            dtr.id,
            dtr.tenant_id,
            dtr.device_id,
            dtr.raw_payload,
            dtr.observed_at,
            dtr.received_at,
            d.category_code
        from public.device_telemetry_raw dtr
        join public.devices d
          on d.id = dtr.device_id
        where dtr.processing_status in ('pending', 'failed')
          and (
                dtr.next_processing_at is null
                or dtr.next_processing_at <= now()
          )
        order by dtr.received_at
        limit p_batch_size
        for update of dtr skip locked

    loop

        begin

            update public.device_telemetry_raw
            set
                processing_status = 'processing',
                processing_attempts = processing_attempts + 1,
                last_processing_at = now(),
                next_processing_at = null
            where id = v_row.id;


            for v_metric in
                select *
                from public.normalize_device_telemetry_payload(
                    v_row.category_code,
                    v_row.raw_payload
                )
            loop

                insert into public.device_metrics (
                    tenant_id,
                    device_id,
                    telemetry_id,
                    metric_key,
                    metric_value,
                    metric_value_text,
                    unit,
                    observed_at
                )
                values (
                    v_row.tenant_id,
                    v_row.device_id,
                    v_row.id,
                    v_metric.metric_key,
                    v_metric.metric_value,
                    v_metric.metric_value_text,
                    v_metric.unit,
                    coalesce(v_row.observed_at, v_row.received_at)
                )
                on conflict (telemetry_id, metric_key)
                do nothing;


                insert into public.device_current_state (
                    device_id,
                    metric_key,
                    telemetry_id,
                    tenant_id,
                    metric_value,
                    metric_value_text,
                    unit,
                    observed_at
                )
                values (
                    v_row.device_id,
                    v_metric.metric_key,
                    v_row.id,
                    v_row.tenant_id,
                    v_metric.metric_value,
                    v_metric.metric_value_text,
                    v_metric.unit,
                    coalesce(v_row.observed_at, v_row.received_at)
                )
                on conflict (device_id, metric_key)
                do update
                set
                    telemetry_id = excluded.telemetry_id,
                    metric_value = excluded.metric_value,
                    metric_value_text = excluded.metric_value_text,
                    unit = excluded.unit,
                    observed_at = excluded.observed_at,
                    updated_at = now()
                where
                    excluded.observed_at > public.device_current_state.observed_at
                    or (
                        excluded.observed_at = public.device_current_state.observed_at
                        and excluded.telemetry_id > public.device_current_state.telemetry_id
                    );

            end loop;


            update public.device_telemetry_raw
            set
                processing_status = 'processed',
                processing_error = null,
                processed_at = now(),
                next_processing_at = null
            where id = v_row.id;

            v_processed := v_processed + 1;

        exception
            when others then

                update public.device_telemetry_raw
                set
                    processing_status = 'failed',
                    processing_error = sqlerrm,
                    processed_at = now(),
                    next_processing_at = now() + least(
                        interval '1 hour',
                        interval '1 minute' * power(2::numeric, least(processing_attempts, 10))
                    )
                where id = v_row.id;

                v_failed := v_failed + 1;

        end;

    end loop;

    return jsonb_build_object(
        'processed', v_processed,
        'failed', v_failed
    );
end;
$$;

comment on function public.process_device_telemetry_batch(int) is
'Claims pending public.device_telemetry_raw rows and derives public.device_metrics + public.device_current_state via normalize_device_telemetry_payload(). Intended to be invoked repeatedly by an external scheduler.';


-- =====================================================
-- 7. SCHEDULING REGISTRATION (CONTROL PLANE ONLY)
-- =====================================================
-- Registers intent, not the actual trigger mechanism.
-- pg_cron / edge-function scheduling of this handler is
-- infrastructure and out of scope for this migration.
-- =====================================================

insert into platform.scheduled_jobs (
    job_name,
    cron_expression,
    handler,
    is_active,
    metadata
)
values (
    'device_telemetry_processing',
    '* * * * *',
    'process_device_telemetry_batch',
    true,
    jsonb_build_object(
        'batch_size', 200,
        'note', 'Invoke public.process_device_telemetry_batch(200) on this schedule via pg_cron or an edge function cron trigger.'
    )
)
on conflict do nothing;


-- =====================================================
-- 8. SCHEMA MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations ( migration_name, version, rollback_available)
values ('008_device_telemetry_processing', 'REV1', false)
on conflict (migration_name) do nothing;


commit;

-- =====================================================
-- END 008 DEVICE TELEMETRY PROCESSING
--
-- SSOT BOUNDARY:
--
-- 007 = Raw telemetry input SSOT (raw payload immutable)
-- 008 = Derived/normalized telemetry SSOT with an independent
-- retention lifecycle from 007 raw telemetry.
--
-- Read access for Appsmith is added to devices_domain()/
-- devices_api() in 004/018 (see that migration's
-- 'list_device_metrics', 'get_device_current_state' and
-- 'list_tenant_device_current_state' operations) - never
-- direct table access to device_metrics or
-- device_current_state.
-- =====================================================
