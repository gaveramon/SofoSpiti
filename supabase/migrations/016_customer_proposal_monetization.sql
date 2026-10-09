-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 016_CUSTOMER_PROPOSAL_MONETIZATION.SQL
-- =====================================================
--
-- CLEAN COMMERCIAL + CONVERSION LOGIC LAYER
-- NO EXECUTION / NO PAYMENT / NO COMMUNICATION SIDE EFFECTS
-- Campaign SSOT: upsell_campaigns (in-product package upsells) only.
-- Plan upsells → 012.upsell_rules. Marketing → 003.crm_campaigns.
-- =====================================================


-- =====================================================
-- 1. CUSTOMER PROPOSALS
-- COMMERCIAL PROPOSAL DATA MODEL
-- =====================================================

create table if not exists public.customer_proposals (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references tenants(id) on delete cascade,

    property_id uuid,

    status proposal_status not null default 'draft',

    total_estimated_value numeric,

    presented_at timestamptz,

    accepted_at timestamptz,

    expires_at timestamptz,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    constraint fk_customer_proposals_property_tenant
        foreign key (property_id, tenant_id)
        references public.properties(id, tenant_id)
        on delete set null (property_id)
);


-- =====================================================
-- 2. MONETIZATION PACKAGES
-- COMMERCIAL PACKAGING OVER 010 DEVICE BUNDLES
-- Hardware BOM SSOT: device_bundles (010).
-- Subscription tiers: product_plans (012).
-- =====================================================

create table if not exists public.monetization_packages (
    id uuid primary key default gen_random_uuid(),

    name text not null,

    description text,

    package_type package_type not null,

    device_bundle_id uuid references device_bundles(id) on delete restrict,

    base_price numeric,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    constraint chk_monetization_package_hardware_bundle check (
        package_type = 'service' or device_bundle_id is not null
    )
);


-- =====================================================
-- 3. PROPOSAL ITEMS
-- OFFERED PRODUCTS, SUBSCRIPTIONS AND SERVICES
-- =====================================================

create table if not exists public.proposal_items (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references tenants(id) on delete cascade,

    proposal_id uuid not null references customer_proposals(id) on delete cascade,

    item_type proposal_item_type not null,

    plan_id uuid references product_plans(id) on delete restrict,

    monetization_package_id uuid references monetization_packages(id) on delete restrict,

    reference_id uuid,

    quantity int not null default 1,

    price_estimate numeric,

    created_at timestamptz not null default now(),

    constraint chk_proposal_items_quantity check (quantity > 0),

    constraint chk_proposal_items_subscription check (
        item_type <> 'subscription' or plan_id is not null
    ),

    constraint chk_proposal_items_device_package check (
        item_type <> 'device_package' or monetization_package_id is not null
    ),

    constraint chk_proposal_items_service check (
        item_type <> 'service' or reference_id is not null
    )
);


-- =====================================================
-- 4. UPSELL CAMPAIGNS
-- COMMERCIAL CONVERSION LOGIC ONLY
-- Subscription/plan upgrades live in 010 upsell_rules.
-- =====================================================

create table if not exists public.upsell_campaigns (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid references tenants(id) on delete cascade,

    trigger_event upsell_package_trigger,

    target_package_id uuid references monetization_packages(id),

    campaign_rules jsonb,

    is_active boolean not null default true,

    created_at timestamptz not null default now()
);


-- =====================================================
-- 5. SERVICE ACTIVATION STATE
-- WORKER-MAINTAINED ACTIVATION PROJECTION
-- SSOT: subscriptions (002) + feature_entitlements (010).
-- Not app-writable truth.
-- =====================================================

create table if not exists public.service_activation_state (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references tenants(id) on delete cascade,

    property_id uuid,

    service_type service_type not null,

    status service_activation_status not null default 'inactive',

    source_proposal_id uuid references customer_proposals(id) on delete set null,

    source_subscription_id uuid references subscriptions(id) on delete set null,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    constraint chk_service_activation_source check (
        source_proposal_id is not null or source_subscription_id is not null
    ),

    constraint fk_service_activation_property_tenant
        foreign key (property_id, tenant_id)
        references public.properties(id, tenant_id)
        on delete set null (property_id)
);


