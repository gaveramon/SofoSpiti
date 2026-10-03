-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 027_CRON_ENGINE.SQL
-- =====================================================
-- SCHEDULED JOBS ON TOP OF THE 000 PLATFORM ENGINE
--
-- 000 already provides:
--   platform.scheduled_jobs       control-plane registry (nothing reads it yet)
--   platform.job_executions       execution history
--   platform.log_job_execution()  history writer
--   platform.ensure_pg_cron_jobs() two fixed jobs:
--       platform-cron-tick          every minute
--       platform-daily-maintenance  02:15 UTC
--   platform.dispatch_http_request() / get_vault_secret()
--
-- 027 ADDS (no new tables):
--   1. unique job_name on scheduled_jobs
--   2. seeds for the commerce / Epsilon jobs
--   3. platform.run_job(job_name)       lock + run + log
--   4. platform.invoke_edge_function()  pg_net call with Vault secrets
--   5. platform.cleanup_job_executions()
--   6. platform.sync_cron_schedules()   registry -> pg_cron
--
-- The two 000 jobs are NOT touched. 027 jobs are scheduled in
-- pg_cron under the name 'job:<job_name>'.
--
-- ADDING A JOB: insert a row in platform.scheduled_jobs, add its
-- handler to the CASE in platform.run_job(), call
-- platform.sync_cron_schedules(). No dynamic SQL is used.
--
-- pg_cron runs in UTC.
-- =====================================================


-- =====================================================
-- 0. PRECONDITIONS
-- =====================================================

do $$
begin
    if to_regclass('platform.scheduled_jobs') is null
       or to_regclass('platform.job_executions') is null then
        raise exception
            '027 requires platform.scheduled_jobs and platform.job_executions from 000';
    end if;

    if to_regprocedure('platform.log_job_execution(uuid,text,integer,text,uuid,integer)') is null then
        raise exception
            '027 requires platform.log_job_execution from 000';
    end if;

    if to_regprocedure('platform.dispatch_http_request(text,text,jsonb,jsonb,integer)') is null
       or to_regprocedure('platform.get_vault_secret(text)') is null then
        raise exception
            '027 requires platform.dispatch_http_request and platform.get_vault_secret from 000';
    end if;

    if to_regprocedure('platform.expire_cancelled_subscriptions()') is null
       or to_regprocedure('platform.epsilon_flag_stuck(integer)') is null
       or to_regprocedure('platform.mark_overdue_invoices()') is null
       or to_regprocedure('platform.expire_trial_subscriptions()') is null then
        raise exception
            '027 requires the platform job functions from 012 (sections 19A, 19C, 19D, 27A)';
    end if;

    if to_regclass('platform.schema_migrations') is null then
        raise exception
            '027 requires platform.schema_migrations';
    end if;
end;
$$;


-- =====================================================
-- 1. REGISTRY KEY
-- =====================================================

create unique index if not exists uq_scheduled_jobs_job_name
on platform.scheduled_jobs (job_name);


-- =====================================================
-- 2. SEEDS
-- =====================================================
--
-- handler = abstract reference resolved in platform.run_job().
-- Re-running updates schedule/handler/metadata but never
-- is_active, so a job disabled by an operator stays disabled.
-- =====================================================

