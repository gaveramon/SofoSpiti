-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 021_SECURITY_HARDENING.SQL
-- =====================================================
-- SECURITY HARDENING
--
-- SECURITY MODEL
-- =====================================================
--
-- PORTAL
--    |
--    v
-- API / RPC
--    |
--    v
-- AUTHORIZATION
--    |
--    v
-- DOMAIN / BACKEND
--    |
--    v
-- TABLES
--
--
-- 021 OWNS
-- ---------
-- - security table registry population
-- - RLS
-- - FORCE RLS
-- - removal of legacy direct-table policies
-- - SECURITY DEFINER hardening
-- - search_path hardening
-- - dependency validation
-- - dynamic SQL validation
-- - tenant-authority validation
-- - security validation
--
--
-- 023 OWNS
-- --------
-- - GRANT
-- - REVOKE
-- - EXECUTE privileges
-- - schema privileges
-- - table privileges
-- - sequence privileges
-- - final privilege validation
-- - Grant Matrix
--
--
-- IMPORTANT
-- ---------
-- 021 deliberately contains NO GRANT / REVOKE statements.
--
-- security_class:
--   business = business/domain ownership
--   backend  = backend/platform ownership
--
-- portal_access:
--   rpc  = portal access only through approved API/RPC
--   none = no portal contract
--
-- platform_admin_access:
--   true  = platform-admin access may exist through explicit
--           platform-admin API/RPC contracts
--   false = no platform-admin contract
--
-- direct_authenticated_access:
--   MUST remain false for all governed tables.
--
-- The security_table_registry is the single maintenance
-- point for the table security boundary.
-- =====================================================


begin;


-- =====================================================
-- 1. SECURITY AUTHORITY FREEZE
-- =====================================================

comment on schema public is
'Business schema. Tenant authority MUST resolve through public.resolve_active_tenant(auth.uid()). Portal access to registered tables is API/RPC-only.';

comment on schema platform is
'Platform infrastructure and security control plane. No business-domain ownership unless explicitly classified in the security registry.';


-- =====================================================
-- 2. RLS COMPATIBILITY SHIMS
-- =====================================================

comment on function platform.has_tenant_access(uuid) is
'RLS compatibility shim only. Tenant authority resolves through public.resolve_active_tenant(auth.uid()). Not an API authorization surface.';

comment on function public.has_tenant_access(uuid) is
'RLS compatibility shim only. Tenant authority resolves through public.resolve_active_tenant(auth.uid()). Not an API authorization surface.';


alter function platform.has_tenant_access(uuid)
set search_path = '';


alter function public.has_tenant_access(uuid)
set search_path = '';


