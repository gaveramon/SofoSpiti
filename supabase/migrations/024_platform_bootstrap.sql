-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 024_PLATFORM_BOOTSTRAP.SQL
-- =====================================================
--
-- Mandatory production gate — runs after full domain stack (002–023)
-- and before the verification gate 025.
-- =====================================================
--
-- Responsibilities:
-- 1. Post-domain column/type binds (001 SSOT → 000 platform columns)
-- 2. Platform notification delivery workers (009 domain objects)
-- 3. Commerce ↔ platform cross-schema binds (012/006 → 000)
-- 4. SCHEDULER (the ONE place where pg_cron is wired):
--      registry seeds, platform.run_job(), platform.sync_cron_schedules(),
--      platform.invoke_edge_function(), platform.cleanup_job_executions()
-- 5. Authenticated grants + default privileges for post-024 migrations
-- 6. FORCE RLS + post-bootstrap RLS verification
--
-- RLS precedence:
-- - Domain modules (002–016) MUST define explicit policies where role gates differ
-- - No generic safety-net RLS is applied here (see section 10, removed)
--
-- -----------------------------------------------------
-- SCHEDULER DESIGN (formerly 027_cron_engine)
-- -----------------------------------------------------
-- 000 provides the TABLES and WORKER FUNCTIONS only:
--   platform.scheduled_jobs       control-plane registry (unique job_name)
--   platform.job_executions       execution history
--   platform.log_job_execution()  history writer
--   platform.run_platform_cron_tick(), run_platform_daily_maintenance(),
--   platform.process_*_batch()    workers
--
-- 024 provides the ONLY route from registry to pg_cron:
--
--   platform.scheduled_jobs (active row)
--        |  platform.sync_cron_schedules()
--        v
--   pg_cron job 'job:<job_name>'
--        |  select platform.run_job('<job_name>')
--        v
--   handler resolved in the CASE of platform.run_job()
--        |
--        v
--   platform.job_executions (success | failed) + scheduled_jobs.last_run
--
-- ADDING A JOB:
--   1. insert a row in platform.scheduled_jobs
--   2. add its handler to the CASE in platform.run_job()
--   3. select platform.sync_cron_schedules();
-- No dynamic SQL is used. An active row without a handler fails
-- (and is logged) on its first run: "handler ... is not implemented".
--
-- ENABLING / DISABLING A JOB:
--   update platform.scheduled_jobs set is_active = ... where job_name = ...;
--   select platform.sync_cron_schedules();
--   Re-running this migration never changes is_active.
--
-- pg_cron runs in UTC.
-- =====================================================


-- =====================================================
-- 1. POST-DOMAIN TYPE BINDS (001 SSOT → 000 PLATFORM)
-- =====================================================

select platform.bind_operation_context_type_column();


-- =====================================================
-- 2. PLATFORM NOTIFICATION DELIVERY WORKERS
-- Domain dependency: 009 Operations Engine
--
-- These functions are platform execution workers.
-- The notification domain objects are owned by module 009.
-- =====================================================

