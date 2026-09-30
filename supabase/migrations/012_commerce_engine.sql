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

    -- Plan every new tenant is provisioned with
    -- (see provision_default_subscription in section 15).
    -- At most one plan can be the default (unique index).
    is_default boolean not null default false,

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    constraint chk_product_plans_default_active
        check (not is_default or is_active is true)
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
-- 4B. INVOICES
-- =====================================================
-- Audit fix: public.payment_intents (000) has always
-- supported target_type = 'invoice' and defensively
-- checks `to_regclass('public.invoices')`, but the table
-- itself was never created. This adds the minimal table
-- that check assumes exists.
-- =====================================================

create table if not exists public.invoices (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    subscription_id uuid references public.subscriptions(id) on delete set null,

    invoice_number text not null,

    status text not null default 'draft'
        check (status in ('draft', 'open', 'paid', 'void', 'uncollectible')),

    currency text not null default 'EUR'
        check (char_length(currency) = 3),

    subtotal numeric(10,2) not null default 0,
    discount_amount numeric(10,2) not null default 0,
    tax_amount numeric(10,2) not null default 0,
    total_amount numeric(10,2) not null default 0,

    issued_at timestamptz,
    due_at timestamptz,
    paid_at timestamptz,

    created_at timestamptz default now(),
    updated_at timestamptz default now(),

    constraint chk_invoices_total_non_negative
        check (total_amount >= 0),

    unique (tenant_id, invoice_number)
);

create index if not exists idx_invoices_tenant_created
on public.invoices (tenant_id, created_at desc);

create index if not exists idx_invoices_tenant_status
on public.invoices (tenant_id, status);


-- =====================================================
-- 4B.1 INVOICE LINES
-- =====================================================
-- Line items returned by get_invoice. Written by the backend
-- (invoice generator, service_role); read-only for the portal
-- through commerce_api.
-- =====================================================

create table if not exists public.invoice_lines (
    id uuid primary key default gen_random_uuid(),

    invoice_id uuid not null
        references public.invoices(id) on delete cascade,

    tenant_id uuid not null
        references public.tenants(id) on delete cascade,

    description text not null,

    quantity numeric(10,2) not null default 1
        check (quantity > 0),

    unit_amount numeric(10,2) not null default 0,

    line_amount numeric(10,2) not null default 0,

    sort_order int not null default 0,

    created_at timestamptz not null default now()
);

create index if not exists idx_invoice_lines_invoice
on public.invoice_lines (invoice_id, sort_order);

create index if not exists idx_invoice_lines_tenant
on public.invoice_lines (tenant_id);

create or replace function public.enforce_invoice_line_tenant_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_invoice_tenant uuid;
begin
    select i.tenant_id
    into v_invoice_tenant
    from public.invoices i
    where i.id = new.invoice_id;

    if v_invoice_tenant is distinct from new.tenant_id then
        raise exception 'invoice_lines.tenant_id must match invoices.tenant_id';
    end if;

    return new;
end;
$$;

drop trigger if exists trg_invoice_lines_tenant_consistency on public.invoice_lines;

create trigger trg_invoice_lines_tenant_consistency
before insert or update of invoice_id, tenant_id on public.invoice_lines
for each row execute function public.enforce_invoice_line_tenant_consistency();


-- =====================================================
-- 4C. DISCOUNTS / COUPONS
-- =====================================================
-- Audit fix: no discount/coupon/voucher concept existed
-- anywhere in the schema. This adds the catalogue and the
-- redemption ledger. RPC wiring lives in commerce_domain() /
-- commerce_api():
--   platform admin : list / create / update / deactivate_discount_code
--   tenant manager : validate_discount_code,
--                    apply_discount_to_invoice,
--                    list_discount_redemptions
-- Rules: one code per invoice, one redemption per tenant per
-- code (relax by dropping uq_discount_redemptions_code_tenant).
-- =====================================================

