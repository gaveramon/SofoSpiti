-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 012_COMMERCE_ENGINE.SQL
-- =====================================================
--
-- NO PAYMENT EXECUTION / NO WEBHOOKS / NO TRANSACTIONS
-- BILLING: Supabase decides WHAT is invoiced (customer, lines, VAT,
-- discounts, credit notes). Epsilon issues the official e-invoice and
-- transmits it to AADE/myDATA (section 16). The portal only reads.
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
-- 4A. BILLING CUSTOMERS
-- =====================================================
-- Legal/fiscal identity a tenant is invoiced under. A tenant
-- may be linked to a CRM company, but the billing identity is
-- kept separate: invoices are fiscal documents and the data on
-- them (name, VAT number, address) must be stable.
-- Epsilon matches customers on VAT number (CustTin), so the VAT
-- number is mandatory for business customers at issue time.
-- =====================================================

create table if not exists public.billing_customers (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    crm_company_id uuid references public.crm_companies(id) on delete set null,

    customer_type text not null default 'business'
        check (customer_type in ('business', 'individual')),

    legal_name text not null,
    trade_name text,

    vat_number text,
    tax_office text,

    country_code text not null default 'GR'
        check (country_code ~ '^[A-Z]{2}$'),

    address_line text,
    postal_code text,
    city text,

    billing_email text,

    -- Set by the Epsilon gateway, never by the portal.
    epsilon_customer_code text,

    is_default boolean not null default true,
    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create unique index if not exists uq_billing_customers_default
on public.billing_customers (tenant_id)
where is_default;

create unique index if not exists uq_billing_customers_epsilon_code
on public.billing_customers (epsilon_customer_code)
where epsilon_customer_code is not null;

create index if not exists idx_billing_customers_tenant
on public.billing_customers (tenant_id);


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

    -- ---- billing identity & document type ----
    billing_customer_id uuid references public.billing_customers(id),

    -- Credit notes are stored with POSITIVE amounts (as in myDATA type 5.1);
    -- the sign comes from document_type.
    document_type text not null default 'invoice'
        check (document_type in ('invoice', 'credit_note')),

    credited_invoice_id uuid references public.invoices(id),
    credit_reason text,

    -- Derived from status; no second field to keep in sync.
    payment_status text generated always as (
        case
            when status = 'paid' then 'paid'
            when status in ('draft', 'void') then 'not_applicable'
            else 'unpaid'
        end
    ) stored,

    -- ---- Epsilon / myDATA (written by platform.epsilon_* only) ----
    mydata_document_type text,
    epsilon_document_id text,
    epsilon_uid text,
    epsilon_mark text,
    epsilon_correlated_mark text,
    epsilon_status text not null default 'not_submitted',
    epsilon_response jsonb,
    epsilon_submitted_at timestamptz,
    epsilon_accepted_at timestamptz,
    epsilon_last_error text,

    -- Set when the invoice is frozen for Epsilon (see section 16).
    locked_at timestamptz,
    snapshot_id uuid,

    created_at timestamptz default now(),
    updated_at timestamptz default now(),

    constraint chk_invoices_total_non_negative
        check (total_amount >= 0),

    constraint chk_invoices_credit_note_link
        check ((document_type = 'credit_note') = (credited_invoice_id is not null)),

    constraint chk_invoices_mydata_document_type
        check (mydata_document_type is null
               or mydata_document_type ~ '^[0-9]{1,2}\.[0-9]{1,2}$'),

    constraint chk_invoices_epsilon_status
        check (epsilon_status in
               ('not_submitted', 'queued', 'submitted', 'accepted', 'rejected', 'error')),

    constraint chk_invoices_accepted_has_mark
        check (epsilon_status <> 'accepted' or epsilon_mark is not null),

    constraint chk_invoices_locked_has_snapshot
        check (locked_at is null or snapshot_id is not null),

    unique (tenant_id, invoice_number)
);

create unique index if not exists uq_invoices_epsilon_document_id
on public.invoices (epsilon_document_id) where epsilon_document_id is not null;

create unique index if not exists uq_invoices_epsilon_uid
on public.invoices (epsilon_uid) where epsilon_uid is not null;

create unique index if not exists uq_invoices_epsilon_mark
on public.invoices (epsilon_mark) where epsilon_mark is not null;

create index if not exists idx_invoices_epsilon_attention
on public.invoices (epsilon_status)
where epsilon_status in ('queued', 'error', 'rejected');

