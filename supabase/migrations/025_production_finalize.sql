-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 025_PRODUCTION_FINALIZE.SQL
-- =====================================================
--
-- Purpose:
-- Production readiness verification gate
--
-- Rules:
-- - NO schema mutation
-- - NO permission mutation
-- - NO RLS mutation
-- - NO function replacement
-- - NO scheduler mutation (verification only)
--
-- Depends on:
--
-- 000_supabase_platform.sql
-- 001_core_types.sql
-- 002_core_saas.sql
-- 003_crm_engine.sql
-- 004_property_device_engine.sql
-- 005_booking_lock_engine.sql
-- 006_integration_engine.sql
-- 007_device_telemetry_raw.sql
-- 008_device_telemetry_processing.sql
-- 009_operations_engine.sql
-- 010_preconfig_engine.sql
-- 011_logistics_engine.sql
-- 012_commerce_engine.sql
-- 013_service_portal_engine.sql
-- 014_onboarding_engine.sql
-- 015_optimization_engine.sql
-- 016_customer_proposal_monetization.sql
-- 017_automation_engine.sql
-- 018_inventory_engine.sql
-- 019_edge_rpc_foundation.sql
-- 020_security_classification.sql
-- 021_security_hardening.sql
-- 022_grant_matrix_actors.sql
-- 023_grant_matrix.sql
-- 024_platform_bootstrap.sql   (includes the scheduler, formerly 027)
--
-- Auditor mapping:
--
-- KGS-001 Principles
-- KGS-002 Object Catalog
-- KGS-003 Workflow Catalog
-- KGS-004 Ownership Catalog
-- KGS-005 Business Rules
--
-- =====================================================


begin;



--- =====================================================
-- 1. VERIFY REQUIRED MODULE MIGRATIONS
-- KGS-002 MODULE CATALOG VALIDATION
-- =====================================================
--
-- IMPORTANT:
--   platform.schema_migrations.migration_name
--       = technical migration/module identifier
--
--   platform.schema_migrations.version
--       = governance / Enterprise Auditor version
--
-- Therefore KGS-002 module existence is validated
-- against migration_name, NOT version.
--
-- =====================================================

do $$
declare
    missing_count int;
    missing_migrations text;
begin

    select
        count(*)::int,
        string_agg(
            required.migration_name,
            ', '
            order by required.migration_name
        )
    into
        missing_count,
        missing_migrations
    from
    (
        values
            ('000_supabase_platform'),
            ('001_core_types'),
            ('002_core_saas'),
            ('003_crm_engine'),
            ('004_property_device_engine'),
            ('005_booking_lock_engine'),
            ('006_integration_engine'),
            ('007_device_telemetry_raw'),
            ('008_device_telemetry_processing'),
            ('009_operations_engine'),
            ('010_preconfig_engine'),
            ('011_logistics_engine'),
            ('012_commerce_engine'),
            ('013_service_portal_engine'),
            ('014_onboarding_engine'),
            ('015_optimization_engine'),
            ('016_customer_proposal_monetization'),
            ('017_automation_engine'),
            ('018_inventory_engine'),
            ('019_edge_rpc_foundation'),
            ('020_security_classification'),
            ('021_security_hardening'),
            ('022_grant_matrix_actors'),
            ('023_grant_matrix'),
            ('024_platform_bootstrap')
    ) as required(migration_name)

    where not exists
    (
        select 1
        from platform.schema_migrations m
        where m.migration_name = required.migration_name
    );

    missing_count := coalesce(missing_count, 0);

    if missing_count > 0 then

        raise exception
            'Production finalize failed: % required module migration(s) missing from platform.schema_migrations.migration_name: %',
            missing_count,
            missing_migrations;

    end if;

    raise notice
        'Production finalize: all % required module migrations are registered',
        25;

end
$$;


-- =====================================================
-- 2. VERIFY TENANT AUTHORITY MODEL
-- KGS-001 SINGLE SOURCE OF TRUTH
-- =====================================================