-- =====================================================
-- 6. CONVERSION EVENTS
-- FUNNEL EVENT DATA ONLY
-- =====================================================

create table if not exists public.conversion_events (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references tenants(id) on delete cascade,

    property_id uuid,

    proposal_id uuid references customer_proposals(id) on delete set null,

    event_type conversion_event_type not null,

    source text not null default 'portal',

    metadata jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),

    constraint fk_conversion_events_property_tenant
        foreign key (property_id, tenant_id)
        references public.properties(id, tenant_id)
        on delete set null (property_id)
);


-- =====================================================
-- 7. CONVERSION SCORES
-- ANALYTICAL / SCORING DATA ONLY
-- =====================================================

create table if not exists public.conversion_scores (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references tenants(id) on delete cascade,

    property_id uuid,

    score numeric(5,2),

    factors jsonb,

    calculated_at timestamptz not null default now(),

    constraint fk_conversion_scores_property_tenant
        foreign key (property_id, tenant_id)
        references public.properties(id, tenant_id)
        on delete set null (property_id)
);


-- =====================================================
-- 8. INDEXES, COMMENTS & DOMAIN EXTENSIONS
-- PERFORMANCE AND CROSS-MODULE REFERENCES
-- =====================================================

create index if not exists idx_customer_proposals_tenant_created
on public.customer_proposals (tenant_id, created_at desc);


create index if not exists idx_customer_proposals_tenant_status
on public.customer_proposals (tenant_id, status);


create index if not exists idx_customer_proposals_property
on public.customer_proposals (property_id)
where property_id is not null;


comment on table public.customer_proposals is
    'Commercial proposal intent. Payment checkout uses platform.payment_intents (target_type=proposal, target_id=id).';


comment on column public.customer_proposals.accepted_at is
    'Set when status becomes accepted. Worker in 000 may create payment_intent / fulfilment intent.';


create index if not exists idx_monetization_packages_bundle
on public.monetization_packages (device_bundle_id)
where device_bundle_id is not null;


comment on table public.monetization_packages is
    'Commercial packaging layer for proposals. Hardware contents SSOT: 010 device_bundles via device_bundle_id.';


create index if not exists idx_proposal_items_proposal
on public.proposal_items (proposal_id);


create index if not exists idx_proposal_items_tenant_created
on public.proposal_items (tenant_id, created_at desc);


comment on column public.proposal_items.plan_id is
    'Required when item_type=subscription. References 012 product_plans.';


comment on column public.proposal_items.monetization_package_id is
    'Required when item_type=device_package. References 016 monetization_packages (linked to 010 device_bundles).';


comment on column public.proposal_items.reference_id is
    'Required when item_type=service. Polymorphic service entity id only.';


create index if not exists idx_upsell_campaigns_tenant_created
on public.upsell_campaigns (tenant_id, created_at desc);


alter table public.customer_proposals
    add column if not exists source_campaign_id uuid references upsell_campaigns(id) on delete set null;


create index if not exists idx_customer_proposals_source_campaign
on public.customer_proposals (source_campaign_id)
where source_campaign_id is not null;


create unique index if not exists uq_service_activation_state_property
on public.service_activation_state (tenant_id, property_id, service_type)
where property_id is not null;


create unique index if not exists uq_service_activation_state_tenant
on public.service_activation_state (tenant_id, service_type)
where property_id is null;


create index if not exists idx_service_activation_state_tenant_created
on public.service_activation_state (tenant_id, created_at desc);


create index if not exists idx_service_activation_state_source_subscription
on public.service_activation_state (source_subscription_id)
where source_subscription_id is not null;


create index if not exists idx_conversion_events_tenant_created
on public.conversion_events (tenant_id, created_at desc);


create index if not exists idx_conversion_events_property
on public.conversion_events (property_id, created_at desc)
where property_id is not null;


create index if not exists idx_conversion_events_proposal
on public.conversion_events (proposal_id, created_at desc)
where proposal_id is not null;


