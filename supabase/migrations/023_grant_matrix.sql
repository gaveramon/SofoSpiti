-- =====================================================
-- REV2 GREENFIELD BASELINE
-- 023_GRANT_MATRIX.SQL
-- =====================================================
--
-- ENTERPRISE SECURITY GRANT BOUNDARY
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
-- 021 OWNS
-- ----------
-- platform.security_actor
-- platform.security_table_actor
--
-- 023 OWNS
-- ----------
-- PostgreSQL privilege boundary
-- schema privileges
-- table privileges
-- sequence privileges
-- view privileges
-- function EXECUTE privileges
-- authenticated RPC exposure
-- security registry protection
-- final grant validation
--
-- 023 DOES NOT OWN
-- -----------------
-- RLS creation
-- RLS policies
-- FORCE RLS creation
-- SECURITY DEFINER creation
-- search_path hardening
--
-- Those belong to 020.
--
-- GRANT MODEL
-- =====================================================
--
-- security_actor.privilege_profile determines WHAT
-- an actor may do.
--
-- security_table_actor determines WHERE the actor
-- may exercise those privileges.
--
-- Profiles:
--
-- none
--     no direct table privileges
--
-- api_only
--     no direct table privileges
--     access is through API/RPC only
--
-- read
--     SELECT
--
-- append
--     SELECT
--     INSERT
--
-- write
--     SELECT
--     INSERT
--     UPDATE
--
-- full
--     SELECT
--     INSERT
--     UPDATE
--     DELETE
--
--
-- IMPORTANT
-- =====================================================
--
-- Logical backend actors normally execute through the
-- Supabase service_role.
--
-- PostgreSQL therefore receives the UNION of the
-- privileges required by active service_role actors.
--
-- The actor registry remains the authoritative security
-- model, while function/API boundaries distinguish the
-- logical actors.
--
-- =====================================================

begin;

-- =====================================================
-- 1. PRECONDITIONS
-- =====================================================

do $$
begin

    if to_regclass('platform.security_actor') is null then
        raise exception
            '023 prerequisite missing: platform.security_actor';
    end if;

    if to_regclass('platform.security_table_actor') is null then
        raise exception
            '023 prerequisite missing: platform.security_table_actor';
    end if;

    if to_regclass('platform.security_table_registry') is null then
        raise exception
            '023 prerequisite missing: platform.security_table_registry';
    end if;

    if to_regclass('platform.security_view_registry') is null then
        raise exception
            '023 prerequisite missing: platform.security_view_registry';
    end if;

end
$$;


-- =====================================================
-- 2. VALIDATE ACTOR PRIVILEGE PROFILES
-- =====================================================

do $$
begin

    if exists (
        select 1
        from platform.security_actor
        where privilege_profile is null
           or privilege_profile not in (
                'none',
                'api_only',
                'read',
                'append',
                'write',
                'full'
           )
    ) then

        raise exception
            '023 validation failed: invalid actor privilege_profile';

    end if;

end
$$;


-- =====================================================
-- 3. VALIDATE AUTH ROLE / PRIVILEGE PROFILE COMBINATIONS
-- =====================================================
--
-- authenticated actors may only be API actors.
--
-- Direct authenticated table access is deliberately
-- prohibited by the security model.
-- =====================================================

do $$
begin

    if exists (
        select 1
        from platform.security_actor
        where is_active
          and auth_role = 'authenticated'
          and privilege_profile not in (
              'none',
              'api_only'
          )
    ) then

        raise exception
            '023 validation failed: authenticated actor has direct table privilege profile';

    end if;

end
$$;


-- =====================================================
-- 4. GLOBAL SCHEMA RESET
-- =====================================================

revoke all
on schema public
from public;

revoke all
on schema platform
from public;


-- =====================================================
-- 5. SCHEMA USAGE
-- =====================================================
--
-- public:
--   authenticated needs schema visibility for RPC calls.
--
-- platform:
--   service_role only.
--
-- =====================================================

grant usage
on schema public
to authenticated;

grant usage
on schema public
to service_role;

grant usage
on schema platform
to service_role;


-- =====================================================
-- 6. RESET APPLICATION FUNCTION / PROCEDURE PRIVILEGES
-- =====================================================
--
-- Application-owned routines are deny-by-default.
--
-- anon and authenticated receive no EXECUTE unless
-- explicitly granted later by the approved API/RPC matrix.
--
-- service_role is intentionally preserved.
--
-- Extension-owned routines are excluded.
-- =====================================================

do $$
declare
    r record;
