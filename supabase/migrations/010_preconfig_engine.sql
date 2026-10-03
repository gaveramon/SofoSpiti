-- =====================================================
-- SOFO SPITI
-- 010_PRECONFIG_ENGINE.SQL
-- REV3
-- =====================================================
--
-- GLOBAL HARDWARE / INSTALLATION CATALOG
-- NO TENANT DATA / NO RUNTIME STATE
--
-- RLS and Security grants/revokes are centralized in 021 and 023.
-- Tenant onboarding and historical snapshots belong in 014.
--
-- REV3
-- - Existing-schema hardening
-- - Stable template code enforced
-- - Version uniqueness enforced
-- - CHECK constraints enforced on existing tables
-- - Published catalog immutability
-- - System catalog protection
-- - Uniform audit payload convention
-- =====================================================


-- =====================================================
-- 0. PAYLOAD VALIDATION
-- =====================================================

create or replace function public.preconfig_validate_payload(
    p_payload jsonb,
    p_required_keys text[] default array[]::text[]
)
returns void
language plpgsql
set search_path = ''
as $$
declare
    v_key text;
begin
    if p_payload is null
       or jsonb_typeof(p_payload) is distinct from 'object' then
        raise exception 'Payload must be a JSON object';
    end if;

    foreach v_key in array p_required_keys loop
        if not (p_payload ? v_key)
           or p_payload->v_key is null
           or jsonb_typeof(p_payload->v_key) = 'null'
           or btrim(coalesce(p_payload->>v_key, '')) = '' then
            raise exception 'Missing required payload field: %', v_key;
        end if;
    end loop;
end;
$$;


create or replace function public.preconfig_validate_json_object(
    p_value jsonb,
    p_field_name text
)
returns void
language plpgsql
set search_path = ''
as $$
begin
    if p_value is null
       or jsonb_typeof(p_value) is distinct from 'object' then
        raise exception 'Payload field "%" must be a JSON object', p_field_name;
    end if;
end;
$$;


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
    property_type public.property_type,
    is_active boolean not null default true,
    is_system boolean not null default false,
    is_published boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint uq_device_bundles_code_version
        unique (code, version),

    constraint chk_device_bundles_version
        check (version > 0),

    constraint chk_device_bundles_code
        check (btrim(code) <> ''),

    constraint chk_device_bundles_name
        check (btrim(name) <> '')
);


-- Compatibility / hardening for existing tables.

alter table public.device_bundles
    add column if not exists is_published boolean not null default false;


-- Existing-schema constraints.
do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.device_bundles'::regclass
          and conname = 'uq_device_bundles_code_version'
    ) then
        alter table public.device_bundles
            add constraint uq_device_bundles_code_version
            unique (code, version);
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.device_bundles'::regclass
          and conname = 'chk_device_bundles_version'
    ) then
        alter table public.device_bundles
            add constraint chk_device_bundles_version
            check (version > 0);
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.device_bundles'::regclass
          and conname = 'chk_device_bundles_code'
    ) then
        alter table public.device_bundles
            add constraint chk_device_bundles_code
            check (btrim(code) <> '');
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.device_bundles'::regclass
          and conname = 'chk_device_bundles_name'
    ) then
        alter table public.device_bundles
            add constraint chk_device_bundles_name
            check (btrim(name) <> '');
    end if;
end;
$$;


-- =====================================================
-- 2. BUNDLE DEVICES
-- =====================================================

create table if not exists public.bundle_devices (
    id uuid primary key default gen_random_uuid(),

    bundle_id uuid not null
        references public.device_bundles(id) on delete cascade,

    category_code text not null
        references public.device_categories(code),

    quantity int not null default 1,
    is_required boolean not null default true,
    config_hint jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),

    constraint uq_bundle_device
        unique (bundle_id, category_code),

    constraint chk_bundle_device_qty
        check (quantity > 0),

    constraint chk_bundle_device_config
        check (jsonb_typeof(config_hint) = 'object')
);


do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.bundle_devices'::regclass
          and conname = 'uq_bundle_device'
    ) then
        alter table public.bundle_devices
            add constraint uq_bundle_device
            unique (bundle_id, category_code);
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.bundle_devices'::regclass
          and conname = 'chk_bundle_device_qty'
    ) then
        alter table public.bundle_devices
            add constraint chk_bundle_device_qty
            check (quantity > 0);
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.bundle_devices'::regclass
          and conname = 'chk_bundle_device_config'
    ) then
        alter table public.bundle_devices
            add constraint chk_bundle_device_config
            check (jsonb_typeof(config_hint) = 'object');
    end if;
end;
$$;


-- =====================================================
-- 3. ONBOARDING BLUEPRINTS
-- =====================================================

create table if not exists public.onboarding_blueprints (
    id uuid primary key default gen_random_uuid(),
    code text not null unique,
    name text not null,
    description text,
    property_type public.property_type,
    is_system boolean not null default false,
    is_active boolean not null default true,
    is_published boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint chk_onboarding_blueprints_code
        check (btrim(code) <> ''),

    constraint chk_onboarding_blueprints_name
        check (btrim(name) <> '')
);


alter table public.onboarding_blueprints
    add column if not exists is_published boolean not null default false;


do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.onboarding_blueprints'::regclass
          and conname = 'uq_onboarding_blueprints_code'
    ) then
        alter table public.onboarding_blueprints
            add constraint uq_onboarding_blueprints_code
            unique (code);
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.onboarding_blueprints'::regclass
          and conname = 'chk_onboarding_blueprints_code'
    ) then
        alter table public.onboarding_blueprints
            add constraint chk_onboarding_blueprints_code
            check (btrim(code) <> '');
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.onboarding_blueprints'::regclass
          and conname = 'chk_onboarding_blueprints_name'
    ) then
        alter table public.onboarding_blueprints
            add constraint chk_onboarding_blueprints_name
            check (btrim(name) <> '');
    end if;
end;
$$;


-- =====================================================
-- 4. ONBOARDING BLUEPRINT STEPS
-- =====================================================

create table if not exists public.onboarding_blueprint_steps (
    id uuid primary key default gen_random_uuid(),

    blueprint_id uuid not null
        references public.onboarding_blueprints(id) on delete cascade,

    step_order int not null,
    step_type public.onboarding_step_type not null,
    config jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),

    constraint uq_onboarding_blueprint_step_order
        unique (blueprint_id, step_order),

    constraint chk_onboarding_blueprint_step_order
        check (step_order > 0),

    constraint chk_onboarding_blueprint_step_config
        check (jsonb_typeof(config) = 'object')
);


