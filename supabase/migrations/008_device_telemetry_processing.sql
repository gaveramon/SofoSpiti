-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 008_DEVICE_TELEMETRY_PROCESSING.SQL
-- =====================================================
--
-- Purpose:
-- Normalize raw device telemetry into queryable metrics
-- and maintain the latest state per device and metric.
--
-- Authority:
-- 007_device_telemetry_raw.sql = RAW TELEMETRY SSOT
-- 004_property_device_engine.sql = DEVICE SSOT
--
-- Ownership:
-- 008 owns normalized metrics, current state and
-- processing logic.
--
-- 008 MUST NOT:
-- - Modify raw_payload or raw telemetry identity.
-- - Resolve providers, tenants or devices (006/004).
-- - Make automation decisions (017).
-- - Grant the portal direct table access.
-- - Implement raw telemetry retention (007/pg_partman).
--
-- Raw telemetry is partitioned by received_at.
-- Its primary key is (id, received_at).
--
-- =====================================================

BEGIN;


-- =====================================================
-- 1. PROCESSING BOOKKEEPING ON THE RAW TABLE
-- =====================================================

ALTER TABLE public.device_telemetry_raw
    ADD COLUMN IF NOT EXISTS processing_status text
        NOT NULL DEFAULT 'pending';

ALTER TABLE public.device_telemetry_raw
    ADD COLUMN IF NOT EXISTS processing_error text;

ALTER TABLE public.device_telemetry_raw
    ADD COLUMN IF NOT EXISTS processed_at timestamptz;

ALTER TABLE public.device_telemetry_raw
    ADD COLUMN IF NOT EXISTS processing_attempts integer
        NOT NULL DEFAULT 0;

ALTER TABLE public.device_telemetry_raw
    ADD COLUMN IF NOT EXISTS last_processing_at timestamptz;

ALTER TABLE public.device_telemetry_raw
    ADD COLUMN IF NOT EXISTS next_processing_at timestamptz;


ALTER TABLE public.device_telemetry_raw
    DROP CONSTRAINT IF EXISTS
        chk_device_telemetry_raw_processing_status;

ALTER TABLE public.device_telemetry_raw
    ADD CONSTRAINT chk_device_telemetry_raw_processing_status
    CHECK (
        processing_status IN (
            'pending',
            'processing',
            'processed',
            'failed'
        )
    );


ALTER TABLE public.device_telemetry_raw
    DROP CONSTRAINT IF EXISTS
        chk_device_telemetry_raw_processing_attempts;

ALTER TABLE public.device_telemetry_raw
    ADD CONSTRAINT chk_device_telemetry_raw_processing_attempts
    CHECK (processing_attempts >= 0);


CREATE INDEX IF NOT EXISTS
    idx_device_telemetry_raw_processing_queue
ON public.device_telemetry_raw (
    received_at,
    id
)
WHERE processing_status IN ('pending', 'failed');


COMMENT ON COLUMN public.device_telemetry_raw.processing_status IS
'Processing state maintained by module 008. Does not modify raw_payload or raw telemetry identity.';

COMMENT ON COLUMN public.device_telemetry_raw.processing_attempts IS
'Number of processing attempts started for this telemetry row.';

COMMENT ON COLUMN public.device_telemetry_raw.next_processing_at IS
'Earliest retry time for a failed telemetry row. NULL means immediately eligible for retry.';


-- =====================================================
-- 2. DEVICE METRICS (NORMALIZED TIME SERIES)
-- =====================================================
-- One row per extracted metric value. This is what
-- powers Appsmith line/bar charts over time.
-- =====================================================

CREATE TABLE IF NOT EXISTS public.device_metrics (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id uuid NOT NULL
        REFERENCES public.tenants(id)
        ON DELETE CASCADE,

    device_id uuid NOT NULL
        REFERENCES public.devices(id)
        ON DELETE CASCADE,

    telemetry_id uuid NOT NULL,

    metric_key text NOT NULL,

    metric_value numeric,
    metric_value_text text,

    unit text,

    observed_at timestamptz NOT NULL,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chk_device_metrics_value_present
        CHECK (
            metric_value IS NOT NULL
            OR metric_value_text IS NOT NULL
        ),

    CONSTRAINT uq_device_metrics_telemetry_metric
        UNIQUE (telemetry_id, metric_key)
);