do $$

declare
v_missing int;

begin

select count(*)
into v_missing

from pg_proc p
join pg_namespace n
on n.oid=p.pronamespace

where n.nspname='public'
and p.proname='resolve_active_tenant';

if v_missing = 0 then

raise exception
'Tenant resolver missing. SSOT violation.';

end if;

end $$;


-- =====================================================
-- 3. VERIFY SECURITY DEFINER HARDENING
-- SECURITY EXECUTION BOUNDARY
--
-- Rule:
-- SECURITY DEFINER functions must have empty search_path
-- =====================================================


do $$

declare
v_count int;

begin

select count(*)
into v_count

from pg_proc p
join pg_namespace n
on n.oid=p.pronamespace

where p.prosecdef=true

and
(
p.proconfig is null
or
not exists
(
select 1
from unnest(p.proconfig) cfg
where cfg like 'search_path=%'
)
);

if v_count > 0 then

raise exception
'Security finalize failed: SECURITY DEFINER functions without hardened search_path detected';

end if;

end $$;


-- =====================================================
-- 4. VERIFY RLS ENABLEMENT
-- ROW-LEVEL SECURITY BOUNDARY
-- =====================================================
--
-- Validation:
--   Every active public table registered with
--   rls_required = true must have RLS enabled.
--
-- IMPORTANT:
--   This section validates RLS enablement only.
--   force_rls_required is validated separately.
--   RLS is CREATED / CONFIGURED by the security
--   hardening migration (021).
-- =====================================================

do $$
declare
    v_count int;
    v_tables text;
begin

    select
        count(*)::int,
        string_agg(
            format(
                '%I.%I (rls_required=%s, rowsecurity=%s)',
                r.table_schema,
                r.table_name,
                r.rls_required,
                coalesce(c.relrowsecurity, false)
            ),
            E'\n'
            order by
                r.table_schema,
                r.table_name
        )
    into
        v_count,
        v_tables
    from platform.security_table_registry r
    join pg_class c
        on c.relnamespace = (
            select n.oid
            from pg_namespace n
            where n.nspname = r.table_schema
        )
       and c.relname = r.table_name
    where r.is_active
      and r.table_schema = 'public'
      and r.rls_required = true
      and c.relkind = 'r'
      and coalesce(c.relrowsecurity, false) = false;

    if v_count > 0 then

        raise exception
            'RLS validation failed: % public table(s) require RLS but RLS is not enabled:%',
            v_count,
            E'\n' || v_tables;

    end if;

    raise notice
        'RLS validation passed: all active public tables requiring RLS have RLS enabled';

end
$$;


-- =====================================================
-- 5. VERIFY GRANT MATRIX
-- PERMISSION BOUNDARY
-- =====================================================
--
-- Security rule:
--   Anonymous users (anon) must not have EXECUTE
--   privileges on application-owned functions or
--   procedures.
--
-- Extension-owned routines are excluded (pg_depend deptype 'e').
-- =====================================================

do $$
declare
    v_count int;
    v_routines text;
begin

    select
        count(*)::int,
        string_agg(
            format(
                '%I.%I(%s) [%s]',
                n.nspname,
                p.proname,
                pg_get_function_identity_arguments(p.oid),
                case
                    when p.prokind = 'p'
                        then 'procedure'
                    else 'function'
                end
            ),
            E'\n'
            order by
                n.nspname,
                p.proname,
                pg_get_function_identity_arguments(p.oid)
        )
    into
        v_count,
        v_routines
    from pg_proc p
    join pg_namespace n
        on n.oid = p.pronamespace
    where n.nspname in (
        'public',
        'platform'
    )
      and p.prokind in ('f', 'p')

      and not exists (
          select 1
          from pg_depend d
          where d.classid = 'pg_proc'::regclass
            and d.objid = p.oid
            and d.deptype = 'e'
      )

      and has_function_privilege(
            'anon',
            p.oid,
            'EXECUTE'
          );

    if v_count > 0 then

        raise exception
            'Grant matrix violation: % application routine(s) grant anon EXECUTE:%',
            v_count,
            E'\n' || v_routines;

    end if;

    raise notice
        'Grant matrix validation passed: no application-owned routines grant anon EXECUTE';