create table if not exists public.discount_codes (
    id uuid primary key default gen_random_uuid(),

    -- null tenant_id = platform-wide code, usable by any tenant
    tenant_id uuid references public.tenants(id) on delete cascade,

    code text not null,

    discount_type text not null
        check (discount_type in ('percentage', 'fixed_amount')),

    value numeric(10,2) not null
        check (value > 0),

    currency text default 'EUR'
        check (currency is null or char_length(currency) = 3),

    applies_to_plan_id uuid references public.product_plans(id),

    max_redemptions int,
    redeemed_count int not null default 0,

    valid_from timestamptz not null default now(),
    valid_until timestamptz,

    is_active boolean not null default true,

    created_at timestamptz default now(),
    updated_at timestamptz default now(),

    constraint chk_discount_codes_percentage_range
        check (discount_type <> 'percentage' or (value > 0 and value <= 100)),

    constraint chk_discount_codes_redemption_cap
        check (max_redemptions is null or redeemed_count <= max_redemptions),

    constraint chk_discount_codes_max_redemptions_positive
        check (max_redemptions is null or max_redemptions > 0),

    constraint chk_discount_codes_code_normalized
        check (code <> '' and code = upper(btrim(code))),

    constraint chk_discount_codes_validity_window
        check (valid_until is null or valid_until > valid_from),

    unique (code)
);

