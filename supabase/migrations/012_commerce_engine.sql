-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 012_COMMERCE_ENGINE.SQL
-- =====================================================
--
-- NO PAYMENT EXECUTION / NO WEBHOOKS / NO TRANSACTIONS
-- Campaign SSOT: upsell_rules (plan upgrades) only.
-- Package upsells → 015.upsell_campaigns. Marketing → 003.crm_campaigns.
-- =====================================================


-- =====================================================
-- 1. COMMERCIAL PRODUCT CATALOG
-- =====================================================
-- Product plans define the commercial subscription offerings.
-- =====================================================

create table if not exists public.product_plans (
    id uuid primary key default gen_random_uuid(),

    name text not null,

    description text,

    tier subscription_tier not null,

    is_active boolean default true,

    created_at timestamptz default now(),

    updated_at timestamptz default now()
);


-- =====================================================
-- 2. PLAN PRICING
-- =====================================================
-- Static commercial pricing attached to product plans.
-- =====================================================

create table if not exists public.plan_pricing (
    id uuid primary key default gen_random_uuid(),

    plan_id uuid not null references product_plans(id) on delete cascade,

    currency text not null default 'EUR',

    monthly_price numeric(10,2),

    yearly_price numeric(10,2),

    effective_from timestamptz not null default now(),

    created_at timestamptz default now(),

    constraint chk_plan_pricing_currency_iso
        check (char_length(currency) = 3),

    constraint chk_plan_pricing_has_amount
        check (monthly_price is not null or yearly_price is not null),

    unique (plan_id, currency)
);


-- =====================================================
-- 3. PLAN FEATURE ENTITLEMENTS
-- =====================================================
-- Defines which platform features a plan enables.
-- =====================================================

create table if not exists public.feature_entitlements (
    id uuid primary key default gen_random_uuid(),

    plan_id uuid not null references product_plans(id) on delete cascade,

    feature_key text not null,
    -- e.g. auto_door_code, energy_reports, guest_messaging

    enabled boolean default true,

    unique (plan_id, feature_key)
);


-- =====================================================
-- 4. UPSELL RULE DEFINITIONS
-- =====================================================
-- Defines subscription/plan upgrade recommendations only.
-- Package upsells live in 015.upsell_campaigns.
-- =====================================================

create table if not exists public.upsell_rules (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid references tenants(id) on delete cascade,

    trigger_event upsell_plan_trigger,

    recommended_plan_id uuid references product_plans(id),

    rule_config jsonb,

    is_active boolean default true,

    created_at timestamptz default now()
);


-- =====================================================
-- 5. SUBSCRIPTION ↔ PLAN BINDING
-- =====================================================
-- Extends the subscriptions SSOT from 002 with the
-- commercial product plan relationship.
-- =====================================================

alter table public.subscriptions
    add column if not exists plan_id uuid references product_plans(id);


alter table public.subscriptions
    drop constraint if exists chk_subscriptions_active_plan;


alter table public.subscriptions
    add constraint chk_subscriptions_active_plan check (
        status not in ('trial', 'pending', 'active', 'past_due')
        or plan_id is not null
    );


comment on column public.subscriptions.tier is
    'Denormalized from product_plans.tier when plan_id is set. Do not edit independently.';


-- =====================================================
-- 6. COMMERCE DOMAIN INDEXES
-- =====================================================

create index if not exists idx_plan_pricing_plan
on public.plan_pricing (plan_id);

create index if not exists idx_feature_entitlements_plan
on public.feature_entitlements (plan_id);

create index if not exists idx_upsell_rules_tenant
on public.upsell_rules (tenant_id);

create index if not exists idx_upsell_rules_tenant_created
on public.upsell_rules (tenant_id, created_at desc)
where tenant_id is not null;

create index if not exists idx_upsell_rules_trigger_active
on public.upsell_rules (trigger_event)
where is_active;

create index if not exists idx_subscriptions_plan
on public.subscriptions (plan_id);