create index if not exists idx_conversion_events_type
on public.conversion_events (tenant_id, event_type, created_at desc);


comment on table public.conversion_events is
    'Append-only commercial funnel events. Checkout/charge execution uses platform.payment_intents in 000.';


create index if not exists idx_conversion_scores_property
on public.conversion_scores (property_id, calculated_at desc)
where property_id is not null;


create index if not exists idx_conversion_scores_tenant_created
on public.conversion_scores (tenant_id, calculated_at desc);


alter table public.fulfilment_orders
    add column if not exists customer_proposal_id uuid references public.customer_proposals(id) on delete set null;


create index if not exists idx_fulfilment_orders_proposal
on public.fulfilment_orders (customer_proposal_id)
where customer_proposal_id is not null;


alter table public.optimization_recommendations
    add column if not exists customer_proposal_id uuid references public.customer_proposals(id) on delete set null;


create index if not exists idx_optimization_recommendations_proposal
on public.optimization_recommendations (customer_proposal_id)
where customer_proposal_id is not null;



-- =====================================================
-- 9. DOMAIN FUNCTIONS
-- TENANT CONSISTENCY & MONETIZATION DOMAIN API
-- =====================================================

create or replace function public.enforce_proposal_items_tenant_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_proposal_tenant uuid;
begin
    select cp.tenant_id
    into v_proposal_tenant
    from public.customer_proposals cp
    where cp.id = new.proposal_id;

    if not found then
        raise exception 'customer proposal not found';
    end if;

    if new.tenant_id <> v_proposal_tenant then
        raise exception 'proposal_items tenant_id must match customer_proposals tenant_id';
    end if;

    return new;
end;
$$;