do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.onboarding_blueprint_steps'::regclass
          and conname = 'uq_onboarding_blueprint_step_order'
    ) then
        alter table public.onboarding_blueprint_steps
            add constraint uq_onboarding_blueprint_step_order
            unique (blueprint_id, step_order);
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.onboarding_blueprint_steps'::regclass
          and conname = 'chk_onboarding_blueprint_step_order'
    ) then
        alter table public.onboarding_blueprint_steps
            add constraint chk_onboarding_blueprint_step_order
            check (step_order > 0);
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.onboarding_blueprint_steps'::regclass
          and conname = 'chk_onboarding_blueprint_step_config'
    ) then
        alter table public.onboarding_blueprint_steps
            add constraint chk_onboarding_blueprint_step_config
            check (jsonb_typeof(config) = 'object');
    end if;
end;
$$;


-- =====================================================
-- 5. PRECONFIG TEMPLATES
-- GLOBAL INSTALLATION BLUEPRINTS
-- =====================================================

create table if not exists public.preconfig_templates (
    id uuid primary key default gen_random_uuid(),

    code text not null,

    device_bundle_id uuid not null
        references public.device_bundles(id) on delete restrict,

    onboarding_blueprint_id uuid
        references public.onboarding_blueprints(id) on delete set null,

    name text not null,
    description text,
    property_type public.property_type,
    is_active boolean not null default true,
    version int not null default 1,
    is_system boolean not null default false,
    is_published boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint uq_preconfig_templates_code_version
        unique (code, version),

    constraint chk_preconfig_templates_code
        check (btrim(code) <> ''),

    constraint chk_preconfig_templates_name
        check (btrim(name) <> ''),

    constraint chk_preconfig_templates_version
        check (version > 0)
);


-- Compatibility for existing tables.

alter table public.preconfig_templates
    add column if not exists code text;

alter table public.preconfig_templates
    add column if not exists is_system boolean not null default false;

alter table public.preconfig_templates
    add column if not exists is_published boolean not null default false;


-- Existing rows MUST receive deliberate stable codes
-- before code can become NOT NULL.
--
-- Do not derive production identifiers silently from names.
-- The migration intentionally fails if existing rows are
-- missing a stable code.

do $$
begin
    if exists (
        select 1
        from public.preconfig_templates
        where code is null
    ) then
        raise exception
            '010 pre-audit failed: public.preconfig_templates contains rows with NULL code. Assign deliberate stable codes before rerunning migration 010.';
    end if;
end;
$$;


alter table public.preconfig_templates
    alter column code set not null;


do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.preconfig_templates'::regclass
          and conname = 'uq_preconfig_templates_code_version'
    ) then
        alter table public.preconfig_templates
            add constraint uq_preconfig_templates_code_version
            unique (code, version);
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.preconfig_templates'::regclass
          and conname = 'chk_preconfig_templates_code'
    ) then
        alter table public.preconfig_templates
            add constraint chk_preconfig_templates_code
            check (btrim(code) <> '');
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.preconfig_templates'::regclass
          and conname = 'chk_preconfig_templates_name'
    ) then
        alter table public.preconfig_templates
            add constraint chk_preconfig_templates_name
            check (btrim(name) <> '');
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.preconfig_templates'::regclass
          and conname = 'chk_preconfig_templates_version'
    ) then
        alter table public.preconfig_templates
            add constraint chk_preconfig_templates_version
            check (version > 0);
    end if;
end;
$$;


-- =====================================================
-- 6. PRECONFIG DEVICE MAP
-- =====================================================

create table if not exists public.preconfig_device_map (
    id uuid primary key default gen_random_uuid(),

    template_id uuid not null
        references public.preconfig_templates(id) on delete cascade,

    category_code text not null
        references public.device_categories(code),

    room_type public.room_type not null,
    recommended_protocol public.device_protocol,
    default_config jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),

    constraint uq_preconfig_device_map
        unique (template_id, category_code, room_type),

    constraint chk_preconfig_device_map_config
        check (jsonb_typeof(default_config) = 'object')
);


do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.preconfig_device_map'::regclass
          and conname = 'uq_preconfig_device_map'
    ) then
        alter table public.preconfig_device_map
            add constraint uq_preconfig_device_map
            unique (template_id, category_code, room_type);
    end if;

    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'public.preconfig_device_map'::regclass
          and conname = 'chk_preconfig_device_map_config'
    ) then
        alter table public.preconfig_device_map
            add constraint chk_preconfig_device_map_config
            check (jsonb_typeof(default_config) = 'object');
    end if;
end;
$$;


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

create index if not exists idx_preconfig_templates_code
    on public.preconfig_templates (code);

create index if not exists idx_preconfig_templates_active
    on public.preconfig_templates (is_active);

create index if not exists idx_preconfig_device_map_template
    on public.preconfig_device_map (template_id);


comment on table public.preconfig_templates is
    'Global versioned installation catalog. Tenant selection and historical snapshots belong in migration 014.';


comment on column public.preconfig_templates.code is
    'Stable logical template identifier shared by its versions.';


comment on column public.preconfig_templates.version is
    'Immutable version number within a template code. Create a new row for a new version.';


comment on column public.preconfig_templates.is_published is
    'Published catalog versions are immutable. Deactivate them instead of editing their contents.';


comment on column public.device_bundles.is_published is
    'Published bundle versions are immutable. Create a new version for content changes.';


comment on column public.onboarding_blueprints.is_published is
    'Published blueprints and their steps are immutable. Create a new blueprint code for content changes.';


-- =====================================================
-- 8. IMMUTABILITY AND SYSTEM RECORD PROTECTION
-- =====================================================

create or replace function public.preconfig_guard_catalog_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_old jsonb;
    v_new jsonb;
    v_parent_id uuid;
    v_parent_is_system boolean;
    v_parent_is_published boolean;
    v_parent_table text;
    v_fk_column text;