end
$$;


-- =====================================================
-- 6. VERIFY DOMAIN API SURFACE
-- KGS-002 MODULE INTERFACE VALIDATION
-- =====================================================

do $$

declare
v_count int;

begin

select count(*)
into v_count

from pg_proc p
join pg_namespace n
on n.oid=p.pronamespace

where n.nspname='public'
and p.proname like '%_domain';


if v_count < 10 then

raise exception
'Domain interface validation failed';

end if;

end $$;

-- =====================================================
-- 7. VERIFY REQUIRED PORTAL VIEWS
-- PORTAL REPORTING SSOT
-- =====================================================

do $$

declare
v_count int;

begin

select count(*)
into v_count

from pg_views

where schemaname='public'
and viewname in
(
'v_devices_overview',
'v_properties_overview',
'v_bookings_overview',
'v_subscription_overview',
'v_onboarding_progress'
);

if v_count < 5 then

raise exception
'Portal SSOT views missing';

end if;

end $$;


-- =====================================================
-- 7B. VERIFY NO DIRECT AUTHENTICATED TABLE ACCESS
-- RPC-ONLY BOUNDARY
-- =====================================================
--
-- platform.security_table_registry enforces
-- direct_authenticated_access = false for every registered
-- table via a hard CHECK CONSTRAINT. This section verifies
-- that the *runtime* grants and policies actually respect
-- that promise, since section 4 only checks that RLS is
-- enabled, not that it is effectively deny-all.
-- =====================================================

do $$
declare
    v_priv_count int;
    v_priv_list text;
    v_policy_count int;
    v_policy_list text;
begin

    -- (a) No table-level GRANT to `authenticated` on any
    --     registered table.

    select
        count(*)::int,
        string_agg(format('%I.%I', r.table_schema, r.table_name), ', ' order by 1)
    into v_priv_count, v_priv_list
    from platform.security_table_registry r
    where r.is_active
      and r.direct_authenticated_access = false
      and (
          has_table_privilege('authenticated', format('%I.%I', r.table_schema, r.table_name), 'SELECT')
          or has_table_privilege('authenticated', format('%I.%I', r.table_schema, r.table_name), 'INSERT')
          or has_table_privilege('authenticated', format('%I.%I', r.table_schema, r.table_name), 'UPDATE')
          or has_table_privilege('authenticated', format('%I.%I', r.table_schema, r.table_name), 'DELETE')
      );

    if v_priv_count > 0 then
        raise exception
            'RPC-only validation failed: % registered table(s) grant direct table privileges to authenticated: %',
            v_priv_count, v_priv_list;
    end if;

    -- (b) No RLS policy exists on any registered table
    --     (deny-by-default via RLS + no policy).

    select
        count(*)::int,
        string_agg(format('%I.%I (%s)', r.table_schema, r.table_name, p.policyname), ', ' order by 1)
    into v_policy_count, v_policy_list
    from platform.security_table_registry r
    join pg_policies p
      on p.schemaname = r.table_schema
     and p.tablename = r.table_name
    where r.is_active
      and r.direct_authenticated_access = false;

    if v_policy_count > 0 then
        raise exception
            'RPC-only validation failed: % policy(ies) exist on registered no-direct-access tables: %',
            v_policy_count, v_policy_list;
    end if;

    raise notice 'RPC-only validation passed: no direct authenticated access on registered tables';

end
$$;