begin

    -- -------------------------------------------------
    -- Functions
    -- -------------------------------------------------

    for r in
        select
            n.nspname as schema_name,
            p.proname as object_name,
            pg_get_function_identity_arguments(p.oid) as args
        from pg_proc p
        join pg_namespace n
            on n.oid = p.pronamespace
        where n.nspname in ('public', 'platform')
          and p.prokind = 'f'
          and not exists (
              select 1
              from pg_depend d
              where d.classid = 'pg_proc'::regclass
                and d.objid = p.oid
                and d.deptype = 'e'
          )
    loop

        execute format(
            'revoke all on function %I.%I(%s) from public, anon, authenticated',
            r.schema_name,
            r.object_name,
            r.args
        );

    end loop;


    -- -------------------------------------------------
    -- Procedures
    -- -------------------------------------------------

    for r in
        select
            n.nspname as schema_name,
            p.proname as object_name,
            pg_get_function_identity_arguments(p.oid) as args
        from pg_proc p
        join pg_namespace n
            on n.oid = p.pronamespace
        where n.nspname in ('public', 'platform')
          and p.prokind = 'p'
          and not exists (
              select 1
              from pg_depend d
              where d.classid = 'pg_proc'::regclass
                and d.objid = p.oid
                and d.deptype = 'e'
          )
    loop

        execute format(
            'revoke all on procedure %I.%I(%s) from public, anon, authenticated',
            r.schema_name,
            r.object_name,
            r.args
        );

    end loop;

end
$$;


-- =====================================================
-- 7. GLOBAL TABLE PRIVILEGE RESET
-- =====================================================
--
-- anon/authenticated receive no direct table access.
--
-- service_role is intentionally NOT globally revoked here;
-- its final privileges are rebuilt from the actor matrix
-- below.
--
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            n.nspname as schema_name,
            c.relname as table_name
        from pg_class c
        join pg_namespace n
            on n.oid = c.relnamespace
        where n.nspname in ('public', 'platform')
          and c.relkind in ('r', 'p', 'f')
    loop

        execute format(
            'revoke all on table %I.%I from anon, authenticated',
            r.schema_name,
            r.table_name
        );

    end loop;

end
$$;


-- =====================================================
-- 8. GLOBAL VIEW PRIVILEGE RESET
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            n.nspname as schema_name,
            c.relname as relation_name
        from pg_class c
        join pg_namespace n
            on n.oid = c.relnamespace
        where n.nspname in ('public', 'platform')
          and c.relkind in ('v', 'm')
    loop

        execute format(
            'revoke all on table %I.%I from anon, authenticated',
            r.schema_name,
            r.relation_name
        );

    end loop;

end
$$;


-- =====================================================
-- 9. GLOBAL SEQUENCE RESET
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            n.nspname as sequence_schema,
            c.relname as sequence_name
        from pg_class c
        join pg_namespace n
            on n.oid = c.relnamespace
        where n.nspname in ('public', 'platform')
          and c.relkind = 'S'
    loop

        execute format(
            'revoke all on sequence %I.%I from public, anon, authenticated',
            r.sequence_schema,
            r.sequence_name
        );

    end loop;

end
$$;


-- =====================================================
-- 10. VALIDATE TABLE REGISTRY
-- =====================================================

do $$
declare
    r record;
begin

    -- -------------------------------------------------
    -- 10.1 VALIDATE SECURITY CLASS
    -- -------------------------------------------------

    select
        table_schema,
        table_name,
        security_class
    into r
    from platform.security_table_registry
    where is_active
      and (
            security_class is null
            or security_class not in (
                'business',
                'backend'
            )
          )
    order by table_schema, table_name
    limit 1;

    if found then

        raise exception
            '023 validation failed: invalid security_class for %.% (security_class=%)',
            r.table_schema,
            r.table_name,
            coalesce(r.security_class, 'NULL');

    end if;


    -- -------------------------------------------------
    -- 10.2 BUSINESS TABLES MUST USE RPC PORTAL ACCESS
    -- -------------------------------------------------

    select
        table_schema,
        table_name,
        security_class,
        portal_access
    into r
    from platform.security_table_registry
    where is_active
      and security_class = 'business'
      and (
            portal_access is null
            or portal_access <> 'rpc'
          )
    order by table_schema, table_name
    limit 1;

    if found then

        raise exception
            '023 validation failed: business table without rpc portal_access: %.% (security_class=%, portal_access=%)',
            r.table_schema,
            r.table_name,
            r.security_class,
            coalesce(r.portal_access, 'NULL');

    end if;


    -- -------------------------------------------------
    -- 10.3 BACKEND TABLES MUST NOT HAVE PORTAL ACCESS
    -- -------------------------------------------------

    select
        table_schema,
        table_name,
        security_class,
        portal_access
    into r
    from platform.security_table_registry
    where is_active
      and security_class = 'backend'
      and (
            portal_access is null
            or portal_access <> 'none'
          )
    order by table_schema, table_name
    limit 1;

    if found then

        raise exception
            '023 validation failed: backend table with portal access: %.% (security_class=%, portal_access=%)',
            r.table_schema,
            r.table_name,
            r.security_class,
            coalesce(r.portal_access, 'NULL');

    end if;


    -- -------------------------------------------------
    -- 10.4 DIRECT AUTHENTICATED ACCESS IS PROHIBITED
    -- -------------------------------------------------

    select
        table_schema,
        table_name,
        security_class,
        portal_access,
        direct_authenticated_access
    into r
    from platform.security_table_registry
    where is_active
      and direct_authenticated_access is true
    order by table_schema, table_name
    limit 1;

    if found then

        raise exception
            '023 validation failed: direct authenticated access prohibited for %.% (security_class=%, portal_access=%, direct_authenticated_access=%)',
            r.table_schema,
            r.table_name,
            r.security_class,
            coalesce(r.portal_access, 'NULL'),
            r.direct_authenticated_access;

    end if;