begin

    -- =================================================
    -- Parent catalog records
    -- =================================================

    if tg_table_name in (
        'device_bundles',
        'onboarding_blueprints',
        'preconfig_templates'
    ) then

        -- ---------------------------------------------
        -- INSERT
        -- ---------------------------------------------

        if tg_op = 'INSERT' then

            if new.is_published then
                raise exception
                    'Create catalog records as drafts, then publish them separately';
            end if;

            return new;
        end if;


        v_old := to_jsonb(old);


        -- ---------------------------------------------
        -- DELETE
        -- ---------------------------------------------

        if tg_op = 'DELETE' then

            if coalesce(
                (v_old->>'is_system')::boolean,
                false
            ) then
                raise exception
                    'System catalog records cannot be deleted';
            end if;

            if coalesce(
                (v_old->>'is_published')::boolean,
                false
            ) then
                raise exception
                    'Published catalog records cannot be deleted';
            end if;

            return old;
        end if;


        -- ---------------------------------------------
        -- UPDATE
        -- ---------------------------------------------

        v_new := to_jsonb(new);


        -- System flag is one-way.
        if coalesce(
               (v_old->>'is_system')::boolean,
               false
           )
           and not coalesce(
               (v_new->>'is_system')::boolean,
               false
           ) then

            raise exception
                'is_system cannot be changed from true to false';
        end if;


        -- ---------------------------------------------
        -- Logical identity is immutable.
        -- ---------------------------------------------

        if tg_table_name = 'device_bundles'
           and (
               v_old->>'code' is distinct from v_new->>'code'
               or v_old->>'version' is distinct from v_new->>'version'
           ) then

            raise exception
                'Device bundle code/version are immutable';
        end if;


        if tg_table_name = 'onboarding_blueprints'
           and v_old->>'code' is distinct from v_new->>'code' then

            raise exception
                'Onboarding blueprint code is immutable';
        end if;


        if tg_table_name = 'preconfig_templates'
           and (
               v_old->>'code' is distinct from v_new->>'code'
               or v_old->>'version' is distinct from v_new->>'version'
           ) then

            raise exception
                'Preconfig template code/version are immutable';
        end if;


        -- ---------------------------------------------
        -- Published records are immutable except
        -- is_active and updated_at.
        -- ---------------------------------------------

        if coalesce(
               (v_old->>'is_published')::boolean,
               false
           ) then

            if (
                v_old - 'is_active' - 'updated_at'
            ) is distinct from (
                v_new - 'is_active' - 'updated_at'
            ) then

                raise exception
                    'Published catalog records are immutable; create a new version';
            end if;

        end if;


        -- ---------------------------------------------
        -- Publishing must not change content.
        -- ---------------------------------------------

        if not coalesce(
               (v_old->>'is_published')::boolean,
               false
           )
           and coalesce(
               (v_new->>'is_published')::boolean,
               false
           ) then

            if (
                v_old - 'is_published' - 'updated_at'
            ) is distinct from (
                v_new - 'is_published' - 'updated_at'
            ) then

                raise exception
                    'Publish a draft without changing its content in the same update';
            end if;

        end if;


        -- ---------------------------------------------
        -- Published state is one-way.
        -- ---------------------------------------------

        if coalesce(
               (v_old->>'is_published')::boolean,
               false
           )
           and not coalesce(
               (v_new->>'is_published')::boolean,
               false
           ) then

            raise exception
                'Published catalog records cannot be unpublished';
        end if;


        return new;
    end if;


    -- =================================================
    -- Child records inherit restrictions from parent.
    -- =================================================

    case tg_table_name

        when 'bundle_devices' then
            v_parent_table := 'public.device_bundles';
            v_fk_column := 'bundle_id';

        when 'onboarding_blueprint_steps' then
            v_parent_table := 'public.onboarding_blueprints';
            v_fk_column := 'blueprint_id';

        when 'preconfig_device_map' then
            v_parent_table := 'public.preconfig_templates';
            v_fk_column := 'template_id';

        else
            raise exception
                'Unsupported preconfig table: %',
                tg_table_name;

    end case;


    -- Determine parent ID.

    if tg_op = 'DELETE' then

        v_parent_id :=
            (to_jsonb(old)->>v_fk_column)::uuid;

    else

        v_parent_id :=
            (to_jsonb(new)->>v_fk_column)::uuid;

    end if;


    -- A child cannot be moved to another parent.

    if tg_op = 'UPDATE'
       and (
           to_jsonb(old)->>v_fk_column
           is distinct from
           to_jsonb(new)->>v_fk_column
       ) then

        raise exception
            'Moving catalog child records between parents is not allowed';

    end if;


    execute format(
        'select is_system, is_published
           from %s
          where id = $1',
        v_parent_table
    )
    into
        v_parent_is_system,
        v_parent_is_published
    using v_parent_id;


    if not found then
        raise exception
            'Catalog parent not found';
    end if;


    if coalesce(v_parent_is_system, false) then
        raise exception
            'Children of system catalog records cannot be changed';
    end if;


    if coalesce(v_parent_is_published, false) then
        raise exception
            'Children of published catalog records are immutable';
    end if;


    if tg_op = 'DELETE' then
        return old;
    end if;


    return new;
end;
$$;


-- =====================================================
-- Parent protection triggers
-- =====================================================

drop trigger if exists trg_device_bundles_guard
    on public.device_bundles;

create trigger trg_device_bundles_guard
before insert or update or delete
on public.device_bundles
for each row
execute function public.preconfig_guard_catalog_mutation();


drop trigger if exists trg_onboarding_blueprints_guard
    on public.onboarding_blueprints;

create trigger trg_onboarding_blueprints_guard
before insert or update or delete
on public.onboarding_blueprints
for each row
execute function public.preconfig_guard_catalog_mutation();


drop trigger if exists trg_preconfig_templates_guard
    on public.preconfig_templates;

create trigger trg_preconfig_templates_guard
before insert or update or delete
on public.preconfig_templates
for each row
execute function public.preconfig_guard_catalog_mutation();


-- =====================================================
-- Child protection triggers
-- =====================================================

drop trigger if exists trg_bundle_devices_guard
    on public.bundle_devices;

create trigger trg_bundle_devices_guard
before insert or update or delete
on public.bundle_devices
for each row
execute function public.preconfig_guard_catalog_mutation();


drop trigger if exists trg_onboarding_blueprint_steps_guard
    on public.onboarding_blueprint_steps;

create trigger trg_onboarding_blueprint_steps_guard
before insert or update or delete
on public.onboarding_blueprint_steps
for each row
execute function public.preconfig_guard_catalog_mutation();


drop trigger if exists trg_preconfig_device_map_guard
    on public.preconfig_device_map;

create trigger trg_preconfig_device_map_guard
before insert or update or delete
on public.preconfig_device_map
for each row
execute function public.preconfig_guard_catalog_mutation();


-- =====================================================
-- 9. UPDATED-AT TRIGGERS
-- =====================================================

drop trigger if exists trg_device_bundles_updated_at
    on public.device_bundles;

create trigger trg_device_bundles_updated_at
before update
on public.device_bundles
for each row
execute function platform.set_updated_at();


drop trigger if exists trg_preconfig_templates_updated_at
    on public.preconfig_templates;

create trigger trg_preconfig_templates_updated_at
before update
on public.preconfig_templates
for each row
execute function platform.set_updated_at();


drop trigger if exists trg_onboarding_blueprints_updated_at
    on public.onboarding_blueprints;

