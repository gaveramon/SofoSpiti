-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 024_PLATFORM_BOOTSTRAP.SQL
-- =====================================================
--
-- Mandatory production gate — runs after full domain stack (002–022)
-- =====================================================
--
-- Responsibilities:
-- 1. Post-domain column/type binds (001 SSOT → 000 platform columns)
-- 2. Safety-net generic tenant RLS for uncovered public.tenant_id tables only
-- 3. pg_cron wiring for platform maintenance workers (platform.ensure_pg_cron_jobs)
-- 4. Commerce ↔ platform cross-schema binds (012/006 → 000)
-- 5. Authenticated grants + default privileges for post-024 migrations
--
-- RLS precedence:
-- - Domain modules (002–016) MUST define explicit policies where role gates differ
-- - This file applies public._apply_public_tenant_rls() ONLY when zero policies exist
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
-- 4. COMMERCE ↔ PLATFORM FOREIGN KEY BINDS
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
-- 5. PAYMENT TARGET TENANT TRIGGER PREPARATION
-- =====================================================

drop trigger if exists trg_payment_intents_target_tenant on platform.payment_intents;


create trigger trg_payment_intents_target_tenant
before insert or update of tenant_id, target_type, target_id on platform.payment_intents
for each row execute function platform.enforce_payment_intent_target_tenant();


-- =====================================================
-- 6. PLATFORM SCHEDULED JOB REGISTRATION
-- =====================================================

insert into platform.scheduled_jobs (job_name, cron_expression, handler, is_active, metadata)
select *
from (
    values
        (
            'platform-cron-tick',
            '* * * * *',
            'platform.run_platform_cron_tick',
            true,
            '{"description":"Watchdog + retry queues"}'::jsonb
        ),
        (
            'platform-daily-maintenance',
            '15 2 * * *',
            'platform.run_platform_daily_maintenance',
            true,
            '{"description":"Partition ensure + log retention purge + service activation sync"}'::jsonb
        )
) as v(job_name, cron_expression, handler, is_active, metadata)
where not exists (
    select 1
    from platform.scheduled_jobs sj
    where sj.job_name = v.job_name
);


-- =====================================================
-- 7. PG_CRON PLATFORM MAINTENANCE WIRING
-- =====================================================

select platform.ensure_pg_cron_jobs();


update platform.scheduled_jobs
set is_active = exists (select 1 from pg_extension where extname = 'pg_cron'),
    metadata = case
        when exists (select 1 from pg_extension where extname = 'pg_cron')
        then coalesce(metadata, '{}'::jsonb) - 'pg_cron_missing'
        else coalesce(metadata, '{}'::jsonb) || '{"pg_cron_missing":true}'::jsonb
    end
where job_name in ('platform-cron-tick', 'platform-daily-maintenance');


-- =====================================================
-- 8. SAFETY-NET TENANT RLS  [REMOVED - see audit fix]
-- =====================================================
-- REMOVED: this block used to auto-create a permissive
-- "tenant_isolation_<table>" policy for every public
-- table with a tenant_id column that had no policy left
-- after 020 dropped the legacy ones.
--
-- Combined with section 9 below (also removed), this
-- gave every `authenticated` client direct CRUD access
-- to ~77 business tables via PostgREST, bypassing the
-- *_api() RPC layer entirely.
--
-- That directly contradicts platform.security_table_registry,
-- which has a HARD CHECK CONSTRAINT
-- (chk_security_table_registry_no_direct_authenticated)
-- forcing direct_authenticated_access = false for every
-- registered table, with no exceptions.
--
-- Access to every registered table must go exclusively
-- through the *_api() SECURITY DEFINER functions granted
-- in 022_grant_matrix.sql. RLS (enabled + forced by 020,
-- driven by the registry) is the deny-by-default backstop:
-- a registered table with zero policies is correctly
-- inaccessible to `authenticated` and `anon`, and only
-- reachable by the SECURITY DEFINER function owner.
--
-- If a specific table genuinely needs direct client
-- access (e.g. a narrow "read your own row" case like
-- platform.profiles), that must be an explicit, reviewed
-- policy added in its own migration - never a generic
-- loop over every tenant_id column.
-- =====================================================


-- =====================================================
-- 9. AUTHENTICATED ROLE GRANTS  [NARROWED - see audit fix]
-- =====================================================
-- REMOVED: blanket `grant select, insert, update, delete
-- on all tables in schema public/platform to authenticated`
-- and the matching sequence grants. These gave `authenticated`
-- direct table access regardless of RLS policies, which
-- violates the RPC-only model above.
--
-- `authenticated` still needs USAGE on both schemas to be
-- able to CALL the *_api() functions (EXECUTE is granted
-- separately in 022_grant_matrix.sql); it needs nothing
-- at the table or sequence level.
-- =====================================================

grant usage on schema public to authenticated;


grant usage on schema platform to authenticated;


-- =====================================================
-- 10. DEFAULT PRIVILEGES  [NARROWED - see audit fix]
-- =====================================================
-- REMOVED: default privileges that would have granted
-- `authenticated` direct table/sequence access on every
-- table created after this migration too (e.g. 015+).
-- service_role keeps full access below - service_role is
-- the trusted backend/admin role, not the portal's client
-- role, so it is not subject to the RPC-only requirement.
-- =====================================================

alter default privileges for role postgres in schema public
    grant all on tables to service_role;


alter default privileges for role postgres in schema public
    grant usage, select on sequences to service_role;


alter default privileges for role postgres in schema platform
    grant all on tables to service_role;


-- =====================================================
-- 11. FORCE ROW LEVEL SECURITY
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
-- 12. POST-BOOTSTRAP RLS VERIFICATION
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
            '023 bootstrap: public.% has tenant_id but RLS is disabled or has no policies',
            v_row.table_name;
    end loop;
end $$;


-- =====================================================
-- 13. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('024_platform_bootstrap', 'REV1', false)
on conflict (migration_name) do nothing;


-- =====================================================
-- END 024 PLATFORM BOOTSTRAP FINALE
-- =====================================================