create table if not exists public.discount_redemptions (
    id uuid primary key default gen_random_uuid(),

    discount_code_id uuid not null references public.discount_codes(id) on delete cascade,

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    invoice_id uuid references public.invoices(id) on delete set null,
    subscription_id uuid references public.subscriptions(id) on delete set null,

    amount_applied numeric(10,2) not null
        check (amount_applied >= 0),

    redeemed_at timestamptz not null default now()
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

create unique index if not exists uq_product_plans_single_default
on public.product_plans (is_default)
where is_default;

create unique index if not exists uq_product_plans_name
on public.product_plans ((lower(name)));

create unique index if not exists uq_discount_redemptions_invoice
on public.discount_redemptions (invoice_id)
where invoice_id is not null;

create unique index if not exists uq_discount_redemptions_code_tenant
on public.discount_redemptions (discount_code_id, tenant_id);

create index if not exists idx_discount_redemptions_tenant
on public.discount_redemptions (tenant_id, redeemed_at desc);

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
-- 11B. DISCOUNT HELPERS (internal, not portal-callable)
-- =====================================================
-- Execute privilege is revoked for anon/authenticated by 022.
-- =====================================================

create or replace function public.commerce_compute_discount_amount(
    p_discount_type text,
    p_value numeric,
    p_base numeric
)
returns numeric
language sql
immutable
set search_path = ''
as $$
    select greatest(
        0,
        case p_discount_type
            when 'percentage'   then round(p_base * p_value / 100, 2)
            when 'fixed_amount' then least(p_value, p_base)
            else 0
        end
    );
$$;


-- Returns the discount code row when the tenant may use it right
-- now, otherwise a row with id = null. The reason is deliberately
-- not distinguished (prevents probing for existing codes).
-- p_lock = true takes a row lock so max_redemptions cannot be
-- exceeded by concurrent redemptions.
create or replace function public.commerce_find_usable_discount_code(
    p_tenant_id uuid,
    p_code text,
    p_plan_id uuid default null,
    p_currency text default null,
    p_lock boolean default false
)
returns public.discount_codes
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_row public.discount_codes;
    v_none public.discount_codes;
begin
    if p_code is null or btrim(p_code) = '' then
        return v_none;
    end if;

    if p_lock then
        select dc.*
        into v_row
        from public.discount_codes dc
        where dc.code = upper(btrim(p_code))
        for update;
    else
        select dc.*
        into v_row
        from public.discount_codes dc
        where dc.code = upper(btrim(p_code));
    end if;

    if v_row.id is null
       or not v_row.is_active
       or v_row.valid_from > now()
       or (v_row.valid_until is not null and v_row.valid_until <= now())
       or (v_row.max_redemptions is not null
           and v_row.redeemed_count >= v_row.max_redemptions)
       or (v_row.tenant_id is not null
           and v_row.tenant_id is distinct from p_tenant_id)
       or (v_row.applies_to_plan_id is not null
           and p_plan_id is not null
           and v_row.applies_to_plan_id <> p_plan_id)
       or (v_row.discount_type = 'fixed_amount'
           and p_currency is not null
           and v_row.currency is not null
           and upper(v_row.currency) <> upper(p_currency))
       or exists (
            select 1
            from public.discount_redemptions r
            where r.discount_code_id = v_row.id
              and r.tenant_id = p_tenant_id
       )
    then
        return v_none;
    end if;

    return v_row;
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
    v_code public.discount_codes;
    v_inv record;
    v_base numeric;
    v_discount numeric;
    v_new_tax numeric;
    v_limit int;
    v_offset int;
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
            -- A tenant may only switch itself to a FREE plan (pricing row
            -- present, no positive price). Paid plans are activated by the
            -- backend after a successful payment (service_role). Without
            -- this guard any tenant manager could upgrade to any plan for
            -- free. Platform admins are exempt.
            if not public.is_platform_admin() then
                if not exists (
                    select 1
                    from public.plan_pricing pr
                    where pr.plan_id = (p_payload->>'plan_id')::uuid
                ) or exists (
                    select 1
                    from public.plan_pricing pr
                    where pr.plan_id = (p_payload->>'plan_id')::uuid
                      and (coalesce(pr.monthly_price, 0) > 0
                           or coalesce(pr.yearly_price, 0) > 0)
                ) then
                    raise exception
                        'PAYMENT_REQUIRED: this plan is activated after payment (use payment_api create_checkout_session)';
                end if;
            end if;

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

        -- =================================================
        -- DISCOUNT CODES - PLATFORM ADMIN
        -- =================================================

        when 'list_discount_codes' then

            select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb)
            into v_result
            from (
                select
                    dc.id,
                    dc.tenant_id,
                    dc.code,
                    dc.discount_type,
                    dc.value,
                    dc.currency,
                    dc.applies_to_plan_id,
                    dc.max_redemptions,
                    dc.redeemed_count,
                    dc.valid_from,
                    dc.valid_until,
                    dc.is_active,
                    dc.created_at,
                    dc.updated_at
                from public.discount_codes dc
                where (p_payload->>'is_active' is null
                       or dc.is_active = (p_payload->>'is_active')::boolean)
                  and (p_payload->>'tenant_id' is null
                       or dc.tenant_id = (p_payload->>'tenant_id')::uuid)
            ) t;

            return v_result;

        when 'create_discount_code' then

            insert into public.discount_codes (
                tenant_id,
                code,
                discount_type,
                value,
                currency,
                applies_to_plan_id,
                max_redemptions,
                valid_from,
                valid_until
            )
            values (
                nullif(p_payload->>'tenant_id', '')::uuid,
                upper(btrim(p_payload->>'code')),
                p_payload->>'discount_type',
                (p_payload->>'value')::numeric,
                case
                    when p_payload->>'discount_type' = 'fixed_amount'
                    then upper(coalesce(nullif(p_payload->>'currency', ''), 'EUR'))
                    else null
                end,
                nullif(p_payload->>'applies_to_plan_id', '')::uuid,
                nullif(p_payload->>'max_redemptions', '')::int,
                coalesce(nullif(p_payload->>'valid_from', '')::timestamptz, now()),
                nullif(p_payload->>'valid_until', '')::timestamptz
            )
            returning
                id, tenant_id, code, discount_type, value, currency,
                applies_to_plan_id, max_redemptions, redeemed_count,
                valid_from, valid_until, is_active, created_at
            into v_row;

            perform platform.log_audit(
                'discount_code.created',
                'discount_code',
                v_row.id,
                jsonb_build_object('code', v_row.code)
            );

            return to_jsonb(v_row);

        -- Financial terms (code, type, value) are immutable once
        -- created: deactivate and create a new code instead.
        when 'update_discount_code' then

            update public.discount_codes dc
            set
                is_active = case
                    when p_payload ? 'is_active'
                    then (p_payload->>'is_active')::boolean
                    else dc.is_active
                end,
                valid_until = case
                    when p_payload ? 'valid_until'
                    then nullif(p_payload->>'valid_until', '')::timestamptz
                    else dc.valid_until
                end,
                max_redemptions = case
                    when p_payload ? 'max_redemptions'
                    then nullif(p_payload->>'max_redemptions', '')::int
                    else dc.max_redemptions
                end,
                applies_to_plan_id = case
                    when p_payload ? 'applies_to_plan_id'
                    then nullif(p_payload->>'applies_to_plan_id', '')::uuid
                    else dc.applies_to_plan_id
                end
            where dc.id = (p_payload->>'id')::uuid
            returning
                dc.id, dc.code, dc.is_active, dc.valid_until,
                dc.max_redemptions, dc.redeemed_count,
                dc.applies_to_plan_id, dc.updated_at
            into v_row;

            if not found then
                raise exception 'Discount code not found';
            end if;

            perform platform.log_audit(
                'discount_code.updated',
                'discount_code',
                v_row.id
            );

            return to_jsonb(v_row);

        when 'deactivate_discount_code' then

            update public.discount_codes dc
            set is_active = false
            where dc.id = (p_payload->>'id')::uuid
            returning dc.id, dc.code, dc.is_active, dc.updated_at
            into v_row;

            if not found then
                raise exception 'Discount code not found';
            end if;

            perform platform.log_audit(
                'discount_code.deactivated',
                'discount_code',
                v_row.id
            );

            return to_jsonb(v_row);

        -- =================================================
        -- DISCOUNT CODES - TENANT
        -- =================================================

        when 'validate_discount_code' then

            v_tid := platform.current_tenant_id();

            v_code := public.commerce_find_usable_discount_code(
                v_tid,
                p_payload->>'code',
                nullif(p_payload->>'plan_id', '')::uuid,
                nullif(p_payload->>'currency', ''),
                false
            );

            if v_code.id is null then
                return jsonb_build_object(
                    'valid', false,
                    'reason', 'invalid_or_unavailable'
                );
            end if;

            v_base := nullif(p_payload->>'amount', '')::numeric;

            return jsonb_build_object(
                'valid', true,
                'code', v_code.code,
                'discount_type', v_code.discount_type,
                'value', v_code.value,
                'currency', v_code.currency,
                'discount_amount', case
                    when v_base is null then null
                    else public.commerce_compute_discount_amount(
                        v_code.discount_type, v_code.value, v_base
                    )
                end
            );

        when 'apply_discount_to_invoice' then

            v_tid := platform.current_tenant_id();

            select i.*
            into v_inv
            from public.invoices i
            where i.id = (p_payload->>'invoice_id')::uuid
              and i.tenant_id = v_tid
            for update;

            if not found then
                raise exception 'Invoice not found';
            end if;

            if v_inv.status <> 'open' then
                raise exception 'A discount can only be applied to an open invoice';
            end if;

            if v_inv.discount_amount > 0
               or exists (
                    select 1
                    from public.discount_redemptions r
                    where r.invoice_id = v_inv.id
               ) then
                raise exception 'A discount was already applied to this invoice';
            end if;

            -- Totals must not change while a payment is in flight.
            if exists (
                select 1
                from platform.payment_intents pi
                where pi.target_type = 'invoice'
                  and pi.target_id = v_inv.id
                  and pi.status::text in ('pending', 'authorized')
            ) then
                raise exception 'Cancel the pending payment before applying a discount';
            end if;

            v_code := public.commerce_find_usable_discount_code(
                v_tid,
                p_payload->>'code',
                (select s.plan_id
                 from public.subscriptions s
                 where s.id = v_inv.subscription_id),
                v_inv.currency,
                true
            );

            if v_code.id is null then
                raise exception 'Discount code is not valid for this invoice';
            end if;

            v_discount := public.commerce_compute_discount_amount(
                v_code.discount_type, v_code.value, v_inv.subtotal
            );

            if v_discount <= 0 then
                raise exception 'Discount code does not reduce this invoice';
            end if;

            -- Tax is scaled proportionally to the discounted subtotal
            -- (assumes a uniform tax rate on the invoice).
            v_new_tax := case
                when v_inv.subtotal > 0
                then round(v_inv.tax_amount * (v_inv.subtotal - v_discount) / v_inv.subtotal, 2)
                else v_inv.tax_amount
            end;

            update public.invoices i
            set
                discount_amount = v_discount,
                tax_amount = v_new_tax,
                total_amount = v_inv.subtotal - v_discount + v_new_tax
            where i.id = v_inv.id
            returning
                i.id, i.invoice_number, i.status, i.currency, i.subtotal,
                i.discount_amount, i.tax_amount, i.total_amount
            into v_row;

            insert into public.discount_redemptions (
                discount_code_id,
                tenant_id,
                invoice_id,
                subscription_id,
                amount_applied
            )
            values (
                v_code.id,
                v_tid,
                v_inv.id,
                v_inv.subscription_id,
                v_discount
            );

            update public.discount_codes dc
            set redeemed_count = dc.redeemed_count + 1
            where dc.id = v_code.id;

            perform platform.log_audit(
                'discount_code.redeemed',
                'invoice',
                v_inv.id,
                jsonb_build_object(
                    'code', v_code.code,
                    'amount_applied', v_discount
                )
            );

            return to_jsonb(v_row);

        when 'list_discount_redemptions' then

            v_tid := platform.current_tenant_id();

            select coalesce(jsonb_agg(to_jsonb(t) order by t.redeemed_at desc), '[]'::jsonb)
            into v_result
            from (
                select
                    r.id,
                    dc.code,
                    r.invoice_id,
                    r.subscription_id,
                    r.amount_applied,
                    r.redeemed_at
                from public.discount_redemptions r
                join public.discount_codes dc
                  on dc.id = r.discount_code_id
                where r.tenant_id = v_tid
            ) t;

            return v_result;

        -- =================================================
        -- INVOICES - TENANT (READ ONLY, drafts are hidden)
        -- =================================================

        when 'list_invoices' then

            v_tid := platform.current_tenant_id();

            v_limit := least(greatest(coalesce(nullif(p_payload->>'limit', '')::int, 50), 1), 200);
            v_offset := greatest(coalesce(nullif(p_payload->>'offset', '')::int, 0), 0);

            select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb)
            into v_result
            from (
                select
                    i.id,
                    i.tenant_id,
                    i.subscription_id,
                    i.invoice_number,
                    i.status,
                    i.currency,
                    i.subtotal,
                    i.discount_amount,
                    i.tax_amount,
                    i.total_amount,
                    i.issued_at,
                    i.due_at,
                    i.paid_at,
                    i.created_at
                from public.invoices i
                where i.tenant_id = v_tid
                  and i.status <> 'draft'
                  and (p_payload->>'status' is null
                       or i.status = p_payload->>'status')
                order by i.created_at desc
                limit v_limit
                offset v_offset
            ) t;

            return v_result;

        when 'get_invoice' then

            v_tid := platform.current_tenant_id();

            select jsonb_build_object(
                'invoice', to_jsonb(inv),
                'lines', coalesce((
                    select jsonb_agg(to_jsonb(l) order by l.sort_order, l.created_at)
                    from (
                        select
                            il.id,
                            il.description,
                            il.quantity,
                            il.unit_amount,
                            il.line_amount,
                            il.sort_order,
                            il.created_at
                        from public.invoice_lines il
                        where il.invoice_id = inv.id
                    ) l
                ), '[]'::jsonb),
                'discounts', coalesce((
                    select jsonb_agg(to_jsonb(d) order by d.redeemed_at)
                    from (
                        select
                            dc.code,
                            r.amount_applied,
                            r.redeemed_at
                        from public.discount_redemptions r
                        join public.discount_codes dc
                          on dc.id = r.discount_code_id
                        where r.invoice_id = inv.id
                    ) d
                ), '[]'::jsonb)
            )
            into v_result
            from (
                select
                    i.id,
                    i.tenant_id,
                    i.subscription_id,
                    i.invoice_number,
                    i.status,
                    i.currency,
                    i.subtotal,
                    i.discount_amount,
                    i.tax_amount,
                    i.total_amount,
                    i.issued_at,
                    i.due_at,
                    i.paid_at,
                    i.created_at
                from public.invoices i
                where i.id = coalesce(
                        nullif(p_payload->>'id', '')::uuid,
                        nullif(p_payload->>'invoice_id', '')::uuid
                    )
                  and i.tenant_id = v_tid
                  and i.status <> 'draft'
            ) inv;

            if v_result is null then
                raise exception 'Invoice not found';
            end if;

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
    v_amount numeric;
    v_currency text;
    v_inv record;
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

        v_amount := (p_payload->>'amount')::numeric;
        v_currency := upper(coalesce(p_payload->>'currency', 'EUR'));

        -- For invoices the amount and currency come from the invoice,
        -- never from the client payload.
        if p_payload->>'target_type' = 'invoice' then
            select i.id, i.status, i.total_amount, i.currency
            into v_inv
            from public.invoices i
            where i.id = nullif(p_payload->>'target_id', '')::uuid
              and i.tenant_id = v_tid;

            if not found then
                raise exception 'Invoice not found';
            end if;

            if v_inv.status <> 'open' then
                raise exception 'Invoice is not payable in status %', v_inv.status;
            end if;

            v_amount := v_inv.total_amount;
            v_currency := upper(v_inv.currency);
        end if;

        if v_amount is null or v_amount <= 0 then
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
            v_amount,
            v_currency,
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
-- 15B. DEFAULT SUBSCRIPTION FOR NEW TENANTS
-- =====================================================
-- Every tenant gets a trial subscription on the default plan
-- (product_plans.is_default). Without it get_tenant_entitlements
-- fails with 'Subscription not found for tenant'.
--
-- Requires the commerce catalogue seed (seed_commerce.sql):
-- tenant creation fails loudly when no default plan exists.
--
-- Trial length is 14 days. NOTE: nothing in the schema moves an
-- expired trial to 'trial_expired' yet; that needs a scheduled job.
-- =====================================================