create trigger trg_onboarding_blueprints_updated_at
before update
on public.onboarding_blueprints
for each row
execute function platform.set_updated_at();


-- =====================================================
-- 10. PRECONFIG DOMAIN API
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
    v_before jsonb;
begin

    p_payload := coalesce(
        p_payload,
        '{}'::jsonb
    );


    perform public.preconfig_validate_payload(
        p_payload
    );


    if p_op is null
       or btrim(p_op) = '' then

        raise exception
            'Operation is required';

    end if;


    case p_op


    -- =================================================
    -- READ: DEVICE BUNDLES
    -- =================================================

    when 'list_device_bundles' then

        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.code, t.version desc
            ),
            '[]'::jsonb
        )
        into v_result

        from (
            select
                db.id,
                db.code,
                db.version,
                db.name,
                db.description,
                db.property_type,
                db.is_active,
                db.is_system,
                db.is_published,
                db.created_at,
                db.updated_at

            from public.device_bundles db

            where (
                coalesce(
                    (p_payload->>'active_only')::boolean,
                    true
                ) = false
                or db.is_active = true
            )

            and (
                p_payload->>'property_type' is null
                or db.property_type::text =
                   p_payload->>'property_type'
            )
        ) t;


    when 'get_device_bundle' then

        if p_payload ? 'code' then

            perform public.preconfig_validate_payload(
                p_payload,
                array['code']::text[]
            );


            select to_jsonb(t)
            into v_result

            from (
                select
                    db.id,
                    db.code,
                    db.version,
                    db.name,
                    db.description,
                    db.property_type,
                    db.is_active,
                    db.is_system,
                    db.is_published,
                    db.created_at,
                    db.updated_at

                from public.device_bundles db

                where db.code =
                      p_payload->>'code'

                and (
                    p_payload->>'version' is null
                    or db.version =
                       (p_payload->>'version')::int
                )

                order by db.version desc
                limit 1
            ) t;

        else

            perform public.preconfig_validate_payload(
                p_payload,
                array['id']::text[]
            );


            select to_jsonb(t)
            into v_result

            from (
                select
                    db.id,
                    db.code,
                    db.version,
                    db.name,
                    db.description,
                    db.property_type,
                    db.is_active,
                    db.is_system,
                    db.is_published,
                    db.created_at,
                    db.updated_at

                from public.device_bundles db

                where db.id =
                      (p_payload->>'id')::uuid
            ) t;

        end if;


        if v_result is null then
            raise exception
                'Device bundle not found';
        end if;


    when 'list_bundle_devices' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['bundle_id']::text[]
        );


        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.category_code
            ),
            '[]'::jsonb
        )
        into v_result

        from (
            select
                bd.id,
                bd.bundle_id,
                bd.category_code,
                bd.quantity,
                bd.is_required,
                bd.config_hint,
                bd.created_at

            from public.bundle_devices bd

            where bd.bundle_id =
                  (p_payload->>'bundle_id')::uuid
        ) t;


    -- =================================================
    -- READ: ONBOARDING BLUEPRINTS
    -- =================================================

    when 'list_onboarding_blueprints' then

        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.name
            ),
            '[]'::jsonb
        )
        into v_result

        from (
            select
                ob.id,
                ob.code,
                ob.name,
                ob.description,
                ob.property_type,
                ob.is_system,
                ob.is_active,
                ob.is_published,
                ob.created_at,
                ob.updated_at

            from public.onboarding_blueprints ob

            where (
                coalesce(
                    (p_payload->>'active_only')::boolean,
                    true
                ) = false
                or ob.is_active = true
            )

            and (
                p_payload->>'property_type' is null
                or ob.property_type::text =
                   p_payload->>'property_type'
            )
        ) t;


    when 'get_onboarding_blueprint' then

        if p_payload ? 'code' then

            perform public.preconfig_validate_payload(
                p_payload,
                array['code']::text[]
            );


            select id
            into v_blueprint_id

            from public.onboarding_blueprints

            where code =
                  p_payload->>'code';


            if not found then
                raise exception
                    'Onboarding blueprint not found';
            end if;

        else

            perform public.preconfig_validate_payload(
                p_payload,
                array['id']::text[]
            );

            v_blueprint_id :=
                (p_payload->>'id')::uuid;

        end if;


        select jsonb_build_object(

            'blueprint', (
                select to_jsonb(t)

                from (
                    select
                        ob.id,
                        ob.code,
                        ob.name,
                        ob.description,
                        ob.property_type,
                        ob.is_system,
                        ob.is_active,
                        ob.is_published,
                        ob.created_at,
                        ob.updated_at

                    from public.onboarding_blueprints ob

                    where ob.id =
                          v_blueprint_id
                ) t
            ),

            'steps', coalesce(
                (
                    select jsonb_agg(
                        to_jsonb(s)
                        order by s.step_order
                    )

                    from (
                        select
                            obs.id,
                            obs.blueprint_id,
                            obs.step_order,
                            obs.step_type,
                            obs.config,
                            obs.created_at

                        from public.onboarding_blueprint_steps obs

                        where obs.blueprint_id =
                              v_blueprint_id
                    ) s
                ),
                '[]'::jsonb
            )

        )
        into v_result;


        if v_result->'blueprint' =
           'null'::jsonb then

            raise exception
                'Onboarding blueprint not found';

        end if;


    when 'list_blueprint_steps' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['blueprint_id']::text[]
        );


        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.step_order
            ),
            '[]'::jsonb
        )
        into v_result

        from (
            select
                obs.id,
                obs.blueprint_id,
                obs.step_order,
                obs.step_type,
                obs.config,
                obs.created_at

            from public.onboarding_blueprint_steps obs

            where obs.blueprint_id =
                  (p_payload->>'blueprint_id')::uuid
        ) t;


    -- =================================================
    -- READ: PRECONFIG TEMPLATES
    -- =================================================

    when 'list_preconfig_templates' then

        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.code, t.version desc
            ),
            '[]'::jsonb
        )
        into v_result

        from (
            select
                pt.id,
                pt.code,
                pt.device_bundle_id,
                pt.onboarding_blueprint_id,
                pt.name,
                pt.description,
                pt.property_type,
                pt.is_active,
                pt.version,
                pt.is_system,
                pt.is_published,
                pt.created_at,
                pt.updated_at

            from public.preconfig_templates pt

            where (
                coalesce(
                    (p_payload->>'active_only')::boolean,
                    true
                ) = false
                or pt.is_active = true
            )

            and (
                p_payload->>'property_type' is null
                or pt.property_type::text =
                   p_payload->>'property_type'
            )
        ) t;


    when 'get_preconfig_template' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        v_template_id :=
            (p_payload->>'id')::uuid;


        select pt.device_bundle_id
        into v_bundle_id

        from public.preconfig_templates pt

        where pt.id =
              v_template_id;


        if not found then
            raise exception
                'Preconfig template not found';
        end if;


        select jsonb_build_object(

            'template', (
                select to_jsonb(t)

                from (
                    select
                        pt.id,
                        pt.code,
                        pt.device_bundle_id,
                        pt.onboarding_blueprint_id,
                        pt.name,
                        pt.description,
                        pt.property_type,
                        pt.is_active,
                        pt.version,
                        pt.is_system,
                        pt.is_published,
                        pt.created_at,
                        pt.updated_at

                    from public.preconfig_templates pt

                    where pt.id =
                          v_template_id
                ) t
            ),

            'device_map', coalesce(
                (
                    select jsonb_agg(
                        to_jsonb(dm)
                        order by dm.room_type
                    )

                    from (
                        select
                            pdm.id,
                            pdm.template_id,
                            pdm.category_code,
                            pdm.room_type,
                            pdm.recommended_protocol,
                            pdm.default_config,
                            pdm.created_at

                        from public.preconfig_device_map pdm

                        where pdm.template_id =
                              v_template_id
                    ) dm
                ),
                '[]'::jsonb
            ),

            'bundle_devices', coalesce(
                (
                    select jsonb_agg(
                        to_jsonb(bd)
                        order by bd.category_code
                    )

                    from (
                        select
                            bd.id,
                            bd.bundle_id,
                            bd.category_code,
                            bd.quantity,
                            bd.is_required,
                            bd.config_hint,
                            bd.created_at

                        from public.bundle_devices bd

                        where bd.bundle_id =
                              v_bundle_id
                    ) bd
                ),
                '[]'::jsonb
            )

        )
        into v_result;


    when 'list_preconfig_device_map' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['template_id']::text[]
        );


        select coalesce(
            jsonb_agg(
                to_jsonb(t)
                order by t.room_type
            ),
            '[]'::jsonb
        )
        into v_result

        from (
            select
                pdm.id,
                pdm.template_id,
                pdm.category_code,
                pdm.room_type,
                pdm.recommended_protocol,
                pdm.default_config,
                pdm.created_at

            from public.preconfig_device_map pdm

            where pdm.template_id =
                  (p_payload->>'template_id')::uuid
        ) t;


    -- =================================================
    -- CREATE: DEVICE BUNDLES
    -- =================================================

    when 'create_device_bundle' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['code', 'name']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        insert into public.device_bundles (
            code,
            name,
            description,
            property_type,
            version,
            is_active,
            is_system
        )

        values (
            p_payload->>'code',
            p_payload->>'name',
            p_payload->>'description',

            case
                when p_payload->>'property_type' is not null
                then
                    (p_payload->>'property_type')
                    ::public.property_type
                else null
            end,

            coalesce(
                (p_payload->>'version')::int,
                1
            ),

            coalesce(
                (p_payload->>'is_active')::boolean,
                true
            ),

            coalesce(
                (p_payload->>'is_system')::boolean,
                false
            )
        )

        returning
            id,
            code,
            version,
            name,
            description,
            property_type,
            is_active,
            is_system,
            is_published,
            created_at,
            updated_at

        into v_row;


        perform platform.log_audit(
            'device_bundle.created',
            'device_bundle',
            v_row.id,
            jsonb_build_object(
                'after', to_jsonb(v_row)
            )
        );


        v_result :=
            to_jsonb(v_row);


    when 'update_device_bundle' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        select to_jsonb(db)
        into v_before

        from public.device_bundles db

        where db.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Device bundle not found';
        end if;


        update public.device_bundles db

        set
            name =
                case
                    when p_payload ? 'name'
                    then p_payload->>'name'
                    else db.name
                end,

            description =
                case
                    when p_payload ? 'description'
                    then p_payload->>'description'
                    else db.description
                end,

            property_type =
                case
                    when p_payload ? 'property_type'
                    then
                        case
                            when p_payload->>'property_type' is null
                            then null
                            else
                                (p_payload->>'property_type')
                                ::public.property_type
                        end
                    else db.property_type
                end,

            is_active =
                case
                    when p_payload ? 'is_active'
                    then
                        (p_payload->>'is_active')::boolean
                    else db.is_active
                end

        where db.id =
              (p_payload->>'id')::uuid


        returning
            db.id,
            db.code,
            db.version,
            db.name,
            db.description,
            db.property_type,
            db.is_active,
            db.is_system,
            db.is_published,
            db.created_at,
            db.updated_at

        into v_row;


        perform platform.log_audit(
            'device_bundle.updated',
            'device_bundle',
            v_row.id,
            jsonb_build_object(
                'before', v_before,
                'after', to_jsonb(v_row)
            )
        );


        v_result :=
            to_jsonb(v_row);


    when 'delete_device_bundle' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        select to_jsonb(db)
        into v_before

        from public.device_bundles db

        where db.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Device bundle not found';
        end if;


        delete from public.device_bundles db

        where db.id =
              (p_payload->>'id')::uuid;


        perform platform.log_audit(
            'device_bundle.deleted',
            'device_bundle',
            (p_payload->>'id')::uuid,
            jsonb_build_object(
                'before', v_before
            )
        );


        v_result :=
            jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );


    -- =================================================
    -- BUNDLE DEVICES
    -- =================================================

    when 'create_bundle_device' then

        perform public.preconfig_validate_payload(
            p_payload,
            array[
                'bundle_id',
                'category_code'
            ]::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        if p_payload ? 'config_hint' then

            perform public.preconfig_validate_json_object(
                p_payload->'config_hint',
                'config_hint'
            );

        end if;


        insert into public.bundle_devices (
            bundle_id,
            category_code,
            quantity,
            is_required,
            config_hint
        )

        values (
            (p_payload->>'bundle_id')::uuid,
            p_payload->>'category_code',

            coalesce(
                (p_payload->>'quantity')::int,
                1
            ),

            coalesce(
                (p_payload->>'is_required')::boolean,
                true
            ),

            coalesce(
                p_payload->'config_hint',
                '{}'::jsonb
            )
        )

        returning
            id,
            bundle_id,
            category_code,
            quantity,
            is_required,
            config_hint,
            created_at

        into v_row;


        perform platform.log_audit(
            'bundle_device.created',
            'bundle_device',
            v_row.id,
            jsonb_build_object(
                'after', to_jsonb(v_row)
            )
        );


        v_result :=
            to_jsonb(v_row);


    when 'update_bundle_device' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        if p_payload ? 'config_hint' then

            perform public.preconfig_validate_json_object(
                p_payload->'config_hint',
                'config_hint'
            );

        end if;


        select to_jsonb(bd)
        into v_before

        from public.bundle_devices bd

        where bd.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Bundle device not found';
        end if;


        update public.bundle_devices bd

        set
            quantity =
                case
                    when p_payload ? 'quantity'
                    then
                        (p_payload->>'quantity')::int
                    else bd.quantity
                end,

            is_required =
                case
                    when p_payload ? 'is_required'
                    then
                        (p_payload->>'is_required')::boolean
                    else bd.is_required
                end,

            config_hint =
                case
                    when p_payload ? 'config_hint'
                    then p_payload->'config_hint'
                    else bd.config_hint
                end

        where bd.id =
              (p_payload->>'id')::uuid


        returning
            bd.id,
            bd.bundle_id,
            bd.category_code,
            bd.quantity,
            bd.is_required,
            bd.config_hint,
            bd.created_at

        into v_row;


        perform platform.log_audit(
            'bundle_device.updated',
            'bundle_device',
            v_row.id,
            jsonb_build_object(
                'before', v_before,
                'after', to_jsonb(v_row)
            )
        );


        v_result :=
            to_jsonb(v_row);


    when 'delete_bundle_device' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        select to_jsonb(bd)
        into v_before

        from public.bundle_devices bd

        where bd.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Bundle device not found';
        end if;


        delete from public.bundle_devices bd

        where bd.id =
              (p_payload->>'id')::uuid;


        perform platform.log_audit(
            'bundle_device.deleted',
            'bundle_device',
            (p_payload->>'id')::uuid,
            jsonb_build_object(
                'before', v_before
            )
        );


        v_result :=
            jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );


    -- =================================================
    -- ONBOARDING BLUEPRINTS
    -- =================================================

    when 'create_onboarding_blueprint' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['code', 'name']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        insert into public.onboarding_blueprints (
            code,
            name,
            description,
            property_type,
            is_system,
            is_active
        )

        values (
            p_payload->>'code',
            p_payload->>'name',
            p_payload->>'description',

            case
                when p_payload->>'property_type' is not null
                then
                    (p_payload->>'property_type')
                    ::public.property_type
                else null
            end,

            coalesce(
                (p_payload->>'is_system')::boolean,
                false
            ),

            coalesce(
                (p_payload->>'is_active')::boolean,
                true
            )
        )

        returning
            id,
            code,
            name,
            description,
            property_type,
            is_system,
            is_active,
            is_published,
            created_at,
            updated_at

        into v_row;


        perform platform.log_audit(
            'onboarding_blueprint.created',
            'onboarding_blueprint',
            v_row.id,
            jsonb_build_object(
                'after', to_jsonb(v_row)
            )
        );


        v_result :=
            to_jsonb(v_row);


    when 'update_onboarding_blueprint' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        select to_jsonb(ob)
        into v_before

        from public.onboarding_blueprints ob

        where ob.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Onboarding blueprint not found';
        end if;


        update public.onboarding_blueprints ob

        set
            name =
                case
                    when p_payload ? 'name'
                    then p_payload->>'name'
                    else ob.name
                end,

            description =
                case
                    when p_payload ? 'description'
                    then p_payload->>'description'
                    else ob.description
                end,

            property_type =
                case
                    when p_payload ? 'property_type'
                    then
                        case
                            when p_payload->>'property_type' is null
                            then null
                            else
                                (p_payload->>'property_type')
                                ::public.property_type
                        end
                    else ob.property_type
                end,

            is_active =
                case
                    when p_payload ? 'is_active'
                    then
                        (p_payload->>'is_active')::boolean
                    else ob.is_active
                end

        where ob.id =
              (p_payload->>'id')::uuid


        returning
            ob.id,
            ob.code,
            ob.name,
            ob.description,
            ob.property_type,
            ob.is_system,
            ob.is_active,
            ob.is_published,
            ob.created_at,
            ob.updated_at

        into v_row;


        perform platform.log_audit(
            'onboarding_blueprint.updated',
            'onboarding_blueprint',
            v_row.id,
            jsonb_build_object(
                'before', v_before,
                'after', to_jsonb(v_row)
            )
        );


        v_result :=
            to_jsonb(v_row);


    when 'delete_onboarding_blueprint' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        select to_jsonb(ob)
        into v_before

        from public.onboarding_blueprints ob

        where ob.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Onboarding blueprint not found';
        end if;


        delete from public.onboarding_blueprints ob

        where ob.id =
              (p_payload->>'id')::uuid;


        perform platform.log_audit(
            'onboarding_blueprint.deleted',
            'onboarding_blueprint',
            (p_payload->>'id')::uuid,
            jsonb_build_object(
                'before', v_before
            )
        );


        v_result :=
            jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );


    -- =================================================
    -- BLUEPRINT STEPS
    -- =================================================

    when 'create_blueprint_step' then

        perform public.preconfig_validate_payload(
            p_payload,
            array[
                'blueprint_id',
                'step_order',
                'step_type'
            ]::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        if p_payload ? 'config' then

            perform public.preconfig_validate_json_object(
                p_payload->'config',
                'config'
            );

        end if;


        insert into public.onboarding_blueprint_steps (
            blueprint_id,
            step_order,
            step_type,
            config
        )

        values (
            (p_payload->>'blueprint_id')::uuid,
            (p_payload->>'step_order')::int,
            (p_payload->>'step_type')
                ::public.onboarding_step_type,

            coalesce(
                p_payload->'config',
                '{}'::jsonb
            )
        )

        returning
            id,
            blueprint_id,
            step_order,
            step_type,
            config,
            created_at

        into v_row;


        perform platform.log_audit(
            'onboarding_blueprint_step.created',
            'onboarding_blueprint_step',
            v_row.id,
            jsonb_build_object(
                'after', to_jsonb(v_row)
            )
        );


        v_result :=
            to_jsonb(v_row);


    when 'update_blueprint_step' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        if p_payload ? 'config' then

            perform public.preconfig_validate_json_object(
                p_payload->'config',
                'config'
            );

        end if;


        select to_jsonb(obs)
        into v_before

        from public.onboarding_blueprint_steps obs

        where obs.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Blueprint step not found';
        end if;


        update public.onboarding_blueprint_steps obs

        set
            step_order =
                case
                    when p_payload ? 'step_order'
                    then
                        (p_payload->>'step_order')::int
                    else obs.step_order
                end,

            step_type =
                case
                    when p_payload ? 'step_type'
                    then
                        (p_payload->>'step_type')
                        ::public.onboarding_step_type
                    else obs.step_type
                end,

            config =
                case
                    when p_payload ? 'config'
                    then p_payload->'config'
                    else obs.config
                end

        where obs.id =
              (p_payload->>'id')::uuid


        returning
            obs.id,
            obs.blueprint_id,
            obs.step_order,
            obs.step_type,
            obs.config,
            obs.created_at

        into v_row;


        perform platform.log_audit(
            'onboarding_blueprint_step.updated',
            'onboarding_blueprint_step',
            v_row.id,
            jsonb_build_object(
                'before', v_before,
                'after', to_jsonb(v_row)
            )
        );


        v_result :=
            to_jsonb(v_row);


    when 'delete_blueprint_step' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        select to_jsonb(obs)
        into v_before

        from public.onboarding_blueprint_steps obs

        where obs.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Blueprint step not found';
        end if;


        delete from public.onboarding_blueprint_steps obs

        where obs.id =
              (p_payload->>'id')::uuid;


        perform platform.log_audit(
            'onboarding_blueprint_step.deleted',
            'onboarding_blueprint_step',
            (p_payload->>'id')::uuid,
            jsonb_build_object(
                'before', v_before
            )
        );


        v_result :=
            jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );


    -- =================================================
    -- PRECONFIG TEMPLATES
    -- =================================================

    when 'create_preconfig_template' then

        perform public.preconfig_validate_payload(
            p_payload,
            array[
                'code',
                'device_bundle_id',
                'name'
            ]::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        insert into public.preconfig_templates (
            code,
            device_bundle_id,
            onboarding_blueprint_id,
            name,
            description,
            property_type,
            is_active,
            version,
            is_system
        )

        values (
            p_payload->>'code',
            (p_payload->>'device_bundle_id')::uuid,

            case
                when p_payload->>'onboarding_blueprint_id'
                     is not null
                then
                    (p_payload->>'onboarding_blueprint_id')::uuid
                else null
            end,

            p_payload->>'name',
            p_payload->>'description',

            case
                when p_payload->>'property_type'
                     is not null
                then
                    (p_payload->>'property_type')
                    ::public.property_type
                else null
            end,

            coalesce(
                (p_payload->>'is_active')::boolean,
                true
            ),

            coalesce(
                (p_payload->>'version')::int,
                1
            ),

            coalesce(
                (p_payload->>'is_system')::boolean,
                false
            )
        )

        returning
            id,
            code,
            device_bundle_id,
            onboarding_blueprint_id,
            name,
            description,
            property_type,
            is_active,
            version,
            is_system,
            is_published,
            created_at,
            updated_at

        into v_row;


        perform platform.log_audit(
            'preconfig_template.created',
            'preconfig_template',
            v_row.id,
            jsonb_build_object(
                'after', to_jsonb(v_row)
            )
        );


        v_result :=
            to_jsonb(v_row);


    when 'update_preconfig_template' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        select to_jsonb(pt)
        into v_before

        from public.preconfig_templates pt

        where pt.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Preconfig template not found';
        end if;


        update public.preconfig_templates pt

        set
            device_bundle_id =
                case
                    when p_payload ? 'device_bundle_id'
                    then
                        (p_payload->>'device_bundle_id')::uuid
                    else pt.device_bundle_id
                end,

            onboarding_blueprint_id =
                case
                    when p_payload ? 'onboarding_blueprint_id'
                    then
                        case
                            when p_payload->>'onboarding_blueprint_id'
                                 is null
                            then null
                            else
                                (p_payload->>'onboarding_blueprint_id')
                                ::uuid
                        end
                    else pt.onboarding_blueprint_id
                end,

            name =
                case
                    when p_payload ? 'name'
                    then p_payload->>'name'
                    else pt.name
                end,

            description =
                case
                    when p_payload ? 'description'
                    then p_payload->>'description'
                    else pt.description
                end,

            property_type =
                case
                    when p_payload ? 'property_type'
                    then
                        case
                            when p_payload->>'property_type' is null
                            then null
                            else
                                (p_payload->>'property_type')
                                ::public.property_type
                        end
                    else pt.property_type
                end,

            is_active =
                case
                    when p_payload ? 'is_active'
                    then
                        (p_payload->>'is_active')::boolean
                    else pt.is_active
                end

        where pt.id =
              (p_payload->>'id')::uuid


        returning
            pt.id,
            pt.code,
            pt.device_bundle_id,
            pt.onboarding_blueprint_id,
            pt.name,
            pt.description,
            pt.property_type,
            pt.is_active,
            pt.version,
            pt.is_system,
            pt.is_published,
            pt.created_at,
            pt.updated_at

        into v_row;


        perform platform.log_audit(
            'preconfig_template.updated',
            'preconfig_template',
            v_row.id,
            jsonb_build_object(
                'before', v_before,
                'after', to_jsonb(v_row)
            )
        );


        v_result :=
            to_jsonb(v_row);


    when 'delete_preconfig_template' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        select to_jsonb(pt)
        into v_before

        from public.preconfig_templates pt

        where pt.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Preconfig template not found';
        end if;


        delete from public.preconfig_templates pt

        where pt.id =
              (p_payload->>'id')::uuid;


        perform platform.log_audit(
            'preconfig_template.deleted',
            'preconfig_template',
            (p_payload->>'id')::uuid,
            jsonb_build_object(
                'before', v_before
            )
        );


        v_result :=
            jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );


    -- =================================================
    -- PRECONFIG DEVICE MAP
    -- =================================================

    when 'create_preconfig_device_map' then

        perform public.preconfig_validate_payload(
            p_payload,
            array[
                'template_id',
                'category_code',
                'room_type'
            ]::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        if p_payload ? 'default_config' then

            perform public.preconfig_validate_json_object(
                p_payload->'default_config',
                'default_config'
            );

        end if;


        insert into public.preconfig_device_map (
            template_id,
            category_code,
            room_type,
            recommended_protocol,
            default_config
        )

        values (
            (p_payload->>'template_id')::uuid,
            p_payload->>'category_code',
            (p_payload->>'room_type')::public.room_type,

            case
                when p_payload->>'recommended_protocol'
                     is not null
                then
                    (p_payload->>'recommended_protocol')
                    ::public.device_protocol
                else null
            end,

            coalesce(
                p_payload->'default_config',
                '{}'::jsonb
            )
        )

        returning
            id,
            template_id,
            category_code,
            room_type,
            recommended_protocol,
            default_config,
            created_at

        into v_row;


        perform platform.log_audit(
            'preconfig_device_map.created',
            'preconfig_device_map',
            v_row.id,
            jsonb_build_object(
                'after', to_jsonb(v_row)
            )
        );


        v_result :=
            to_jsonb(v_row);


    when 'update_preconfig_device_map' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        if p_payload ? 'default_config' then

            perform public.preconfig_validate_json_object(
                p_payload->'default_config',
                'default_config'
            );

        end if;


        select to_jsonb(pdm)
        into v_before

        from public.preconfig_device_map pdm

        where pdm.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Preconfig device map not found';
        end if;


        update public.preconfig_device_map pdm

        set
            category_code =
                case
                    when p_payload ? 'category_code'
                    then p_payload->>'category_code'
                    else pdm.category_code
                end,

            room_type =
                case
                    when p_payload ? 'room_type'
                    then
                        (p_payload->>'room_type')
                        ::public.room_type
                    else pdm.room_type
                end,

            recommended_protocol =
                case
                    when p_payload ? 'recommended_protocol'
                    then
                        case
                            when p_payload->>'recommended_protocol'
                                 is null
                            then null
                            else
                                (p_payload->>'recommended_protocol')
                                ::public.device_protocol
                        end
                    else pdm.recommended_protocol
                end,

            default_config =
                case
                    when p_payload ? 'default_config'
                    then p_payload->'default_config'
                    else pdm.default_config
                end

        where pdm.id =
              (p_payload->>'id')::uuid


        returning
            pdm.id,
            pdm.template_id,
            pdm.category_code,
            pdm.room_type,
            pdm.recommended_protocol,
            pdm.default_config,
            pdm.created_at

        into v_row;


        perform platform.log_audit(
            'preconfig_device_map.updated',
            'preconfig_device_map',
            v_row.id,
            jsonb_build_object(
                'before', v_before,
                'after', to_jsonb(v_row)
            )
        );


        v_result :=
            to_jsonb(v_row);


    when 'delete_preconfig_device_map' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        select to_jsonb(pdm)
        into v_before

        from public.preconfig_device_map pdm

        where pdm.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Preconfig device map not found';
        end if;


        delete from public.preconfig_device_map pdm

        where pdm.id =
              (p_payload->>'id')::uuid;


        perform platform.log_audit(
            'preconfig_device_map.deleted',
            'preconfig_device_map',
            (p_payload->>'id')::uuid,
            jsonb_build_object(
                'before', v_before
            )
        );


        v_result :=
            jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );


    -- =================================================
    -- PUBLISHING
    -- Publish is separate from editing.
    -- =================================================

    when 'publish_device_bundle' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        select to_jsonb(db)
        into v_before

        from public.device_bundles db

        where db.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Device bundle not found';
        end if;


        update public.device_bundles

        set is_published = true

        where id =
              (p_payload->>'id')::uuid

          and is_published = false


        returning
            id,
            code,
            version,
            name,
            description,
            property_type,
            is_active,
            is_system,
            is_published,
            created_at,
            updated_at

        into v_row;


        if not found then

            select
                db.id,
                db.code,
                db.version,
                db.name,
                db.description,
                db.property_type,
                db.is_active,
                db.is_system,
                db.is_published,
                db.created_at,
                db.updated_at

            into v_row

            from public.device_bundles db

            where db.id =
                  (p_payload->>'id')::uuid;

        else

            perform platform.log_audit(
                'device_bundle.published',
                'device_bundle',
                v_row.id,
                jsonb_build_object(
                    'before', v_before,
                    'after', to_jsonb(v_row)
                )
            );

        end if;


        v_result :=
            to_jsonb(v_row);


    when 'publish_onboarding_blueprint' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        select to_jsonb(ob)
        into v_before

        from public.onboarding_blueprints ob

        where ob.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Onboarding blueprint not found';
        end if;


        update public.onboarding_blueprints

        set is_published = true

        where id =
              (p_payload->>'id')::uuid

          and is_published = false


        returning
            id,
            code,
            name,
            description,
            property_type,
            is_system,
            is_active,
            is_published,
            created_at,
            updated_at

        into v_row;


        if not found then

            select
                ob.id,
                ob.code,
                ob.name,
                ob.description,
                ob.property_type,
                ob.is_system,
                ob.is_active,
                ob.is_published,
                ob.created_at,
                ob.updated_at

            into v_row

            from public.onboarding_blueprints ob

            where ob.id =
                  (p_payload->>'id')::uuid;

        else

            perform platform.log_audit(
                'onboarding_blueprint.published',
                'onboarding_blueprint',
                v_row.id,
                jsonb_build_object(
                    'before', v_before,
                    'after', to_jsonb(v_row)
                )
            );

        end if;


        v_result :=
            to_jsonb(v_row);


    when 'publish_preconfig_template' then

        perform public.preconfig_validate_payload(
            p_payload,
            array['id']::text[]
        );


        if not platform.is_platform_admin() then
            raise exception
                'platform admin role required';
        end if;


        select to_jsonb(pt)
        into v_before

        from public.preconfig_templates pt

        where pt.id =
              (p_payload->>'id')::uuid;


        if v_before is null then
            raise exception
                'Preconfig template not found';
        end if;


        update public.preconfig_templates

        set is_published = true

        where id =
              (p_payload->>'id')::uuid

          and is_published = false


        returning
            id,
            code,
            device_bundle_id,
            onboarding_blueprint_id,
            name,
            description,
            property_type,
            is_active,
            version,
            is_system,
            is_published,
            created_at,
            updated_at

        into v_row;


        if not found then

            select
                pt.id,
                pt.code,
                pt.device_bundle_id,
                pt.onboarding_blueprint_id,
                pt.name,
                pt.description,
                pt.property_type,
                pt.is_active,
                pt.version,
                pt.is_system,
                pt.is_published,
                pt.created_at,
                pt.updated_at

            into v_row

            from public.preconfig_templates pt

            where pt.id =
                  (p_payload->>'id')::uuid;

        else

            perform platform.log_audit(
                'preconfig_template.published',
                'preconfig_template',
                v_row.id,
                jsonb_build_object(
                    'before', v_before,
                    'after', to_jsonb(v_row)
                )
            );

        end if;


        v_result :=
            to_jsonb(v_row);


    -- =================================================
    -- UNKNOWN OPERATION
    -- =================================================

    else

        raise exception
            'unknown preconfig_domain operation: %',
            p_op;

    end case;


    return v_result;

end;
$$;


-- =====================================================
-- 11. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (
    migration_name,
    version,
    rollback_available
)
values (
    '010_preconfig_engine',
    'REV3',
    false
)

on conflict (migration_name)
do update
set
    version = excluded.version,
    rollback_available = excluded.rollback_available;


-- =====================================================
-- END 010 PRECONFIG ENGINE REV3
-- =====================================================