CREATE INDEX IF NOT EXISTS
    idx_device_metrics_device_key_observed
ON public.device_metrics (
    device_id,
    metric_key,
    observed_at DESC
);


CREATE INDEX IF NOT EXISTS
    idx_device_metrics_tenant_observed
ON public.device_metrics (
    tenant_id,
    observed_at DESC
);


COMMENT ON TABLE public.device_metrics IS
'Normalized typed telemetry time series derived from raw telemetry. One row per metric per raw event. Portal access is exclusively through approved RPC operations.';

COMMENT ON COLUMN public.device_metrics.telemetry_id IS
'Source telemetry event ID. Provenance only; intentionally has no FK to the partitioned raw telemetry table.';


-- =====================================================
-- 3. DEVICE CURRENT STATE (LATEST SNAPSHOT)
-- =====================================================
-- One row per device/metric_key, always holding the most
-- recent observed value. This is what powers Appsmith
-- device lists and dashboard tiles without scanning the
-- time series.
-- =====================================================

CREATE TABLE IF NOT EXISTS public.device_current_state (
    device_id uuid NOT NULL
        REFERENCES public.devices(id)
        ON DELETE CASCADE,

    metric_key text NOT NULL,

    tenant_id uuid NOT NULL
        REFERENCES public.tenants(id)
        ON DELETE CASCADE,

    telemetry_id uuid NOT NULL,

    metric_value numeric,
    metric_value_text text,

    unit text,

    observed_at timestamptz NOT NULL,

    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT device_current_state_pkey
        PRIMARY KEY (device_id, metric_key),

    CONSTRAINT chk_device_current_state_value_present
        CHECK (
            metric_value IS NOT NULL
            OR metric_value_text IS NOT NULL
        )
);


CREATE INDEX IF NOT EXISTS
    idx_device_current_state_tenant
ON public.device_current_state (
    tenant_id,
    device_id
);


COMMENT ON TABLE public.device_current_state IS
'Latest known value per device and metric. Updated by process_device_telemetry_batch(). Portal access is exclusively through approved RPC operations.';

COMMENT ON COLUMN public.device_current_state.telemetry_id IS
'Source telemetry event ID for the current value; used as a deterministic tie-breaker when observed_at is equal.';


-- =====================================================
-- 4. DEVICE ↔ TENANT INVARIANT
-- Same integrity boundary as 007, applied to the two
-- new tables.
-- =====================================================

CREATE OR REPLACE FUNCTION
    public.enforce_device_metrics_tenant_consistency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
    v_device_tenant uuid;
BEGIN
    SELECT d.tenant_id
    INTO v_device_tenant
    FROM public.devices AS d
    WHERE d.id = NEW.device_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'device not found';
    END IF;

    IF v_device_tenant IS DISTINCT FROM NEW.tenant_id THEN
        RAISE EXCEPTION
            'metric tenant must match device tenant';
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION
    public.enforce_device_metrics_tenant_consistency()
SET search_path = '';


DROP TRIGGER IF EXISTS
    trg_device_metrics_tenant_consistency
ON public.device_metrics;

CREATE TRIGGER trg_device_metrics_tenant_consistency
BEFORE INSERT OR UPDATE OF device_id, tenant_id
ON public.device_metrics
FOR EACH ROW
EXECUTE FUNCTION
    public.enforce_device_metrics_tenant_consistency();


DROP TRIGGER IF EXISTS
    trg_device_current_state_tenant_consistency
ON public.device_current_state;

CREATE TRIGGER trg_device_current_state_tenant_consistency
BEFORE INSERT OR UPDATE OF device_id, tenant_id
ON public.device_current_state
FOR EACH ROW
EXECUTE FUNCTION
    public.enforce_device_metrics_tenant_consistency();


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

CREATE OR REPLACE FUNCTION
    public.normalize_device_telemetry_payload(
        p_category_code text,
        p_raw_payload jsonb
    )