create index if not exists idx_invoices_credited
on public.invoices (credited_invoice_id) where credited_invoice_id is not null;

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

    -- line_amount = NET amount (quantity * unit_amount) before discount.
    -- gross_amount = line_amount - discount_amount + vat_amount
    -- (verified when the invoice is frozen for Epsilon).
    product_plan_id uuid references public.product_plans(id) on delete set null,

    vat_rate numeric(5,2)
        check (vat_rate is null or (vat_rate >= 0 and vat_rate <= 100)),
    discount_amount numeric(10,2) not null default 0
        check (discount_amount >= 0),
    vat_amount numeric(10,2) not null default 0
        check (vat_amount >= 0),
    gross_amount numeric(10,2) not null default 0
        check (gross_amount >= 0),

    -- Filled from billing_item_mappings (trigger below); required at issue time.
    epsilon_item_code text,
    mydata_income_class_type text,
    mydata_income_class_category text,
    vat_exemption_category text,

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

            if v_inv.document_type <> 'invoice' then
                raise exception 'A discount cannot be applied to a credit note';
            end if;

            -- Once frozen for Epsilon the invoice is a fiscal document.
            if v_inv.locked_at is not null then
                raise exception 'This invoice has already been issued; a discount can no longer be applied';
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

            if exists (
                select 1 from public.invoice_lines il where il.invoice_id = v_inv.id
            ) then
                -- Distribute the discount pro rata over the lines (rounding rest
                -- on the last line), recompute VAT per line, roll up to the invoice.
                with ordered as (
                    select
                        il.id,
                        il.line_amount,
                        il.vat_rate,
                        row_number() over (
                            order by il.sort_order desc, il.created_at desc, il.id
                        ) as rn_last,
                        sum(il.line_amount) over () as total_net
                    from public.invoice_lines il
                    where il.invoice_id = v_inv.id
                ),
                alloc as (
                    select
                        o.id, o.line_amount, o.vat_rate, o.rn_last,
                        case when o.total_net > 0
                             then round(v_discount * o.line_amount / o.total_net, 2)
                             else 0 end as share
                    from ordered o
                ),
                fixed as (
                    select
                        a.id, a.line_amount, a.vat_rate,
                        a.share + case when a.rn_last = 1
                                       then v_discount - sum(a.share) over ()
                                       else 0 end as disc
                    from alloc a
                )
                update public.invoice_lines il
                set
                    discount_amount = f.disc,
                    vat_amount = round((il.line_amount - f.disc) * coalesce(f.vat_rate, 0) / 100, 2),
                    gross_amount = (il.line_amount - f.disc)
                        + round((il.line_amount - f.disc) * coalesce(f.vat_rate, 0) / 100, 2)
                from fixed f
                where il.id = f.id;

                select coalesce(sum(il.vat_amount), 0)
                into v_new_tax
                from public.invoice_lines il
                where il.invoice_id = v_inv.id;
            else
                -- Header-only invoice (no lines): scale tax proportionally
                -- (assumes a uniform tax rate on the invoice).
                v_new_tax := case
                    when v_inv.subtotal > 0
                    then round(v_inv.tax_amount * (v_inv.subtotal - v_discount) / v_inv.subtotal, 2)
                    else v_inv.tax_amount
                end;
            end if;

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
                    i.document_type,
                    i.credited_invoice_id,
                    i.credit_reason,
                    i.payment_status,
                    i.epsilon_status,
                    i.epsilon_uid,
                    i.epsilon_mark,
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
                            il.discount_amount,
                            il.vat_rate,
                            il.vat_amount,
                            il.gross_amount,
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
                    i.document_type,
                    i.credited_invoice_id,
                    i.credit_reason,
                    i.payment_status,
                    i.epsilon_status,
                    i.epsilon_uid,
                    i.epsilon_mark,
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

        -- =================================================
        -- BILLING CUSTOMER - TENANT
        -- =================================================

        when 'get_billing_customer' then

            v_tid := platform.current_tenant_id();

            select to_jsonb(t)
            into v_result
            from (
                select
                    bc.id,
                    bc.customer_type,
                    bc.legal_name,
                    bc.trade_name,
                    bc.vat_number,
                    bc.tax_office,
                    bc.country_code,
                    bc.address_line,
                    bc.postal_code,
                    bc.city,
                    bc.billing_email
                from public.billing_customers bc
                where bc.tenant_id = v_tid
                  and bc.is_default
                  and bc.is_active
            ) t;

            return v_result;

        when 'update_billing_customer' then

            v_tid := platform.current_tenant_id();

            if nullif(btrim(coalesce(p_payload->>'legal_name', '')), '') is null then
                raise exception 'legal_name is required';
            end if;

            if coalesce(p_payload->>'customer_type', 'business') not in ('business', 'individual') then
                raise exception 'customer_type must be business or individual';
            end if;

            if coalesce(p_payload->>'customer_type', 'business') = 'business'
               and upper(coalesce(p_payload->>'country_code', 'GR')) = 'GR'
               and coalesce(p_payload->>'vat_number', '') !~ '^[0-9]{9}$' then
                raise exception 'A Greek business customer requires a 9-digit VAT number';
            end if;

            insert into public.billing_customers (
                tenant_id, customer_type, legal_name, trade_name, vat_number,
                tax_office, country_code, address_line, postal_code, city, billing_email
            )
            values (
                v_tid,
                coalesce(p_payload->>'customer_type', 'business'),
                btrim(p_payload->>'legal_name'),
                nullif(btrim(coalesce(p_payload->>'trade_name', '')), ''),
                nullif(btrim(coalesce(p_payload->>'vat_number', '')), ''),
                nullif(btrim(coalesce(p_payload->>'tax_office', '')), ''),
                upper(coalesce(p_payload->>'country_code', 'GR')),
                nullif(btrim(coalesce(p_payload->>'address_line', '')), ''),
                nullif(btrim(coalesce(p_payload->>'postal_code', '')), ''),
                nullif(btrim(coalesce(p_payload->>'city', '')), ''),
                nullif(btrim(coalesce(p_payload->>'billing_email', '')), '')
            )
            on conflict (tenant_id) where is_default
            do update set
                customer_type = excluded.customer_type,
                legal_name = excluded.legal_name,
                trade_name = excluded.trade_name,
                vat_number = excluded.vat_number,
                tax_office = excluded.tax_office,
                country_code = excluded.country_code,
                address_line = excluded.address_line,
                postal_code = excluded.postal_code,
                city = excluded.city,
                billing_email = excluded.billing_email,
                is_active = true
            returning id, customer_type, legal_name, trade_name, vat_number,
                      tax_office, country_code, address_line, postal_code, city,
                      billing_email
            into v_row;

            perform platform.log_audit(
                'billing_customer.updated',
                'billing_customer',
                v_row.id,
                jsonb_build_object('vat_number', v_row.vat_number)
            );

            return to_jsonb(v_row);

        -- =================================================
        -- EPSILON BILLING - PLATFORM ADMIN
        -- (authorised in commerce_api via edge_require_platform_admin)
        -- =================================================

        when 'list_billing_item_mappings' then

            select coalesce(jsonb_agg(to_jsonb(m) order by m.item_key), '[]'::jsonb)
            into v_result
            from (
                select
                    bm.id, bm.item_key, bm.plan_id, bm.description,
                    bm.epsilon_item_id, bm.epsilon_item_code,
                    bm.mydata_income_class_type, bm.mydata_income_class_category,
                    bm.default_vat_rate, bm.vat_exemption_category,
                    bm.is_active, bm.updated_at
                from public.billing_item_mappings bm
            ) m;

            return v_result;

        when 'upsert_billing_item_mapping' then

            if nullif(btrim(coalesce(p_payload->>'item_key', '')), '') is null
               or nullif(btrim(coalesce(p_payload->>'epsilon_item_code', '')), '') is null
               or nullif(btrim(coalesce(p_payload->>'mydata_income_class_type', '')), '') is null
               or nullif(btrim(coalesce(p_payload->>'mydata_income_class_category', '')), '') is null
               or nullif(p_payload->>'default_vat_rate', '') is null then
                raise exception 'item_key, epsilon_item_code, mydata_income_class_type, mydata_income_class_category and default_vat_rate are required';
            end if;

            insert into public.billing_item_mappings (
                item_key, plan_id, description, epsilon_item_id, epsilon_item_code,
                mydata_income_class_type, mydata_income_class_category,
                default_vat_rate, vat_exemption_category
            )
            values (
                btrim(p_payload->>'item_key'),
                nullif(p_payload->>'plan_id', '')::uuid,
                nullif(btrim(coalesce(p_payload->>'description', '')), ''),
                nullif(btrim(coalesce(p_payload->>'epsilon_item_id', '')), ''),
                btrim(p_payload->>'epsilon_item_code'),
                btrim(p_payload->>'mydata_income_class_type'),
                btrim(p_payload->>'mydata_income_class_category'),
                (p_payload->>'default_vat_rate')::numeric,
                nullif(btrim(coalesce(p_payload->>'vat_exemption_category', '')), '')
            )
            on conflict (item_key) do update set
                plan_id = excluded.plan_id,
                description = excluded.description,
                epsilon_item_id = excluded.epsilon_item_id,
                epsilon_item_code = excluded.epsilon_item_code,
                mydata_income_class_type = excluded.mydata_income_class_type,
                mydata_income_class_category = excluded.mydata_income_class_category,
                default_vat_rate = excluded.default_vat_rate,
                vat_exemption_category = excluded.vat_exemption_category,
                is_active = true
            returning id, item_key, plan_id, epsilon_item_code,
                      mydata_income_class_type, mydata_income_class_category,
                      default_vat_rate, vat_exemption_category, is_active
            into v_row;

            perform platform.log_audit(
                'billing_item_mapping.upserted',
                'billing_item_mapping',
                v_row.id,
                jsonb_build_object('item_key', v_row.item_key)
            );

            return to_jsonb(v_row);

        when 'deactivate_billing_item_mapping' then

            update public.billing_item_mappings bm
            set is_active = false
            where bm.id = (p_payload->>'id')::uuid
            returning bm.id, bm.item_key, bm.is_active
            into v_row;

            if not found then
                raise exception 'Billing item mapping not found';
            end if;

            perform platform.log_audit(
                'billing_item_mapping.deactivated',
                'billing_item_mapping',
                v_row.id,
                jsonb_build_object('item_key', v_row.item_key)
            );

            return to_jsonb(v_row);

        when 'list_epsilon_issues' then

            v_limit := least(greatest(coalesce(nullif(p_payload->>'limit', '')::int, 50), 1), 200);
            v_offset := greatest(coalesce(nullif(p_payload->>'offset', '')::int, 0), 0);

            -- Platform-wide: invoices that need attention.
            select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb)
            into v_result
            from (
                select
                    i.id,
                    i.tenant_id,
                    i.invoice_number,
                    i.document_type,
                    i.epsilon_status,
                    i.epsilon_last_error,
                    i.epsilon_uid,
                    i.epsilon_mark,
                    i.locked_at,
                    i.created_at,
                    (
                        select jsonb_build_object(
                            'id', es.id,
                            'status', es.status,
                            'attempts', es.attempts,
                            'http_status', es.http_status,
                            'error', es.error,
                            'next_attempt_at', es.next_attempt_at
                        )
                        from public.epsilon_submissions es
                        where es.invoice_id = i.id
                        order by es.created_at desc
                        limit 1
                    ) as last_submission
                from public.invoices i
                where i.epsilon_status in ('queued', 'error', 'rejected')
                order by i.created_at desc
                limit v_limit
                offset v_offset
            ) t;

            return v_result;

        when 'requeue_epsilon_invoice' then

            select i.id, i.document_type, i.epsilon_status
            into v_inv
            from public.invoices i
            where i.id = (p_payload->>'invoice_id')::uuid;

            if not found then
                raise exception 'Invoice not found';
            end if;

            -- A rejection by AADE cannot be fixed by resending the same data;
            -- that requires a credit note / corrected invoice.
            if v_inv.epsilon_status <> 'error' then
                raise exception 'Only invoices with Epsilon status error can be re-queued (status: %)', v_inv.epsilon_status;
            end if;

            perform platform.epsilon_enqueue_invoice(
                v_inv.id,
                case when v_inv.document_type = 'credit_note' then 'credit' else 'issue' end
            );

            perform platform.log_audit(
                'invoice.epsilon_requeued',
                'invoice',
                v_inv.id,
                '{}'::jsonb
            );

            return jsonb_build_object('invoice_id', v_inv.id, 'status', 'queued');

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
            select i.id, i.status, i.total_amount, i.currency, i.document_type
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

            if v_inv.document_type <> 'invoice' then
                raise exception 'A credit note is not payable';
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