end
$$;


-- =====================================================
-- 11. VALIDATE REGISTERED TABLES EXIST
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
        where is_active
    loop

        if to_regclass(
            format(
                '%I.%I',
                r.table_schema,
                r.table_name
            )
        ) is null then

            raise exception
                '023 validation failed: registered table %.% does not exist',
                r.table_schema,
                r.table_name;

        end if;

    end loop;

end
$$;


-- =====================================================
-- 12. VALIDATE ACTIVE TABLES HAVE ACTOR ASSIGNMENTS
-- =====================================================
--
-- Every active governed table must have at least one
-- active security actor assignment.
--
-- Security registries themselves are excluded because
-- they are protected explicitly later in this migration.
--
-- Relationship:
--
--   security_table_registry
--       (table_schema, table_name)
--                 |
--                 | FK
--                 v
--   security_table_actor
--       (table_schema, table_name, actor_id)
--
-- There is NO security_table_registry.id column.
-- There is NO security_table_actor.security_table_id column.
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            str.table_schema,
            str.table_name
        from platform.security_table_registry str
        where str.is_active
          and not (
              str.table_schema = 'platform'
              and str.table_name in (
                  'security_table_registry',
                  'security_actor',
                  'security_table_actor',
                  'security_view_registry'
              )
          )
        order by
            str.table_schema,
            str.table_name
    loop

        if not exists (
            select 1
            from platform.security_table_actor sta
            where sta.table_schema = r.table_schema
              and sta.table_name = r.table_name
              and sta.is_active
        ) then

            raise exception
                '023 validation failed: active table %.% has no active actor assignment',
                r.table_schema,
                r.table_name;

        end if;

    end loop;

end
$$;


-- =====================================================
-- 13. VALIDATE TABLE -> ACTOR REFERENCES
-- =====================================================

do $$
begin

    if exists (
        select 1
        from platform.security_table_actor sta
        left join platform.security_table_registry str
            on str.table_schema = sta.table_schema
           and str.table_name = sta.table_name
        left join platform.security_actor sa
            on sa.id = sta.actor_id
        where sta.is_active
          and (
              str.table_schema is null
              or str.table_name is null
              or sa.id is null
              or not sa.is_active
          )
    ) then

        raise exception
            '023 validation failed: active table actor references inactive/missing table or actor';

    end if;

end
$$;


-- =====================================================
-- 14. VALIDATE ACTOR ASSIGNMENTS AGAINST TABLE CLASS
-- =====================================================
--
-- api_only / none actors do not create direct table grants.
--
-- Portal actors must not receive direct table privileges.
--
-- Authenticated actors must not receive direct table
-- privileges.
--
-- Registry relationship:
--
--   security_table_registry
--       (table_schema, table_name)
--                 |
--                 | FK
--                 v
--   security_table_actor
--       (table_schema, table_name, actor_id)
--
-- There is NO security_table_registry.id.
-- There is NO security_table_actor.security_table_id.
-- =====================================================

do $$
begin

    -- -------------------------------------------------
    -- 14.1 PORTAL ACTORS
    -- -------------------------------------------------

    if exists (
        select 1
        from platform.security_table_actor sta
        join platform.security_actor sa
            on sa.id = sta.actor_id
        join platform.security_table_registry str
            on str.table_schema = sta.table_schema
           and str.table_name = sta.table_name
        where sta.is_active
          and sa.is_active
          and str.is_active
          and sa.actor_type = 'portal'
          and sa.privilege_profile not in (
              'none',
              'api_only'
          )
    ) then

        raise exception
            '023 validation failed: portal actor has direct table privilege profile';

    end if;


    -- -------------------------------------------------
    -- 14.2 AUTHENTICATED ACTORS
    -- -------------------------------------------------

    if exists (
        select 1
        from platform.security_table_actor sta
        join platform.security_actor sa
            on sa.id = sta.actor_id
        join platform.security_table_registry str
            on str.table_schema = sta.table_schema
           and str.table_name = sta.table_name
        where sta.is_active
          and sa.is_active
          and str.is_active
          and sa.auth_role = 'authenticated'
          and sa.privilege_profile not in (
              'none',
              'api_only'
          )
    ) then

        raise exception
            '023 validation failed: authenticated actor has direct table privilege profile';

    end if;