create or replace function platform.has_tenant_access(tid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select tid = public.resolve_active_tenant((select auth.uid()));
$$;


create or replace function public.has_tenant_access(p_public_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select p_public_tenant_id =
           public.resolve_active_tenant((select auth.uid()));
$$;


-- =====================================================
-- 3. REGISTRY INTEGRITY VALIDATION
-- =====================================================

do $$
declare
    r record;
    v_duplicate_count integer;
begin

    -- Every active registry entry must resolve to a real table.
    for r in
        select
            table_schema,
            table_name
        from platform.security_table_registry
        where is_active = true
    loop

        if to_regclass(
            format('%I.%I', r.table_schema, r.table_name)
        ) is null then

            raise exception
                '021 security hardening failed: registered table %.% does not exist',
                r.table_schema,
                r.table_name;

        end if;

    end loop;


    -- There must be exactly one active registry row per table.
    for r in
        select
            table_schema,
            table_name,
            count(*) as row_count
        from platform.security_table_registry
        where is_active = true
        group by
            table_schema,
            table_name
        having count(*) > 1
    loop

        raise exception
            '021 security hardening failed: duplicate active registry entries for %.% (% rows)',
            r.table_schema,
            r.table_name,
            r.row_count;

    end loop;

end;
$$;


-- =====================================================
-- 4. REGISTRY SEMANTIC VALIDATION
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            table_schema,
            table_name,
            security_class,
            portal_access,
            platform_admin_access,
            direct_authenticated_access,
            rls_required,
            force_rls_required
        from platform.security_table_registry
        where is_active = true
    loop

        -- -------------------------------------------------
        -- security_class
        -- -------------------------------------------------

        if r.security_class not in ('business', 'backend') then

            raise exception
                '021 security hardening failed: %.% has invalid security_class=%; expected business or backend',
                r.table_schema,
                r.table_name,
                r.security_class;

        end if;


        -- -------------------------------------------------
        -- portal_access
        -- -------------------------------------------------

        if r.portal_access not in ('rpc', 'none') then

            raise exception
                '021 security hardening failed: %.% has invalid portal_access=%; expected rpc or none',
                r.table_schema,
                r.table_name,
                r.portal_access;

        end if;


        -- -------------------------------------------------
        -- direct authenticated access
        -- -------------------------------------------------

        if r.direct_authenticated_access is distinct from false then

            raise exception
                '021 security hardening failed: %.% permits direct authenticated access',
                r.table_schema,
                r.table_name;

        end if;


        -- -------------------------------------------------
        -- portal contract semantics
        -- -------------------------------------------------

        if r.security_class = 'backend'
           and r.portal_access = 'rpc'
           and r.platform_admin_access is null then

            raise exception
                '021 security hardening failed: backend-owned portal-exposed table %.% must explicitly define platform_admin_access',
                r.table_schema,
                r.table_name;

        end if;


        -- -------------------------------------------------
        -- RLS requirements
        -- -------------------------------------------------

        if r.rls_required is distinct from true then

            raise exception
                '021 security hardening failed: registered table %.% must require RLS',
                r.table_schema,
                r.table_name;

        end if;


        -- -------------------------------------------------
-- FORCE RLS requirements
-- -------------------------------------------------

        if r.security_class = 'business'
        and r.force_rls_required is distinct from true then

            raise exception
                '021 security hardening failed: business table %.% must require FORCE RLS',
                r.table_schema,
                r.table_name;

        end if;

    end loop;

end;
$$;


-- =====================================================
-- 5. ENABLE RLS + FORCE RLS
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            table_schema,
            table_name
        from platform.security_table_registry
        where is_active = true
          and rls_required = true
    loop

        execute format(
            'alter table %I.%I enable row level security',
            r.table_schema,
            r.table_name
        );

        if (
            select force_rls_required
            from platform.security_table_registry
            where table_schema = r.table_schema
              and table_name = r.table_name
              and is_active = true
        ) = true then

            execute format(
                'alter table %I.%I force row level security',
                r.table_schema,
                r.table_name
            );

        end if;

    end loop;

end;
$$;


-- =====================================================
-- 6. REMOVE ALL LEGACY RLS POLICIES
-- =====================================================
--
-- Direct authenticated/anon table policies are removed.
--
-- Portal access is NOT implemented through direct-table
-- policies. Approved portal reads/writes are implemented
-- through API/RPC contracts.
--
-- RLS therefore acts as a defense-in-depth direct-table
-- boundary.
-- =====================================================

do $$
declare
    r record;
    p record;
begin

    for r in
        select
            table_schema,
            table_name
        from platform.security_table_registry
        where is_active = true
    loop

        for p in
            select
                policyname
            from pg_policies
            where schemaname = r.table_schema
              and tablename = r.table_name
        loop

            execute format(
                'drop policy if exists %I on %I.%I',
                p.policyname,
                r.table_schema,
                r.table_name
            );

        end loop;

    end loop;

end;
$$;


-- =====================================================
-- 7. POST-POLICY SECURITY VALIDATION
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            p.schemaname,
            p.tablename,
            p.policyname,
            p.roles
        from pg_policies p
        join platform.security_table_registry s
          on s.table_schema = p.schemaname
         and s.table_name = p.tablename
        where s.is_active = true
          and (
              'anon' = any (p.roles)
              or 'authenticated' = any (p.roles)
          )
    loop

        raise exception
            '021 security hardening failed: direct anon/authenticated policy remains on %.%: %',
            r.schemaname,
            r.tablename,
            r.policyname;

    end loop;

end;
$$;


-- =====================================================
-- 8. RLS / FORCE RLS VALIDATION
-- =====================================================

do $$
declare
    r record;
    v_relrowsecurity boolean;
    v_relforcerowsecurity boolean;
begin

    for r in
        select
            s.table_schema,
            s.table_name,
            s.rls_required,
            s.force_rls_required
        from platform.security_table_registry s
        where s.is_active = true
    loop

        select
            c.relrowsecurity,
            c.relforcerowsecurity
        into
            v_relrowsecurity,
            v_relforcerowsecurity
        from pg_class c
        join pg_namespace n
          on n.oid = c.relnamespace
        where n.nspname = r.table_schema
          and c.relname = r.table_name
          and c.relkind in ('r', 'p');


        if not found then

            raise exception
                '021 security hardening failed: table %.% not found in pg_class',
                r.table_schema,
                r.table_name;

        end if;


        if r.rls_required
           and v_relrowsecurity is distinct from true then

            raise exception
                '021 security hardening failed: RLS not enabled on %.%',
                r.table_schema,
                r.table_name;

        end if;


        if r.force_rls_required
           and v_relforcerowsecurity is distinct from true then

            raise exception
                '021 security hardening failed: FORCE RLS not enabled on %.%',
                r.table_schema,
                r.table_name;

        end if;

    end loop;

end;
$$;


-- =====================================================
-- 9. SECURITY DEFINER HARDENING
-- =====================================================
--
-- Automatically discovers all SECURITY DEFINER functions
-- in public and platform.
--
-- All discovered SECURITY DEFINER functions receive:
--
--     search_path = ''
--
-- No manual function list is required.
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            p.oid,
            n.nspname as schema_name,
            p.proname as function_name,
            pg_get_function_identity_arguments(p.oid)
                as arguments
        from pg_proc p
        join pg_namespace n
          on n.oid = p.pronamespace
        where p.prokind = 'f'
          and p.prosecdef = true
          and n.nspname in ('public', 'platform')
        order by
            n.nspname,
            p.proname,
            pg_get_function_identity_arguments(p.oid)
    loop

        execute format(
            'alter function %I.%I(%s) set search_path = ''''',
            r.schema_name,
            r.function_name,
            r.arguments
        );

    end loop;

end;
$$;

-- =====================================================
-- 10. SECURITY DEFINER RELATION DEPENDENCY VALIDATION
-- =====================================================
--
-- SECURITY DEFINER functions may only resolve static
-- relation dependencies inside explicitly approved schemas.
--
-- Approved:
--   pg_catalog
--   information_schema
--   public
--   platform
-- =====================================================

do $$
declare
    r record;
    d record;

    v_allowed_schemas text[] := array[
        'pg_catalog',
        'information_schema',
        'public',
        'platform'
    ];

begin

    for r in
        select
            p.oid,
            n.nspname as schema_name,
            p.proname as function_name,
            pg_get_function_identity_arguments(p.oid)
                as arguments
        from pg_proc p
        join pg_namespace n
          on n.oid = p.pronamespace
        where p.prokind = 'f'
          and p.prosecdef = true
          and n.nspname in ('public', 'platform')
    loop

        for d in
            select distinct
                dep_ns.nspname as dependency_schema,
                dep_cls.relname as dependency_name,
                dep_cls.relkind as dependency_kind
            from pg_depend dep
            join pg_class dep_cls
              on dep_cls.oid = dep.refobjid
            join pg_namespace dep_ns
              on dep_ns.oid = dep_cls.relnamespace
            where dep.classid = 'pg_proc'::regclass
              and dep.objid = r.oid
              and dep.refclassid = 'pg_class'::regclass
              and dep.deptype <> 'p'
        loop

            if not (
                d.dependency_schema = any(v_allowed_schemas)
            ) then

                raise exception
                    '021 security hardening failed: SECURITY DEFINER %.%(%s) depends on non-approved relation %.%',
                    r.schema_name,
                    r.function_name,
                    r.arguments,
                    d.dependency_schema,
                    d.dependency_name;

            end if;

        end loop;


        for d in
            select distinct
                dep_ns.nspname as dependency_schema,
                dep_proc.proname as dependency_name,
                pg_get_function_identity_arguments(
                    dep_proc.oid
                ) as dependency_arguments
            from pg_depend dep
            join pg_proc dep_proc
              on dep_proc.oid = dep.refobjid
            join pg_namespace dep_ns
              on dep_ns.oid = dep_proc.pronamespace
            where dep.classid = 'pg_proc'::regclass
              and dep.objid = r.oid
              and dep.refclassid = 'pg_proc'::regclass
              and dep.deptype <> 'p'
        loop

            if not (
                d.dependency_schema = any(v_allowed_schemas)
            ) then

                raise exception
                    '021 security hardening failed: SECURITY DEFINER %.%(%s) depends on non-approved function %.%(%)',
                    r.schema_name,
                    r.function_name,
                    r.arguments,
                    d.dependency_schema,
                    d.dependency_name,
                    d.dependency_arguments;

            end if;

        end loop;

    end loop;

end;
$$;


-- =====================================================
-- 11. DYNAMIC SQL VALIDATION
-- =====================================================
--
-- Static pg_depend validation cannot prove the security
-- of dynamically constructed identifiers.
--
-- Therefore SECURITY DEFINER functions containing
-- EXECUTE require explicit security review.
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            p.oid,
            n.nspname as schema_name,
            p.proname as function_name,
            pg_get_function_identity_arguments(p.oid)
                as arguments,
            pg_get_functiondef(p.oid) as definition
        from pg_proc p
        join pg_namespace n
          on n.oid = p.pronamespace
        where p.prokind = 'f'
          and p.prosecdef = true
          and n.nspname in ('public', 'platform')
    loop

        if r.definition ~* '\mEXECUTE\M' then

            if not exists (
                select 1
                from platform.security_dynamic_sql_review s
                where s.function_schema = r.schema_name
                  and s.function_name = r.function_name
                  and s.identity_arguments = r.arguments
                  and s.review_status = 'approved'
            ) then

                raise exception
                    '018b security hardening failed: SECURITY DEFINER %.%(%s) contains dynamic SQL without approved security review',
                    r.schema_name,
                    r.function_name,
                    r.arguments;

            end if;

        end if;

    end loop;

end;
$$;

-- =====================================================
-- 12. FINAL SECURITY DEFINER SEARCH_PATH VALIDATION
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            p.oid,
            n.nspname as schema_name,
            p.proname as function_name,
            pg_get_function_identity_arguments(p.oid)
                as arguments,
            p.proconfig
        from pg_proc p
        join pg_namespace n
            on n.oid = p.pronamespace
        where p.prokind = 'f'
          and p.prosecdef = true
          and n.nspname in ('public', 'platform')
    loop

        if not exists (
            select 1
            from unnest(
                coalesce(
                    r.proconfig,
                    array[]::text[]
                )
            ) cfg
            where cfg = 'search_path=""'
        ) then

            raise exception
                '021 security hardening failed: SECURITY DEFINER %.%(%s) does not have search_path = ''''',
                r.schema_name,
                r.function_name,
                r.arguments;

        end if;

    end loop;

end;
$$;

-- =====================================================
-- 13. TENANT AUTHORITY VALIDATION
-- =====================================================

do $$
declare
    v_function_count integer;
begin

    select count(*)
    into v_function_count
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'resolve_active_tenant'
      and pg_get_function_identity_arguments(p.oid)
            = 'p_user_id uuid, p_verify_tenant_id uuid';

    if v_function_count = 0 then

        raise exception
            '021 security hardening failed: public.resolve_active_tenant(uuid, uuid) not found';

    end if;

end;
$$;

-- =====================================================
-- 14. REGISTRY / SECURITY CONSISTENCY VALIDATION
-- =====================================================
--
-- Every active registered table must:
--   - exist
--   - have RLS
--   - satisfy its declared FORCE RLS requirement
--   - have no anon/authenticated policy
--   - deny direct authenticated access by contract
-- =====================================================

do $$
declare
    r record;
    v_policy_count integer;
    v_rls boolean;
    v_force_rls boolean;
begin

    for r in
        select
            s.table_schema,
            s.table_name,
            s.direct_authenticated_access,
            s.rls_required,
            s.force_rls_required
        from platform.security_table_registry s
        where s.is_active = true
    loop

        select
            c.relrowsecurity,
            c.relforcerowsecurity
        into
            v_rls,
            v_force_rls
        from pg_class c
        join pg_namespace n
          on n.oid = c.relnamespace
        where n.nspname = r.table_schema
          and c.relname = r.table_name
          and c.relkind in ('r', 'p');


        if not found then

            raise exception
                '021 security hardening failed: registry table %.% disappeared',
                r.table_schema,
                r.table_name;

        end if;


        -- -------------------------------------------------
        -- RLS requirement
        -- -------------------------------------------------

        if r.rls_required
           and v_rls is distinct from true then

            raise exception
                '021 security hardening failed: registry table %.% has RLS disabled',
                r.table_schema,
                r.table_name;

        end if;


        -- -------------------------------------------------
        -- FORCE RLS requirement
        -- -------------------------------------------------

        if r.force_rls_required
           and v_force_rls is distinct from true then

            raise exception
                '021 security hardening failed: FORCE RLS disabled on %.%',
                r.table_schema,
                r.table_name;

        end if;


        -- -------------------------------------------------
        -- Direct authenticated access
        -- -------------------------------------------------

        if r.direct_authenticated_access is distinct from false then

            raise exception
                '021 security hardening failed: registry table %.% permits direct authenticated access',
                r.table_schema,
                r.table_name;

        end if;


        -- -------------------------------------------------
        -- Direct anon/authenticated policies
        -- -------------------------------------------------

        select count(*)
        into v_policy_count
        from pg_policies
        where schemaname = r.table_schema
          and tablename = r.table_name
          and (
              'anon' = any(roles)
              or 'authenticated' = any(roles)
          );


        if v_policy_count > 0 then

            raise exception
                '021 security hardening failed: registry table %.% still has anon/authenticated policies',
                r.table_schema,
                r.table_name;

        end if;

    end loop;

end;
$$;

-- =====================================================
-- 15. SECURITY MODEL DOCUMENTATION
-- =====================================================

comment on table platform.security_table_registry is
'Central security classification for governed tables. security_class identifies business versus backend ownership. portal_access defines whether controlled portal access exists through approved API/RPC contracts. Direct authenticated table access is prohibited. 021 enforces RLS/FORCE RLS and removes legacy direct-table policies. 023 owns all privileges and grants/revokes.';

-- =====================================================
-- 16. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations ( migration_name, version, rollback_available)
values ( '021_security_hardening', 'REV1', false)
on conflict (migration_name) do nothing;

commit;