create or replace function platform.complete_notification_delivery(
    p_queue_id uuid,
    p_success boolean,
    p_error jsonb default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_row public.notification_queue;
    v_status public.notification_delivery_status;
begin
    select * into v_row
    from public.notification_queue nq
    where nq.id = p_queue_id
    for update;

    if not found then
        raise exception 'notification queue item % not found', p_queue_id;
    end if;

    if p_success then
        v_status := 'sent'::public.notification_delivery_status;
        update public.notification_queue set
            status = v_status,
            last_error = null,
            updated_at = now()
        where id = p_queue_id;

        insert into public.notification_history (
            tenant_id, queue_id, channel, recipient, status, subject, body, payload, error
        )
        values (
            v_row.tenant_id, v_row.id, v_row.channel, v_row.recipient, v_status,
            v_row.subject, v_row.body, v_row.payload, null
        );
    else
        if v_row.attempt_count >= v_row.max_attempts then
            v_status := 'failed'::public.notification_delivery_status;
            update public.notification_queue set
                status = v_status,
                last_error = coalesce(p_error, '{}'::jsonb),
                updated_at = now()
            where id = p_queue_id;

            insert into public.notification_history (
                tenant_id, queue_id, channel, recipient, status, subject, body, payload, error
            )
            values (
                v_row.tenant_id, v_row.id, v_row.channel, v_row.recipient, v_status,
                v_row.subject, v_row.body, v_row.payload, coalesce(p_error, '{}'::jsonb)
            );
        else
            update public.notification_queue set
                status = 'queued'::public.notification_delivery_status,
                last_error = coalesce(p_error, '{}'::jsonb),
                scheduled_at = now() + (interval '1 minute' * v_row.attempt_count),
                updated_at = now()
            where id = p_queue_id;
        end if;
    end if;
end;
$$;


create or replace function platform.fetch_notification_batch(p_limit int default 50)
returns setof public.notification_queue
language plpgsql
security definer
set search_path = ''
as $$
begin
    return query
    with picked as (
        select nq.id
        from public.notification_queue nq
        where nq.status = 'queued'::public.notification_delivery_status
          and nq.scheduled_at <= now()
        order by nq.scheduled_at
        for update skip locked
        limit greatest(p_limit, 1)
    )
    update public.notification_queue nq set
        status = 'processing'::public.notification_delivery_status,
        attempt_count = nq.attempt_count + 1,
        updated_at = now()
    from picked
    where nq.id = picked.id
    returning nq.*;
end;
$$;


-- =====================================================
-- 3. COMMERCE ↔ PLATFORM TYPE BINDS
-- Cross-schema binds: 011/006 → 000
-- =====================================================

do $$
begin
    alter table platform.payment_intents
        alter column status drop default;

    alter table platform.payment_intents
        alter column status type payment_status using status::payment_status;

    alter table platform.payment_intents
        alter column status set default 'pending'::payment_status;

    alter table platform.payment_events
        alter column old_status type payment_status using old_status::payment_status;

    alter table platform.payment_events
        alter column new_status type payment_status using new_status::payment_status;
exception
    when undefined_table then null;
    when undefined_object then null;
end $$;


-- =====================================================
-- 3B. COMMERCE ↔ PLATFORM FOREIGN KEY BINDS
-- =====================================================

do $$
begin
    alter table platform.payment_intents
        add constraint fk_payment_intents_provider_code
        foreign key (provider) references public.integration_providers(code);
exception
    when duplicate_object then null;
    when undefined_table then null;
end $$;


do $$
begin
    alter table platform.payment_provider_refs
        add constraint fk_payment_provider_refs_provider_code
        foreign key (provider) references public.integration_providers(code);
exception
    when duplicate_object then null;
    when undefined_table then null;
end $$;


do $$
begin
    alter table platform.payment_intents
        add constraint chk_payment_intents_target_type
        check (target_type in ('subscription', 'proposal', 'invoice'));
exception
    when duplicate_object then null;
    when undefined_table then null;
end $$;


do $$
begin
    alter table platform.payment_intents
        add constraint fk_payment_intents_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
    when undefined_table then null;
end $$;


do $$
begin
    alter table platform.webhook_provider_tenant_map
        add constraint fk_webhook_provider_tenant_map_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
    when undefined_table then null;
end $$;


-- =====================================================
-- 3C. PAYMENT TARGET TENANT TRIGGER PREPARATION
-- =====================================================

drop trigger if exists trg_payment_intents_target_tenant on platform.payment_intents;


create trigger trg_payment_intents_target_tenant
before insert or update of tenant_id, target_type, target_id on platform.payment_intents
for each row execute function platform.enforce_payment_intent_target_tenant();


-- =====================================================
-- 4. SCHEDULER
-- =====================================================

-- -----------------------------------------------------
-- 4.0 PRECONDITIONS
-- -----------------------------------------------------

do $$
declare
    v_sig text;
begin
    if to_regclass('platform.scheduled_jobs') is null
       or to_regclass('platform.job_executions') is null
       or to_regclass('platform.schema_migrations') is null then
        raise exception
            '024 scheduler requires platform.scheduled_jobs, platform.job_executions and platform.schema_migrations from 000';
    end if;

    if not exists (
        select 1
        from pg_indexes i
        where i.schemaname = 'platform'
          and i.tablename = 'scheduled_jobs'
          and i.indexname = 'uq_scheduled_jobs_job_name'
    ) then
        raise exception
            '024 scheduler requires unique index uq_scheduled_jobs_job_name from 000';
    end if;

    foreach v_sig in array array[
        -- 000 platform
        'platform.log_job_execution(uuid,text,integer,text,uuid,integer)',
        'platform.dispatch_http_request(text,text,jsonb,jsonb,integer)',
        'platform.get_vault_secret(text)',
        'platform.run_platform_cron_tick()',
        'platform.run_platform_daily_maintenance()',
        'platform.process_external_webhook_batch(integer)',
        'platform.process_integration_queue_batch(integer)',
        'platform.process_device_command_batch(integer,text)',
        'platform.process_notification_batch(integer)',
        'platform.process_retry_task_batch(integer)',
        'platform.process_shipment_dispatch_batch(integer)',
        -- 002 / 012 commerce jobs
        'platform.expire_cancelled_subscriptions()',
        'platform.expire_trial_subscriptions()',
        'platform.mark_overdue_invoices()',
        'platform.epsilon_flag_stuck(integer)',
        -- 008 telemetry
        'public.process_device_telemetry_batch(integer)'
    ]
    loop
        if to_regprocedure(v_sig) is null then
            raise exception '024 scheduler requires %', v_sig;
        end if;
    end loop;

    -- pg_partman maintenance (function form: a procedure that COMMITs
    -- cannot be called from inside platform.run_job()).
    if not exists (
        select 1
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'partman'
          and p.proname = 'run_maintenance'
          and p.prokind = 'f'
    ) then
        raise exception
            '024 scheduler requires partman.run_maintenance() (pg_partman, see 000/007)';
    end if;
end;
$$;


-- -----------------------------------------------------
-- 4.1 REGISTRY SEEDS
-- -----------------------------------------------------
--
-- handler = abstract reference resolved in platform.run_job().
-- Re-running updates schedule/handler/metadata but NEVER
-- is_active, so a job disabled by an operator stays disabled.
--
-- The registry names of the two platform jobs are unchanged;
-- their pg_cron names are now 'job:platform-cron-tick' and
-- 'job:platform-daily-maintenance'.
-- -----------------------------------------------------

insert into platform.scheduled_jobs (
    job_name,
    cron_expression,
    handler,
    is_active,
    metadata
)
values

    -- ---------------- platform ----------------

    -- Execution watchdog (device commands stuck in 'processing').
    (
        'platform-cron-tick',
        '* * * * *',
        'platform.run_platform_cron_tick',
        true,
        '{"description": "Execution watchdog"}'::jsonb
    ),

    -- Log partitions + log retention purge + service activation sync.
    (
        'platform-daily-maintenance',
        '15 2 * * *',
        'platform.run_platform_daily_maintenance',
        true,
        '{"description": "Partition ensure + log retention purge + service activation sync"}'::jsonb
    ),

    -- Retention of platform.job_executions and cron.job_run_details.
    (
        'cleanup_job_executions',
        '45 2 * * *',
        'platform.cleanup_job_executions',
        true,
        '{"retention_days": 30}'::jsonb
    ),

    -- pg_partman: creates the next daily partitions of
    -- public.device_telemetry_raw and drops partitions older than
    -- the 7 day retention configured in 007. Without this job the
    -- premade partitions (7 days) run out and raw telemetry inserts
    -- fail. pg_partman's background worker is not assumed.
    (
        'partman_maintenance',
        '5 * * * *',
        'partman.run_maintenance',
        true,
        '{}'::jsonb
    ),

    -- ---------------- ingestion pipeline ----------------

    -- Inbound vendor webhooks (Aqara, Shelly, TTLock, ...) -> 006 router
    -- -> raw telemetry (007). Pure SQL, safe on an empty queue.
    (
        'external_webhook_batch',
        '* * * * *',
        'platform.process_external_webhook_batch',
        true,
        '{"batch_limit": 50}'::jsonb
    ),

    -- Raw telemetry (007) -> device_metrics + device_current_state (008).
    -- This row is also seeded by 008; this upsert only normalises the
    -- handler name.
    (
        'device_telemetry_processing',
        '* * * * *',
        'telemetry.process_device_telemetry_batch',
        true,
        '{"batch_size": 200}'::jsonb
    ),

    -- Outbound HTTP deliveries enqueued by platform.enqueue_http_delivery().
    (
        'integration_queue_batch',
        '* * * * *',
        'platform.process_integration_queue_batch',
        true,
        '{"batch_limit": 50}'::jsonb
    ),

    -- ---------------- commerce ----------------

    -- Cancellations per end of month (002 section 14C).
    (
        'expire_cancelled_subscriptions',
        '0 * * * *',
        'commerce.expire_cancelled_subscriptions',
        true,
        '{}'::jsonb
    ),

    -- trial -> trial_expired when current_period_end has passed
    -- (002 section 014B).
    (
        'expire_trial_subscriptions',
        '15 * * * *',
        'commerce.expire_trial_subscriptions',
        true,
        '{}'::jsonb
    ),

    -- Epsilon submissions stuck in_flight -> needs_review (012 27A).
    (
        'epsilon_flag_stuck',
        '*/5 * * * *',
        'commerce.epsilon_flag_stuck',
        true,
        '{"stuck_minutes": 10}'::jsonb
    ),

    -- Epsilon outbox worker: only called when there is work.
    (
        'epsilon_gateway_process',
        '* * * * *',
        'edge.invoke',
        true,
        '{
            "function": "epsilon_gateway",
            "payload": {"action": "process"},
            "only_if": "pending_epsilon_submissions"
        }'::jsonb
    ),

    -- Epsilon status poll (UID / MARK / rejection).
    (
        'epsilon_gateway_poll',
        '*/10 * * * *',
        'edge.invoke',
        true,
        '{
            "function": "epsilon_gateway",
            "payload": {"action": "poll"},
            "only_if": "submitted_epsilon_invoices"
        }'::jsonb
    ),

    -- issued/sent invoices past due_at -> overdue (012 section 19C).
    (
        'mark_overdue_invoices',
        '30 2 * * *',
        'commerce.mark_overdue_invoices',
        true,
        '{}'::jsonb
    ),

    -- NOT BUILT YET: the invoice generator does not exist.
    -- Enable only after the handler is implemented in run_job().
    (
        'generate_monthly_invoices',
        '0 3 1 * *',
        'commerce.generate_monthly_invoices',
        false,
        '{"note": "generator not implemented"}'::jsonb
    ),

    -- ---------------- workers that need an edge function first ----------------
    --
    -- Handlers exist in run_job(), but the platform SQL workers cannot
    -- complete the work on their own, so the rows are INACTIVE:
    --
    --  device_command_batch   needs payload.url; get_device_command_context()
    --                         returns no dispatch_url -> every command would
    --                         retry and end in the DLQ. Needs a provider
    --                         adapter (Aqara / Shelly / TTLock) in an edge
    --                         function.
    --  notification_batch     needs payload.url; e-mail / SMS rows have none
    --                         -> every notification would be marked failed.
    --                         Needs a mail/SMS edge function.
    --  shipment_dispatch_batch marks the shipment 'dispatched' even when no
    --                         carrier call was made (payload.url is optional).
    --  retry_task_batch       needs payload.url; also see the note on
    --                         process_retry_tasks() before enabling.
    --
    -- Activate one only after its edge function / fix exists:
    --   update platform.scheduled_jobs set is_active = true where job_name = '...';
    --   select platform.sync_cron_schedules();

    (
        'device_command_batch',
        '* * * * *',
        'platform.process_device_command_batch',
        false,
        '{"batch_limit": 50, "worker_id": "pg_cron", "note": "needs provider adapter edge function"}'::jsonb
    ),
    (
        'notification_batch',
        '* * * * *',
        'platform.process_notification_batch',
        false,
        '{"batch_limit": 50, "note": "needs mail/SMS edge function"}'::jsonb
    ),
    (
        'shipment_dispatch_batch',
        '*/5 * * * *',
        'platform.process_shipment_dispatch_batch',
        false,
        '{"batch_limit": 50, "note": "needs carrier edge function"}'::jsonb
    ),
    (
        'retry_task_batch',
        '*/5 * * * *',
        'platform.process_retry_task_batch',
        false,
        '{"batch_limit": 50, "note": "needs payload.url on retry tasks"}'::jsonb
    )

