-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 013_SERVICE_PORTAL_ENGINE.SQL
-- =====================================================
--
-- CLEAN UI / PORTAL LAYER
-- =====================================================
--
-- NO LOGS / NO EVENTS / NO DOMAIN TRUTH / NO SUPPORT CASES
--
-- Tenant config SSOT: tenant_portal_settings.
-- Plan entitlements SSOT: feature_entitlements (010).
-- Support cases SSOT: support_tickets / support_messages (006).
-- Runtime logs SSOT: platform.event_log, operation_log, audit_log (000).
--
-- =====================================================


-- =====================================================
-- 1. TENANT PORTAL SETTINGS
-- TENANT-LEVEL PORTAL UI CONFIGURATION SSOT
-- =====================================================

create table if not exists public.tenant_portal_settings (

    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references tenants(id) on delete cascade,

    theme jsonb,

    default_language text default 'en',

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    unique (tenant_id)
);


-- =====================================================
-- 2. DASHBOARD CONFIGURATION
-- TENANT DASHBOARD LAYOUT DEFINITIONS
-- =====================================================

create table if not exists public.dashboard_configs (

    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references tenants(id) on delete cascade,

    name text not null,

    layout jsonb,

    is_default boolean default false,

    created_at timestamptz default now()
);


-- =====================================================
-- 3. PORTAL USER PREFERENCES
-- PER-USER PORTAL UI STATE
-- =====================================================

create table if not exists public.portal_user_preferences (

    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references tenants(id) on delete cascade,

    user_id uuid not null references platform.profiles(id) on delete cascade,

    preference_key text not null,

    value jsonb not null default '{}'::jsonb,

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    unique (tenant_id, user_id, preference_key)

);


-- =====================================================
-- 4. PORTAL FEATURE FLAGS
-- UI-ONLY FEATURE VISIBILITY CONTROL
--
-- Keys MUST use ui_ prefix — never overlap
-- feature_entitlements (010).
-- =====================================================

create table if not exists public.portal_feature_flags (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references tenants(id) on delete cascade,
    feature_key text not null,
    enabled boolean default true,
    created_at timestamptz not null default now(),
    unique (tenant_id, feature_key),
    constraint chk_portal_feature_flags_ui_prefix
        check (feature_key ~ '^ui_')
);

-- =====================================================
-- 5. INDEXES & PORTAL DATA ACCESS OPTIMIZATION
-- =====================================================

create index if not exists idx_portal_settings_tenant_created
on public.tenant_portal_settings (tenant_id, created_at desc);

create unique index if not exists idx_dashboard_configs_one_default_per_tenant
on public.dashboard_configs (tenant_id)
where is_default = true;

create index if not exists idx_dashboard_configs_tenant_created
on public.dashboard_configs (tenant_id, created_at desc);

create index if not exists idx_portal_user_preferences_tenant_created
on public.portal_user_preferences (tenant_id, created_at desc);

create index if not exists idx_portal_user_preferences_user
on public.portal_user_preferences (tenant_id, user_id);

create index if not exists idx_portal_feature_flags_tenant
on public.portal_feature_flags (tenant_id);

create index if not exists idx_portal_feature_flags_tenant_created
on public.portal_feature_flags (tenant_id, created_at desc);

-- =====================================================
-- 6. TABLE DOCUMENTATION
-- PORTAL SSOT / OWNERSHIP DECLARATIONS
-- =====================================================

comment on table public.tenant_portal_settings is
    'Tenant portal UI configuration SSOT. Platform infra must not duplicate tenant config.';

comment on table public.portal_feature_flags is
    'Portal UI visibility only (ui_* keys). Plan entitlements SSOT: feature_entitlements (012).';

-- =====================================================
-- 7. PORTAL DOMAIN & CONSISTENCY FUNCTIONS
-- =====================================================

create or replace function public.enforce_portal_user_preference_membership()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if not exists (
        select 1
        from public.tenant_memberships tm
        where tm.tenant_id = new.tenant_id
          and tm.user_id = new.user_id
          and tm.is_active = true
    ) then
        raise exception 'user_id must be an active member of tenant_id';
    end if;
    return new;

end;
$$;