end
$$;


-- =====================================================
-- 15. REBUILD SERVICE_ROLE TABLE PRIVILEGES
-- =====================================================
--
-- service_role receives the UNION of all privileges
-- required by active actors with auth_role = service_role.
--
-- The rebuild is deterministic:
--   1. revoke all service_role privileges on governed tables
--   2. rebuild privileges from the active actor matrix
--
-- Security registry tables are excluded here and are
-- handled explicitly in section 22.
--
-- privilege profiles:
--   none     => nothing
--   api_only => nothing
--   read     => SELECT
--   append   => SELECT + INSERT
--   write    => SELECT + INSERT + UPDATE
--   full     => SELECT + INSERT + UPDATE + DELETE
-- =====================================================

do $$
declare
    r record;
begin

    -- -------------------------------------------------
    -- 15.1 Reset service_role privileges
    -- -------------------------------------------------
    --
    -- Remove any stale privileges from previously
    -- assigned actors or privilege profiles.
    --
    -- Security registry tables are intentionally excluded.
    -- They are handled explicitly in section 22.
    -- -------------------------------------------------

    for r in
        select
            str.table_schema,
            str.table_name
        from platform.security_table_registry str
        where str.is_active
          and not (
                str.table_schema = 'platform'
                and str.table_name in (
                    'security_actor',
                    'security_table_registry',
                    'security_table_actor',
                    'security_function_registry'
                )
          )
    loop
        execute format(
            'revoke all on table %I.%I from service_role',
            r.table_schema,
            r.table_name
        );
    end loop;


    -- -------------------------------------------------
    -- 15.2 Rebuild service_role privileges
    -- -------------------------------------------------
    --
    -- The effective privilege set is the UNION of all
    -- active service_role actors assigned to the table.
    -- -------------------------------------------------

    for r in
        select distinct
            str.table_schema,
            str.table_name,
            sa.privilege_profile
        from platform.security_table_actor sta
        join platform.security_actor sa
            on sa.id = sta.actor_id
        join platform.security_table_registry str
            on str.table_schema = sta.table_schema
           and str.table_name = sta.table_name
        where sta.is_active
          and sa.is_active
          and sa.auth_role = 'service_role'
          and str.is_active
          and sa.privilege_profile not in (
              'none',
              'api_only'
          )
          and not (
              str.table_schema = 'platform'
              and str.table_name in (
                  'security_actor',
                  'security_table_registry',
                  'security_table_actor',
                  'security_function_registry'
              )
          )
    loop

        -- ---------------------------------------------
        -- read
        -- append
        -- write
        -- full
        -- ---------------------------------------------

        if r.privilege_profile in (
            'read',
            'append',
            'write',
            'full'
        ) then

            execute format(
                'grant select on table %I.%I to service_role',
                r.table_schema,
                r.table_name
            );

        end if;


        -- ---------------------------------------------
        -- append
        -- write
        -- full
        -- ---------------------------------------------

        if r.privilege_profile in (
            'append',
            'write',
            'full'
        ) then

            execute format(
                'grant insert on table %I.%I to service_role',
                r.table_schema,
                r.table_name
            );

        end if;


        -- ---------------------------------------------
        -- write
        -- full
        -- ---------------------------------------------

        if r.privilege_profile in (
            'write',
            'full'
        ) then

            execute format(
                'grant update on table %I.%I to service_role',
                r.table_schema,
                r.table_name
            );

        end if;


        -- ---------------------------------------------
        -- full
        -- ---------------------------------------------

        if r.privilege_profile = 'full' then

            execute format(
                'grant delete on table %I.%I to service_role',
                r.table_schema,
                r.table_name
            );

        end if;

    end loop;

end
$$;