create or replace function public.monetization_domain(
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
    v_proposal_id uuid;
    v_limit int;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op
    when 'list_proposals' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb) into v_result
        from (
            select cp.id, cp.tenant_id, cp.property_id, cp.status, cp.total_estimated_value,
                   cp.presented_at, cp.accepted_at, cp.expires_at, cp.source_campaign_id, cp.created_at, cp.updated_at
            from public.customer_proposals cp
            where cp.tenant_id = v_tid
              and (p_payload->>'status' is null or cp.status::text = p_payload->>'status')
              and (p_payload->>'property_id' is null or cp.property_id = (p_payload->>'property_id')::uuid)
        ) t;

    when 'get_proposal' then
        v_tid := platform.current_tenant_id();
        v_proposal_id := (p_payload->>'id')::uuid;
        select jsonb_build_object(
            'proposal', (
                select to_jsonb(t) from (
                    select cp.id, cp.tenant_id, cp.property_id, cp.status, cp.total_estimated_value,
                           cp.presented_at, cp.accepted_at, cp.expires_at, cp.source_campaign_id, cp.created_at, cp.updated_at
                    from public.customer_proposals cp
                    where cp.id = v_proposal_id and cp.tenant_id = v_tid
                ) t
            ),
            'items', coalesce((
                select jsonb_agg(to_jsonb(pi) order by pi.created_at)
                from (
                    select pi.id, pi.tenant_id, pi.proposal_id, pi.item_type, pi.plan_id,
                           pi.monetization_package_id, pi.reference_id, pi.quantity, pi.price_estimate, pi.created_at
                    from public.proposal_items pi where pi.proposal_id = v_proposal_id
                ) pi
            ), '[]'::jsonb)
        ) into v_result;
        if v_result->'proposal' = 'null'::jsonb then raise exception 'Customer proposal not found'; end if;

    when 'create_proposal' then
        v_tid := platform.current_tenant_id();
        insert into public.customer_proposals (
            tenant_id, property_id, total_estimated_value, expires_at, source_campaign_id, status
        )
        values (
            v_tid,
            case when p_payload ? 'property_id' then (p_payload->>'property_id')::uuid else null end,
            case when p_payload ? 'total_estimated_value' then (p_payload->>'total_estimated_value')::numeric else null end,
            case when p_payload ? 'expires_at' then (p_payload->>'expires_at')::timestamptz else null end,
            case when p_payload ? 'source_campaign_id' then (p_payload->>'source_campaign_id')::uuid else null end,
            'draft'::public.proposal_status
        )
        returning id, tenant_id, property_id, status, total_estimated_value, presented_at, accepted_at,
                  expires_at, source_campaign_id, created_at, updated_at into v_row;
        perform platform.log_audit('customer_proposal.created', 'customer_proposal', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_proposal' then
        v_tid := platform.current_tenant_id();
        update public.customer_proposals cp set
            property_id = case when p_payload ? 'property_id'
                then (p_payload->>'property_id')::uuid else cp.property_id end,
            total_estimated_value = case when p_payload ? 'total_estimated_value'
                then (p_payload->>'total_estimated_value')::numeric else cp.total_estimated_value end,
            expires_at = case when p_payload ? 'expires_at'
                then (p_payload->>'expires_at')::timestamptz else cp.expires_at end,
            source_campaign_id = case when p_payload ? 'source_campaign_id'
                then (p_payload->>'source_campaign_id')::uuid else cp.source_campaign_id end,
            status = case when p_payload ? 'status'
                then (p_payload->>'status')::public.proposal_status else cp.status end
        where cp.id = (p_payload->>'id')::uuid and cp.tenant_id = v_tid
        returning cp.id, cp.tenant_id, cp.property_id, cp.status, cp.total_estimated_value, cp.presented_at,
                  cp.accepted_at, cp.expires_at, cp.source_campaign_id, cp.created_at, cp.updated_at into v_row;
        if not found then raise exception 'Customer proposal not found'; end if;
        perform platform.log_audit('customer_proposal.updated', 'customer_proposal', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_proposal' then
        v_tid := platform.current_tenant_id();
        delete from public.customer_proposals cp
        where cp.id = (p_payload->>'id')::uuid and cp.tenant_id = v_tid;
        if not found then raise exception 'Customer proposal not found'; end if;
        perform platform.log_audit('customer_proposal.deleted', 'customer_proposal', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_proposal_items' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb) into v_result
        from (
            select pi.id, pi.tenant_id, pi.proposal_id, pi.item_type, pi.plan_id,
                   pi.monetization_package_id, pi.reference_id, pi.quantity, pi.price_estimate, pi.created_at
            from public.proposal_items pi
            where pi.proposal_id = (p_payload->>'proposal_id')::uuid and pi.tenant_id = v_tid
        ) t;

    when 'create_proposal_item' then
        v_tid := platform.current_tenant_id();
        insert into public.proposal_items (
            tenant_id, proposal_id, item_type, plan_id, monetization_package_id, reference_id, quantity, price_estimate
        )
        values (
            v_tid,
            (p_payload->>'proposal_id')::uuid,
            (p_payload->>'item_type')::public.proposal_item_type,
            case when p_payload ? 'plan_id' then (p_payload->>'plan_id')::uuid else null end,
            case when p_payload ? 'monetization_package_id' then (p_payload->>'monetization_package_id')::uuid else null end,
            case when p_payload ? 'reference_id' then (p_payload->>'reference_id')::uuid else null end,
            coalesce((p_payload->>'quantity')::int, 1),
            case when p_payload ? 'price_estimate' then (p_payload->>'price_estimate')::numeric else null end
        )
        returning id, tenant_id, proposal_id, item_type, plan_id, monetization_package_id,
                  reference_id, quantity, price_estimate, created_at into v_row;
        perform platform.log_audit('proposal_item.created', 'proposal_item', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_proposal_item' then
        v_tid := platform.current_tenant_id();
        update public.proposal_items pi set
            item_type = case when p_payload ? 'item_type'
                then (p_payload->>'item_type')::public.proposal_item_type else pi.item_type end,
            plan_id = case when p_payload ? 'plan_id' then (p_payload->>'plan_id')::uuid else pi.plan_id end,
            monetization_package_id = case when p_payload ? 'monetization_package_id'
                then (p_payload->>'monetization_package_id')::uuid else pi.monetization_package_id end,
            reference_id = case when p_payload ? 'reference_id'
                then (p_payload->>'reference_id')::uuid else pi.reference_id end,
            quantity = case when p_payload ? 'quantity' then (p_payload->>'quantity')::int else pi.quantity end,
            price_estimate = case when p_payload ? 'price_estimate'
                then (p_payload->>'price_estimate')::numeric else pi.price_estimate end
        where pi.id = (p_payload->>'id')::uuid and pi.tenant_id = v_tid
        returning pi.id, pi.tenant_id, pi.proposal_id, pi.item_type, pi.plan_id, pi.monetization_package_id,
                  pi.reference_id, pi.quantity, pi.price_estimate, pi.created_at into v_row;
        if not found then raise exception 'Proposal item not found'; end if;
        perform platform.log_audit('proposal_item.updated', 'proposal_item', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_proposal_item' then
        v_tid := platform.current_tenant_id();
        delete from public.proposal_items pi
        where pi.id = (p_payload->>'id')::uuid and pi.tenant_id = v_tid;
        if not found then raise exception 'Proposal item not found'; end if;
        perform platform.log_audit('proposal_item.deleted', 'proposal_item', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_packages' then
        select coalesce(jsonb_agg(to_jsonb(t) order by t.name), '[]'::jsonb) into v_result
        from (
            select mp.id, mp.name, mp.description, mp.package_type, mp.device_bundle_id,
                   mp.base_price, mp.is_active, mp.created_at, mp.updated_at
            from public.monetization_packages mp
            where coalesce((p_payload->>'active_only')::boolean, true) = false or mp.is_active = true
        ) t;

    when 'get_package' then
        select to_jsonb(t) into v_result from (
            select mp.id, mp.name, mp.description, mp.package_type, mp.device_bundle_id,
                   mp.base_price, mp.is_active, mp.created_at, mp.updated_at
            from public.monetization_packages mp where mp.id = (p_payload->>'id')::uuid
        ) t;
        if v_result is null then raise exception 'Monetization package not found'; end if;

    when 'create_package' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        insert into public.monetization_packages (name, description, package_type, device_bundle_id, base_price, is_active)
        values (
            p_payload->>'name',
            p_payload->>'description',
            (p_payload->>'package_type')::public.package_type,
            case when p_payload ? 'device_bundle_id' then (p_payload->>'device_bundle_id')::uuid else null end,
            case when p_payload ? 'base_price' then (p_payload->>'base_price')::numeric else null end,
            coalesce((p_payload->>'is_active')::boolean, true)
        )
        returning id, name, description, package_type, device_bundle_id, base_price, is_active, created_at, updated_at into v_row;
        perform platform.log_audit('monetization_package.created', 'monetization_package', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_package' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        update public.monetization_packages mp set
            name = case when p_payload ? 'name' then p_payload->>'name' else mp.name end,
            description = case when p_payload ? 'description' then p_payload->>'description' else mp.description end,
            package_type = case when p_payload ? 'package_type'
                then (p_payload->>'package_type')::public.package_type else mp.package_type end,
            device_bundle_id = case when p_payload ? 'device_bundle_id'
                then (p_payload->>'device_bundle_id')::uuid else mp.device_bundle_id end,
            base_price = case when p_payload ? 'base_price'
                then (p_payload->>'base_price')::numeric else mp.base_price end,
            is_active = case when p_payload ? 'is_active' then (p_payload->>'is_active')::boolean else mp.is_active end
        where mp.id = (p_payload->>'id')::uuid
        returning mp.id, mp.name, mp.description, mp.package_type, mp.device_bundle_id,
                  mp.base_price, mp.is_active, mp.created_at, mp.updated_at into v_row;
        if not found then raise exception 'Monetization package not found'; end if;
        perform platform.log_audit('monetization_package.updated', 'monetization_package', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_package' then
        if not platform.is_platform_admin() then raise exception 'platform admin role required'; end if;
        delete from public.monetization_packages mp where mp.id = (p_payload->>'id')::uuid;
        if not found then raise exception 'Monetization package not found'; end if;
        perform platform.log_audit('monetization_package.deleted', 'monetization_package', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_upsell_campaigns' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb) into v_result
        from (
            select uc.id, uc.tenant_id, uc.trigger_event, uc.target_package_id, uc.campaign_rules, uc.is_active, uc.created_at
            from public.upsell_campaigns uc
            where (uc.tenant_id is null or uc.tenant_id = v_tid or platform.is_platform_admin())
              and (coalesce((p_payload->>'active_only')::boolean, true) = false or uc.is_active = true)
              and (p_payload->>'trigger_event' is null or uc.trigger_event::text = p_payload->>'trigger_event')
        ) t;

    when 'get_upsell_campaign' then
        v_tid := platform.current_tenant_id();
        select to_jsonb(t) into v_result from (
            select uc.id, uc.tenant_id, uc.trigger_event, uc.target_package_id, uc.campaign_rules, uc.is_active, uc.created_at
            from public.upsell_campaigns uc
            where uc.id = (p_payload->>'id')::uuid
              and (uc.tenant_id is null or uc.tenant_id = v_tid or platform.is_platform_admin())
        ) t;
        if v_result is null then raise exception 'Upsell campaign not found'; end if;

    when 'create_upsell_campaign' then
        if platform.is_platform_admin() then
            v_tid := case when p_payload ? 'tenant_id' then (p_payload->>'tenant_id')::uuid else null end;
        else
            v_tid := platform.current_tenant_id();
            if p_payload ? 'tenant_id' and (p_payload->>'tenant_id')::uuid is distinct from v_tid then
                raise exception 'Tenant managers can only create campaigns for their tenant';
            end if;
        end if;
        insert into public.upsell_campaigns (tenant_id, trigger_event, target_package_id, campaign_rules, is_active)
        values (
            v_tid,
            case when p_payload ? 'trigger_event' and p_payload->>'trigger_event' is not null
                then (p_payload->>'trigger_event')::public.upsell_package_trigger else null end,
            case when p_payload ? 'target_package_id' then (p_payload->>'target_package_id')::uuid else null end,
            case when p_payload ? 'campaign_rules' then p_payload->'campaign_rules' else null end,
            coalesce((p_payload->>'is_active')::boolean, true)
        )
        returning id, tenant_id, trigger_event, target_package_id, campaign_rules, is_active, created_at into v_row;
        perform platform.log_audit('upsell_campaign.created', 'upsell_campaign', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_upsell_campaign' then
        if not platform.is_platform_admin() then perform public.edge_require_manager(); end if;
        v_tid := platform.current_tenant_id();
        update public.upsell_campaigns uc set
            trigger_event = case when p_payload ? 'trigger_event'
                then case when p_payload->>'trigger_event' is null then null
                     else (p_payload->>'trigger_event')::public.upsell_package_trigger end
                else uc.trigger_event end,
            target_package_id = case when p_payload ? 'target_package_id'
                then (p_payload->>'target_package_id')::uuid else uc.target_package_id end,
            campaign_rules = case when p_payload ? 'campaign_rules' then p_payload->'campaign_rules' else uc.campaign_rules end,
            is_active = case when p_payload ? 'is_active' then (p_payload->>'is_active')::boolean else uc.is_active end
        where uc.id = (p_payload->>'id')::uuid
          and (platform.is_platform_admin() or uc.tenant_id = v_tid)
        returning uc.id, uc.tenant_id, uc.trigger_event, uc.target_package_id, uc.campaign_rules, uc.is_active, uc.created_at into v_row;
        if not found then raise exception 'Upsell campaign not found'; end if;
        perform platform.log_audit('upsell_campaign.updated', 'upsell_campaign', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_upsell_campaign' then
        if not platform.is_platform_admin() then perform public.edge_require_manager(); end if;
        v_tid := platform.current_tenant_id();
        delete from public.upsell_campaigns uc
        where uc.id = (p_payload->>'id')::uuid
          and (platform.is_platform_admin() or uc.tenant_id = v_tid);
        if not found then raise exception 'Upsell campaign not found'; end if;
        perform platform.log_audit('upsell_campaign.deleted', 'upsell_campaign', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_activation_state' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.updated_at desc), '[]'::jsonb) into v_result
        from (
            select sas.id, sas.tenant_id, sas.property_id, sas.service_type, sas.status,
                   sas.source_proposal_id, sas.source_subscription_id, sas.created_at, sas.updated_at
            from public.service_activation_state sas
            where sas.tenant_id = v_tid
              and (p_payload->>'property_id' is null or sas.property_id = (p_payload->>'property_id')::uuid)
              and (p_payload->>'service_type' is null or sas.service_type::text = p_payload->>'service_type')
        ) t;

    when 'list_conversion_events' then
        v_tid := platform.current_tenant_id();
        v_limit := least(coalesce((p_payload->>'limit')::int, 100), 500);
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb) into v_result
        from (
            select ce.id, ce.tenant_id, ce.property_id, ce.proposal_id, ce.event_type, ce.source, ce.metadata, ce.created_at
            from public.conversion_events ce
            where ce.tenant_id = v_tid
              and (p_payload->>'proposal_id' is null or ce.proposal_id = (p_payload->>'proposal_id')::uuid)
              and (p_payload->>'event_type' is null or ce.event_type::text = p_payload->>'event_type')
            order by ce.created_at desc
            limit v_limit
        ) t;

    when 'list_conversion_scores' then
        v_tid := platform.current_tenant_id();
        v_limit := least(coalesce((p_payload->>'limit')::int, 50), 200);
        select coalesce(jsonb_agg(to_jsonb(t) order by t.calculated_at desc), '[]'::jsonb) into v_result
        from (
            select cs.id, cs.tenant_id, cs.property_id, cs.score, cs.factors, cs.calculated_at
            from public.conversion_scores cs
            where cs.tenant_id = v_tid
              and (p_payload->>'property_id' is null or cs.property_id = (p_payload->>'property_id')::uuid)
            order by cs.calculated_at desc
            limit v_limit
        ) t;

    else
        raise exception 'unknown monetization_api operation: %', p_op;
    end case;

    return v_result;
end;
$$;


-- =====================================================
-- 10. PROPOSAL STATUS TIMESTAMP FUNCTION
-- =====================================================

create or replace function public.trg_customer_proposals_status_timestamps()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.status is distinct from old.status then
        if new.status = 'presented'::public.proposal_status then
            new.presented_at := coalesce(new.presented_at, now());
        elsif new.status = 'accepted'::public.proposal_status then
            new.accepted_at := coalesce(new.accepted_at, now());
        end if;
    end if;
    return new;
end;
$$;


-- =====================================================
-- 11. TRIGGERS & DATA CONSISTENCY
-- =====================================================

create trigger trg_customer_proposals_updated_at
before update on customer_proposals
for each row execute function platform.set_updated_at();

create trigger trg_monetization_packages_updated_at
before update on monetization_packages
for each row execute function platform.set_updated_at();

create trigger trg_proposal_items_tenant_consistency
before insert or update on public.proposal_items
for each row execute function public.enforce_proposal_items_tenant_consistency();

create trigger trg_service_activation_state_updated_at
before update on service_activation_state
for each row execute function platform.set_updated_at();

create trigger trg_customer_proposals_property_tenant
before insert or update on public.customer_proposals
for each row execute function public.enforce_property_tenant_consistency();

create trigger trg_service_activation_state_property_tenant
before insert or update on public.service_activation_state
for each row execute function public.enforce_property_tenant_consistency();

create trigger trg_conversion_events_property_tenant
before insert or update on public.conversion_events
for each row execute function public.enforce_property_tenant_consistency();

create trigger trg_customer_proposals_status_timestamps
before update of status on public.customer_proposals
for each row execute function public.trg_customer_proposals_status_timestamps();


-- =====================================================
-- 12. MODULE REGISTRATION
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('016_customer_proposal_monetization', 'REV1', false)
on conflict (migration_name) do nothing;


-- =====================================================
-- END 016 MONETIZATION ENGINE (CLEAN DOMAIN ONLY)
-- =====================================================