RETURNS TABLE (
    metric_key text,
    metric_value numeric,
    metric_value_text text,
    unit text
)
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
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
BEGIN

    v_raw_temp := coalesce(
        v_payload ->> 'temperature',
        v_payload ->> 'temp'
    );

    v_raw_target_temp := coalesce(
        v_payload ->> 'target_temperature',
        v_payload ->> 'target_temp',
        v_payload ->> 'set_point'
    );

    v_raw_humidity := coalesce(
        v_payload ->> 'humidity',
        v_payload ->> 'hum'
    );

    v_raw_battery := coalesce(
        v_payload ->> 'battery_pct',
        v_payload ->> 'battery_level',
        v_payload ->> 'battery'
    );

    v_raw_power := coalesce(
        v_payload ->> 'power_w',
        v_payload ->> 'power',
        v_payload ->> 'watt'
    );

    v_raw_energy := coalesce(
        v_payload ->> 'energy_kwh',
        v_payload ->> 'energy'
    );


    IF v_raw_temp IS NOT NULL
       AND v_raw_temp ~ '^-?[0-9]+(\.[0-9]+)?$'
    THEN
        metric_key := 'temperature';
        metric_value := v_raw_temp::numeric;
        metric_value_text := NULL;
        unit := '°C';
        RETURN NEXT;
    END IF;


    IF v_raw_target_temp IS NOT NULL
       AND v_raw_target_temp ~ '^-?[0-9]+(\.[0-9]+)?$'
    THEN
        metric_key := 'target_temperature';
        metric_value := v_raw_target_temp::numeric;
        metric_value_text := NULL;
        unit := '°C';
        RETURN NEXT;
    END IF;


    IF v_raw_humidity IS NOT NULL
       AND v_raw_humidity ~ '^[0-9]+(\.[0-9]+)?$'
    THEN
        metric_key := 'humidity';
        metric_value := v_raw_humidity::numeric;
        metric_value_text := NULL;
        unit := '%';
        RETURN NEXT;
    END IF;


    IF v_raw_battery IS NOT NULL
       AND v_raw_battery ~ '^[0-9]+(\.[0-9]+)?$'
    THEN
        metric_key := 'battery_pct';
        metric_value := v_raw_battery::numeric;
        metric_value_text := NULL;
        unit := '%';
        RETURN NEXT;
    END IF;


    IF v_raw_power IS NOT NULL
       AND v_raw_power ~ '^[0-9]+(\.[0-9]+)?$'
    THEN
        metric_key := 'power_w';
        metric_value := v_raw_power::numeric;
        metric_value_text := NULL;
        unit := 'W';
        RETURN NEXT;
    END IF;


    IF v_raw_energy IS NOT NULL
       AND v_raw_energy ~ '^[0-9]+(\.[0-9]+)?$'
    THEN
        metric_key := 'energy_kwh';
        metric_value := v_raw_energy::numeric;
        metric_value_text := NULL;
        unit := 'kWh';
        RETURN NEXT;
    END IF;


    CASE p_category_code

        WHEN 'lock' THEN

            v_raw_state := coalesce(
                v_payload ->> 'lock_state',
                v_payload ->> 'state'
            );

            IF v_raw_state IS NOT NULL THEN
                metric_key := 'lock_state';
                metric_value := NULL;

                metric_value_text :=
                    CASE lower(v_raw_state)
                        WHEN 'locked' THEN 'locked'
                        WHEN 'lock' THEN 'locked'
                        WHEN 'unlocked' THEN 'unlocked'
                        WHEN 'unlock' THEN 'unlocked'
                        ELSE lower(v_raw_state)
                    END;

                unit := NULL;
                RETURN NEXT;
            END IF;


        WHEN 'switch' THEN

            v_raw_state := coalesce(
                v_payload ->> 'switch_state',
                v_payload ->> 'power_state',
                v_payload ->> 'state'
            );

            IF v_raw_state IS NOT NULL THEN
                metric_key := 'switch_state';
                metric_value := NULL;

                metric_value_text :=
                    CASE lower(v_raw_state)
                        WHEN 'on' THEN 'on'
                        WHEN 'true' THEN 'on'
                        WHEN '1' THEN 'on'
                        WHEN 'off' THEN 'off'
                        WHEN 'false' THEN 'off'
                        WHEN '0' THEN 'off'
                        ELSE lower(v_raw_state)
                    END;

                unit := NULL;
                RETURN NEXT;
            END IF;


        WHEN 'gateway' THEN

            v_raw_online := coalesce(
                v_payload ->> 'online',
                v_payload ->> 'is_online',
                v_payload ->> 'status'
            );

            IF v_raw_online IS NOT NULL THEN
                metric_key := 'online';
                metric_value := NULL;

                metric_value_text :=
                    CASE lower(v_raw_online)
                        WHEN 'true' THEN 'true'
                        WHEN 'online' THEN 'true'
                        WHEN '1' THEN 'true'
                        ELSE 'false'
                    END;

                unit := NULL;
                RETURN NEXT;
            END IF;


        WHEN 'ir_controller' THEN

            v_raw_command := coalesce(
                v_payload ->> 'last_command',
                v_payload ->> 'command'
            );

            IF v_raw_command IS NOT NULL THEN
                metric_key := 'last_command';
                metric_value := NULL;
                metric_value_text := v_raw_command;
                unit := NULL;
                RETURN NEXT;
            END IF;


        ELSE
            NULL;

    END CASE;

    RETURN;
