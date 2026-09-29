-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 011_LOGISTICS_ENGINE.SQL
-- =====================================================
--
-- CLEAN FULFILMENT DEFINITION & DOMAIN LAYER
-- NO SHIPPING EXECUTION / NO TRACKING / NO EVENTS / NO LABEL GENERATION
-- =====================================================
--
-- SSOT HIERARCHY
-- device_bundles (010)     — hardware BOM (package contents live there)
-- logistics_templates      — delivery blueprint per tenant or platform
-- package_definitions      — shipment package = template + device_bundle
-- shipping_carriers       — carrier catalog
-- shipping_rules           — routing/pricing rules (definition only)
-- warehouses               — fulfilment origin locations (definition only)
-- shipping_label_templates — label format/service codes per carrier
-- fulfilment_orders        — shipment intent (business status only, no tracking)
--
-- EXECUTION (000): shipment_dispatch_queue, shipment_tracking_events, carrier API
-- =====================================================


-- =====================================================
-- 1. SHIPPING CARRIERS
-- GLOBAL CARRIER CATALOG
-- =====================================================

create table if not exists public.shipping_carriers (
    id uuid primary key default gen_random_uuid(),

    name text not null,

    provider_code text,

    is_active boolean default true,

    created_at timestamptz default now(),

    unique (name)
);


-- =====================================================
-- 2. SHIPPING LABEL TEMPLATES
-- CARRIER-SPECIFIC LABEL FORMAT DEFINITIONS
-- =====================================================

create table if not exists public.shipping_label_templates (
    id uuid primary key default gen_random_uuid(),

    carrier_id uuid not null references shipping_carriers(id) on delete cascade,

    name text not null,

    label_format text not null default 'pdf',

    service_code text,

    config jsonb not null default '{}'::jsonb,

    is_active boolean default true,

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    unique (carrier_id, name),

    constraint chk_shipping_label_templates_format check (
        label_format in ('pdf', 'zpl', 'png')
    )
);


-- =====================================================
-- 3. LOGISTICS TEMPLATES
-- DELIVERY BLUEPRINTS PER TENANT OR PLATFORM
-- =====================================================

create table if not exists public.logistics_templates (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid,

    is_system boolean not null default false,

    name text not null,

    description text,

    is_active boolean default true,

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    constraint chk_logistics_templates_system_scope check (
        (is_system and tenant_id is null)
        or (not is_system and tenant_id is not null)
    )
);


-- =====================================================
-- 4. WAREHOUSES
-- FULFILMENT ORIGIN LOCATIONS
-- =====================================================

create table if not exists public.warehouses (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid,

    is_system boolean not null default false,

    name text not null,

    address text,

    country_code text not null default 'GR',

    default_carrier_id uuid references shipping_carriers(id) on delete set null,

    is_active boolean default true,

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    constraint chk_warehouses_system_scope check (
        (is_system and tenant_id is null)
        or (not is_system and tenant_id is not null)
    )
);


-- =====================================================
-- 5. SHIPPING RULES
-- ROUTING / PRICING / SERVICE DEFINITIONS
-- =====================================================

create table if not exists public.shipping_rules (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid,

    is_system boolean not null default false,

    carrier_id uuid references shipping_carriers(id) on delete set null,

    rule_name text not null,

    rule_config jsonb not null default '{}'::jsonb,

    is_active boolean default true,

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    constraint chk_shipping_rules_system_scope check (
        (is_system and tenant_id is null)
        or (not is_system and tenant_id is not null)
    )
);


-- =====================================================
-- 6. PACKAGE DEFINITIONS
-- SHIPMENT PACKAGE = LOGISTICS TEMPLATE + DEVICE BUNDLE
-- BOM CONTENTS REMAIN IN 010 device_bundles
-- =====================================================

create table if not exists public.package_definitions (
    id uuid primary key default gen_random_uuid(),

    template_id uuid not null references logistics_templates(id) on delete cascade,

    device_bundle_id uuid not null references device_bundles(id) on delete restrict,

    name text not null,

    description text,

    unique (template_id, device_bundle_id)
);


-- =====================================================
-- 7. FULFILMENT ORDERS
-- SHIPMENT INTENT — NO TRACKING
-- =====================================================

create table if not exists public.fulfilment_orders (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    property_id uuid not null references properties(id) on delete restrict,

    package_definition_id uuid references package_definitions(id) on delete restrict,

    device_bundle_id uuid references device_bundles(id) on delete restrict,

    carrier_id uuid references shipping_carriers(id) on delete set null,

    warehouse_id uuid references warehouses(id) on delete set null,

    label_template_id uuid references shipping_label_templates(id) on delete set null,

    status fulfilment_status not null default 'draft',

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    constraint chk_fulfilment_orders_package check (
        package_definition_id is not null
        or device_bundle_id is not null
    )
);


