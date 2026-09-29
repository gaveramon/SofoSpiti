-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 010_PRECONFIG_ENGINE.SQL
-- =====================================================
--
-- PHYSICAL DEPLOYMENT / HARDWARE / INSTALLATION LAYER
-- GLOBAL BLUEPRINTS ONLY — NO TENANT DATA / NO RUNTIME STATE
-- =====================================================


-- =====================================================
-- 1. DEVICE BUNDLES
-- VERSIONED HARDWARE BILL-OF-MATERIALS CATALOG
-- =====================================================

create table if not exists public.device_bundles (
    id uuid primary key default gen_random_uuid(),

    code text not null,

    version int not null default 1,

    name text not null,

    description text,

    property_type property_type,

    is_active boolean not null default true,

    is_system boolean not null default false,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    constraint uq_device_bundles_code_version

        unique (code, version)

);


-- =====================================================
-- 2. BUNDLE DEVICES
-- HARDWARE COMPONENTS INCLUDED IN A DEVICE BUNDLE
-- =====================================================



create table if not exists public.bundle_devices (

    id uuid primary key default gen_random_uuid(),

    bundle_id uuid not null references device_bundles(id) on delete cascade,

    category_code text not null references public.device_categories(code),

    quantity int not null default 1,

    is_required boolean not null default true,

    config_hint jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),

    constraint uq_bundle_device unique (bundle_id, category_code),

    constraint chk_bundle_device_qty check (quantity > 0)

);


-- =====================================================
-- 3. ONBOARDING BLUEPRINTS
-- GLOBAL INSTALLATION / ONBOARDING FLOW DEFINITIONS
-- =====================================================

create table if not exists public.onboarding_blueprints (

    id uuid primary key default gen_random_uuid(),

    code text not null unique,

    name text not null,

    description text,

    property_type property_type,

    is_system boolean not null default false,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now()

);


-- =====================================================
-- 4. ONBOARDING BLUEPRINT STEPS
-- ORDERED STEPS WITHIN AN ONBOARDING BLUEPRINT
-- =====================================================

create table if not exists public.onboarding_blueprint_steps (

    id uuid primary key default gen_random_uuid(),

    blueprint_id uuid not null references onboarding_blueprints(id) on delete cascade,

    step_order int not null,

    step_type onboarding_step_type not null,

    config jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),

    unique (blueprint_id, step_order),

    constraint chk_step_order check (step_order > 0)

);


-- =====================================================
-- 5. PRECONFIG TEMPLATES
-- GLOBAL INSTALLATION BLUEPRINTS
-- Tenant template selection lives in 014 onboarding_sessions.
-- =====================================================

create table if not exists public.preconfig_templates (

    id uuid primary key default gen_random_uuid(),

    device_bundle_id uuid not null references device_bundles(id) on delete restrict,

    onboarding_blueprint_id uuid references onboarding_blueprints(id) on delete set null,

    name text not null,

    description text,

    property_type property_type,

    is_active boolean not null default true,

    version int not null default 1,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now()

);


-- =====================================================
-- 6. PRECONFIG DEVICE MAP
-- DEVICE → ROOM INSTALLATION MAPPING
-- =====================================================

create table if not exists public.preconfig_device_map (

    id uuid primary key default gen_random_uuid(),

    template_id uuid not null references preconfig_templates(id) on delete cascade,

    category_code text not null references public.device_categories(code),

    room_type room_type not null,

    recommended_protocol device_protocol,

    default_config jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),

    unique (template_id, category_code, room_type)

);


-- =====================================================
-- 7. CATALOG INDEXES AND DOCUMENTATION
-- =====================================================

create index if not exists idx_device_bundles_code
    on public.device_bundles (code);

create index if not exists idx_device_bundles_active
    on public.device_bundles (is_active);

create index if not exists idx_bundle_devices_bundle
    on public.bundle_devices (bundle_id);

create index if not exists idx_onboarding_steps_blueprint
    on public.onboarding_blueprint_steps (blueprint_id);