END;
$$;


ALTER FUNCTION
    public.normalize_device_telemetry_payload(text, jsonb)
SET search_path = '';


COMMENT ON FUNCTION
    public.normalize_device_telemetry_payload(text, jsonb)
IS
'Pure mapping from raw provider payloads to typed metrics, aware of device category. Extend when actual provider payload shapes are confirmed.';


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

CREATE OR REPLACE FUNCTION
    public.process_device_telemetry_batch(
        p_batch_size int DEFAULT 200
    )
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_row record;
    v_metric record;

    v_processed integer := 0;
    v_failed integer := 0;
    v_batch_size integer;
BEGIN

    v_batch_size := greatest(
        coalesce(p_batch_size, 200),
        1
    );


    FOR v_row IN
        SELECT
            dtr.id,
            dtr.tenant_id,
            dtr.device_id,
            dtr.raw_payload,
            dtr.observed_at,
            dtr.received_at,
            dtr.processing_attempts,
            d.category_code
        FROM public.device_telemetry_raw AS dtr
        JOIN public.devices AS d
          ON d.id = dtr.device_id
        WHERE
            dtr.processing_status = 'pending'
            OR (
                dtr.processing_status = 'failed'
                AND (
                    dtr.next_processing_at IS NULL
                    OR dtr.next_processing_at <= now()
                )
            )
        ORDER BY dtr.received_at, dtr.id
        LIMIT v_batch_size
        FOR UPDATE OF dtr SKIP LOCKED

    LOOP

        UPDATE public.device_telemetry_raw
        SET
            processing_status = 'processing',
            processing_attempts = processing_attempts + 1,
            last_processing_at = now(),
            processing_error = NULL,
            next_processing_at = NULL
        WHERE id = v_row.id
          AND received_at = v_row.received_at;


        BEGIN

            FOR v_metric IN
                SELECT *
                FROM public.normalize_device_telemetry_payload(
                    v_row.category_code,
                    v_row.raw_payload
                )
            LOOP

                INSERT INTO public.device_metrics (
                    tenant_id,
                    device_id,
                    telemetry_id,
                    metric_key,
                    metric_value,
                    metric_value_text,
                    unit,
                    observed_at
                )
                VALUES (
                    v_row.tenant_id,
                    v_row.device_id,
                    v_row.id,
                    v_metric.metric_key,
                    v_metric.metric_value,
                    v_metric.metric_value_text,
                    v_metric.unit,
                    coalesce(
                        v_row.observed_at,
                        v_row.received_at
                    )
                )
                ON CONFLICT (
                    telemetry_id,
                    metric_key
                )
                DO NOTHING;


                INSERT INTO public.device_current_state (
                    device_id,
                    metric_key,
                    tenant_id,
                    telemetry_id,
                    metric_value,
                    metric_value_text,
                    unit,
                    observed_at
                )
                VALUES (
                    v_row.device_id,
                    v_metric.metric_key,
                    v_row.tenant_id,
                    v_row.id,
                    v_metric.metric_value,
                    v_metric.metric_value_text,
                    v_metric.unit,
                    coalesce(
                        v_row.observed_at,
                        v_row.received_at
                    )
                )
                ON CONFLICT (device_id, metric_key)
                DO UPDATE SET
                    tenant_id = EXCLUDED.tenant_id,
                    telemetry_id = EXCLUDED.telemetry_id,
                    metric_value = EXCLUDED.metric_value,
                    metric_value_text = EXCLUDED.metric_value_text,
                    unit = EXCLUDED.unit,
                    observed_at = EXCLUDED.observed_at,
                    updated_at = now()
                WHERE
                    EXCLUDED.observed_at
                        > public.device_current_state.observed_at
                    OR (
                        EXCLUDED.observed_at
                            = public.device_current_state.observed_at
                        AND EXCLUDED.telemetry_id
                            > public.device_current_state.telemetry_id
                    );

            END LOOP;


            UPDATE public.device_telemetry_raw
            SET
                processing_status = 'processed',
                processing_error = NULL,
                processed_at = now(),
                next_processing_at = NULL
            WHERE id = v_row.id
              AND received_at = v_row.received_at;

            v_processed := v_processed + 1;


        EXCEPTION
            WHEN OTHERS THEN

                UPDATE public.device_telemetry_raw
                SET
                    processing_status = 'failed',
                    processing_error = SQLERRM,
                    processed_at = NULL,
                    next_processing_at =
                        now() + make_interval(
                            mins => least(
                                1440,
                                power(
                                    2::numeric,
                                    least(
                                        processing_attempts - 1,
                                        11
                                    )
                                )::integer
                            )
                        )
                WHERE id = v_row.id
                  AND received_at = v_row.received_at;

                v_failed := v_failed + 1;

        END;

    END LOOP;


    RETURN jsonb_build_object(
        'processed', v_processed,
        'failed', v_failed
    );