-- =====================================================
-- 16. SEQUENCE PRIVILEGES
-- =====================================================
--
-- Sequence access follows the INSERT capability of the
-- actor profile.
--
-- A sequence is granted only when it belongs to a table
-- for which an active service_role actor has INSERT access.
--
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select distinct
            seq_ns.nspname as sequence_schema,
            seq.relname as sequence_name
        from pg_class seq
        join pg_namespace seq_ns
            on seq_ns.oid = seq.relnamespace
        join pg_depend dep
            on dep.objid = seq.oid
           and dep.deptype = 'a'
        join pg_class tbl
            on tbl.oid = dep.refobjid
        join pg_namespace tbl_ns
            on tbl_ns.oid = tbl.relnamespace
        join platform.security_table_registry str
            on str.table_schema = tbl_ns.nspname
           and str.table_name = tbl.relname
        join platform.security_table_actor sta
            on sta.table_schema = str.table_schema
           and sta.table_name = str.table_name
           and sta.is_active
        join platform.security_actor sa
            on sa.id = sta.actor_id
           and sa.is_active
        where seq.relkind = 'S'
          and seq_ns.nspname in ('public', 'platform')
          and str.is_active
          and sa.auth_role = 'service_role'
          and sa.privilege_profile in (
              'append',
              'write',
              'full'
          )
    loop

        execute format(
            'grant usage, select, update on sequence %I.%I to service_role',
            r.sequence_schema,
            r.sequence_name
        );

    end loop;

end
$$;


-- =====================================================
-- 17. VIEW REGISTRY VALIDATION
-- =====================================================
--
-- The existing view registry is authoritative for views.
--
-- No view may expose direct authenticated access.
-- =====================================================

do $$
begin

    if exists (
        select 1
        from platform.security_view_registry
        where is_active
          and (
              portal_access is null
              or portal_access is true
              or direct_authenticated_access is null
              or direct_authenticated_access is true
          )
    ) then

        raise exception
            '023 validation failed: security_view_registry contains direct portal/authenticated access';

    end if;

end
$$;


-- =====================================================
-- 18. SERVICE_ROLE VIEW ACCESS
-- =====================================================
--
-- Registered security views are backend-readable.
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            view_schema,
            view_name
        from platform.security_view_registry
        where is_active
    loop

        if to_regclass(
            format(
                '%I.%I',
                r.view_schema,
                r.view_name
            )
        ) is null then

            raise exception
                '023 validation failed: registered view %.% does not exist',
                r.view_schema,
                r.view_name;

        end if;


        execute format(
            'grant select on table %I.%I to service_role',
            r.view_schema,
            r.view_name
        );

    end loop;

end
$$;


-- =====================================================
-- 19. APPROVED AUTHENTICATED API / RPC SURFACE
-- =====================================================

grant execute on function public.auth_api(text, jsonb)
to authenticated;

grant execute on function public.booking_api(text, jsonb)
to authenticated;

grant execute on function public.devices_api(text, jsonb)
to authenticated;

grant execute on function public.crm_api(text, jsonb)
to authenticated;

grant execute on function public.commerce_api(text, jsonb)
to authenticated;

grant execute on function public.integrations_api(text, jsonb)
to authenticated;

grant execute on function public.locks_api(text, jsonb)
to authenticated;

grant execute on function public.logistics_api(text, jsonb)
to authenticated;

grant execute on function public.notification_api(text, jsonb)
to authenticated;

grant execute on function public.onboarding_api(text, jsonb)
to authenticated;

grant execute on function public.operations_api(text, jsonb)
to authenticated;

grant execute on function public.optimization_api(text, jsonb)
to authenticated;

grant execute on function public.payment_api(text, jsonb)
to authenticated;

grant execute on function public.portal_api(text, jsonb)
to authenticated;

grant execute on function public.preconfig_api(text, jsonb)
to authenticated;

grant execute on function public.automation_api(text, jsonb)
to authenticated;

grant execute on function public.monetization_api(text, jsonb)
to authenticated;


-- =====================================================
-- 20. AUTHORIZATION HELPERS
-- =====================================================

grant execute on function platform.current_tenant_id()
to authenticated;

grant execute on function platform.has_role(text)
to authenticated;

grant execute on function platform.has_permission(text)
to authenticated;


-- =====================================================
-- 21. PROTECT TENANT RESOLUTION
-- =====================================================
--
-- resolve_active_tenant is internal authorization
-- infrastructure and must not be directly callable
-- by anon/authenticated.
--
-- IMPORTANT:
-- only functions are processed here.
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            n.nspname as schema_name,
            p.proname as function_name,
            pg_get_function_identity_arguments(p.oid) as args
        from pg_proc p
        join pg_namespace n
            on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname = 'resolve_active_tenant'
          and p.prokind = 'f'
    loop

        execute format(
            'revoke execute on function %I.%I(%s) from anon, authenticated',
            r.schema_name,
            r.function_name,
            r.args
        );

    end loop;

end
$$;


-- =====================================================
-- 22. PROTECT SECURITY REGISTRIES
-- =====================================================
--
-- Security metadata is service_role only.
-- =====================================================

revoke all
on table platform.security_table_registry
from public, anon, authenticated;

grant select, insert, update, delete
on table platform.security_table_registry
to service_role;


revoke all
on table platform.security_actor
from public, anon, authenticated;

grant select, insert, update, delete
on table platform.security_actor
to service_role;


revoke all
on table platform.security_table_actor
from public, anon, authenticated;