create or replace function public.provision_default_subscription()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_plan_id uuid;
    v_tier public.subscription_tier;
begin
    select pp.id, pp.tier
    into v_plan_id, v_tier
    from public.product_plans pp
    where pp.is_default
      and pp.is_active is true
    limit 1;

    if v_plan_id is null then
        raise exception
            'NO_DEFAULT_PRODUCT_PLAN: seed public.product_plans (is_default = true) before creating tenants';
    end if;

    insert into public.subscriptions (
        tenant_id,
        plan_id,
        tier,
        status,
        current_period_start,
        current_period_end
    )
    values (
        new.id,
        v_plan_id,
        v_tier,
        'trial'::public.subscription_status,
        now(),
        now() + interval '14 days'
    )
    on conflict (tenant_id) do nothing;

    return new;
end;
$$;

drop trigger if exists trg_tenants_provision_default_subscription on public.tenants;

create trigger trg_tenants_provision_default_subscription
after insert on public.tenants
for each row execute function public.provision_default_subscription();

drop trigger if exists trg_invoices_updated_at on public.invoices;

create trigger trg_invoices_updated_at
before update on public.invoices
for each row execute function platform.set_updated_at();

drop trigger if exists trg_discount_codes_updated_at on public.discount_codes;

create trigger trg_discount_codes_updated_at
before update on public.discount_codes
for each row execute function platform.set_updated_at();


-- =====================================================
-- 16. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('012_commerce_engine', 'REV1', false)
on conflict (migration_name) do nothing;