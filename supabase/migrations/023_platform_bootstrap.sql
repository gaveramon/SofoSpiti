-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 023_PLATFORM_BOOTSTRAP.SQL
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
-- 8. SAFETY-NET TENANT RLS
-- =====================================================
-- Uncovered public.tenant_id tables only.
--
-- Existing custom domain policies are preserved.
--
-- resolve_active_tenant() is the sole tenant authority.
--
-- =====================================================

do $$
declare
    v_row record;
    v_policy_name text;
begin

    for v_row in
        select distinct
            c.table_name
        from information_schema.columns c
        join information_schema.tables t
          on t.table_schema = c.table_schema
         and t.table_name = c.table_name
        where c.table_schema = 'public'
          and c.column_name = 'tenant_id'
          and t.table_type = 'BASE TABLE'
          and not exists (
              select 1
              from pg_policies p
              where p.schemaname = 'public'
                and p.tablename = c.table_name
          )
        order by c.table_name

    loop

        -- -------------------------------------------------
        -- Enable RLS
        -- -------------------------------------------------

        execute format(
            'alter table public.%I enable row level security',
            v_row.table_name
        );


        -- -------------------------------------------------
        -- Force RLS
        -- -------------------------------------------------

        execute format(
            'alter table public.%I force row level security',
            v_row.table_name
        );


        -- -------------------------------------------------
        -- Generic tenant-isolation policy
        -- -------------------------------------------------

        v_policy_name :=
            'tenant_isolation_' || v_row.table_name;

        execute format(
            'create policy %I
             on public.%I
             for all
             to authenticated
             using (
                 tenant_id = public.resolve_active_tenant(auth.uid())
             )
             with check (
                 tenant_id = public.resolve_active_tenant(auth.uid())
             )',
            v_policy_name,
            v_row.table_name
        );


        raise notice
            '023 bootstrap: applied generic tenant RLS to public.%',
            v_row.table_name;

    end loop;

end
$$;


-- =====================================================
-- 9. AUTHENTICATED ROLE GRANTS
-- RLS remains the tenant-isolation gate
-- Canonical authenticated grants live here
-- 000 grants service_role only
-- =====================================================

grant usage on schema public to authenticated;


grant select, insert, update, delete on all tables in schema public to authenticated;


grant usage, select on all sequences in schema public to authenticated;


grant usage on schema platform to authenticated;


grant select on all tables in schema platform to authenticated;


grant update on table platform.profiles to authenticated;


-- =====================================================
-- 10. DEFAULT PRIVILEGES
-- Applies to tables created by migrations after 024, e.g. 015+
-- =====================================================

alter default privileges for role postgres in schema public
    grant select, insert, update, delete on tables to authenticated;


alter default privileges for role postgres in schema public
    grant usage, select on sequences to authenticated;


alter default privileges for role postgres in schema public
    grant all on tables to service_role;


alter default privileges for role postgres in schema public
    grant usage, select on sequences to service_role;


alter default privileges for role postgres in schema platform
    grant select on tables to authenticated;


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
values ('023_platform_bootstrap', 'REV1', false)
on conflict (migration_name) do nothing;


-- =====================================================
-- END 023 PLATFORM BOOTSTRAP FINALE
-- =====================================================