create index if not exists idx_preconfig_templates_bundle
    on public.preconfig_templates (device_bundle_id);

comment on table public.preconfig_templates is
    'Global install blueprint catalog. Tenants select via onboarding_sessions.preconfig_template_id (012).';

create index if not exists idx_preconfig_device_map_template
    on public.preconfig_device_map (template_id);


-- =====================================================
-- 8. PRECONFIG DOMAIN API
-- READ / WRITE OPERATIONS FOR THE PRECONFIG CATALOG
-- =====================================================

create or replace function public.preconfig_domain(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_row record;
    v_result jsonb;
    v_bundle_id uuid;
    v_blueprint_id uuid;
    v_template_id uuid;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op
    when 'list_device_bundles' then
        select coalesce(jsonb_agg(to_jsonb(t) order by t.code), '[]'::jsonb) into v_result
        from (
            select db.id, db.code, db.version, db.name, db.description, db.property_type, db.is_active, db.is_system, db.created_at, db.updated_at
            from public.device_bundles db
            where (coalesce((p_payload->>'active_only')::boolean, true) = false or db.is_active = true)
              and (p_payload->>'property_type' is null or db.property_type::text = p_payload->>'property_type')
        ) t;

    when 'get_device_bundle' then
        if p_payload ? 'code' then
            select to_jsonb(t) into v_result from (
                select db.id, db.code, db.version, db.name, db.description, db.property_type, db.is_active, db.is_system, db.created_at, db.updated_at
                from public.device_bundles db
                where db.code = p_payload->>'code'
                  and (p_payload->>'version' is null or db.version = (p_payload->>'version')::int)
                order by db.version desc
                limit 1
            ) t;
        else
            select to_jsonb(t) into v_result from (
                select db.id, db.code, db.version, db.name, db.description, db.property_type, db.is_active, db.is_system, db.created_at, db.updated_at
                from public.device_bundles db where db.id = (p_payload->>'id')::uuid
            ) t;
        end if;
        if v_result is null then raise exception 'Device bundle not found'; end if;

    when 'list_bundle_devices' then
        select coalesce(jsonb_agg(to_jsonb(t) order by t.category_code), '[]'::jsonb) into v_result
        from (
            select bd.id, bd.bundle_id, bd.category_code, bd.quantity, bd.is_required, bd.config_hint, bd.created_at
            from public.bundle_devices bd where bd.bundle_id = (p_payload->>'bundle_id')::uuid
        ) t;

    when 'list_onboarding_blueprints' then
        select coalesce(jsonb_agg(to_jsonb(t) order by t.name), '[]'::jsonb) into v_result
        from (
            select ob.id, ob.code, ob.name, ob.description, ob.property_type, ob.is_system, ob.is_active, ob.created_at, ob.updated_at
            from public.onboarding_blueprints ob
            where (coalesce((p_payload->>'active_only')::boolean, true) = false or ob.is_active = true)
              and (p_payload->>'property_type' is null or ob.property_type::text = p_payload->>'property_type')
        ) t;

    when 'get_onboarding_blueprint' then
        if p_payload ? 'code' then
            select id into v_blueprint_id from public.onboarding_blueprints where code = p_payload->>'code';
            if not found then raise exception 'Onboarding blueprint not found'; end if;
        else
            v_blueprint_id := (p_payload->>'id')::uuid;
        end if;
        select jsonb_build_object(
            'blueprint', (
                select to_jsonb(t) from (
                    select ob.id, ob.code, ob.name, ob.description, ob.property_type, ob.is_system, ob.is_active, ob.created_at, ob.updated_at
                    from public.onboarding_blueprints ob where ob.id = v_blueprint_id
                ) t
            ),
            'steps', coalesce((
                select jsonb_agg(to_jsonb(s) order by s.step_order)
                from (
                    select obs.id, obs.blueprint_id, obs.step_order, obs.step_type, obs.config, obs.created_at
                    from public.onboarding_blueprint_steps obs where obs.blueprint_id = v_blueprint_id
                ) s
            ), '[]'::jsonb)
        ) into v_result;
        if v_result->'blueprint' = 'null'::jsonb then raise exception 'Onboarding blueprint not found'; end if;

    when 'list_blueprint_steps' then
        select coalesce(jsonb_agg(to_jsonb(t) order by t.step_order), '[]'::jsonb) into v_result
        from (
            select obs.id, obs.blueprint_id, obs.step_order, obs.step_type, obs.config, obs.created_at
            from public.onboarding_blueprint_steps obs where obs.blueprint_id = (p_payload->>'blueprint_id')::uuid
        ) t;

    when 'list_preconfig_templates' then
        select coalesce(jsonb_agg(to_jsonb(t) order by t.name), '[]'::jsonb) into v_result
        from (
            select pt.id, pt.device_bundle_id, pt.onboarding_blueprint_id, pt.name, pt.description, pt.property_type, pt.is_active, pt.version, pt.created_at, pt.updated_at
            from public.preconfig_templates pt
            where (coalesce((p_payload->>'active_only')::boolean, true) = false or pt.is_active = true)
              and (p_payload->>'property_type' is null or pt.property_type::text = p_payload->>'property_type')
        ) t;

    when 'get_preconfig_template' then
        v_template_id := (p_payload->>'id')::uuid;
        select pt.device_bundle_id into v_bundle_id from public.preconfig_templates pt where pt.id = v_template_id;
        if not found then raise exception 'Preconfig template not found'; end if;
        select jsonb_build_object(
            'template', (
                select to_jsonb(t) from (
                    select pt.id, pt.device_bundle_id, pt.onboarding_blueprint_id, pt.name, pt.description, pt.property_type, pt.is_active, pt.version, pt.created_at, pt.updated_at
                    from public.preconfig_templates pt where pt.id = v_template_id
                ) t
            ),
            'device_map', coalesce((
                select jsonb_agg(to_jsonb(dm) order by dm.room_type)
                from (
                    select pdm.id, pdm.template_id, pdm.category_code, pdm.room_type, pdm.recommended_protocol, pdm.default_config, pdm.created_at
                    from public.preconfig_device_map pdm where pdm.template_id = v_template_id
                ) dm
            ), '[]'::jsonb),
            'bundle_devices', coalesce((
                select jsonb_agg(to_jsonb(bd) order by bd.category_code)
                from (
                    select bd.id, bd.bundle_id, bd.category_code, bd.quantity, bd.is_required, bd.config_hint, bd.created_at
                    from public.bundle_devices bd where bd.bundle_id = v_bundle_id
                ) bd
            ), '[]'::jsonb)
        ) into v_result;

    when 'list_preconfig_device_map' then
        select coalesce(jsonb_agg(to_jsonb(t) order by t.room_type), '[]'::jsonb) into v_result
        from (
            select pdm.id, pdm.template_id, pdm.category_code, pdm.room_type, pdm.recommended_protocol, pdm.default_config, pdm.created_at
            from public.preconfig_device_map pdm where pdm.template_id = (p_payload->>'template_id')::uuid
        ) t;

    when 'create_device_bundle' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        insert into public.device_bundles (code, name, description, property_type, version, is_active, is_system)
        values (
            p_payload->>'code', p_payload->>'name', p_payload->>'description',
            case when p_payload ? 'property_type' and p_payload->>'property_type' is not null
                then (p_payload->>'property_type')::public.property_type else null end,
            coalesce((p_payload->>'version')::int, 1),
            coalesce((p_payload->>'is_active')::boolean, true),
            coalesce((p_payload->>'is_system')::boolean, false)
        )
        returning id, code, version, name, description, property_type, is_active, is_system, created_at, updated_at into v_row;
        perform platform.log_audit('device_bundle.created', 'device_bundle', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_device_bundle' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        update public.device_bundles db set
            code = case when p_payload ? 'code' then p_payload->>'code' else db.code end,
            name = case when p_payload ? 'name' then p_payload->>'name' else db.name end,
            description = case when p_payload ? 'description' then p_payload->>'description' else db.description end,
            property_type = case when p_payload ? 'property_type'
                then case when p_payload->>'property_type' is null then null else (p_payload->>'property_type')::public.property_type end
                else db.property_type end,
            version = case when p_payload ? 'version' then (p_payload->>'version')::int else db.version end,
            is_active = case when p_payload ? 'is_active' then (p_payload->>'is_active')::boolean else db.is_active end,
            is_system = case when p_payload ? 'is_system' then (p_payload->>'is_system')::boolean else db.is_system end
        where db.id = (p_payload->>'id')::uuid
        returning db.id, db.code, db.version, db.name, db.description, db.property_type, db.is_active, db.is_system, db.created_at, db.updated_at into v_row;
        if not found then raise exception 'Device bundle not found'; end if;
        perform platform.log_audit('device_bundle.updated', 'device_bundle', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_device_bundle' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        delete from public.device_bundles db where db.id = (p_payload->>'id')::uuid;
        if not found then raise exception 'Device bundle not found'; end if;
        perform platform.log_audit('device_bundle.deleted', 'device_bundle', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'create_bundle_device' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        insert into public.bundle_devices (bundle_id, category_code, quantity, is_required, config_hint)
        values (
            (p_payload->>'bundle_id')::uuid, p_payload->>'category_code',
            coalesce((p_payload->>'quantity')::int, 1),
            coalesce((p_payload->>'is_required')::boolean, true),
            coalesce(p_payload->'config_hint', '{}'::jsonb)
        )
        returning id, bundle_id, category_code, quantity, is_required, config_hint, created_at into v_row;
        perform platform.log_audit('bundle_device.created', 'bundle_device', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_bundle_device' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        update public.bundle_devices bd set
            quantity = case when p_payload ? 'quantity' then (p_payload->>'quantity')::int else bd.quantity end,
            is_required = case when p_payload ? 'is_required' then (p_payload->>'is_required')::boolean else bd.is_required end,
            config_hint = case when p_payload ? 'config_hint' then p_payload->'config_hint' else bd.config_hint end
        where bd.id = (p_payload->>'id')::uuid
        returning bd.id, bd.bundle_id, bd.category_code, bd.quantity, bd.is_required, bd.config_hint, bd.created_at into v_row;
        if not found then raise exception 'Bundle device not found'; end if;
        perform platform.log_audit('bundle_device.updated', 'bundle_device', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_bundle_device' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        delete from public.bundle_devices bd where bd.id = (p_payload->>'id')::uuid;
        if not found then raise exception 'Bundle device not found'; end if;
        perform platform.log_audit('bundle_device.deleted', 'bundle_device', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'create_onboarding_blueprint' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        insert into public.onboarding_blueprints (code, name, description, property_type, is_system, is_active)
        values (
            p_payload->>'code', p_payload->>'name', p_payload->>'description',
            case when p_payload ? 'property_type' and p_payload->>'property_type' is not null
                then (p_payload->>'property_type')::public.property_type else null end,
            coalesce((p_payload->>'is_system')::boolean, false),
            coalesce((p_payload->>'is_active')::boolean, true)
        )
        returning id, code, name, description, property_type, is_system, is_active, created_at, updated_at into v_row;
        perform platform.log_audit('onboarding_blueprint.created', 'onboarding_blueprint', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_onboarding_blueprint' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        update public.onboarding_blueprints ob set
            code = case when p_payload ? 'code' then p_payload->>'code' else ob.code end,
            name = case when p_payload ? 'name' then p_payload->>'name' else ob.name end,
            description = case when p_payload ? 'description' then p_payload->>'description' else ob.description end,
            property_type = case when p_payload ? 'property_type'
                then case when p_payload->>'property_type' is null then null else (p_payload->>'property_type')::public.property_type end
                else ob.property_type end,
            is_system = case when p_payload ? 'is_system' then (p_payload->>'is_system')::boolean else ob.is_system end,
            is_active = case when p_payload ? 'is_active' then (p_payload->>'is_active')::boolean else ob.is_active end
        where ob.id = (p_payload->>'id')::uuid
        returning ob.id, ob.code, ob.name, ob.description, ob.property_type, ob.is_system, ob.is_active, ob.created_at, ob.updated_at into v_row;
        if not found then raise exception 'Onboarding blueprint not found'; end if;
        perform platform.log_audit('onboarding_blueprint.updated', 'onboarding_blueprint', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_onboarding_blueprint' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        delete from public.onboarding_blueprints ob where ob.id = (p_payload->>'id')::uuid;
        if not found then raise exception 'Onboarding blueprint not found'; end if;
        perform platform.log_audit('onboarding_blueprint.deleted', 'onboarding_blueprint', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'create_blueprint_step' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        insert into public.onboarding_blueprint_steps (blueprint_id, step_order, step_type, config)
        values (
            (p_payload->>'blueprint_id')::uuid,
            (p_payload->>'step_order')::int,
            (p_payload->>'step_type')::public.onboarding_step_type,
            coalesce(p_payload->'config', '{}'::jsonb)
        )
        returning id, blueprint_id, step_order, step_type, config, created_at into v_row;
        perform platform.log_audit('onboarding_blueprint_step.created', 'onboarding_blueprint_step', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_blueprint_step' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        update public.onboarding_blueprint_steps obs set
            step_order = case when p_payload ? 'step_order' then (p_payload->>'step_order')::int else obs.step_order end,
            step_type = case when p_payload ? 'step_type'
                then (p_payload->>'step_type')::public.onboarding_step_type else obs.step_type end,
            config = case when p_payload ? 'config' then p_payload->'config' else obs.config end
        where obs.id = (p_payload->>'id')::uuid
        returning obs.id, obs.blueprint_id, obs.step_order, obs.step_type, obs.config, obs.created_at into v_row;
        if not found then raise exception 'Blueprint step not found'; end if;
        perform platform.log_audit('onboarding_blueprint_step.updated', 'onboarding_blueprint_step', v_row.id);
        v_result := to_jsonb(v_row);

    when 'delete_blueprint_step' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        delete from public.onboarding_blueprint_steps obs where obs.id = (p_payload->>'id')::uuid;
        if not found then raise exception 'Blueprint step not found'; end if;
        perform platform.log_audit('onboarding_blueprint_step.deleted', 'onboarding_blueprint_step', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'create_preconfig_template' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        insert into public.preconfig_templates (
            device_bundle_id, onboarding_blueprint_id, name, description, property_type, is_active, version
        )
        values (
            (p_payload->>'device_bundle_id')::uuid,
            case when p_payload ? 'onboarding_blueprint_id' then (p_payload->>'onboarding_blueprint_id')::uuid else null end,
            p_payload->>'name', p_payload->>'description',
            case when p_payload ? 'property_type' and p_payload->>'property_type' is not null
                then (p_payload->>'property_type')::public.property_type else null end,
            coalesce((p_payload->>'is_active')::boolean, true),
            coalesce((p_payload->>'version')::int, 1)
        )
        returning id, device_bundle_id, onboarding_blueprint_id, name, description, property_type, is_active, version, created_at, updated_at into v_row;
        perform platform.log_audit('preconfig_template.created', 'preconfig_template', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_preconfig_template' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        update public.preconfig_templates pt set
            device_bundle_id = case when p_payload ? 'device_bundle_id'
                then (p_payload->>'device_bundle_id')::uuid else pt.device_bundle_id end,
            onboarding_blueprint_id = case when p_payload ? 'onboarding_blueprint_id'
                then (p_payload->>'onboarding_blueprint_id')::uuid else pt.onboarding_blueprint_id end,
            name = case when p_payload ? 'name' then p_payload->>'name' else pt.name end,
            description = case when p_payload ? 'description' then p_payload->>'description' else pt.description end,
            property_type = case when p_payload ? 'property_type'
                then case when p_payload->>'property_type' is null then null else (p_payload->>'property_type')::public.property_type end
                else pt.property_type end,
            is_active = case when p_payload ? 'is_active' then (p_payload->>'is_active')::boolean else pt.is_active end,
            version = case when p_payload ? 'version' then (p_payload->>'version')::int else pt.version end
        where pt.id = (p_payload->>'id')::uuid
        returning pt.id, pt.device_bundle_id, pt.onboarding_blueprint_id, pt.name, pt.description, pt.property_type, pt.is_active, pt.version, pt.created_at, pt.updated_at into v_row;
        if not found then raise exception 'Preconfig template not found'; end if;
        perform platform.log_audit('preconfig_template.updated', 'preconfig_template', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_preconfig_template' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        delete from public.preconfig_templates pt where pt.id = (p_payload->>'id')::uuid;
        if not found then raise exception 'Preconfig template not found'; end if;
        perform platform.log_audit('preconfig_template.deleted', 'preconfig_template', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'create_preconfig_device_map' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        insert into public.preconfig_device_map (template_id, category_code, room_type, recommended_protocol, default_config)
        values (
            (p_payload->>'template_id')::uuid,
            p_payload->>'category_code',
            (p_payload->>'room_type')::public.room_type,
            case when p_payload ? 'recommended_protocol' and p_payload->>'recommended_protocol' is not null
                then (p_payload->>'recommended_protocol')::public.device_protocol else null end,
            coalesce(p_payload->'default_config', '{}'::jsonb)
        )
        returning id, template_id, category_code, room_type, recommended_protocol, default_config, created_at into v_row;
        perform platform.log_audit('preconfig_device_map.created', 'preconfig_device_map', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_preconfig_device_map' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        update public.preconfig_device_map pdm set
            category_code = case when p_payload ? 'category_code' then p_payload->>'category_code' else pdm.category_code end,
            room_type = case when p_payload ? 'room_type'
                then (p_payload->>'room_type')::public.room_type else pdm.room_type end,
            recommended_protocol = case when p_payload ? 'recommended_protocol'
                then case when p_payload->>'recommended_protocol' is null then null
                     else (p_payload->>'recommended_protocol')::public.device_protocol end
                else pdm.recommended_protocol end,
            default_config = case when p_payload ? 'default_config' then p_payload->'default_config' else pdm.default_config end
        where pdm.id = (p_payload->>'id')::uuid
        returning pdm.id, pdm.template_id, pdm.category_code, pdm.room_type, pdm.recommended_protocol, pdm.default_config, pdm.created_at into v_row;
        if not found then raise exception 'Preconfig device map not found'; end if;
        perform platform.log_audit('preconfig_device_map.updated', 'preconfig_device_map', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_preconfig_device_map' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        delete from public.preconfig_device_map pdm where pdm.id = (p_payload->>'id')::uuid;
        if not found then raise exception 'Preconfig device map not found'; end if;
        perform platform.log_audit('preconfig_device_map.deleted', 'preconfig_device_map', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    else
        raise exception 'unknown preconfig_api operation: %', p_op;
    end case;

    return v_result;
end;
$$;


-- =====================================================
-- 9. UPDATED-AT TRIGGERS
-- =====================================================

create trigger trg_device_bundles_updated_at
before update on device_bundles
for each row execute function platform.set_updated_at();


create trigger trg_preconfig_templates_updated_at
before update on preconfig_templates
for each row execute function platform.set_updated_at();


-- =====================================================
-- 10. MIGRATION SCHEMA
-- =====================================================


insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('010_preconfig_engine', 'REV1', false)
on conflict (migration_name) do nothing;

-- =====================================================
-- END 010 PRECONFIG ENGINE
-- =====================================================