create index if not exists idx_subscriptions_tenant_created
on public.subscriptions (tenant_id, created_at desc);

drop index if exists public.uq_subscriptions_active_tenant;

create unique index uq_subscriptions_active_tenant
on public.subscriptions (tenant_id)
where status in ('trial', 'pending', 'active', 'past_due');

-- =====================================================
-- 9. SUBSCRIPTION / COMMERCE VIEWS
-- =====================================================

create or replace view public.v_subscription_overview
with (security_invoker = true)
as
select
    s.id,
    s.tenant_id,
    t.name as tenant_name,
    s.tier,
    s.status,
    s.plan_id,
    pp.name as plan_name,
    s.current_period_start,
    s.current_period_end,
    s.created_at,
    s.updated_at
from public.subscriptions s
join public.tenants t on t.id = s.tenant_id
left join public.product_plans pp on pp.id = s.plan_id;


-- =====================================================
-- 10. SUBSCRIPTION PLAN CONSISTENCY FUNCTIONS
-- =====================================================

create or replace function public.enforce_subscription_plan_required()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.status in ('trial', 'pending', 'active', 'past_due')
       and new.plan_id is null then
        raise exception 'subscriptions with active lifecycle status require plan_id';
    end if;

    if tg_op = 'UPDATE'
       and new.tier is distinct from old.tier
       and new.plan_id is null then
        raise exception 'subscriptions.tier cannot change without plan_id';
    end if;

    return new;
end;
$$;


create or replace function public.prevent_subscription_tier_drift()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.plan_id is not null
       and tg_op = 'UPDATE'
       and new.tier is distinct from old.tier
       and new.plan_id is not distinct from old.plan_id then
        raise exception 'subscriptions.tier is derived from plan_id; update plan_id instead';
    end if;

    return new;
end;
$$;


create or replace function public.sync_subscription_tier_from_plan()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.plan_id is not null then
        select pp.tier
        into new.tier
        from public.product_plans pp
        where pp.id = new.plan_id;

        if not found then
            raise exception 'plan_id % not found in product_plans', new.plan_id;
        end if;
    end if;

    return new;
end;
$$;


-- =====================================================
-- 11. COMMERCE SUBSCRIPTION FUNCTIONS
-- =====================================================