-- =====================================================
-- 8. INDEXES
-- DOMAIN QUERY PERFORMANCE
-- =====================================================

create index if not exists idx_logistics_templates_tenant
on public.logistics_templates (tenant_id);

create index if not exists idx_package_definitions_template
on public.package_definitions (template_id);

create index if not exists idx_package_definitions_bundle
on public.package_definitions (device_bundle_id);

create index if not exists idx_warehouses_tenant
on public.warehouses (tenant_id);

create index if not exists idx_shipping_label_templates_carrier
on public.shipping_label_templates (carrier_id);

create index if not exists idx_shipping_rules_tenant
on public.shipping_rules (tenant_id);

create index if not exists idx_shipping_rules_carrier
on public.shipping_rules (carrier_id)
where carrier_id is not null;

create index if not exists idx_fulfilment_orders_tenant
on public.fulfilment_orders (tenant_id);

create index if not exists idx_fulfilment_orders_tenant_status
on public.fulfilment_orders (tenant_id, status);

create index if not exists idx_fulfilment_orders_tenant_created
on public.fulfilment_orders (tenant_id, created_at desc);

create index if not exists idx_fulfilment_orders_property
on public.fulfilment_orders (property_id);


-- =====================================================
-- 9. TABLE & COLUMN DOCUMENTATION
-- =====================================================

comment on table public.package_definitions is
    'Shipment package definition. BOM contents come from 010 device_bundles / bundle_devices.';

comment on table public.shipping_carriers is
    'Carrier catalog. API dispatch and tracking ingest belong in platform layer (000).';

comment on table public.warehouses is
    'Fulfilment origin locations. Stock movements and inventory execution belong in 000.';

comment on table public.shipping_label_templates is
    'Label format and carrier service codes. Generated artifacts stored via platform.shipment_dispatch_queue (000).';

comment on column public.shipping_label_templates.config is
    'Non-secret template options: { paper_size, orientation, margin_mm }.';

comment on column public.shipping_rules.rule_config is
    'Non-secret routing rules: { country, min_weight, max_weight, service_level, priority }.';

comment on table public.fulfilment_orders is
    'Domain shipment intent. No tracking numbers or label URLs — those belong in platform layer (000).';


-- =====================================================
-- 10. SYSTEM SCOPE BACKFILL
-- EXISTING DEPLOYMENT COMPATIBILITY
-- =====================================================

alter table public.warehouses
    add column if not exists is_system boolean not null default false;


update public.warehouses
set is_system = true
where tenant_id is null
  and not is_system;


alter table public.warehouses
    drop constraint if exists chk_warehouses_system_scope;


alter table public.warehouses
    add constraint chk_warehouses_system_scope check (
        (is_system and tenant_id is null)
        or (not is_system and tenant_id is not null)
    );


alter table public.shipping_rules
    add column if not exists is_system boolean not null default false;


update public.shipping_rules
set is_system = true
where tenant_id is null
  and not is_system;


alter table public.shipping_rules
    drop constraint if exists chk_shipping_rules_system_scope;


alter table public.shipping_rules
    add constraint chk_shipping_rules_system_scope check (
        (is_system and tenant_id is null)
        or (not is_system and tenant_id is not null)
    );


-- =====================================================
-- 11. DEFERRED TENANT FOREIGN KEYS
-- TENANTS ARE ESTABLISHED IN 002
-- =====================================================

do $$
begin
    alter table public.logistics_templates
        add constraint fk_logistics_templates_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table public.shipping_rules
        add constraint fk_shipping_rules_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table public.fulfilment_orders
        add constraint fk_fulfilment_orders_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table public.warehouses
        add constraint fk_warehouses_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


-- =====================================================
-- 12. SHIPPING CARRIER PROVIDER FK
-- PROVIDER CATALOG SSOT FROM 005
-- =====================================================

do $$
begin
    alter table public.shipping_carriers
        add constraint fk_shipping_carriers_provider_code
        foreign key (provider_code) references public.integration_providers(code);
exception when duplicate_object then null;
end $$;


-- =====================================================
-- 13. PLATFORM EXECUTION BINDINGS
-- 000 SHIPMENT DISPATCH / TRACKING
-- =====================================================