END;
$$;


ALTER FUNCTION
    public.process_device_telemetry_batch(integer)
SET search_path = '';


COMMENT ON FUNCTION
    public.process_device_telemetry_batch(integer)
IS
'Claims eligible raw telemetry rows and derives device_metrics and device_current_state. Uses SKIP LOCKED for concurrent workers, idempotent metric inserts and deterministic current-state ordering.';


-- =====================================================
-- 7. FUNCTION PRIVILEGES
-- =====================================================
-- Table grants and RLS are handled by the dedicated
-- security migrations. The worker function is executable
-- by service_role only.
-- =====================================================

REVOKE ALL ON FUNCTION
    public.normalize_device_telemetry_payload(text, jsonb)
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION
    public.process_device_telemetry_batch(integer)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
    public.process_device_telemetry_batch(integer)
TO service_role;


-- =====================================================
-- Registers intent, not the actual trigger mechanism.
-- pg_cron / edge-function scheduling of this handler is
-- infrastructure and out of scope for this migration.
-- =====================================================

INSERT INTO platform.scheduled_jobs (
    job_name,
    cron_expression,
    handler,
    is_active,
    metadata
)
VALUES (
    'device_telemetry_processing',
    '* * * * *',
    'process_device_telemetry_batch',
    true,
    jsonb_build_object(
        'batch_size', 200,
        'note',
        'Invoke public.process_device_telemetry_batch(200) every minute using the configured scheduler.'
    )
)
ON CONFLICT DO NOTHING;


-- =====================================================
-- 8. SCHEMA MIGRATION REGISTRATION
-- =====================================================

INSERT INTO platform.schema_migrations (
    migration_name,
    version,
    rollback_available
)
VALUES (
    '008_device_telemetry_processing',
    'REV1',
    false
)
ON CONFLICT (migration_name) DO NOTHING;


COMMIT;


-- =====================================================
-- END 008 DEVICE TELEMETRY PROCESSING
-- =====================================================
--
-- SSOT BOUNDARY:
--
-- 007 = Raw telemetry input SSOT (immutable payload)
-- 008 = Derived normalized telemetry SSOT
--
-- Portal access to derived telemetry is exclusively
-- through the approved devices_domain()/devices_api()
-- RPC operations defined by the relevant API migrations.
--
-- =====================================================