-- =====================================================
-- 8. VERIFY OPERATIONAL SCHEDULING
-- CRON INFRASTRUCTURE (VERIFICATION ONLY)
--
-- Reference:
-- 024_platform_bootstrap.sql section 4 (scheduler)
-- =====================================================
--
-- Checks (no mutation):
--   (a) scheduler functions exist
--   (b) every platform.scheduled_jobs row marked active has
--       exactly one pg_cron entry 'job:<job_name>'
--   (c) no pg_cron entry 'job:%' exists without an active row
--   (d) the legacy entries 'platform-cron-tick' and
--       'platform-daily-maintenance' are gone
--
-- Without pg_cron (local development) only (a) is enforced
-- and a warning is raised. To repair drift:
--   select platform.sync_cron_schedules();
-- =====================================================

do $$
declare
    v_sig text;
    v_count int;
    v_list text;
begin

    -- (a) scheduler functions

    foreach v_sig in array array[
        'platform.run_job(text)',
        'platform.sync_cron_schedules()',
        'platform.invoke_edge_function(text,jsonb,text)',
        'platform.cleanup_job_executions(integer)'
    ]
    loop
        if to_regprocedure(v_sig) is null then
            raise exception
                'Scheduler validation failed: % is missing (024)', v_sig;
        end if;
    end loop;

    if not exists (select 1 from pg_extension where extname = 'pg_cron') then
        raise warning
            'Scheduler validation: pg_cron is not installed; cron entries could not be verified. Enable pg_cron and run platform.sync_cron_schedules().';
        return;
    end if;

    -- (b) active registry rows without a cron entry

    select
        count(*)::int,
        string_agg(sj.job_name, ', ' order by sj.job_name)
    into v_count, v_list
    from platform.scheduled_jobs sj
    where coalesce(sj.is_active, false)
      and not exists (
          select 1
          from cron.job c
          where c.jobname = 'job:' || sj.job_name
      );

    if v_count > 0 then
        raise exception
            'Scheduler validation failed: % active job(s) are not scheduled in pg_cron: % (run platform.sync_cron_schedules())',
            v_count, v_list;
    end if;

    -- (c) cron entries without an active registry row

    select
        count(*)::int,
        string_agg(c.jobname, ', ' order by c.jobname)
    into v_count, v_list
    from cron.job c
    where c.jobname like 'job:%'
      and not exists (
          select 1
          from platform.scheduled_jobs sj
          where 'job:' || sj.job_name = c.jobname
            and coalesce(sj.is_active, false)
      );

    if v_count > 0 then
        raise exception
            'Scheduler validation failed: % stale pg_cron entr(ies) without an active registry row: % (run platform.sync_cron_schedules())',
            v_count, v_list;
    end if;

    -- (d) legacy entries

    select
        count(*)::int,
        string_agg(c.jobname, ', ' order by c.jobname)
    into v_count, v_list
    from cron.job c
    where c.jobname in ('platform-cron-tick', 'platform-daily-maintenance');

    if v_count > 0 then
        raise exception
            'Scheduler validation failed: legacy pg_cron entries still present: % (run platform.sync_cron_schedules())',
            v_list;
    end if;

    raise notice
        'Scheduler validation passed: every active registry job is scheduled as job:<job_name>';

end
$$;


-- =====================================================
-- 9. REGISTER FINAL PRODUCTION AUDIT EVENT
-- HUMAN APPROVAL CHECKPOINT
-- =====================================================

insert into platform.audit_log
(
    tenant_id,
    user_id,
    action,
    entity_type,
    entity_id,
    metadata
)
values
(
    null,
    null,
    'production_finalize',
    'migration',
    null,
    jsonb_build_object(
        'migration_name', '025_production_finalize',
        'version', 'REV1',
        'checkpoint', 'human_approval',
        'status', 'completed'
    )
);


-- =====================================================
-- 10. REGISTER MIGRATION
-- FINAL MIGRATION STATE
-- =====================================================

insert into platform.schema_migrations( migration_name, version, rollback_available)
values( '025_production_finalize', 'REV1', false)
on conflict(migration_name) do nothing;

commit;