insert into platform.scheduled_jobs (
    job_name,
    cron_expression,
    handler,
    is_active,
    metadata
)
values

    -- Cancellations per end of month (012 section 19A).
    (
        'expire_cancelled_subscriptions',
        '0 * * * *',
        'commerce.expire_cancelled_subscriptions',
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

    -- Retention of platform.job_executions and cron.job_run_details.
    (
        'cleanup_job_executions',
        '45 2 * * *',
        'platform.cleanup_job_executions',
        true,
        '{"retention_days": 30}'::jsonb
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

    -- trial -> trial_expired when current_period_end has passed
    -- (012 section 19D).
    (
        'expire_trial_subscriptions',
        '15 * * * *',
        'commerce.expire_trial_subscriptions',
        true,
        '{}'::jsonb
    )

on conflict (job_name) do update
set
    cron_expression = excluded.cron_expression,
    handler = excluded.handler,
    metadata = excluded.metadata;


-- =====================================================
-- 3. EDGE FUNCTION INVOCATION (pg_net + Vault)
-- =====================================================
--
-- Vault secrets expected:
--   project_url        e.g. https://<ref>.supabase.co
--   service_role_key
--
-- pg_net is asynchronous: success only means the request was
-- queued. The edge function reports its own result.
-- =====================================================

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


-- =====================================================
-- 4. RETENTION
-- =====================================================

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


-- =====================================================
-- 5. RUN A JOB
-- =====================================================
--
-- Called by pg_cron as: select platform.run_job('<job_name>');
--
--   - an overlapping run of the same job is skipped silently
--   - the work runs in a sub-transaction: a failure rolls back
--     the job's own changes but is still logged
--   - every run is written to platform.job_executions
--     (status success | failed) and scheduled_jobs.last_run
-- =====================================================

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

    begin

        case v_job.handler

            when 'commerce.expire_cancelled_subscriptions' then
                v_rows := platform.expire_cancelled_subscriptions();

            when 'commerce.epsilon_flag_stuck' then
                v_rows := platform.epsilon_flag_stuck(
                    coalesce(
                        nullif(v_job.metadata->>'stuck_minutes', '')::int,
                        10
                    )
                );

            when 'commerce.mark_overdue_invoices' then
                v_rows := platform.mark_overdue_invoices();

            when 'commerce.expire_trial_subscriptions' then
                v_rows := platform.expire_trial_subscriptions();

            when 'platform.cleanup_job_executions' then
                v_rows := platform.cleanup_job_executions(
                    coalesce(
                        nullif(v_job.metadata->>'retention_days', '')::int,
                        30
                    )
                );

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
        null,
        v_corr,
        1
    );

    return jsonb_build_object(
        'status', 'success',
        'rows', v_rows
    );

end;
$$;


-- =====================================================
-- 6. REGISTRY -> pg_cron
-- =====================================================
--
-- Idempotent and re-callable (like platform.ensure_pg_cron_jobs()).
-- Active rows are scheduled, inactive or removed rows are
-- unscheduled. Returns the number of scheduled jobs, or -1
-- when pg_cron is not available (e.g. local development).
-- =====================================================

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
            '027: pg_cron not available; call platform.sync_cron_schedules() after enabling it';
        return -1;
    end if;

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
                    '027: could not schedule job % (%): %',
                    v_job.job_name, v_job.cron_expression, sqlerrm;
        end;
    end loop;

    return v_n;

end;
$$;


-- =====================================================
-- 7. EXECUTE PRIVILEGES
-- =====================================================
--
-- pg_cron runs as postgres. Final execution privileges are
-- owned by the grants migration.
-- =====================================================

revoke all on function platform.invoke_edge_function(text, jsonb, text) from public, anon, authenticated;
revoke all on function platform.cleanup_job_executions(int)              from public, anon, authenticated;
revoke all on function platform.run_job(text)                            from public, anon, authenticated;
revoke all on function platform.sync_cron_schedules()                    from public, anon, authenticated;

grant execute on function platform.run_job(text)           to service_role;
grant execute on function platform.sync_cron_schedules()   to service_role;


-- =====================================================
-- 8. WIRE pg_cron NOW (never fails the migration)
-- =====================================================

do $$
begin
    perform platform.sync_cron_schedules();
exception
    when others then
        raise warning
            '027: sync_cron_schedules failed: %; call it manually after enabling pg_cron', sqlerrm;
end;
$$;


-- =====================================================
-- 9. COMMENTS
-- =====================================================

comment on function platform.run_job(text) is
    'Runs a registered job: advisory lock, sub-transaction, logs to platform.job_executions and updates scheduled_jobs.last_run. Called by pg_cron.';

comment on function platform.sync_cron_schedules() is
    'Schedules every active platform.scheduled_jobs row in pg_cron as job:<job_name>. Idempotent.';

comment on function platform.invoke_edge_function(text, jsonb, text) is
    'Asynchronous edge function call via pg_net using Vault secrets project_url and service_role_key. Optionally skipped when there is no work.';


-- =====================================================
-- 10. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (
    migration_name,
    version,
    rollback_available
)
values (
    '027_cron_engine',
    'REV1',
    false
)
on conflict (migration_name)
do update
set
    version = excluded.version,
    rollback_available = excluded.rollback_available;


-- =====================================================
-- END 027 CRON ENGINE
-- =====================================================