grant select, insert, update, delete
on table platform.security_table_actor
to service_role;


revoke all
on table platform.security_view_registry
from public, anon, authenticated;

grant select, insert, update, delete
on table platform.security_view_registry
to service_role;


-- =====================================================
-- 23. SECURITY REGISTRY SEQUENCES
-- =====================================================
--
-- Registry UUIDs normally use gen_random_uuid(), so there
-- should be no sequence dependency.
--
-- No sequence grant is created merely because a registry
-- table exists.
--
-- =====================================================


-- =====================================================
-- 24. VALIDATE ANON HAS NO DIRECT TABLE ACCESS
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            n.nspname as schema_name,
            c.relname as relation_name
        from pg_class c
        join pg_namespace n
            on n.oid = c.relnamespace
        where n.nspname in ('public', 'platform')
          and c.relkind in ('r', 'p', 'f')
    loop

        if has_table_privilege(
            'anon',
            format(
                '%I.%I',
                r.schema_name,
                r.relation_name
            ),
            'SELECT'
        )
        or has_table_privilege(
            'anon',
            format(
                '%I.%I',
                r.schema_name,
                r.relation_name
            ),
            'INSERT'
        )
        or has_table_privilege(
            'anon',
            format(
                '%I.%I',
                r.schema_name,
                r.relation_name
            ),
            'UPDATE'
        )
        or has_table_privilege(
            'anon',
            format(
                '%I.%I',
                r.schema_name,
                r.relation_name
            ),
            'DELETE'
        ) then

            raise exception
                '023 validation failed: anon has direct table access on %.%',
                r.schema_name,
                r.relation_name;

        end if;

    end loop;

end
$$;


-- =====================================================
-- 25. VALIDATE AUTHENTICATED HAS NO DIRECT TABLE ACCESS
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            n.nspname as schema_name,
            c.relname as relation_name
        from pg_class c
        join pg_namespace n
            on n.oid = c.relnamespace
        where n.nspname in ('public', 'platform')
          and c.relkind in ('r', 'p', 'f')
    loop

        if has_table_privilege(
            'authenticated',
            format(
                '%I.%I',
                r.schema_name,
                r.relation_name
            ),
            'SELECT'
        )
        or has_table_privilege(
            'authenticated',
            format(
                '%I.%I',
                r.schema_name,
                r.relation_name
            ),
            'INSERT'
        )
        or has_table_privilege(
            'authenticated',
            format(
                '%I.%I',
                r.schema_name,
                r.relation_name
            ),
            'UPDATE'
        )
        or has_table_privilege(
            'authenticated',
            format(
                '%I.%I',
                r.schema_name,
                r.relation_name
            ),
            'DELETE'
        ) then

            raise exception
                '023 validation failed: authenticated has direct table access on %.%',
                r.schema_name,
                r.relation_name;

        end if;

    end loop;

end
$$;


-- =====================================================
-- 26. VALIDATE APPROVED RPC FUNCTIONS EXIST
-- =====================================================

do $$
declare
    required_function text;
begin

    foreach required_function in array array[
        'public.auth_api(text,jsonb)',
        'public.booking_api(text,jsonb)',
        'public.devices_api(text,jsonb)',
        'public.crm_api(text,jsonb)',
        'public.commerce_api(text,jsonb)',
        'public.integrations_api(text,jsonb)',
        'public.locks_api(text,jsonb)',
        'public.logistics_api(text,jsonb)',
        'public.notification_api(text,jsonb)',
        'public.onboarding_api(text,jsonb)',
        'public.operations_api(text,jsonb)',
        'public.optimization_api(text,jsonb)',
        'public.payment_api(text,jsonb)',
        'public.portal_api(text,jsonb)',
        'public.preconfig_api(text,jsonb)',
        'public.automation_api(text,jsonb)',
        'public.monetization_api(text,jsonb)'
    ]
    loop

        if to_regprocedure(required_function) is null then

            raise exception
                '023 validation failed: approved API function missing: %',
                required_function;

        end if;

    end loop;

end
$$;


-- =====================================================
-- 27. VALIDATE APPROVED RPC EXECUTE PRIVILEGES
-- =====================================================

do $$
declare
    required_function text;
begin

    foreach required_function in array array[
        'public.auth_api(text,jsonb)',
        'public.booking_api(text,jsonb)',
        'public.devices_api(text,jsonb)',
        'public.crm_api(text,jsonb)',
        'public.commerce_api(text,jsonb)',
        'public.integrations_api(text,jsonb)',
        'public.locks_api(text,jsonb)',
        'public.logistics_api(text,jsonb)',
        'public.notification_api(text,jsonb)',
        'public.onboarding_api(text,jsonb)',
        'public.operations_api(text,jsonb)',
        'public.optimization_api(text,jsonb)',
        'public.payment_api(text,jsonb)',
        'public.portal_api(text,jsonb)',
        'public.preconfig_api(text,jsonb)',
        'public.automation_api(text,jsonb)',
        'public.monetization_api(text,jsonb)'
    ]
    loop

        if not has_function_privilege(
            'authenticated',
            required_function,
            'EXECUTE'
        ) then

            raise exception
                '023 validation failed: authenticated lacks EXECUTE on %',
                required_function;

        end if;

    end loop;