drop trigger if exists trg_billing_customers_updated_at on public.billing_customers;

create trigger trg_billing_customers_updated_at
before update on public.billing_customers
for each row execute function platform.set_updated_at();

drop trigger if exists trg_discount_codes_updated_at on public.discount_codes;

create trigger trg_discount_codes_updated_at
before update on public.discount_codes
for each row execute function platform.set_updated_at();


-- =====================================================
-- 16. EPSILON E-INVOICING
-- =====================================================
-- Supabase decides what is invoiced. Epsilon issues the
-- official electronic invoice and transmits it to AADE.
--
--   billing_item_mappings : plan -> Epsilon item + myDATA classification
--   invoice_snapshots     : immutable copy of what was sent to Epsilon
--   epsilon_submissions   : API tracking + idempotency (outbox)
--   platform.epsilon_*    : worker functions (service_role only;
--                           execute is revoked for anon/authenticated by 022)
--
-- Flow:
--   1. generator creates invoice + lines (status 'open')
--   2. platform.epsilon_enqueue_invoice() validates, freezes (snapshot +
--      locked_at) and queues a submission
--   3. gateway: epsilon_claim_submissions -> HTTP call -> epsilon_record_result
--   4. later MARK/UID/rejection: epsilon_apply_status
-- No dynamic SQL is used in this section.
-- =====================================================