do $$
begin
    alter table platform.shipment_dispatch_queue
        add constraint fk_shipment_dispatch_fulfilment_order
        foreign key (fulfilment_order_id) references public.fulfilment_orders(id) on delete restrict;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table platform.shipment_tracking_events
        add constraint fk_shipment_tracking_fulfilment_order
        foreign key (fulfilment_order_id) references public.fulfilment_orders(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


comment on constraint fk_shipment_dispatch_fulfilment_order on platform.shipment_dispatch_queue is
    'Domain fulfilment intent (011) is SSOT; restrict delete while dispatch may exist.';


-- =====================================================
-- 14. FULFILMENT ORDER CONSISTENCY
-- DOMAIN INTEGRITY TRIGGER FUNCTION
-- =====================================================

create or replace function public.enforce_fulfilment_order_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_property_tenant uuid;
    v_package_bundle uuid;
begin
    select p.tenant_id
    into v_property_tenant
    from public.properties p
    where p.id = new.property_id;

    if not found then
        raise exception 'property not found';
    end if;

    if new.tenant_id <> v_property_tenant then
        raise exception 'fulfilment order tenant_id must match property tenant_id';
    end if;

    if new.package_definition_id is not null then
        select pd.device_bundle_id
        into v_package_bundle
        from public.package_definitions pd
        where pd.id = new.package_definition_id;

        if not found then
            raise exception 'package definition not found';
        end if;

        if new.device_bundle_id is not null
           and new.device_bundle_id <> v_package_bundle then
            raise exception 'device_bundle_id must match package_definition device_bundle_id';
        end if;

        new.device_bundle_id := coalesce(new.device_bundle_id, v_package_bundle);
    end if;

    if new.label_template_id is not null and new.carrier_id is not null then
        if not exists (
            select 1
            from public.shipping_label_templates slt
            where slt.id = new.label_template_id
              and slt.carrier_id = new.carrier_id
        ) then
            raise exception 'label_template_id must belong to the selected carrier';
        end if;
    end if;

    if new.warehouse_id is not null then
        if exists (
            select 1
            from public.warehouses w
            where w.id = new.warehouse_id
              and w.tenant_id is not null
              and w.tenant_id <> new.tenant_id
        ) then
            raise exception 'warehouse must belong to the fulfilment order tenant';
        end if;
    end if;

    return new;
end;
$$;


-- =====================================================
-- 15. FULFILMENT DISPATCH WORKFLOW
-- DOMAIN → PLATFORM DISPATCH QUEUE
-- =====================================================

create or replace function public.logistics_dispatch_fulfilment_order(
    p_fulfilment_order_id uuid,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_order record;
    v_queue_id text;
    v_merged jsonb;
begin
    v_tid := platform.current_tenant_id();

    select fo.id, fo.status, fo.property_id, fo.carrier_id, fo.warehouse_id,
           fo.label_template_id, fo.package_definition_id, fo.device_bundle_id
    into v_order
    from public.fulfilment_orders fo
    where fo.id = p_fulfilment_order_id
      and fo.tenant_id = v_tid
      and fo.deleted_at is null;

    if not found then
        raise exception 'fulfilment order not found';
    end if;

    if v_order.status <> 'ready_to_ship' then
        raise exception 'fulfilment order must be ready_to_ship before dispatch (current: %)', v_order.status;
    end if;

    v_merged := coalesce(p_payload, '{}'::jsonb)
        || jsonb_build_object(
            'property_id', v_order.property_id,
            'carrier_id', v_order.carrier_id,
            'warehouse_id', v_order.warehouse_id,
            'label_template_id', v_order.label_template_id,
            'package_definition_id', v_order.package_definition_id,
            'device_bundle_id', v_order.device_bundle_id
        );

    v_queue_id := platform.enqueue_shipment_dispatch(
        v_tid,
        v_order.id,
        v_merged
    );

    return jsonb_build_object(
        'queued', true,
        'dispatch_queue_id', v_queue_id,
        'fulfilment_order_id', v_order.id
    );
end;
$$;


-- =====================================================
-- 16. LOGISTICS DOMAIN API
-- TENANT-FACING DOMAIN OPERATIONS
-- =====================================================

create or replace function public.logistics_domain(
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
    v_row record;
    v_result jsonb;
    v_template record;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op
        when 'list_logistics_templates' then
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            select coalesce(
                jsonb_agg(to_jsonb(lt) order by lt.name),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    l.id,
                    l.tenant_id,
                    l.is_system,
                    l.name,
                    l.description,
                    l.is_active,
                    l.created_at,
                    l.updated_at
                from public.logistics_templates l
                where l.tenant_id = v_tid
                   or l.is_system = true
            ) lt;

            return v_result;

        when 'get_logistics_template' then
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            select
                l.id,
                l.tenant_id,
                l.is_system,
                l.name,
                l.description,
                l.is_active,
                l.created_at,
                l.updated_at
            into v_template
            from public.logistics_templates l
            where l.id = (p_payload->>'id')::uuid
              and (l.tenant_id = v_tid or l.is_system = true);

            if not found then
                raise exception 'Logistics template not found';
            end if;

            select jsonb_build_object(
                'template', to_jsonb(v_template),
                'packages', coalesce((
                    select jsonb_agg(to_jsonb(pd) order by pd.name)
                    from (
                        select
                            p.id,
                            p.template_id,
                            p.device_bundle_id,
                            p.name,
                            p.description
                        from public.package_definitions p
                        where p.template_id = v_template.id
                    ) pd
                ), '[]'::jsonb)
            )
            into v_result;

            return v_result;

        when 'create_logistics_template' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            insert into public.logistics_templates (
                tenant_id,
                is_system,
                name,
                description,
                is_active
            )
            values (
                v_tid,
                false,
                p_payload->>'name',
                p_payload->>'description',
                coalesce((p_payload->>'is_active')::boolean, true)
            )
            returning
                id,
                tenant_id,
                is_system,
                name,
                description,
                is_active,
                created_at,
                updated_at
            into v_row;

            perform platform.log_audit(
                'logistics_template.created',
                'logistics_template',
                v_row.id
            );

            return to_jsonb(v_row);

        when 'update_logistics_template' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            update public.logistics_templates l
            set
                name = case
                    when p_payload ? 'name' then p_payload->>'name'
                    else l.name
                end,
                description = case
                    when p_payload ? 'description' then p_payload->>'description'
                    else l.description
                end,
                is_active = case
                    when p_payload ? 'is_active'
                        then (p_payload->>'is_active')::boolean
                    else l.is_active
                end
            where l.id = (p_payload->>'id')::uuid
              and l.is_system = false
              and l.tenant_id = v_tid
            returning
                l.id,
                l.tenant_id,
                l.is_system,
                l.name,
                l.description,
                l.is_active,
                l.created_at,
                l.updated_at
            into v_row;

            if not found then
                raise exception 'Logistics template not found';
            end if;

            perform platform.log_audit(
                'logistics_template.updated',
                'logistics_template',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);

        when 'delete_logistics_template' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            delete from public.logistics_templates l
            where l.id = (p_payload->>'id')::uuid
              and l.is_system = false
              and l.tenant_id = v_tid;

            if not found then
                raise exception 'Logistics template not found';
            end if;

            perform platform.log_audit(
                'logistics_template.deleted',
                'logistics_template',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );

        when 'list_package_definitions' then
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            select coalesce(
                jsonb_agg(to_jsonb(pd) order by pd.name),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    p.id,
                    p.template_id,
                    p.device_bundle_id,
                    p.name,
                    p.description
                from public.package_definitions p
                join public.logistics_templates lt on lt.id = p.template_id
                where p.template_id = (p_payload->>'template_id')::uuid
                  and (lt.tenant_id = v_tid or lt.is_system = true)
            ) pd;

            return v_result;

        when 'create_package_definition' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            if not exists (
                select 1
                from public.logistics_templates lt
                where lt.id = (p_payload->>'template_id')::uuid
                  and lt.tenant_id = v_tid
                  and lt.is_system = false
            ) then
                raise exception 'Logistics template not found';
            end if;

            insert into public.package_definitions (
                template_id,
                device_bundle_id,
                name,
                description
            )
            values (
                (p_payload->>'template_id')::uuid,
                (p_payload->>'device_bundle_id')::uuid,
                p_payload->>'name',
                p_payload->>'description'
            )
            returning
                id,
                template_id,
                device_bundle_id,
                name,
                description
            into v_row;

            perform platform.log_audit(
                'package_definition.created',
                'package_definition',
                v_row.id
            );

            return to_jsonb(v_row);

        when 'update_package_definition' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            update public.package_definitions p
            set
                name = case
                    when p_payload ? 'name' then p_payload->>'name'
                    else p.name
                end,
                description = case
                    when p_payload ? 'description' then p_payload->>'description'
                    else p.description
                end
            from public.logistics_templates lt
            where p.id = (p_payload->>'id')::uuid
              and p.template_id = lt.id
              and lt.tenant_id = v_tid
              and lt.is_system = false
            returning
                p.id,
                p.template_id,
                p.device_bundle_id,
                p.name,
                p.description
            into v_row;

            if not found then
                raise exception 'Package definition not found';
            end if;

            perform platform.log_audit(
                'package_definition.updated',
                'package_definition',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);

        when 'delete_package_definition' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            delete from public.package_definitions p
            using public.logistics_templates lt
            where p.id = (p_payload->>'id')::uuid
              and p.template_id = lt.id
              and lt.tenant_id = v_tid
              and lt.is_system = false;

            if not found then
                raise exception 'Package definition not found';
            end if;

            perform platform.log_audit(
                'package_definition.deleted',
                'package_definition',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );

        when 'list_carriers' then

            select coalesce(
                jsonb_agg(to_jsonb(c) order by c.name),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    sc.id,
                    sc.name,
                    sc.provider_code,
                    sc.is_active,
                    sc.created_at
                from public.shipping_carriers sc
                where sc.is_active = true
            ) c;

            return v_result;

        when 'get_carrier' then

            select
                sc.id,
                sc.name,
                sc.provider_code,
                sc.is_active,
                sc.created_at
            into v_row
            from public.shipping_carriers sc
            where sc.id = (p_payload->>'id')::uuid;

            if not found then
                raise exception 'Shipping carrier not found';
            end if;

            return to_jsonb(v_row);

        when 'create_carrier' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            insert into public.shipping_carriers (
                name,
                provider_code,
                is_active
            )
            values (
                p_payload->>'name',
                p_payload->>'provider_code',
                coalesce((p_payload->>'is_active')::boolean, true)
            )
            returning
                id,
                name,
                provider_code,
                is_active,
                created_at
            into v_row;

            perform platform.log_audit(
                'shipping_carrier.created',
                'shipping_carrier',
                v_row.id
            );

            return to_jsonb(v_row);

        when 'update_carrier' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            update public.shipping_carriers sc
            set
                name = case
                    when p_payload ? 'name' then p_payload->>'name'
                    else sc.name
                end,
                provider_code = case
                    when p_payload ? 'provider_code' then p_payload->>'provider_code'
                    else sc.provider_code
                end,
                is_active = case
                    when p_payload ? 'is_active'
                        then (p_payload->>'is_active')::boolean
                    else sc.is_active
                end
            where sc.id = (p_payload->>'id')::uuid
            returning
                sc.id,
                sc.name,
                sc.provider_code,
                sc.is_active,
                sc.created_at
            into v_row;

            if not found then
                raise exception 'Shipping carrier not found';
            end if;

            perform platform.log_audit(
                'shipping_carrier.updated',
                'shipping_carrier',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);

        when 'delete_carrier' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            delete from public.shipping_carriers sc
            where sc.id = (p_payload->>'id')::uuid;

            if not found then
                raise exception 'Shipping carrier not found';
            end if;

            perform platform.log_audit(
                'shipping_carrier.deleted',
                'shipping_carrier',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );

        when 'list_warehouses' then
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            select coalesce(
                jsonb_agg(to_jsonb(w) order by w.name),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    wh.id,
                    wh.tenant_id,
                    wh.is_system,
                    wh.name,
                    wh.address,
                    wh.country_code,
                    wh.default_carrier_id,
                    wh.is_active,
                    wh.created_at,
                    wh.updated_at
                from public.warehouses wh
                where wh.tenant_id = v_tid
                   or wh.is_system = true
            ) w;

            return v_result;

        when 'get_warehouse' then
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            select
                wh.id,
                wh.tenant_id,
                wh.is_system,
                wh.name,
                wh.address,
                wh.country_code,
                wh.default_carrier_id,
                wh.is_active,
                wh.created_at,
                wh.updated_at
            into v_row
            from public.warehouses wh
            where wh.id = (p_payload->>'id')::uuid
              and (wh.tenant_id = v_tid or wh.is_system = true);

            if not found then
                raise exception 'Warehouse not found';
            end if;

            return to_jsonb(v_row);

        when 'create_warehouse' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            insert into public.warehouses (
                tenant_id,
                is_system,
                name,
                address,
                country_code,
                default_carrier_id,
                is_active
            )
            values (
                v_tid,
                false,
                p_payload->>'name',
                p_payload->>'address',
                coalesce(p_payload->>'country_code', 'GR'),
                nullif(p_payload->>'default_carrier_id', '')::uuid,
                coalesce((p_payload->>'is_active')::boolean, true)
            )
            returning
                id,
                tenant_id,
                is_system,
                name,
                address,
                country_code,
                default_carrier_id,
                is_active,
                created_at,
                updated_at
            into v_row;

            perform platform.log_audit(
                'warehouse.created',
                'warehouse',
                v_row.id
            );

            return to_jsonb(v_row);

        when 'update_warehouse' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            update public.warehouses wh
            set
                name = case
                    when p_payload ? 'name' then p_payload->>'name'
                    else wh.name
                end,
                address = case
                    when p_payload ? 'address' then p_payload->>'address'
                    else wh.address
                end,
                country_code = case
                    when p_payload ? 'country_code' then p_payload->>'country_code'
                    else wh.country_code
                end,
                default_carrier_id = case
                    when p_payload ? 'default_carrier_id'
                        then nullif(p_payload->>'default_carrier_id', '')::uuid
                    else wh.default_carrier_id
                end,
                is_active = case
                    when p_payload ? 'is_active'
                        then (p_payload->>'is_active')::boolean
                    else wh.is_active
                end
            where wh.id = (p_payload->>'id')::uuid
              and wh.is_system = false
              and wh.tenant_id = v_tid
            returning
                wh.id,
                wh.tenant_id,
                wh.is_system,
                wh.name,
                wh.address,
                wh.country_code,
                wh.default_carrier_id,
                wh.is_active,
                wh.created_at,
                wh.updated_at
            into v_row;

            if not found then
                raise exception 'Warehouse not found';
            end if;

            perform platform.log_audit(
                'warehouse.updated',
                'warehouse',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);

        when 'delete_warehouse' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            delete from public.warehouses wh
            where wh.id = (p_payload->>'id')::uuid
              and wh.is_system = false
              and wh.tenant_id = v_tid;

            if not found then
                raise exception 'Warehouse not found';
            end if;

            perform platform.log_audit(
                'warehouse.deleted',
                'warehouse',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );

        when 'list_label_templates' then

            select coalesce(
                jsonb_agg(to_jsonb(lt) order by lt.name),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    sl.id,
                    sl.carrier_id,
                    sl.name,
                    sl.label_format,
                    sl.service_code,
                    sl.config,
                    sl.is_active,
                    sl.created_at,
                    sl.updated_at
                from public.shipping_label_templates sl
                where sl.is_active = true
                  and (
                      p_payload->>'carrier_id' is null
                      or sl.carrier_id = (p_payload->>'carrier_id')::uuid
                  )
            ) lt;

            return v_result;

        when 'create_label_template' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            insert into public.shipping_label_templates (
                carrier_id,
                name,
                label_format,
                service_code,
                config,
                is_active
            )
            values (
                (p_payload->>'carrier_id')::uuid,
                p_payload->>'name',
                coalesce(p_payload->>'label_format', 'pdf'),
                p_payload->>'service_code',
                coalesce(p_payload->'config', '{}'::jsonb),
                coalesce((p_payload->>'is_active')::boolean, true)
            )
            returning
                id,
                carrier_id,
                name,
                label_format,
                service_code,
                config,
                is_active,
                created_at,
                updated_at
            into v_row;

            perform platform.log_audit(
                'shipping_label_template.created',
                'shipping_label_template',
                v_row.id
            );

            return to_jsonb(v_row);

        when 'update_label_template' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            update public.shipping_label_templates sl
            set
                name = case
                    when p_payload ? 'name' then p_payload->>'name'
                    else sl.name
                end,
                label_format = case
                    when p_payload ? 'label_format' then p_payload->>'label_format'
                    else sl.label_format
                end,
                service_code = case
                    when p_payload ? 'service_code' then p_payload->>'service_code'
                    else sl.service_code
                end,
                config = case
                    when p_payload ? 'config' then p_payload->'config'
                    else sl.config
                end,
                is_active = case
                    when p_payload ? 'is_active'
                        then (p_payload->>'is_active')::boolean
                    else sl.is_active
                end
            where sl.id = (p_payload->>'id')::uuid
            returning
                sl.id,
                sl.carrier_id,
                sl.name,
                sl.label_format,
                sl.service_code,
                sl.config,
                sl.is_active,
                sl.created_at,
                sl.updated_at
            into v_row;

            if not found then
                raise exception 'Shipping label template not found';
            end if;

            perform platform.log_audit(
                'shipping_label_template.updated',
                'shipping_label_template',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);

        when 'delete_label_template' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            delete from public.shipping_label_templates sl
            where sl.id = (p_payload->>'id')::uuid;

            if not found then
                raise exception 'Shipping label template not found';
            end if;

            perform platform.log_audit(
                'shipping_label_template.deleted',
                'shipping_label_template',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );

        when 'list_shipping_rules' then
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            select coalesce(
                jsonb_agg(to_jsonb(sr) order by sr.rule_name),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    s.id,
                    s.tenant_id,
                    s.is_system,
                    s.carrier_id,
                    s.rule_name,
                    s.rule_config,
                    s.is_active,
                    s.created_at,
                    s.updated_at
                from public.shipping_rules s
                where s.tenant_id = v_tid
                   or s.is_system = true
            ) sr;

            return v_result;

        when 'create_shipping_rule' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            insert into public.shipping_rules (
                tenant_id,
                is_system,
                carrier_id,
                rule_name,
                rule_config,
                is_active
            )
            values (
                v_tid,
                false,
                nullif(p_payload->>'carrier_id', '')::uuid,
                p_payload->>'rule_name',
                coalesce(p_payload->'rule_config', '{}'::jsonb),
                coalesce((p_payload->>'is_active')::boolean, true)
            )
            returning
                id,
                tenant_id,
                is_system,
                carrier_id,
                rule_name,
                rule_config,
                is_active,
                created_at,
                updated_at
            into v_row;

            perform platform.log_audit(
                'shipping_rule.created',
                'shipping_rule',
                v_row.id
            );

            return to_jsonb(v_row);

        when 'update_shipping_rule' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            update public.shipping_rules s
            set
                rule_name = case
                    when p_payload ? 'rule_name' then p_payload->>'rule_name'
                    else s.rule_name
                end,
                carrier_id = case
                    when p_payload ? 'carrier_id'
                        then nullif(p_payload->>'carrier_id', '')::uuid
                    else s.carrier_id
                end,
                rule_config = case
                    when p_payload ? 'rule_config' then p_payload->'rule_config'
                    else s.rule_config
                end,
                is_active = case
                    when p_payload ? 'is_active'
                        then (p_payload->>'is_active')::boolean
                    else s.is_active
                end
            where s.id = (p_payload->>'id')::uuid
              and s.is_system = false
              and s.tenant_id = v_tid
            returning
                s.id,
                s.tenant_id,
                s.is_system,
                s.carrier_id,
                s.rule_name,
                s.rule_config,
                s.is_active,
                s.created_at,
                s.updated_at
            into v_row;

            if not found then
                raise exception 'Shipping rule not found';
            end if;

            perform platform.log_audit(
                'shipping_rule.updated',
                'shipping_rule',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);

        when 'delete_shipping_rule' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            delete from public.shipping_rules s
            where s.id = (p_payload->>'id')::uuid
              and s.is_system = false
              and s.tenant_id = v_tid;

            if not found then
                raise exception 'Shipping rule not found';
            end if;

            perform platform.log_audit(
                'shipping_rule.deleted',
                'shipping_rule',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );

        when 'list_fulfilment_orders' then
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            select coalesce(
                jsonb_agg(to_jsonb(fo) order by fo.created_at desc),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    f.id,
                    f.tenant_id,
                    f.property_id,
                    f.package_definition_id,
                    f.device_bundle_id,
                    f.carrier_id,
                    f.warehouse_id,
                    f.label_template_id,
                    f.customer_proposal_id,
                    f.status,
                    f.created_at,
                    f.updated_at
                from public.fulfilment_orders f
                where f.tenant_id = v_tid
                  and (
                      p_payload->>'status' is null
                      or f.status = (p_payload->>'status')::public.fulfilment_status
                  )
                  and (
                      p_payload->>'property_id' is null
                      or f.property_id = (p_payload->>'property_id')::uuid
                  )
            ) fo;

            return v_result;

        when 'get_fulfilment_order' then
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            select
                f.id,
                f.tenant_id,
                f.property_id,
                f.package_definition_id,
                f.device_bundle_id,
                f.carrier_id,
                f.warehouse_id,
                f.label_template_id,
                f.customer_proposal_id,
                f.status,
                f.created_at,
                f.updated_at
            into v_row
            from public.fulfilment_orders f
            where f.id = (p_payload->>'id')::uuid
              and f.tenant_id = v_tid;

            if not found then
                raise exception 'Fulfilment order not found';
            end if;

            return to_jsonb(v_row);

        when 'create_fulfilment_order' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            insert into public.fulfilment_orders (
                tenant_id,
                property_id,
                package_definition_id,
                device_bundle_id,
                carrier_id,
                warehouse_id,
                label_template_id,
                customer_proposal_id,
                status
            )
            values (
                v_tid,
                (p_payload->>'property_id')::uuid,
                nullif(p_payload->>'package_definition_id', '')::uuid,
                nullif(p_payload->>'device_bundle_id', '')::uuid,
                nullif(p_payload->>'carrier_id', '')::uuid,
                nullif(p_payload->>'warehouse_id', '')::uuid,
                nullif(p_payload->>'label_template_id', '')::uuid,
                nullif(p_payload->>'customer_proposal_id', '')::uuid,
                coalesce(
                    (p_payload->>'status')::public.fulfilment_status,
                    'draft'::public.fulfilment_status
                )
            )
            returning
                id,
                tenant_id,
                property_id,
                package_definition_id,
                device_bundle_id,
                carrier_id,
                warehouse_id,
                label_template_id,
                customer_proposal_id,
                status,
                created_at,
                updated_at
            into v_row;

            perform platform.log_audit(
                'fulfilment_order.created',
                'fulfilment_order',
                v_row.id
            );

            return to_jsonb(v_row);

        when 'update_fulfilment_order' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            update public.fulfilment_orders f
            set
                property_id = case
                    when p_payload ? 'property_id'
                        then (p_payload->>'property_id')::uuid
                    else f.property_id
                end,
                package_definition_id = case
                    when p_payload ? 'package_definition_id'
                        then nullif(p_payload->>'package_definition_id', '')::uuid
                    else f.package_definition_id
                end,
                device_bundle_id = case
                    when p_payload ? 'device_bundle_id'
                        then nullif(p_payload->>'device_bundle_id', '')::uuid
                    else f.device_bundle_id
                end,
                carrier_id = case
                    when p_payload ? 'carrier_id'
                        then nullif(p_payload->>'carrier_id', '')::uuid
                    else f.carrier_id
                end,
                warehouse_id = case
                    when p_payload ? 'warehouse_id'
                        then nullif(p_payload->>'warehouse_id', '')::uuid
                    else f.warehouse_id
                end,
                label_template_id = case
                    when p_payload ? 'label_template_id'
                        then nullif(p_payload->>'label_template_id', '')::uuid
                    else f.label_template_id
                end,
                customer_proposal_id = case
                    when p_payload ? 'customer_proposal_id'
                        then nullif(p_payload->>'customer_proposal_id', '')::uuid
                    else f.customer_proposal_id
                end,
                status = case
                    when p_payload ? 'status'
                        then (p_payload->>'status')::public.fulfilment_status
                    else f.status
                end
            where f.id = (p_payload->>'id')::uuid
              and f.tenant_id = v_tid
            returning
                f.id,
                f.tenant_id,
                f.property_id,
                f.package_definition_id,
                f.device_bundle_id,
                f.carrier_id,
                f.warehouse_id,
                f.label_template_id,
                f.customer_proposal_id,
                f.status,
                f.created_at,
                f.updated_at
            into v_row;

            if not found then
                raise exception 'Fulfilment order not found';
            end if;

            perform platform.log_audit(
                'fulfilment_order.updated',
                'fulfilment_order',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);

        when 'delete_fulfilment_order' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            delete from public.fulfilment_orders f
            where f.id = (p_payload->>'id')::uuid
              and f.tenant_id = v_tid;

            if not found then
                raise exception 'Fulfilment order not found';
            end if;

            perform platform.log_audit(
                'fulfilment_order.deleted',
                'fulfilment_order',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );

        when 'dispatch_fulfilment_order' then
            perform public.edge_require_manager();
            v_tid := platform.current_tenant_id();
            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            v_result := public.logistics_dispatch_fulfilment_order(
                (p_payload->>'fulfilment_order_id')::uuid,
                coalesce(p_payload->'payload', '{}'::jsonb)
            );

            perform platform.log_audit(
                'fulfilment_order.dispatch_queued',
                'fulfilment_order',
                (v_result->>'fulfilment_order_id')::uuid,
                jsonb_build_object(
                    'dispatch_queue_id', v_result->>'dispatch_queue_id'
                )
            );

            return v_result;

        else
            raise exception 'unknown logistics operation: %', p_op;
    end case;
end;
$$;

-- =====================================================
-- 28. UPDATED_AT TRIGGERS
-- =====================================================

create trigger trg_logistics_templates_updated_at
before update on logistics_templates
for each row execute function platform.set_updated_at();


create trigger trg_warehouses_updated_at
before update on warehouses
for each row execute function platform.set_updated_at();


create trigger trg_shipping_label_templates_updated_at
before update on shipping_label_templates
for each row execute function platform.set_updated_at();


create trigger trg_shipping_rules_updated_at
before update on shipping_rules
for each row execute function platform.set_updated_at();


create trigger trg_fulfilment_orders_updated_at
before update on fulfilment_orders
for each row execute function platform.set_updated_at();


-- =====================================================
-- 29. FULFILMENT ORDER CONSISTENCY TRIGGER
-- =====================================================

create trigger trg_fulfilment_orders_consistency
before insert or update on public.fulfilment_orders
for each row execute function public.enforce_fulfilment_order_consistency();


-- =====================================================
-- END 011 LOGISTICS ENGINE
-- CLEAN DOMAIN ONLY
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('011_logistics_engine', 'REV1', false)
on conflict (migration_name) do nothing;