create or replace function public.portal_domain(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_uid uuid;
    v_row record;
    v_result jsonb;
    v_existing uuid;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);
    v_uid := (select auth.uid());

    case p_op
    when 'get_portal_bootstrap' then
        v_tid := platform.current_tenant_id();
        select jsonb_build_object(
            'settings', (
                select to_jsonb(t) from (
                    select s.id, s.tenant_id, s.theme, s.default_language, s.created_at, s.updated_at
                    from public.tenant_portal_settings s where s.tenant_id = v_tid
                ) t
            ),
            'default_dashboard', (
                select to_jsonb(t) from (
                    select d.id, d.tenant_id, d.name, d.layout, d.is_default, d.created_at
                    from public.dashboard_configs d
                    where d.tenant_id = v_tid and d.is_default = true
                ) t
            ),
            'feature_flags', coalesce((
                select jsonb_agg(to_jsonb(f) order by f.feature_key)
                from (
                    select ff.id, ff.tenant_id, ff.feature_key, ff.enabled, ff.created_at
                    from public.portal_feature_flags ff where ff.tenant_id = v_tid
                ) f
            ), '[]'::jsonb)
        ) into v_result;

    when 'get_portal_settings' then
        v_tid := platform.current_tenant_id();
        select to_jsonb(t) into v_result from (
            select s.id, s.tenant_id, s.theme, s.default_language, s.created_at, s.updated_at
            from public.tenant_portal_settings s where s.tenant_id = v_tid
        ) t;

    when 'upsert_portal_settings' then
        v_tid := platform.current_tenant_id();
        select s.id into v_existing from public.tenant_portal_settings s where s.tenant_id = v_tid;
        if found then
            update public.tenant_portal_settings s set
                theme = case when p_payload ? 'theme' then p_payload->'theme' else s.theme end,
                default_language = case when p_payload ? 'default_language' then p_payload->>'default_language' else s.default_language end
            where s.tenant_id = v_tid
            returning s.id, s.tenant_id, s.theme, s.default_language, s.created_at, s.updated_at into v_row;
            perform platform.log_audit('portal_settings.updated', 'tenant_portal_settings', v_row.id, p_payload);
        else
            insert into public.tenant_portal_settings (tenant_id, theme, default_language)
            values (
                v_tid,
                case when p_payload ? 'theme' then p_payload->'theme' else null end,
                coalesce(p_payload->>'default_language', 'en')
            )
            returning id, tenant_id, theme, default_language, created_at, updated_at into v_row;
            perform platform.log_audit('portal_settings.created', 'tenant_portal_settings', v_row.id);
        end if;
        v_result := to_jsonb(v_row);

    when 'list_dashboards' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb) into v_result
        from (
            select d.id, d.tenant_id, d.name, d.layout, d.is_default, d.created_at
            from public.dashboard_configs d where d.tenant_id = v_tid
        ) t;

    when 'get_dashboard' then
        v_tid := platform.current_tenant_id();
        select to_jsonb(t) into v_result from (
            select d.id, d.tenant_id, d.name, d.layout, d.is_default, d.created_at
            from public.dashboard_configs d
            where d.id = (p_payload->>'id')::uuid and d.tenant_id = v_tid
        ) t;
        if v_result is null then raise exception 'Dashboard config not found'; end if;

    when 'create_dashboard' then
        v_tid := platform.current_tenant_id();
        if coalesce((p_payload->>'is_default')::boolean, false) then
            update public.dashboard_configs set is_default = false
            where tenant_id = v_tid and is_default = true;
        end if;
        insert into public.dashboard_configs (tenant_id, name, layout, is_default)
        values (
            v_tid,
            p_payload->>'name',
            case when p_payload ? 'layout' then p_payload->'layout' else null end,
            coalesce((p_payload->>'is_default')::boolean, false)
        )
        returning id, tenant_id, name, layout, is_default, created_at into v_row;
        perform platform.log_audit('dashboard_config.created', 'dashboard_config', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_dashboard' then
        v_tid := platform.current_tenant_id();
        if coalesce((p_payload->>'is_default')::boolean, false) then
            update public.dashboard_configs set is_default = false
            where tenant_id = v_tid and is_default = true;
        end if;
        update public.dashboard_configs d set
            name = case when p_payload ? 'name' then p_payload->>'name' else d.name end,
            layout = case when p_payload ? 'layout' then p_payload->'layout' else d.layout end,
            is_default = case when p_payload ? 'is_default' then (p_payload->>'is_default')::boolean else d.is_default end
        where d.id = (p_payload->>'id')::uuid and d.tenant_id = v_tid
        returning d.id, d.tenant_id, d.name, d.layout, d.is_default, d.created_at into v_row;
        if not found then raise exception 'Dashboard config not found'; end if;
        perform platform.log_audit('dashboard_config.updated', 'dashboard_config', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_dashboard' then
        v_tid := platform.current_tenant_id();
        delete from public.dashboard_configs d
        where d.id = (p_payload->>'id')::uuid and d.tenant_id = v_tid;
        if not found then raise exception 'Dashboard config not found'; end if;
        perform platform.log_audit('dashboard_config.deleted', 'dashboard_config', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_user_preferences' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.preference_key), '[]'::jsonb) into v_result
        from (
            select p.id, p.tenant_id, p.user_id, p.preference_key, p.value, p.created_at, p.updated_at
            from public.portal_user_preferences p
            where p.tenant_id = v_tid and p.user_id = v_uid
        ) t;

    when 'get_user_preference' then
        v_tid := platform.current_tenant_id();
        select to_jsonb(t) into v_result from (
            select p.id, p.tenant_id, p.user_id, p.preference_key, p.value, p.created_at, p.updated_at
            from public.portal_user_preferences p
            where p.tenant_id = v_tid and p.user_id = v_uid
              and p.preference_key = p_payload->>'preference_key'
        ) t;

    when 'upsert_user_preference' then
        v_tid := platform.current_tenant_id();
        select p.id into v_existing from public.portal_user_preferences p
        where p.tenant_id = v_tid and p.user_id = v_uid
          and p.preference_key = p_payload->>'preference_key';
        if found then
            update public.portal_user_preferences p set value = p_payload->'value'
            where p.id = v_existing
            returning p.id, p.tenant_id, p.user_id, p.preference_key, p.value, p.created_at, p.updated_at into v_row;
        else
            insert into public.portal_user_preferences (tenant_id, user_id, preference_key, value)
            values (v_tid, v_uid, p_payload->>'preference_key', p_payload->'value')
            returning id, tenant_id, user_id, preference_key, value, created_at, updated_at into v_row;
        end if;
        v_result := to_jsonb(v_row);

    when 'update_user_preference' then
        v_tid := platform.current_tenant_id();
        update public.portal_user_preferences p set
            value = case when p_payload ? 'value' then p_payload->'value' else p.value end
        where p.tenant_id = v_tid and p.user_id = v_uid
          and p.preference_key = p_payload->>'preference_key'
        returning p.id, p.tenant_id, p.user_id, p.preference_key, p.value, p.created_at, p.updated_at into v_row;
        if not found then raise exception 'Preference not found'; end if;
        v_result := to_jsonb(v_row);

    when 'delete_user_preference' then
        v_tid := platform.current_tenant_id();
        delete from public.portal_user_preferences p
        where p.tenant_id = v_tid and p.user_id = v_uid
          and p.preference_key = p_payload->>'preference_key';
        v_result := jsonb_build_object('deleted', true, 'preference_key', p_payload->>'preference_key');

    when 'list_feature_flags' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.feature_key), '[]'::jsonb) into v_result
        from (
            select ff.id, ff.tenant_id, ff.feature_key, ff.enabled, ff.created_at
            from public.portal_feature_flags ff where ff.tenant_id = v_tid
        ) t;

    when 'create_feature_flag' then
        v_tid := platform.current_tenant_id();
        insert into public.portal_feature_flags (tenant_id, feature_key, enabled)
        values (
            v_tid,
            p_payload->>'feature_key',
            coalesce((p_payload->>'enabled')::boolean, true)
        )
        returning id, tenant_id, feature_key, enabled, created_at into v_row;
        perform platform.log_audit('portal_feature_flag.created', 'portal_feature_flag', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_feature_flag' then
        v_tid := platform.current_tenant_id();
        update public.portal_feature_flags ff set
            feature_key = case when p_payload ? 'feature_key' then p_payload->>'feature_key' else ff.feature_key end,
            enabled = case when p_payload ? 'enabled' then (p_payload->>'enabled')::boolean else ff.enabled end
        where ff.id = (p_payload->>'id')::uuid and ff.tenant_id = v_tid
        returning ff.id, ff.tenant_id, ff.feature_key, ff.enabled, ff.created_at into v_row;
        if not found then raise exception 'Feature flag not found'; end if;
        perform platform.log_audit('portal_feature_flag.updated', 'portal_feature_flag', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_feature_flag' then
        v_tid := platform.current_tenant_id();
        delete from public.portal_feature_flags ff
        where ff.id = (p_payload->>'id')::uuid and ff.tenant_id = v_tid;
        if not found then raise exception 'Feature flag not found'; end if;
        perform platform.log_audit('portal_feature_flag.deleted', 'portal_feature_flag', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    else
        raise exception 'unknown portal_api operation: %', p_op;
    end case;

    return v_result;
end;
$$;

-- =====================================================
-- 13. PORTAL TRIGGERS
-- AUTOMATIC TIMESTAMPS & MEMBERSHIP VALIDATION
-- =====================================================

create trigger trg_portal_settings_updated_at
before update on tenant_portal_settings
for each row execute function platform.set_updated_at();

create trigger trg_portal_user_preferences_updated_at
before update on portal_user_preferences
for each row execute function platform.set_updated_at();

create trigger trg_portal_user_preferences_membership
before insert or update on public.portal_user_preferences
for each row execute function public.enforce_portal_user_preference_membership();

-- =====================================================
-- 14. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('013_service_portal_engine', 'REV1', false)
on conflict (migration_name) do nothing;

-- =====================================================
-- END 013 SERVICE & PORTAL ENGINE
-- =====================================================