on conflict (job_name) do update
set
    cron_expression = excluded.cron_expression,
    handler = excluded.handler,
    metadata = excluded.metadata;


-- -----------------------------------------------------
-- 4.2 EDGE FUNCTION INVOCATION (pg_net + Vault)
-- -----------------------------------------------------
--
-- Vault secrets expected:
--   project_url        e.g. https://<ref>.supabase.co
--   service_role_key
--
-- pg_net is asynchronous: success only means the request was
-- queued. The edge function reports its own result.
-- -----------------------------------------------------

create or replace function platform.invoke_edge_function(
    p_function text,
    p_payload jsonb default '{}'::jsonb,
    p_only_if text default null
)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_url text;
    v_key text;
    v_request_id bigint;
    v_has_work boolean;
begin

    if p_function is null or p_function !~ '^[a-z0-9_-]+$' then
        raise exception 'invalid edge function name: %', p_function;
    end if;

    -- Skip the call when there is nothing to do.
    if p_only_if is not null then

        v_has_work := case p_only_if
            when 'pending_epsilon_submissions' then
                exists (
                    select 1
                    from public.epsilon_submissions es
                    where es.status = 'pending'
                      and es.next_attempt_at <= now()
                )
            when 'submitted_epsilon_invoices' then
                exists (
                    select 1
                    from public.invoices i
                    where i.epsilon_status = 'submitted'
                )
            else null
        end;

        if v_has_work is null then
            raise exception 'unknown only_if condition: %', p_only_if;
        end if;

        if not v_has_work then
            return 0;
        end if;

    end if;

    v_url := platform.get_vault_secret('project_url');
    v_key := platform.get_vault_secret('service_role_key');

    if v_url is null or v_key is null then
        raise exception
            'vault secrets project_url and service_role_key are required';
    end if;

    v_request_id := platform.dispatch_http_request(
        rtrim(v_url, '/') || '/functions/v1/' || p_function,
        'POST',
        jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_key
        ),
        coalesce(p_payload, '{}'::jsonb),
        10000
    );

    if v_request_id is null then
        raise exception 'pg_net is not available';
    end if;

    return 1;