-- 16.1 PLAN -> EPSILON ITEM / myDATA MAPPING
-- Deliberately NOT seeded: classification codes and VAT categories
-- must be confirmed by the accountant.

create table if not exists public.billing_item_mappings (
    id uuid primary key default gen_random_uuid(),

    item_key text not null unique,

    plan_id uuid references public.product_plans(id) on delete set null,

    description text,

    epsilon_item_id text,
    epsilon_item_code text not null,

    mydata_income_class_type text not null,
    mydata_income_class_category text not null,

    default_vat_rate numeric(5,2) not null
        check (default_vat_rate >= 0 and default_vat_rate <= 100),
    vat_exemption_category text,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint chk_billing_item_exemption
        check (default_vat_rate > 0 or vat_exemption_category is not null)
);

create unique index if not exists uq_billing_item_mappings_plan
on public.billing_item_mappings (plan_id)
where plan_id is not null and is_active;

drop trigger if exists trg_billing_item_mappings_updated_at on public.billing_item_mappings;

create trigger trg_billing_item_mappings_updated_at
before update on public.billing_item_mappings
for each row execute function platform.set_updated_at();


-- 16.2 AUTO-FILL LINE DEFAULTS FROM THE MAPPING
-- The generator only sets product_plan_id; item code, classification
-- and VAT come from the mapping unless explicitly provided.