end
$$;


-- =====================================================
-- 28. VALIDATE NO UNAPPROVED AUTHENTICATED EXECUTE
-- =====================================================
--
-- Only:
--
--   approved API functions
--   authorization helpers
--
-- may be directly executed by authenticated.
--
-- Extension-owned functions are excluded from this
-- application authorization check.
--
-- Function identity is validated by PostgreSQL function
-- OID. Parameter names are therefore irrelevant.
--
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            n.nspname as schema_name,
            p.proname as function_name,
            pg_get_function_identity_arguments(p.oid) as args
        from pg_proc p
        join pg_namespace n
            on n.oid = p.pronamespace
        where n.nspname in ('public', 'platform')
          and p.prokind = 'f'
          and has_function_privilege(
              'authenticated',
              p.oid,
              'EXECUTE'
          )
          and not exists (
              select 1
              from pg_depend d
              where d.classid = 'pg_proc'::regclass
                and d.objid = p.oid
                and d.deptype = 'e'
          )

    loop

        if not exists (
            select 1
            from pg_proc approved_proc
            join pg_namespace approved_ns
                on approved_ns.oid = approved_proc.pronamespace
            where
                (
                    approved_ns.nspname = 'public'
                    and approved_proc.proname in (
                        'auth_api',
                        'booking_api',
                        'devices_api',
                        'crm_api',
                        'commerce_api',
                        'integrations_api',
                        'locks_api',
                        'logistics_api',
                        'notification_api',
                        'onboarding_api',
                        'operations_api',
                        'optimization_api',
                        'payment_api',
                        'portal_api',
                        'preconfig_api',
                        'automation_api',
                        'monetization_api'
                    )
                    and pg_get_function_identity_arguments(
                        approved_proc.oid
                    ) = 'p_op text, p_payload jsonb'
                )
                or
                (
                    approved_ns.nspname = 'platform'
                    and approved_proc.proname = 'current_tenant_id'
                    and pg_get_function_identity_arguments(
                        approved_proc.oid
                    ) = ''
                )
                or
                (
                    approved_ns.nspname = 'platform'
                    and approved_proc.proname in (
                        'has_role',
                        'has_permission'
                    )
                    and pg_get_function_identity_arguments(
                        approved_proc.oid
                    ) in (
                        'required_role text',
                        'required_permission text'
                    )
                )
            and approved_proc.oid = (
                select p2.oid
                from pg_proc p2
                join pg_namespace n2
                    on n2.oid = p2.pronamespace
                where n2.nspname = r.schema_name
                  and p2.proname = r.function_name
                  and pg_get_function_identity_arguments(p2.oid) = r.args
                limit 1
            )
        ) then

            raise exception
                '023 validation failed: unapproved authenticated EXECUTE privilege on %.%(%)',
                r.schema_name,
                r.function_name,
                r.args;

        end if;

    end loop;

end
$$;


-- =====================================================
-- 29. VALIDATE SERVICE_ROLE PRIVILEGES AGAINST ACTOR MATRIX
-- =====================================================
--
-- For every active service_role actor assignment:
--
-- read   => SELECT
-- append => SELECT + INSERT
-- write  => SELECT + INSERT + UPDATE
-- full   => SELECT + INSERT + UPDATE + DELETE
--
-- This validates the actual PostgreSQL boundary.
--
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select distinct
            str.table_schema,
            str.table_name,
            sa.privilege_profile
        from platform.security_table_actor sta
        join platform.security_actor sa
            on sa.id = sta.actor_id
        join platform.security_table_registry str
            on str.table_schema = sta.table_schema
           and str.table_name = sta.table_name
        where sta.is_active
          and sa.is_active
          and str.is_active
          and sa.auth_role = 'service_role'
          and sa.privilege_profile not in (
              'none',
              'api_only'
          )
    loop

        if r.privilege_profile in (
            'read',
            'append',
            'write',
            'full'
        )
        and not has_table_privilege(
            'service_role',
            format(
                '%I.%I',
                r.table_schema,
                r.table_name
            ),
            'SELECT'
        ) then

            raise exception
                '023 validation failed: service_role missing SELECT on %.%',
                r.table_schema,
                r.table_name;

        end if;


        if r.privilege_profile in (
            'append',
            'write',
            'full'
        )
        and not has_table_privilege(
            'service_role',
            format(
                '%I.%I',
                r.table_schema,
                r.table_name
            ),
            'INSERT'
        ) then

            raise exception
                '023 validation failed: service_role missing INSERT on %.%',
                r.table_schema,
                r.table_name;

        end if;


        if r.privilege_profile in (
            'write',
            'full'
        )
        and not has_table_privilege(
            'service_role',
            format(
                '%I.%I',
                r.table_schema,
                r.table_name
            ),
            'UPDATE'
        ) then

            raise exception
                '023 validation failed: service_role missing UPDATE on %.%',
                r.table_schema,
                r.table_name;

        end if;


        if r.privilege_profile = 'full'
        and not has_table_privilege(
            'service_role',
            format(
                '%I.%I',
                r.table_schema,
                r.table_name
            ),
            'DELETE'
        ) then

            raise exception
                '023 validation failed: service_role missing DELETE on %.%',
                r.table_schema,
                r.table_name;

        end if;

    end loop;