end;
$$;


-- -----------------------------------------------------
-- 4.3 RETENTION
-- -----------------------------------------------------

create or replace function platform.cleanup_job_executions(
    p_retention_days int default 30
)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_n int;
    v_days int := greatest(coalesce(p_retention_days, 30), 1);
begin

    delete from platform.job_executions je
    where je.started_at < now() - make_interval(days => v_days);

    get diagnostics v_n = row_count;

    -- pg_cron keeps its own run history; keep it short.
    if exists (select 1 from pg_extension where extname = 'pg_cron') then
        delete from cron.job_run_details d
        where d.end_time < now() - make_interval(days => least(v_days, 7));
    end if;

    return v_n;

end;
$$;


-- -----------------------------------------------------
-- 4.4 RUN A JOB
-- -----------------------------------------------------
--
-- Called by pg_cron as: select platform.run_job('<job_name>');
--
--   - an overlapping run of the same job is skipped silently
--   - the work runs in a sub-transaction: a failure rolls back
--     the job's own changes but is still logged
--   - every run is written to platform.job_executions
--     (status success | failed) and scheduled_jobs.last_run
--   - batch workers that return {processed, failed} report the
--     processed count in the result; when items failed, the
--     job_executions.error column carries "<n> item(s) failed"
--     (status stays 'success': the job itself ran)
-- -----------------------------------------------------