create or replace function public.fill_invoice_line_billing_defaults()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_map public.billing_item_mappings;
begin
    if new.product_plan_id is null then
        return new;
    end if;

    select m.*
    into v_map
    from public.billing_item_mappings m
    where m.plan_id = new.product_plan_id
      and m.is_active;

    if v_map.id is null then
        return new;
    end if;

    new.epsilon_item_code := coalesce(new.epsilon_item_code, v_map.epsilon_item_code);
    new.mydata_income_class_type := coalesce(new.mydata_income_class_type, v_map.mydata_income_class_type);
    new.mydata_income_class_category := coalesce(new.mydata_income_class_category, v_map.mydata_income_class_category);
    new.vat_rate := coalesce(new.vat_rate, v_map.default_vat_rate);
    new.vat_exemption_category := coalesce(new.vat_exemption_category, v_map.vat_exemption_category);

    return new;
end;
$$;

drop trigger if exists trg_invoice_lines_fill_billing_defaults on public.invoice_lines;

create trigger trg_invoice_lines_fill_billing_defaults
before insert on public.invoice_lines
for each row execute function public.fill_invoice_line_billing_defaults();


-- 16.3 IMMUTABLE SNAPSHOT

create table if not exists public.invoice_snapshots (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id),
    invoice_id uuid not null references public.invoices(id),

    version int not null,

    snapshot jsonb not null,
    snapshot_hash text not null,

    created_at timestamptz not null default now(),

    unique (invoice_id, version)
);

create index if not exists idx_invoice_snapshots_tenant
on public.invoice_snapshots (tenant_id);

do $$
begin
    if not exists (
        select 1 from pg_constraint where conname = 'fk_invoices_snapshot'
    ) then
        alter table public.invoices
            add constraint fk_invoices_snapshot
            foreign key (snapshot_id) references public.invoice_snapshots(id);
    end if;
end;
$$;

create or replace function platform.deny_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    raise exception '% on % is not allowed (immutable)', tg_op, tg_table_name;
end;
$$;

drop trigger if exists trg_invoice_snapshots_immutable on public.invoice_snapshots;

create trigger trg_invoice_snapshots_immutable
before update or delete on public.invoice_snapshots
for each row execute function platform.deny_mutation();


-- 16.4 API TRACKING + IDEMPOTENCY

create table if not exists public.epsilon_submissions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id),
    invoice_id uuid not null references public.invoices(id),
    snapshot_id uuid not null references public.invoice_snapshots(id),

    kind text not null default 'issue'
        check (kind in ('issue', 'credit', 'cancel')),

    idempotency_key text not null unique,

    -- Sent to Epsilon as RefDocCode.
    ref_doc_code text not null,
    request_hash text not null,

    status text not null default 'pending'
        check (status in ('pending', 'in_flight', 'succeeded', 'failed', 'needs_review')),

    attempts int not null default 0,
    next_attempt_at timestamptz not null default now(),

    locked_by text,
    locked_at timestamptz,

    http_status int,
    response jsonb,
    error text,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    completed_at timestamptz
);

-- At most one live or successful submission per invoice and kind.
create unique index if not exists uq_epsilon_submissions_active
on public.epsilon_submissions (invoice_id, kind)
where status in ('pending', 'in_flight', 'succeeded');

create index if not exists idx_epsilon_submissions_queue
on public.epsilon_submissions (next_attempt_at)
where status = 'pending';

create index if not exists idx_epsilon_submissions_tenant
on public.epsilon_submissions (tenant_id);


-- 16.5 GUARDS: A FROZEN INVOICE IS A FISCAL DOCUMENT
-- Only status/payment/Epsilon fields may still change.
-- Corrections are made with a credit note.
-- Intended side effect: a tenant with issued invoices cannot be
-- hard-deleted (fiscal retention) - anonymise instead.

create or replace function platform.invoices_guard_locked()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_allowed constant text[] := array[
        'status', 'payment_status', 'paid_at', 'updated_at',
        'epsilon_document_id', 'epsilon_uid', 'epsilon_mark',
        'epsilon_status', 'epsilon_response',
        'epsilon_submitted_at', 'epsilon_accepted_at', 'epsilon_last_error'
    ];
begin
    if old.locked_at is null then
        return case when tg_op = 'DELETE' then old else new end;
    end if;

    if tg_op = 'DELETE' then
        raise exception 'invoice % is issued and cannot be deleted', old.id;
    end if;

    if (to_jsonb(old) - v_allowed) is distinct from (to_jsonb(new) - v_allowed) then
        raise exception 'invoice % is issued: financial fields cannot be changed (use a credit note)', old.id;
    end if;

    return new;
end;
$$;

drop trigger if exists trg_invoices_guard_locked on public.invoices;

create trigger trg_invoices_guard_locked
before update or delete on public.invoices
for each row execute function platform.invoices_guard_locked();