end
$$;


-- =====================================================
-- 30. VALIDATE BUSINESS TABLES ARE API-ONLY
-- =====================================================

do $$
begin

    if exists (
        select 1
        from platform.security_table_registry
        where is_active
          and security_class = 'business'
          and (
              portal_access is null
              or portal_access <> 'rpc'
              or direct_authenticated_access is null
              or direct_authenticated_access is true
          )
    ) then

        raise exception
            '023 validation failed: business table violates API/RPC-only boundary';

    end if;

end
$$;


-- =====================================================
-- 31. VALIDATE BACKEND TABLES ARE NOT PORTAL ACCESSIBLE
-- =====================================================

do $$
begin

    if exists (
        select 1
        from platform.security_table_registry
        where is_active
          and security_class = 'backend'
          and (
              portal_access is null
              or portal_access <> 'none'
          )
    ) then

        raise exception
            '023 validation failed: backend table is portal accessible';

    end if;

end
$$;


-- =====================================================
-- 32. VALIDATE RLS / FORCE RLS AGAINST REGISTRY
-- =====================================================
--
-- 020 owns the actual RLS implementation.
--
-- 023 only validates that PostgreSQL state matches
-- security_table_registry.
--
-- =====================================================

do $$
declare
    r record;
begin

    for r in
        select
            str.table_schema,
            str.table_name,
            str.rls_required,
            str.force_rls_required,
            c.relrowsecurity,
            c.relforcerowsecurity
        from platform.security_table_registry str
        join pg_class c
            on c.relname = str.table_name
        join pg_namespace n
            on n.oid = c.relnamespace
           and n.nspname = str.table_schema
        where str.is_active
    loop

        if r.rls_required is distinct from r.relrowsecurity then

            raise exception
                '023 validation failed: RLS mismatch on %.% expected %, actual %',
                r.table_schema,
                r.table_name,
                r.rls_required,
                r.relrowsecurity;

        end if;


        if r.force_rls_required is distinct from r.relforcerowsecurity then

            raise exception
                '023 validation failed: FORCE RLS mismatch on %.% expected %, actual %',
                r.table_schema,
                r.table_name,
                r.force_rls_required,
                r.relforcerowsecurity;

        end if;

    end loop;

end
$$;


-- =====================================================
-- 33. VALIDATE SERVICE_ROLE SCHEMA ACCESS
-- =====================================================

do $$
begin

    if not has_schema_privilege(
        'service_role',
        'public',
        'USAGE'
    ) then

        raise exception
            '023 validation failed: service_role lacks USAGE on public schema';

    end if;


    if not has_schema_privilege(
        'service_role',
        'platform',
        'USAGE'
    ) then

        raise exception
            '023 validation failed: service_role lacks USAGE on platform schema';

    end if;

end
$$;


-- =====================================================
-- 34. SECURITY AUDIT EVENT
-- =====================================================

insert into platform.event_log (
    event_type,
    source,
    payload
)
values (
    'security.grant_boundary.applied',
    'rev22_migration',
    jsonb_build_object(
        'version', 'REV2.GRANT.MATRIX.023',
        'model', 'actor_registry_driven',
        'privilege_source', 'security_actor.privilege_profile',
        'table_assignment_source', 'security_table_actor',
        'portal_access', 'api_rpc_only',
        'direct_authenticated_table_access', false,
        'anon_direct_table_access', false,
        'actor_matrix', true,
        'privilege_profiles', jsonb_build_array(
            'none',
            'api_only',
            'read',
            'append',
            'write',
            'full'
        ),
        'rls_owned_by', '020'
    )
);


-- =====================================================
-- 35. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations ( migration_name, version, rollback_available)
values ( '023_grant_matrix', 'REV1', false)
on conflict (migration_name) do nothing;


-- =====================================================
-- COMMIT
-- =====================================================

commit;