create or replace function platform.run_job(p_job_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_job platform.scheduled_jobs%rowtype;
    v_corr uuid := gen_random_uuid();
    v_started timestamptz := clock_timestamp();
    v_ms int;
    v_rows int := 0;
    v_timeout int;
    v_res jsonb;
    v_warn text;
    v_limit int;
begin

    select *
    into v_job
    from platform.scheduled_jobs sj
    where sj.job_name = p_job_name;

    if not found then
        raise exception 'unknown job: %', p_job_name;
    end if;

    if not coalesce(v_job.is_active, false) then
        return jsonb_build_object('status', 'inactive');
    end if;

    -- Held until the end of this transaction.
    if not pg_try_advisory_xact_lock(
        hashtextextended('platform.run_job:' || p_job_name, 0)
    ) then
        return jsonb_build_object('status', 'skipped');
    end if;

    v_timeout := coalesce(
        nullif(v_job.metadata->>'timeout_seconds', '')::int,
        120
    );

    perform set_config(
        'statement_timeout',
        (v_timeout * 1000)::text,
        true
    );

    v_limit := coalesce(
        nullif(v_job.metadata->>'batch_limit', '')::int,
        50
    );

    begin

        case v_job.handler

            -- ---------------- platform ----------------

            when 'platform.run_platform_cron_tick' then
                perform platform.run_platform_cron_tick();

            when 'platform.run_platform_daily_maintenance' then
                perform platform.run_platform_daily_maintenance();

            when 'platform.cleanup_job_executions' then
                v_rows := platform.cleanup_job_executions(
                    coalesce(
                        nullif(v_job.metadata->>'retention_days', '')::int,
                        30
                    )
                );

            when 'partman.run_maintenance' then
                perform partman.run_maintenance(
                    p_analyze := false,
                    p_jobmon := false
                );

            -- ---------------- ingestion pipeline ----------------

            when 'platform.process_external_webhook_batch' then
                v_res := platform.process_external_webhook_batch(v_limit);

            when 'telemetry.process_device_telemetry_batch' then
                v_res := public.process_device_telemetry_batch(
                    coalesce(
                        nullif(v_job.metadata->>'batch_size', '')::int,
                        200
                    )
                );

            when 'platform.process_integration_queue_batch' then
                v_res := platform.process_integration_queue_batch(v_limit);

            -- ---------------- workers (rows inactive until their edge function exists) ----------------

            when 'platform.process_device_command_batch' then
                v_res := platform.process_device_command_batch(
                    v_limit,
                    coalesce(v_job.metadata->>'worker_id', 'pg_cron')
                );

            when 'platform.process_notification_batch' then
                v_res := platform.process_notification_batch(v_limit);

            when 'platform.process_shipment_dispatch_batch' then
                v_res := platform.process_shipment_dispatch_batch(v_limit);

            when 'platform.process_retry_task_batch' then
                v_res := platform.process_retry_task_batch(v_limit);

            -- ---------------- commerce ----------------

            when 'commerce.expire_cancelled_subscriptions' then
                v_rows := platform.expire_cancelled_subscriptions();

            when 'commerce.expire_trial_subscriptions' then
                -- 002 returns (subscriptions_expired, seconds_elapsed).
                select t.subscriptions_expired::int
                into v_rows
                from platform.expire_trial_subscriptions() t;

            when 'commerce.mark_overdue_invoices' then
                v_rows := platform.mark_overdue_invoices();

            when 'commerce.epsilon_flag_stuck' then
                v_rows := platform.epsilon_flag_stuck(
                    coalesce(
                        nullif(v_job.metadata->>'stuck_minutes', '')::int,
                        10
                    )
                );

            -- ---------------- edge functions ----------------

            when 'edge.invoke' then
                v_rows := platform.invoke_edge_function(
                    v_job.metadata->>'function',
                    coalesce(v_job.metadata->'payload', '{}'::jsonb),
                    v_job.metadata->>'only_if'
                );

            else
                raise exception
                    'handler % is not implemented', v_job.handler;

        end case;

        -- Batch workers report {processed, failed}.
        if v_res is not null then
            v_rows := coalesce((v_res->>'processed')::int, 0);

            if coalesce((v_res->>'failed')::int, 0) > 0 then
                v_warn := (v_res->>'failed') || ' item(s) failed';
            end if;
        end if;

    exception
        when others then

            v_ms := (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int;

            update platform.scheduled_jobs sj
            set last_run = now()
            where sj.id = v_job.id;

            perform platform.log_job_execution(
                v_job.id,
                'failed',
                v_ms,
                sqlerrm,
                v_corr,
                1
            );

            return jsonb_build_object(
                'status', 'failed',
                'error', sqlerrm
            );

    end;

    v_ms := (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int;

    update platform.scheduled_jobs sj
    set last_run = now()
    where sj.id = v_job.id;

    perform platform.log_job_execution(
        v_job.id,
        'success',
        v_ms,
        v_warn,
        v_corr,
        1
    );

    return jsonb_build_object(
        'status', 'success',
        'rows', v_rows
    );

end;
$$;


-- -----------------------------------------------------
-- 4.5 REGISTRY -> pg_cron
-- -----------------------------------------------------
--
-- Idempotent and re-callable. Active rows are scheduled,
-- inactive or removed rows are unscheduled. Also removes the
-- legacy pg_cron entries 'platform-cron-tick' and
-- 'platform-daily-maintenance' (created by the former
-- platform.ensure_pg_cron_jobs()). Returns the number of
-- scheduled jobs, or -1 when pg_cron is not available.
-- -----------------------------------------------------

create or replace function platform.sync_cron_schedules()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_job record;
    v_cron record;
    v_n int := 0;
begin

    if not exists (select 1 from pg_extension where extname = 'pg_cron') then
        raise warning
            '024: pg_cron not available; call platform.sync_cron_schedules() after enabling it';
        return -1;
    end if;

    -- Legacy entries from the former ensure_pg_cron_jobs().
    for v_cron in
        select c.jobid
        from cron.job c
        where c.jobname in ('platform-cron-tick', 'platform-daily-maintenance')
    loop
        perform cron.unschedule(v_cron.jobid);
    end loop;

    -- Remove cron entries without an active registry row.
    for v_cron in
        select c.jobid, c.jobname
        from cron.job c
        where c.jobname like 'job:%'
          and not exists (
              select 1
              from platform.scheduled_jobs sj
              where 'job:' || sj.job_name = c.jobname
                and coalesce(sj.is_active, false)
          )
    loop
        perform cron.unschedule(v_cron.jobid);
    end loop;

    for v_job in
        select sj.job_name, sj.cron_expression
        from platform.scheduled_jobs sj
        where coalesce(sj.is_active, false)
    loop
        begin

            for v_cron in
                select c.jobid
                from cron.job c
                where c.jobname = 'job:' || v_job.job_name
            loop
                perform cron.unschedule(v_cron.jobid);
            end loop;

            perform cron.schedule(
                'job:' || v_job.job_name,
                v_job.cron_expression,
                format('select platform.run_job(%L);', v_job.job_name)
            );

            v_n := v_n + 1;

        exception
            when others then
                raise warning
                    '024: could not schedule job % (%): %',
                    v_job.job_name, v_job.cron_expression, sqlerrm;
        end;
    end loop;

    return v_n;

end;
$$;


-- -----------------------------------------------------
-- 4.6 EXECUTE PRIVILEGES
-- -----------------------------------------------------
--
-- pg_cron runs as the role that scheduled the job (postgres).
-- Nothing in the scheduler is callable by the portal roles.
-- -----------------------------------------------------

revoke all on function platform.invoke_edge_function(text, jsonb, text) from public, anon, authenticated;
revoke all on function platform.cleanup_job_executions(int)              from public, anon, authenticated;
revoke all on function platform.run_job(text)                            from public, anon, authenticated;
revoke all on function platform.sync_cron_schedules()                    from public, anon, authenticated;

grant execute on function platform.run_job(text)           to service_role;
grant execute on function platform.sync_cron_schedules()   to service_role;


-- -----------------------------------------------------
-- 4.7 WIRE pg_cron NOW (never fails the migration)
-- -----------------------------------------------------

do $$
begin
    perform platform.sync_cron_schedules();
exception
    when others then
        raise warning
            '024: sync_cron_schedules failed: %; call it manually after enabling pg_cron', sqlerrm;
end;
$$;


-- -----------------------------------------------------
-- 4.8 COMMENTS
-- -----------------------------------------------------

comment on function platform.run_job(text) is
    'Runs a registered job: advisory lock, sub-transaction, logs to platform.job_executions and updates scheduled_jobs.last_run. Called by pg_cron as job:<job_name>.';

comment on function platform.sync_cron_schedules() is
    'Schedules every active platform.scheduled_jobs row in pg_cron as job:<job_name> and unschedules the rest. Idempotent. Returns -1 without pg_cron.';

comment on function platform.invoke_edge_function(text, jsonb, text) is
    'Asynchronous edge function call via pg_net using Vault secrets project_url and service_role_key. Optionally skipped when there is no work.';

comment on function platform.cleanup_job_executions(int) is
    'Retention for platform.job_executions and cron.job_run_details.';


-- =====================================================
-- 5. AUTHENTICATED ROLE GRANTS  [NARROWED - see audit fix]
-- =====================================================
-- REMOVED: blanket `grant select, insert, update, delete
-- on all tables in schema public/platform to authenticated`
-- and the matching sequence grants. These gave `authenticated`
-- direct table access regardless of RLS policies, which
-- violates the RPC-only model (platform.security_table_registry
-- forces direct_authenticated_access = false).
--
-- `authenticated` still needs USAGE on both schemas to be
-- able to CALL the *_api() functions (EXECUTE is granted
-- separately in the grant matrix); it needs nothing
-- at the table or sequence level.
-- =====================================================

grant usage on schema public to authenticated;


grant usage on schema platform to authenticated;


-- =====================================================
-- 6. DEFAULT PRIVILEGES  [NARROWED - see audit fix]
-- =====================================================
-- service_role keeps full access on new tables - it is the
-- trusted backend/admin role, not the portal's client role.
-- `authenticated` gets nothing by default.
-- =====================================================

alter default privileges for role postgres in schema public
    grant all on tables to service_role;


alter default privileges for role postgres in schema public
    grant usage, select on sequences to service_role;


alter default privileges for role postgres in schema platform
    grant all on tables to service_role;


-- =====================================================
-- 7. FORCE ROW LEVEL SECURITY
-- public + platform
-- =====================================================

do $$
declare
    v_row record;
begin
    for v_row in
        select n.nspname as schema_name, c.relname as table_name
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where c.relkind = 'r'
          and c.relrowsecurity
          and n.nspname in ('public', 'platform')
        order by n.nspname, c.relname
    loop
        execute format(
            'alter table %I.%I force row level security',
            v_row.schema_name,
            v_row.table_name
        );
    end loop;
end $$;


revoke all
on function platform.complete_notification_delivery(
    uuid,
    boolean,
    jsonb
)
from public, anon, authenticated;

revoke all
on function platform.fetch_notification_batch(
    integer
)
from public, anon, authenticated;


-- =====================================================
-- 8. SAFETY-NET TENANT RLS  [REMOVED - see audit fix]
-- =====================================================
-- The former generic loop created a permissive
-- "tenant_isolation_<table>" policy for every public table with a
-- tenant_id column and no policy. That gave every `authenticated`
-- client direct CRUD access to ~77 business tables via PostgREST,
-- bypassing the *_api() RPC layer, and contradicts
-- chk_security_table_registry_no_direct_authenticated.
--
-- A registered table with zero policies is correctly inaccessible
-- to `authenticated` and `anon`. If a table genuinely needs direct
-- client access (e.g. "read your own row" on platform.profiles),
-- add an explicit, reviewed policy in its own migration.
-- =====================================================


-- =====================================================
-- 9. POST-BOOTSTRAP RLS VERIFICATION
-- WARN ONLY — DOES NOT BLOCK MIGRATION
-- =====================================================

do $$
declare
    v_row record;
begin
    for v_row in
        select distinct c.table_name
        from information_schema.columns c
        join information_schema.tables t
          on t.table_schema = c.table_schema
         and t.table_name = c.table_name
        join pg_class pc
          on pc.relname = c.table_name
        join pg_namespace pn
          on pn.oid = pc.relnamespace
         and pn.nspname = 'public'
        where c.table_schema = 'public'
          and c.column_name = 'tenant_id'
          and t.table_type = 'BASE TABLE'
          and (
              not pc.relrowsecurity
              or not exists (
                  select 1
                  from pg_policies p
                  where p.schemaname = 'public'
                    and p.tablename = c.table_name
              )
          )
        order by c.table_name
    loop
        raise warning
            '024 bootstrap: public.% has tenant_id but RLS is disabled or has no policies',
            v_row.table_name;
    end loop;
end $$;


-- =====================================================
-- 10. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('024_platform_bootstrap', 'REV1', false)
on conflict (migration_name) do nothing;


-- =====================================================
-- END 024 PLATFORM BOOTSTRAP FINALE (includes the scheduler)
-- =====================================================