create or replace function platform.invoice_lines_guard_locked()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_id uuid;
begin
    foreach v_id in array (
        case tg_op
            when 'INSERT' then array[new.invoice_id]
            when 'DELETE' then array[old.invoice_id]
            else array[old.invoice_id, new.invoice_id]
        end
    ) loop
        if exists (
            select 1 from public.invoices i
            where i.id = v_id and i.locked_at is not null
        ) then
            raise exception 'invoice % is issued: lines cannot be changed', v_id;
        end if;
    end loop;

    return case when tg_op = 'DELETE' then old else new end;
end;
$$;

drop trigger if exists trg_invoice_lines_guard_locked on public.invoice_lines;

create trigger trg_invoice_lines_guard_locked
before insert or update or delete on public.invoice_lines
for each row execute function platform.invoice_lines_guard_locked();


-- 16.6 ENQUEUE: VALIDATE, FREEZE, QUEUE (idempotent)

create or replace function platform.epsilon_enqueue_invoice(
    p_invoice_id uuid,
    p_kind text default 'issue'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_inv public.invoices%rowtype;
    v_cust public.billing_customers%rowtype;
    v_sub public.epsilon_submissions%rowtype;
    v_lines jsonb;
    v_line_count int;
    v_incomplete int;
    v_inconsistent int;
    v_sum_net numeric;
    v_sum_disc numeric;
    v_sum_vat numeric;
    v_corr_mark text;
    v_snap jsonb;
    v_snap_id uuid;
    v_version int;
    v_hash text;
    v_key text;
    v_new boolean := false;
begin
    if p_kind not in ('issue', 'credit', 'cancel') then
        raise exception 'unknown submission kind: %', p_kind;
    end if;

    select * into v_inv
    from public.invoices i
    where i.id = p_invoice_id
    for update;

    if not found then
        raise exception 'invoice % not found', p_invoice_id;
    end if;

    if p_kind = 'issue' and v_inv.document_type <> 'invoice' then
        raise exception 'kind issue requires an invoice';
    end if;
    if p_kind = 'credit' and v_inv.document_type <> 'credit_note' then
        raise exception 'kind credit requires a credit note';
    end if;

    if v_inv.locked_at is null then

        if v_inv.status not in ('open', 'paid') then
            raise exception 'invoice % has status %: only open or paid invoices can be issued',
                p_invoice_id, v_inv.status;
        end if;

        -- ---- billing customer ----
        if v_inv.billing_customer_id is null then
            raise exception 'invoice %: billing customer is missing', p_invoice_id;
        end if;

        select * into v_cust
        from public.billing_customers c
        where c.id = v_inv.billing_customer_id
          and c.tenant_id = v_inv.tenant_id;

        if not found then
            raise exception 'invoice %: billing customer does not belong to this tenant', p_invoice_id;
        end if;

        if v_cust.customer_type = 'business' and v_cust.vat_number is null then
            raise exception 'invoice %: business customer has no VAT number', p_invoice_id;
        end if;

        -- ---- document type / credit note ----
        v_inv.mydata_document_type := coalesce(
            v_inv.mydata_document_type,
            case v_inv.document_type when 'credit_note' then '5.1' else '2.1' end
        );

        if v_inv.document_type = 'credit_note' then
            select i.epsilon_mark into v_corr_mark
            from public.invoices i
            where i.id = v_inv.credited_invoice_id;

            if v_corr_mark is null then
                raise exception 'credit note %: the original invoice has no MARK yet', p_invoice_id;
            end if;
            v_inv.epsilon_correlated_mark := v_corr_mark;
        end if;

        -- ---- lines ----
        select
            coalesce(jsonb_agg(to_jsonb(l) order by l.sort_order, l.created_at, l.id), '[]'::jsonb),
            count(*),
            count(*) filter (where
                l.vat_rate is null
                or l.epsilon_item_code is null
                or l.mydata_income_class_type is null
                or l.mydata_income_class_category is null
                or (l.vat_rate = 0 and l.vat_exemption_category is null)),
            count(*) filter (where
                l.gross_amount <> l.line_amount - l.discount_amount + l.vat_amount),
            coalesce(sum(l.line_amount), 0),
            coalesce(sum(l.discount_amount), 0),
            coalesce(sum(l.vat_amount), 0)
        into v_lines, v_line_count, v_incomplete, v_inconsistent,
             v_sum_net, v_sum_disc, v_sum_vat
        from public.invoice_lines l
        where l.invoice_id = p_invoice_id;

        if v_line_count = 0 then
            raise exception 'invoice %: no lines', p_invoice_id;
        end if;
        if v_incomplete > 0 then
            raise exception 'invoice %: % line(s) without VAT rate, Epsilon item code or myDATA classification',
                p_invoice_id, v_incomplete;
        end if;
        if v_inconsistent > 0 then
            raise exception 'invoice %: % line(s) where gross <> net - discount + VAT',
                p_invoice_id, v_inconsistent;
        end if;
        if v_sum_net <> v_inv.subtotal
           or v_sum_disc <> v_inv.discount_amount
           or v_sum_vat <> v_inv.tax_amount
           or v_inv.total_amount <> v_inv.subtotal - v_inv.discount_amount + v_inv.tax_amount then
            raise exception 'invoice %: invoice totals do not match the lines', p_invoice_id;
        end if;

        -- ---- freeze ----
        v_snap := jsonb_build_object(
            'schema_version', 1,
            'invoice', to_jsonb(v_inv),
            'lines', v_lines,
            'billing_customer', to_jsonb(v_cust)
        );
        v_hash := encode(sha256(convert_to(v_snap::text, 'UTF8')), 'hex');

        select coalesce(max(s.version), 0) + 1
        into v_version
        from public.invoice_snapshots s
        where s.invoice_id = p_invoice_id;

        insert into public.invoice_snapshots (tenant_id, invoice_id, version, snapshot, snapshot_hash)
        values (v_inv.tenant_id, p_invoice_id, v_version, v_snap, v_hash)
        returning id into v_snap_id;

        update public.invoices i
        set
            locked_at = now(),
            snapshot_id = v_snap_id,
            epsilon_status = 'queued',
            mydata_document_type = v_inv.mydata_document_type,
            epsilon_correlated_mark = v_inv.epsilon_correlated_mark
        where i.id = p_invoice_id;

    else
        v_snap_id := v_inv.snapshot_id;

        select s.version, s.snapshot_hash
        into v_version, v_hash
        from public.invoice_snapshots s
        where s.id = v_snap_id;
    end if;

    v_key := 'inv:' || p_invoice_id::text || ':' || p_kind || ':s' || v_version::text;

    select * into v_sub
    from public.epsilon_submissions es
    where es.idempotency_key = v_key
    for update;

    if found then
        -- Same snapshot, same key: re-queue only a failed/needs_review one.
        if v_sub.status in ('failed', 'needs_review') then
            update public.epsilon_submissions es
            set status = 'pending', next_attempt_at = now(), error = null, updated_at = now()
            where es.id = v_sub.id;

            update public.invoices i
            set epsilon_status = 'queued', epsilon_last_error = null
            where i.id = p_invoice_id and i.epsilon_status = 'error';
        end if;
        return v_sub.id;
    end if;

    insert into public.epsilon_submissions (
        tenant_id, invoice_id, snapshot_id, kind,
        idempotency_key, ref_doc_code, request_hash
    )
    values (
        v_inv.tenant_id, p_invoice_id, v_snap_id, p_kind,
        v_key, 'SS-' || p_invoice_id::text, v_hash
    )
    returning id into v_sub.id;

    perform platform.log_audit(
        'invoice.queued_for_epsilon',
        'invoice',
        p_invoice_id,
        jsonb_build_object('kind', p_kind, 'snapshot_version', v_version)
    );

    return v_sub.id;
end;
$$;


-- 16.7 CLAIM WORK (parallel workers are safe)

create or replace function platform.epsilon_claim_submissions(
    p_worker text,
    p_limit int default 10
)
returns setof public.epsilon_submissions
language sql
security definer
set search_path = ''
as $$
    update public.epsilon_submissions s
    set
        status = 'in_flight',
        locked_by = p_worker,
        locked_at = now(),
        attempts = s.attempts + 1,
        updated_at = now()
    where s.id in (
        select q.id
        from public.epsilon_submissions q
        where q.status = 'pending'
          and q.next_attempt_at <= now()
        order by q.next_attempt_at
        limit greatest(p_limit, 1)
        for update skip locked
    )
    returning s.*;
$$;


-- 16.8 STUCK IN-FLIGHT: NEVER RETRY AUTOMATICALLY
-- The call may have succeeded at Epsilon without the result being
-- recorded; an automatic retry could create a second fiscal document.

create or replace function platform.epsilon_flag_stuck(p_minutes int default 10)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_n int;
begin
    with stuck as (
        update public.epsilon_submissions s
        set
            status = 'needs_review',
            error = 'in_flight too long: verify in Epsilon before re-queueing',
            updated_at = now()
        where s.status = 'in_flight'
          and s.locked_at < now() - make_interval(mins => p_minutes)
        returning s.invoice_id
    )
    update public.invoices i
    set
        epsilon_status = 'error',
        epsilon_last_error = 'submission stuck: verify in Epsilon'
    from stuck
    where i.id = stuck.invoice_id;

    get diagnostics v_n = row_count;
    return v_n;
end;
$$;


-- 16.9 RECORD THE RESULT OF AN API CALL

create or replace function platform.epsilon_record_result(
    p_submission_id uuid,
    p_http_status int,
    p_response jsonb default null,
    p_document_id text default null,
    p_uid text default null,
    p_mark text default null,
    p_error text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_sub public.epsilon_submissions%rowtype;
    v_retryable boolean;
    v_msg text;
begin
    select * into v_sub
    from public.epsilon_submissions s
    where s.id = p_submission_id
    for update;

    if not found then
        raise exception 'submission % not found', p_submission_id;
    end if;

    if v_sub.status <> 'in_flight' then
        raise exception 'submission % has status %, expected in_flight', p_submission_id, v_sub.status;
    end if;

    if p_error is null and p_http_status between 200 and 299 then

        update public.epsilon_submissions s
        set
            status = 'succeeded',
            http_status = p_http_status,
            response = p_response,
            error = null,
            completed_at = now(),
            updated_at = now(),
            locked_by = null,
            locked_at = null
        where s.id = p_submission_id;

        update public.invoices i
        set
            epsilon_document_id = coalesce(p_document_id, i.epsilon_document_id),
            epsilon_uid = coalesce(p_uid, i.epsilon_uid),
            epsilon_mark = coalesce(p_mark, i.epsilon_mark),
            epsilon_response = p_response,
            epsilon_submitted_at = coalesce(i.epsilon_submitted_at, now()),
            epsilon_accepted_at = case
                when coalesce(p_mark, i.epsilon_mark) is not null then now()
                else i.epsilon_accepted_at end,
            epsilon_status = case
                when coalesce(p_mark, i.epsilon_mark) is not null then 'accepted'
                else 'submitted' end,
            epsilon_last_error = null
        where i.id = v_sub.invoice_id;

        perform platform.log_audit(
            'invoice.epsilon_submitted',
            'invoice',
            v_sub.invoice_id,
            jsonb_build_object('submission_id', p_submission_id, 'http_status', p_http_status)
        );

        return 'succeeded';
    end if;

    v_msg := coalesce(p_error, 'http ' || coalesce(p_http_status::text, 'timeout'));

    -- 4xx (except 408/429) is a validation error: retrying will not help.
    v_retryable := p_http_status is null
                   or p_http_status in (408, 429)
                   or p_http_status >= 500;

    if v_retryable and v_sub.attempts < 8 then

        update public.epsilon_submissions s
        set
            status = 'pending',
            http_status = p_http_status,
            response = p_response,
            error = v_msg,
            next_attempt_at = now() + least(
                make_interval(mins => v_sub.attempts * v_sub.attempts),
                interval '6 hours'
            ),
            updated_at = now(),
            locked_by = null,
            locked_at = null
        where s.id = p_submission_id;

        update public.invoices i
        set epsilon_last_error = v_msg
        where i.id = v_sub.invoice_id;

        return 'retry_scheduled';
    end if;

    update public.epsilon_submissions s
    set
        status = 'needs_review',
        http_status = p_http_status,
        response = p_response,
        error = v_msg,
        updated_at = now(),
        locked_by = null,
        locked_at = null
    where s.id = p_submission_id;

    update public.invoices i
    set
        epsilon_status = 'error',
        epsilon_response = p_response,
        epsilon_last_error = v_msg
    where i.id = v_sub.invoice_id;

    perform platform.log_audit(
        'invoice.epsilon_needs_review',
        'invoice',
        v_sub.invoice_id,
        jsonb_build_object('submission_id', p_submission_id, 'error', v_msg)
    );

    return 'needs_review';
end;
$$;


-- 16.10 LATER STATUS UPDATE (polling / webhook): UID, MARK, rejection

create or replace function platform.epsilon_apply_status(
    p_invoice_id uuid,
    p_status text,
    p_document_id text default null,
    p_uid text default null,
    p_mark text default null,
    p_response jsonb default null,
    p_error text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_inv public.invoices%rowtype;
begin
    if p_status not in ('submitted', 'accepted', 'rejected', 'error') then
        raise exception 'invalid status %', p_status;
    end if;

    select * into v_inv
    from public.invoices i
    where i.id = p_invoice_id
    for update;

    if not found then
        raise exception 'invoice % not found', p_invoice_id;
    end if;

    if p_status = 'accepted' and coalesce(p_mark, v_inv.epsilon_mark) is null then
        raise exception 'invoice %: accepted requires a MARK', p_invoice_id;
    end if;

    update public.invoices i
    set
        epsilon_status = p_status,
        epsilon_document_id = coalesce(p_document_id, i.epsilon_document_id),
        epsilon_uid = coalesce(p_uid, i.epsilon_uid),
        epsilon_mark = coalesce(p_mark, i.epsilon_mark),
        epsilon_response = coalesce(p_response, i.epsilon_response),
        epsilon_accepted_at = case
            when p_status = 'accepted' then now() else i.epsilon_accepted_at end,
        epsilon_last_error = case
            when p_status in ('rejected', 'error') then p_error else null end
    where i.id = p_invoice_id;

    perform platform.log_audit(
        'invoice.epsilon_status',
        'invoice',
        p_invoice_id,
        jsonb_build_object('status', p_status)
    );
end;
$$;


-- =====================================================
-- 17. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('012_commerce_engine', 'REV1', false)
on conflict (migration_name) do nothing;