create or replace function public.commerce_change_subscription_plan(p_plan_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_sub record;
begin
    v_tid := platform.current_tenant_id();

    if not exists (
        select 1 from public.product_plans pp
        where pp.id = p_plan_id and pp.is_active = true
    ) then
        raise exception 'product plan not found or inactive';
    end if;

    update public.subscriptions s
    set plan_id = p_plan_id
    where s.tenant_id = v_tid
    returning s.id, s.plan_id, s.tier, s.status
    into v_sub;

    if not found then
        raise exception 'subscription not found for tenant';
    end if;

    return jsonb_build_object(
        'subscription_id', v_sub.id,
        'plan_id', v_sub.plan_id,
        'tier', v_sub.tier,
        'status', v_sub.status
    );
end;
$$;


create or replace function public.commerce_create_subscription(
    p_plan_id uuid,
    p_tier public.subscription_tier default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_row record;
begin
    v_tid := platform.current_tenant_id();
    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    if not exists (
        select 1 from public.product_plans pp
        where pp.id = p_plan_id and pp.is_active = true
    ) then
        raise exception 'product plan not found or inactive';
    end if;

    insert into public.subscriptions (tenant_id, plan_id, tier, status)
    values (
        v_tid,
        p_plan_id,
        coalesce(
            p_tier,
            (select pp.tier from public.product_plans pp where pp.id = p_plan_id)
        ),
        'trial'::public.subscription_status
    )
    returning id, tenant_id, plan_id, tier, status, created_at into v_row;

    return to_jsonb(v_row);
end;
$$;


-- =====================================================
-- 12. COMMERCE DOMAIN API
-- =====================================================

create or replace function public.commerce_domain(
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
    v_plan record;
    v_sub record;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op
        when 'list_product_plans' then

            select coalesce(
                jsonb_agg(to_jsonb(pp) order by pp.tier),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    p.id,
                    p.name,
                    p.description,
                    p.tier,
                    p.is_active,
                    p.created_at,
                    p.updated_at
                from public.product_plans p
                where p.is_active = true
            ) pp;

            return v_result;

        when 'get_product_plan' then

            select
                p.id,
                p.name,
                p.description,
                p.tier,
                p.is_active,
                p.created_at,
                p.updated_at
            into v_plan
            from public.product_plans p
            where p.id = coalesce(
                nullif(p_payload->>'id', '')::uuid,
                nullif(p_payload->>'plan_id', '')::uuid
            );

            if not found then
                raise exception 'Product plan not found';
            end if;

            select jsonb_build_object(
                'plan', to_jsonb(v_plan),
                'pricing', coalesce((
                    select jsonb_agg(to_jsonb(pr) order by pr.currency)
                    from (
                        select
                            pp.id,
                            pp.plan_id,
                            pp.currency,
                            pp.monthly_price,
                            pp.yearly_price,
                            pp.effective_from,
                            pp.created_at
                        from public.plan_pricing pp
                        where pp.plan_id = v_plan.id
                    ) pr
                ), '[]'::jsonb),
                'entitlements', coalesce((
                    select jsonb_agg(to_jsonb(fe) order by fe.feature_key)
                    from (
                        select
                            fe.id,
                            fe.plan_id,
                            fe.feature_key,
                            fe.enabled
                        from public.feature_entitlements fe
                        where fe.plan_id = v_plan.id
                    ) fe
                ), '[]'::jsonb)
            )
            into v_result;

            return v_result;

        when 'create_product_plan' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            insert into public.product_plans (
                name,
                description,
                tier,
                is_active
            )
            values (
                p_payload->>'name',
                p_payload->>'description',
                (p_payload->>'tier')::public.subscription_tier,
                coalesce((p_payload->>'is_active')::boolean, true)
            )
            returning
                id,
                name,
                description,
                tier,
                is_active,
                created_at,
                updated_at
            into v_row;

            perform platform.log_audit(
                'product_plan.created',
                'product_plan',
                v_row.id
            );

            return to_jsonb(v_row);

        when 'update_product_plan' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            update public.product_plans pp
            set
                name = case
                    when p_payload ? 'name' then p_payload->>'name'
                    else pp.name
                end,
                description = case
                    when p_payload ? 'description' then p_payload->>'description'
                    else pp.description
                end,
                tier = case
                    when p_payload ? 'tier'
                        then (p_payload->>'tier')::public.subscription_tier
                    else pp.tier
                end,
                is_active = case
                    when p_payload ? 'is_active'
                        then (p_payload->>'is_active')::boolean
                    else pp.is_active
                end
            where pp.id = (p_payload->>'id')::uuid
            returning
                pp.id,
                pp.name,
                pp.description,
                pp.tier,
                pp.is_active,
                pp.created_at,
                pp.updated_at
            into v_row;

            if not found then
                raise exception 'Product plan not found';
            end if;

            perform platform.log_audit(
                'product_plan.updated',
                'product_plan',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);

        when 'delete_product_plan' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            delete from public.product_plans pp
            where pp.id = (p_payload->>'id')::uuid;

            if not found then
                raise exception 'Product plan not found';
            end if;

            perform platform.log_audit(
                'product_plan.deleted',
                'product_plan',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );

        when 'list_plan_pricing' then

            select coalesce(
                jsonb_agg(to_jsonb(pr) order by pr.currency),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    pp.id,
                    pp.plan_id,
                    pp.currency,
                    pp.monthly_price,
                    pp.yearly_price,
                    pp.effective_from,
                    pp.created_at
                from public.plan_pricing pp
                where pp.plan_id = (p_payload->>'plan_id')::uuid
            ) pr;

            return v_result;

        when 'create_plan_pricing' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            insert into public.plan_pricing (
                plan_id,
                currency,
                monthly_price,
                yearly_price,
                effective_from
            )
            values (
                (p_payload->>'plan_id')::uuid,
                coalesce(p_payload->>'currency', 'EUR'),
                (p_payload->>'monthly_price')::numeric,
                (p_payload->>'yearly_price')::numeric,
                coalesce(
                    (p_payload->>'effective_from')::timestamptz,
                    now()
                )
            )
            returning
                id,
                plan_id,
                currency,
                monthly_price,
                yearly_price,
                effective_from,
                created_at
            into v_row;

            perform platform.log_audit(
                'plan_pricing.created',
                'plan_pricing',
                v_row.id
            );

            return to_jsonb(v_row);

        when 'update_plan_pricing' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            update public.plan_pricing pp
            set
                currency = case
                    when p_payload ? 'currency' then p_payload->>'currency'
                    else pp.currency
                end,
                monthly_price = case
                    when p_payload ? 'monthly_price'
                        then (p_payload->>'monthly_price')::numeric
                    else pp.monthly_price
                end,
                yearly_price = case
                    when p_payload ? 'yearly_price'
                        then (p_payload->>'yearly_price')::numeric
                    else pp.yearly_price
                end,
                effective_from = case
                    when p_payload ? 'effective_from'
                        then (p_payload->>'effective_from')::timestamptz
                    else pp.effective_from
                end
            where pp.id = (p_payload->>'id')::uuid
            returning
                pp.id,
                pp.plan_id,
                pp.currency,
                pp.monthly_price,
                pp.yearly_price,
                pp.effective_from,
                pp.created_at
            into v_row;

            if not found then
                raise exception 'Plan pricing not found';
            end if;

            perform platform.log_audit(
                'plan_pricing.updated',
                'plan_pricing',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);

        when 'delete_plan_pricing' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            delete from public.plan_pricing pp
            where pp.id = (p_payload->>'id')::uuid;

            if not found then
                raise exception 'Plan pricing not found';
            end if;

            perform platform.log_audit(
                'plan_pricing.deleted',
                'plan_pricing',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );

        when 'list_feature_entitlements' then

            select coalesce(
                jsonb_agg(to_jsonb(fe) order by fe.feature_key),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    f.id,
                    f.plan_id,
                    f.feature_key,
                    f.enabled
                from public.feature_entitlements f
                where f.plan_id = (p_payload->>'plan_id')::uuid
            ) fe;

            return v_result;

        when 'create_feature_entitlement' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            insert into public.feature_entitlements (
                plan_id,
                feature_key,
                enabled
            )
            values (
                (p_payload->>'plan_id')::uuid,
                p_payload->>'feature_key',
                coalesce((p_payload->>'enabled')::boolean, true)
            )
            returning
                id,
                plan_id,
                feature_key,
                enabled
            into v_row;

            perform platform.log_audit(
                'feature_entitlement.created',
                'feature_entitlement',
                v_row.id
            );

            return to_jsonb(v_row);

        when 'update_feature_entitlement' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            update public.feature_entitlements fe
            set
                feature_key = case
                    when p_payload ? 'feature_key' then p_payload->>'feature_key'
                    else fe.feature_key
                end,
                enabled = case
                    when p_payload ? 'enabled'
                        then (p_payload->>'enabled')::boolean
                    else fe.enabled
                end
            where fe.id = (p_payload->>'id')::uuid
            returning
                fe.id,
                fe.plan_id,
                fe.feature_key,
                fe.enabled
            into v_row;

            if not found then
                raise exception 'Feature entitlement not found';
            end if;

            perform platform.log_audit(
                'feature_entitlement.updated',
                'feature_entitlement',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);

        when 'delete_feature_entitlement' then
            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;
            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            delete from public.feature_entitlements fe
            where fe.id = (p_payload->>'id')::uuid;

            if not found then
                raise exception 'Feature entitlement not found';
            end if;

            perform platform.log_audit(
                'feature_entitlement.deleted',
                'feature_entitlement',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );

        when 'list_upsell_rules' then
            v_tid := platform.current_tenant_id();

            select coalesce(
                jsonb_agg(to_jsonb(ur) order by ur.created_at),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    u.id,
                    u.tenant_id,
                    u.trigger_event,
                    u.recommended_plan_id,
                    u.rule_config,
                    u.is_active,
                    u.created_at
                from public.upsell_rules u
                where u.is_active = true
                  and (
                      u.tenant_id is null
                      or u.tenant_id = v_tid
                  )
                  and (
                      p_payload->>'trigger_event' is null
                      or u.trigger_event = (p_payload->>'trigger_event')::public.upsell_plan_trigger
                  )
            ) ur;

            return v_result;

        when 'create_upsell_rule' then
            v_tid := platform.current_tenant_id();

            insert into public.upsell_rules (
                tenant_id,
                trigger_event,
                recommended_plan_id,
                rule_config,
                is_active
            )
            values (
                v_tid,
                nullif(p_payload->>'trigger_event', '')::public.upsell_plan_trigger,
                nullif(p_payload->>'recommended_plan_id', '')::uuid,
                p_payload->'rule_config',
                coalesce((p_payload->>'is_active')::boolean, true)
            )
            returning
                id,
                tenant_id,
                trigger_event,
                recommended_plan_id,
                rule_config,
                is_active,
                created_at
            into v_row;

            perform platform.log_audit(
                'upsell_rule.created',
                'upsell_rule',
                v_row.id
            );

            return to_jsonb(v_row);

        when 'update_upsell_rule' then
            v_tid := platform.current_tenant_id();

            update public.upsell_rules u
            set
                trigger_event = case
                    when p_payload ? 'trigger_event'
                        then nullif(p_payload->>'trigger_event', '')::public.upsell_plan_trigger
                    else u.trigger_event
                end,
                recommended_plan_id = case
                    when p_payload ? 'recommended_plan_id'
                        then nullif(p_payload->>'recommended_plan_id', '')::uuid
                    else u.recommended_plan_id
                end,
                rule_config = case
                    when p_payload ? 'rule_config' then p_payload->'rule_config'
                    else u.rule_config
                end,
                is_active = case
                    when p_payload ? 'is_active'
                        then (p_payload->>'is_active')::boolean
                    else u.is_active
                end
            where u.id = (p_payload->>'id')::uuid
              and u.tenant_id = v_tid
            returning
                u.id,
                u.tenant_id,
                u.trigger_event,
                u.recommended_plan_id,
                u.rule_config,
                u.is_active,
                u.created_at
            into v_row;

            if not found then
                raise exception 'Upsell rule not found';
            end if;

            perform platform.log_audit(
                'upsell_rule.updated',
                'upsell_rule',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);

        when 'delete_upsell_rule' then
            v_tid := platform.current_tenant_id();

            delete from public.upsell_rules u
            where u.id = (p_payload->>'id')::uuid
              and u.tenant_id = v_tid;

            if not found then
                raise exception 'Upsell rule not found';
            end if;

            perform platform.log_audit(
                'upsell_rule.deleted',
                'upsell_rule',
                (p_payload->>'id')::uuid
            );

            return jsonb_build_object(
                'deleted', true,
                'id', p_payload->>'id'
            );

        when 'get_tenant_entitlements' then
            v_tid := platform.current_tenant_id();

            select s.plan_id, s.tier
            into v_sub
            from public.subscriptions s
            where s.tenant_id = v_tid;

            if not found then
                raise exception 'Subscription not found for tenant';
            end if;

            if v_sub.plan_id is null then
                return jsonb_build_object(
                    'tenant_id', v_tid,
                    'plan_id', null,
                    'tier', v_sub.tier,
                    'features', '[]'::jsonb
                );
            end if;

            select jsonb_build_object(
                'tenant_id', v_tid,
                'plan_id', v_sub.plan_id,
                'tier', v_sub.tier,
                'features', coalesce((
                    select jsonb_agg(to_jsonb(fe) order by fe.feature_key)
                    from (
                        select
                            f.id,
                            f.plan_id,
                            f.feature_key,
                            f.enabled
                        from public.feature_entitlements f
                        where f.plan_id = v_sub.plan_id
                          and f.enabled = true
                    ) fe
                ), '[]'::jsonb)
            )
            into v_result;

            return v_result;

        when 'change_plan' then
            v_result := public.commerce_change_subscription_plan(
                (p_payload->>'plan_id')::uuid
            );

            perform platform.log_audit(
                'subscription.plan_changed',
                'subscription',
                (v_result->>'subscription_id')::uuid,
                jsonb_build_object(
                    'plan_id', v_result->>'plan_id',
                    'tier', v_result->>'tier'
                )
            );

            return v_result;

        else
            raise exception 'unknown commerce operation: %', p_op;
    end case;
end;
$$;


-- =====================================================
-- 13. PAYMENT STATUS TRANSITION BRIDGE
-- =====================================================
-- Commerce-facing bridge into the platform payment engine
-- defined in 000.
-- =====================================================

create or replace function public.payment_transition_status(
    p_intent_id uuid,
    p_new_status public.payment_status,
    p_source text,
    p_event_type text default 'status_changed',
    p_external_event_id text default null,
    p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
begin
    v_tid := platform.current_tenant_id();
    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    if not exists (
        select 1 from platform.payment_intents pi
        where pi.id = p_intent_id and pi.tenant_id = v_tid
    ) then
        raise exception 'Payment not found';
    end if;

    perform platform.apply_payment_status(
        p_intent_id,
        p_new_status::text,
        p_source,
        p_event_type,
        p_external_event_id,
        coalesce(p_metadata, '{}'::jsonb)
    );
end;
$$;


-- =====================================================
-- 14. PAYMENT DOMAIN API
-- =====================================================
-- Checkout/payment orchestration.
-- Actual payment execution remains outside this domain.
-- =====================================================

create or replace function public.payment_domain(
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
    v_intent_id uuid;
    v_status public.payment_status;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);
    v_tid := platform.current_tenant_id();

    case p_op
    when 'create_checkout_session' then
        if v_tid is null then raise exception 'no active tenant'; end if;

        if not exists (
            select 1 from public.integration_providers ip
            where ip.code = p_payload->>'provider' and ip.is_active = true
        ) then
            raise exception 'Unknown or inactive payment provider: %', p_payload->>'provider';
        end if;

        if (p_payload->>'amount')::numeric <= 0 then
            raise exception 'amount must be positive';
        end if;

        insert into platform.payment_intents (
            tenant_id,
            provider,
            amount,
            currency,
            status,
            target_type,
            target_id,
            metadata
        )
        values (
            v_tid,
            p_payload->>'provider',
            (p_payload->>'amount')::numeric,
            upper(coalesce(p_payload->>'currency', 'EUR')),
            'pending'::public.payment_status,
            p_payload->>'target_type',
            (p_payload->>'target_id')::uuid,
            coalesce(p_payload->'metadata', '{}'::jsonb)
        )
        returning id, tenant_id, provider, external_intent_id, amount, currency,
                  status, target_type, target_id, metadata, created_at, updated_at
        into v_row;

        insert into platform.payment_events (
            payment_intent_id, tenant_id, event_type, old_status, new_status, source, payload
        )
        values (
            v_row.id, v_tid, 'intent_created', null, 'pending', 'api',
            jsonb_build_object('target_type', v_row.target_type, 'target_id', v_row.target_id)
        );

        perform platform.log_audit(
            'payment.checkout_created',
            'payment_intent',
            v_row.id,
            jsonb_build_object('provider', v_row.provider, 'amount', v_row.amount)
        );

        v_result := to_jsonb(v_row);

    when 'get_payment' then
        if v_tid is null then raise exception 'no active tenant'; end if;
        select to_jsonb(t) into v_result from (
            select pi.id, pi.tenant_id, pi.provider, pi.external_intent_id, pi.amount,
                   pi.currency, pi.status, pi.target_type, pi.target_id, pi.metadata,
                   pi.created_at, pi.updated_at
            from platform.payment_intents pi
            where pi.id = (p_payload->>'id')::uuid and pi.tenant_id = v_tid
        ) t;
        if v_result is null then raise exception 'Payment not found'; end if;

    when 'list_payments' then
        if v_tid is null then raise exception 'no active tenant'; end if;
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb) into v_result
        from (
            select pi.id, pi.tenant_id, pi.provider, pi.external_intent_id, pi.amount,
                   pi.currency, pi.status, pi.target_type, pi.target_id, pi.created_at, pi.updated_at
            from platform.payment_intents pi
            where pi.tenant_id = v_tid
              and (p_payload->>'status' is null or pi.status::text = p_payload->>'status')
              and (p_payload->>'target_type' is null or pi.target_type = p_payload->>'target_type')
              and (p_payload->>'target_id' is null or pi.target_id = (p_payload->>'target_id')::uuid)
        ) t;

    when 'cancel_payment' then
        if v_tid is null then raise exception 'no active tenant'; end if;

        select pi.id, pi.status into v_intent_id, v_status
        from platform.payment_intents pi
        where pi.id = (p_payload->>'id')::uuid and pi.tenant_id = v_tid
        for update;

        if not found then raise exception 'Payment not found'; end if;

        if v_status not in ('pending'::public.payment_status, 'authorized'::public.payment_status) then
            raise exception 'Payment cannot be cancelled in status %', v_status;
        end if;

        perform public.payment_transition_status(
            v_intent_id,
            'cancelled'::public.payment_status,
            'api',
            'cancelled',
            null,
            coalesce(p_payload->'metadata', '{}'::jsonb)
        );

        select to_jsonb(t) into v_result from (
            select pi.id, pi.tenant_id, pi.provider, pi.status, pi.updated_at
            from platform.payment_intents pi where pi.id = v_intent_id
        ) t;

        perform platform.log_audit('payment.cancelled', 'payment_intent', v_intent_id);

    when 'payment_history' then
        if v_tid is null then raise exception 'no active tenant'; end if;

        if not exists (
            select 1 from platform.payment_intents pi
            where pi.id = (p_payload->>'payment_intent_id')::uuid and pi.tenant_id = v_tid
        ) then
            raise exception 'Payment not found';
        end if;

        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb) into v_result
        from (
            select pe.id, pe.payment_intent_id, pe.event_type, pe.old_status, pe.new_status,
                   pe.source, pe.external_event_id, pe.payload, pe.created_at
            from platform.payment_events pe
            where pe.payment_intent_id = (p_payload->>'payment_intent_id')::uuid
              and pe.tenant_id = v_tid
        ) t;

    else
        raise exception 'unknown payment_domain operation: %', p_op;
    end case;

    return v_result;
end;
$$;


-- =====================================================
-- 15. SUBSCRIPTION / COMMERCE TRIGGERS
-- =====================================================

drop trigger if exists trg_subscriptions_sync_tier_from_plan on public.subscriptions;


drop trigger if exists trg_subscriptions_prevent_tier_drift on public.subscriptions;


drop trigger if exists trg_subscriptions_plan_required on public.subscriptions;


create trigger trg_product_plans_updated_at
before update on product_plans
for each row execute function platform.set_updated_at();


create trigger trg_subscriptions_sync_tier_from_plan
before insert or update of plan_id on public.subscriptions
for each row execute function public.sync_subscription_tier_from_plan();


create trigger trg_subscriptions_prevent_tier_drift
before update of tier on public.subscriptions
for each row execute function public.prevent_subscription_tier_drift();


create trigger trg_subscriptions_plan_required
before insert or update on public.subscriptions
for each row execute function public.enforce_subscription_plan_required();


-- =====================================================
-- 16. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('012_commerce_engine', 'REV1', false)
on conflict (migration_name) do nothing;