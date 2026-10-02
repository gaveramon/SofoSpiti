-- =====================================================
-- REV2 GREENFIELD BASELINE
-- 012_COMMERCE_ENGINE.SQL
-- =====================================================
-- COMMERCE DOMAIN
-- 012 OWNS:
--   - subscription product plans
--   - plan pricing
--   - feature entitlements
--   - subscription <-> plan relationship
--   - subscription cancellation per end of month
--   - upsell rules
--   - billing customers (fiscal identity used on invoices)
--   - invoices (incl. credit notes)
--   - invoice lines
--   - discount codes
--   - discount redemptions
--   - Epsilon e-invoicing outbox, immutable invoice snapshots
--     and plan -> Epsilon item / myDATA classification mapping
-- 012 DOES NOT OWN:
--   - tenants / customer identity
--   - customer accounts
--   - physical product catalog
--   - device bundles / BOM
--   - logistics
--   - fulfilment
--   - warehouses
--   - inventory / stock
--   - stock movements
--   - payment execution
--   - payment provider credentials
--   - payment webhooks
-- OWNERSHIP:
--   002 CORE SaaS
--       subscriptions baseline
--             │
--             ↓
--   012 COMMERCE
--       plans
--       pricing
--       entitlements
--       discounts
--       invoices
--   003 CUSTOMER / CRM
--       customer accounts
--       customer-account discounts
--             │
--             ↓
--       012 applies commercial effect
--   010 DEVICE / BOM
--             │
--             ↓
--   011 LOGISTICS
--       fulfilment
--       warehouses
--       shipping
--   018 INVENTORY
--       stock
--       reservations
--       movements
--   000 PLATFORM EXECUTION
--       payment execution
--       payment provider webhooks
--
-- BILLING / E-INVOICING
--   Supabase (012) decides WHAT is invoiced: billing customer,
--   lines, VAT, discounts, credit notes.
--   Epsilon issues the official electronic invoice and
--   transmits it to AADE/myDATA (section 27A).
--   The portal only reads; it never calls Epsilon.
-- =====================================================
-- =====================================================
-- 0. PRECONDITIONS
-- =====================================================
do $$
begin
if to_regclass('public.tenants') is null then
    raise exception
        '012 requires public.tenants from the core SaaS layer';
end if;

if to_regclass('public.subscriptions') is null then
    raise exception
        '012 requires public.subscriptions from the core SaaS layer';
end if;

if to_regclass('platform.schema_migrations') is null then
    raise exception
        '012 requires platform.schema_migrations';
end if;

if to_regclass('public.crm_companies') is null then
    raise exception
        '012 requires public.crm_companies from the CRM layer (003)';
end if;
end;
$$;


-- =====================================================
-- 1. SUBSCRIPTION PRODUCT PLANS
-- =====================================================
--
-- Commercial subscription catalog.
--
-- IMPORTANT:
-- This is NOT a physical product catalog.
-- Physical hardware/product inventory belongs to 018.
-- =====================================================

create table if not exists public.product_plans (
    id uuid primary key default gen_random_uuid(),

    name text not null,

    description text,

    tier subscription_tier not null,

    is_active boolean not null default true,

    is_default boolean not null default false,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    constraint chk_product_plans_name_nonempty
        check (btrim(name) <> '')
);


-- =====================================================
-- 2. PLAN PRICING
-- =====================================================
--
-- Pricing history is retained through effective_from.
--
-- Multiple historical/future prices for the same plan and
-- currency are therefore allowed.
-- =====================================================

create table if not exists public.plan_pricing (
    id uuid primary key default gen_random_uuid(),

    plan_id uuid not null
        references public.product_plans(id)
        on delete cascade,

    currency text not null default 'EUR',

    monthly_price numeric(12,2),

    yearly_price numeric(12,2),

    effective_from timestamptz not null default now(),

    created_at timestamptz not null default now(),

    constraint uq_plan_pricing_effective
        unique (plan_id, currency, effective_from),

    constraint chk_plan_pricing_currency
        check (
            char_length(currency) = 3
            and currency = upper(currency)
        ),

    constraint chk_plan_pricing_monthly_nonnegative
        check (
            monthly_price is null
            or monthly_price >= 0
        ),

    constraint chk_plan_pricing_yearly_nonnegative
        check (
            yearly_price is null
            or yearly_price >= 0
        ),

    constraint chk_plan_pricing_has_price
        check (
            monthly_price is not null
            or yearly_price is not null
        )
);


-- =====================================================
-- 3. FEATURE ENTITLEMENTS
-- =====================================================

create table if not exists public.feature_entitlements (
    id uuid primary key default gen_random_uuid(),

    plan_id uuid not null
        references public.product_plans(id)
        on delete cascade,

    feature_key text not null,

    enabled boolean not null default true,

    created_at timestamptz not null default now(),

    constraint uq_feature_entitlements_plan_feature
        unique (plan_id, feature_key),

    constraint chk_feature_entitlements_key_nonempty
        check (btrim(feature_key) <> '')
);


-- =====================================================
-- 4. UPSELL RULES
-- =====================================================
--
-- Commercial subscription recommendations only.
--
-- Hardware recommendations belong outside Commerce.
-- Package recommendations belong outside Commerce.
-- =====================================================

create table if not exists public.upsell_rules (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid
        references public.tenants(id)
        on delete cascade,

    trigger_event text not null,

    recommended_plan_id uuid not null
        references public.product_plans(id)
        on delete restrict,

    rule_config jsonb not null default '{}'::jsonb,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    constraint chk_upsell_rules_trigger_nonempty
        check (btrim(trigger_event) <> '')
);


-- =====================================================
-- 5. SUBSCRIPTION -> PLAN RELATIONSHIP
-- =====================================================
--
-- subscriptions belongs to the Core SaaS domain.
-- 012 adds the commercial plan relationship.
-- =====================================================

alter table public.subscriptions
    add column if not exists plan_id uuid;


do $$
begin
    alter table public.subscriptions
        add constraint fk_subscriptions_plan
        foreign key (plan_id)
        references public.product_plans(id)
        on delete restrict;
exception
    when duplicate_object then
        null;
end;
$$;


-- Cancellation per end of month (see section 19A).
-- subscriptions has exactly one row per tenant (002).
alter table public.subscriptions
    add column if not exists cancel_requested_at timestamptz,
    add column if not exists cancel_effective_at timestamptz,
    add column if not exists cancel_reason text;


do $$
begin
    alter table public.subscriptions
        add constraint chk_subscriptions_cancellation
        check (
            (cancel_requested_at is null and cancel_effective_at is null)
            or (
                cancel_requested_at is not null
                and cancel_effective_at is not null
                and cancel_effective_at > cancel_requested_at
            )
        );
exception
    when duplicate_object then
        null;
end;
$$;


-- =====================================================
-- 5A. BILLING CUSTOMERS
-- =====================================================
--
-- Legal/fiscal identity a tenant is invoiced under.
--
-- Kept separate from the CRM company: an invoice is a fiscal
-- document and the data on it (name, VAT number, address)
-- must be stable. A CRM company may be linked for convenience.
--
-- Epsilon matches customers on VAT number (CustTin), so the VAT
-- number is mandatory for business customers at issue time.
-- =====================================================

create table if not exists public.billing_customers (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    crm_company_id uuid
        references public.crm_companies(id)
        on delete set null,

    customer_type text not null default 'business',

    legal_name text not null,

    trade_name text,

    vat_number text,

    tax_office text,

    country_code text not null default 'GR',

    address_line text,

    postal_code text,

    city text,

    billing_email text,

    -- Set by the Epsilon gateway, never by the portal.
    epsilon_customer_code text,

    is_default boolean not null default true,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    constraint chk_billing_customers_type
        check (customer_type in ('business', 'individual')),

    constraint chk_billing_customers_legal_name
        check (btrim(legal_name) <> ''),

    constraint chk_billing_customers_country
        check (country_code ~ '^[A-Z]{2}$')
);


-- =====================================================
-- 6. INVOICES
-- =====================================================
--
-- Commercial invoice SSOT.
--
-- Accounting/provider integrations consume this state.
-- They do not become the Commerce SSOT.
--
-- Lifecycle:
--   draft  -> discounts may be applied, lines may change
--   issued -> frozen by platform.epsilon_enqueue_invoice()
--             (snapshot + locked_at); only status/payment/
--             Epsilon fields may still change. Corrections are
--             made with a credit note, never by editing.
--
-- Credit notes are stored with POSITIVE amounts (as myDATA
-- type 5.1); the sign comes from document_type.
-- =====================================================

create table if not exists public.invoices (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    subscription_id uuid
        references public.subscriptions(id)
        on delete restrict,

    invoice_number text not null,

    status text not null default 'draft',

    currency text not null default 'EUR',

    subtotal numeric(12,2) not null default 0,

    discount_amount numeric(12,2) not null default 0,

    tax_amount numeric(12,2) not null default 0,

    total_amount numeric(12,2) not null default 0,

    issued_at timestamptz,

    due_at timestamptz,

    paid_at timestamptz,

    -- Service period covered by the invoice. Required for subscription
    -- invoices; used to stop billing after a cancellation (19A).
    period_start date,

    period_end date,

    -- ---- billing identity & document type ----

    billing_customer_id uuid
        references public.billing_customers(id)
        on delete restrict,

    document_type text not null default 'invoice',

    credited_invoice_id uuid
        references public.invoices(id)
        on delete restrict,

    credit_reason text,

    -- Derived from status; no second field to keep in sync.
    payment_status text generated always as (
        case
            when status = 'paid' then 'paid'
            when status in ('draft', 'void', 'cancelled') then 'not_applicable'
            else 'unpaid'
        end
    ) stored,

    -- ---- Epsilon / myDATA (written by platform.epsilon_* only) ----

    mydata_document_type text,

    epsilon_document_id text,

    epsilon_uid text,

    epsilon_mark text,

    -- Credit notes (5.x): MARK of the original invoice.
    epsilon_correlated_mark text,

    epsilon_status text not null default 'not_submitted',

    epsilon_response jsonb,

    epsilon_submitted_at timestamptz,

    epsilon_accepted_at timestamptz,

    epsilon_last_error text,

    -- Set when the invoice is frozen for Epsilon (section 27A).
    locked_at timestamptz,

    snapshot_id uuid,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    constraint uq_invoices_tenant_number
        unique (tenant_id, invoice_number),

    constraint chk_invoices_status
        check (
            status in (
                'draft',
                'issued',
                'sent',
                'paid',
                'overdue',
                'void',
                'cancelled'
            )
        ),

    constraint chk_invoices_currency
        check (
            char_length(currency) = 3
            and currency = upper(currency)
        ),

    constraint chk_invoices_subtotal_nonnegative
        check (subtotal >= 0),

    constraint chk_invoices_discount_nonnegative
        check (discount_amount >= 0),

    constraint chk_invoices_tax_nonnegative
        check (tax_amount >= 0),

    constraint chk_invoices_discount_not_above_subtotal
        check (discount_amount <= subtotal),

    constraint chk_invoices_total_nonnegative
        check (total_amount >= 0),

    constraint chk_invoices_total_consistency
        check (
            total_amount =
            round(subtotal - discount_amount + tax_amount, 2)
        ),

    constraint chk_invoices_period
        check (
            (period_start is null and period_end is null)
            or (
                period_start is not null
                and period_end is not null
                and period_end >= period_start
            )
        ),

    constraint chk_invoices_document_type
        check (document_type in ('invoice', 'credit_note')),

    constraint chk_invoices_credit_note_link
        check (
            (document_type = 'credit_note')
            = (credited_invoice_id is not null)
        ),

    constraint chk_invoices_mydata_document_type
        check (
            mydata_document_type is null
            or mydata_document_type ~ '^[0-9]{1,2}\.[0-9]{1,2}$'
        ),

    constraint chk_invoices_epsilon_status
        check (
            epsilon_status in (
                'not_submitted',
                'queued',
                'submitted',
                'accepted',
                'rejected',
                'error'
            )
        ),

    constraint chk_invoices_accepted_has_mark
        check (
            epsilon_status <> 'accepted'
            or epsilon_mark is not null
        ),

    constraint chk_invoices_locked_has_snapshot
        check (
            locked_at is null
            or snapshot_id is not null
        )
);


-- =====================================================
-- 7. INVOICE LINES
-- =====================================================
--
-- line_amount      = NET amount (quantity * unit_amount), before discount
-- discount_amount  = discount allocated to this line
-- vat_amount       = VAT on (line_amount - discount_amount)
-- gross_amount     = line_amount - discount_amount + vat_amount
--
-- gross is verified when the invoice is frozen for Epsilon.
-- =====================================================

create table if not exists public.invoice_lines (
    id uuid primary key default gen_random_uuid(),

    invoice_id uuid not null
        references public.invoices(id)
        on delete cascade,

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    description text not null,

    quantity numeric(12,3) not null default 1,

    unit_amount numeric(12,2) not null default 0,

    line_amount numeric(12,2) not null default 0,

    sort_order integer not null default 0,

    -- ---- product link, VAT and myDATA ----

    product_plan_id uuid
        references public.product_plans(id)
        on delete set null,

    vat_rate numeric(5,2),

    discount_amount numeric(12,2) not null default 0,

    vat_amount numeric(12,2) not null default 0,

    gross_amount numeric(12,2) not null default 0,

    -- Filled from billing_item_mappings (trigger in 27A);
    -- required when the invoice is frozen.
    epsilon_item_code text,

    mydata_income_class_type text,

    mydata_income_class_category text,

    vat_exemption_category text,

    created_at timestamptz not null default now(),

    constraint chk_invoice_lines_description
        check (btrim(description) <> ''),

    constraint chk_invoice_lines_quantity
        check (quantity > 0),

    constraint chk_invoice_lines_unit_amount
        check (unit_amount >= 0),

    constraint chk_invoice_lines_line_amount
        check (line_amount >= 0),

    constraint chk_invoice_lines_vat_rate
        check (
            vat_rate is null
            or (vat_rate >= 0 and vat_rate <= 100)
        ),

    constraint chk_invoice_lines_discount_amount
        check (discount_amount >= 0),

    constraint chk_invoice_lines_vat_amount
        check (vat_amount >= 0),

    constraint chk_invoice_lines_gross_amount
        check (gross_amount >= 0)
);


-- =====================================================
-- 8. DISCOUNT CODES
-- =====================================================

create table if not exists public.discount_codes (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid
        references public.tenants(id)
        on delete cascade,

    code text not null,

    discount_type text not null,

    value numeric(12,2) not null,

    currency text,

    applies_to_plan_id uuid
        references public.product_plans(id)
        on delete restrict,

    max_redemptions integer,

    redeemed_count integer not null default 0,

    valid_from timestamptz,

    valid_until timestamptz,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    constraint chk_discount_codes_code_nonempty
        check (btrim(code) <> ''),

    constraint chk_discount_codes_type
        check (
            discount_type in (
                'percentage',
                'fixed_amount'
            )
        ),

    constraint chk_discount_codes_value_nonnegative
        check (value >= 0),

    constraint chk_discount_codes_percentage
        check (
            discount_type <> 'percentage'
            or value <= 100
        ),

    constraint chk_discount_codes_currency
        check (
            currency is null
            or (
                char_length(currency) = 3
                and currency = upper(currency)
            )
        ),

    constraint chk_discount_codes_fixed_currency
        check (
            discount_type <> 'fixed_amount'
            or currency is not null
        ),

    constraint chk_discount_codes_max_redemptions
        check (
            max_redemptions is null
            or max_redemptions > 0
        ),

    constraint chk_discount_codes_redeemed_count
        check (redeemed_count >= 0),

    constraint chk_discount_codes_validity
        check (
            valid_until is null
            or valid_from is null
            or valid_until >= valid_from
        )
);


-- =====================================================
-- 9. DISCOUNT REDEMPTIONS
-- =====================================================

create table if not exists public.discount_redemptions (
    id uuid primary key default gen_random_uuid(),

    discount_code_id uuid not null
        references public.discount_codes(id)
        on delete restrict,

    tenant_id uuid not null
        references public.tenants(id)
        on delete cascade,

    invoice_id uuid
        references public.invoices(id)
        on delete restrict,

    subscription_id uuid
        references public.subscriptions(id)
        on delete restrict,

    amount_applied numeric(12,2) not null default 0,

    redeemed_at timestamptz not null default now(),

    constraint chk_discount_redemptions_amount
        check (amount_applied >= 0)
);


-- =====================================================
-- 10. NORMALIZE EXISTING COMMERCE CONSTRAINTS
-- =====================================================

alter table public.product_plans
    drop constraint if exists chk_product_plans_name_nonempty;

alter table public.product_plans
    add constraint chk_product_plans_name_nonempty
    check (btrim(name) <> '');


alter table public.plan_pricing
    drop constraint if exists chk_plan_pricing_currency;

alter table public.plan_pricing
    add constraint chk_plan_pricing_currency
    check (
        char_length(currency) = 3
        and currency = upper(currency)
    );


alter table public.discount_codes
    drop constraint if exists chk_discount_codes_currency;

alter table public.discount_codes
    add constraint chk_discount_codes_currency
    check (
        currency is null
        or (
            char_length(currency) = 3
            and currency = upper(currency)
        )
    );


-- =====================================================
-- 11. NORMALIZE DISCOUNT CODE VALUES
-- =====================================================

update public.discount_codes
set
    code = upper(btrim(code)),
    currency = case
        when currency is null then null
        else upper(btrim(currency))
    end;


-- =====================================================
-- 12. UNIQUE / PERFORMANCE INDEXES
-- =====================================================

create unique index if not exists uq_product_plans_name_ci
on public.product_plans (lower(name));


create unique index if not exists uq_product_plans_default
on public.product_plans (is_default)
where is_default = true;


create index if not exists idx_plan_pricing_plan_effective
on public.plan_pricing (
    plan_id,
    currency,
    effective_from desc
);


create index if not exists idx_feature_entitlements_plan
on public.feature_entitlements (plan_id);


create index if not exists idx_upsell_rules_tenant
on public.upsell_rules (tenant_id);


create index if not exists idx_upsell_rules_plan
on public.upsell_rules (recommended_plan_id);


create index if not exists idx_subscriptions_plan
on public.subscriptions (plan_id);


create unique index if not exists uq_billing_customers_default
on public.billing_customers (tenant_id)
where is_default;


create unique index if not exists uq_billing_customers_epsilon_code
on public.billing_customers (epsilon_customer_code)
where epsilon_customer_code is not null;


create index if not exists idx_billing_customers_tenant
on public.billing_customers (tenant_id);


create index if not exists idx_invoices_tenant
on public.invoices (tenant_id);


create index if not exists idx_invoices_subscription
on public.invoices (subscription_id);


create index if not exists idx_invoices_tenant_status
on public.invoices (tenant_id, status);


create index if not exists idx_invoices_billing_customer
on public.invoices (billing_customer_id);


create index if not exists idx_invoices_credited
on public.invoices (credited_invoice_id)
where credited_invoice_id is not null;


create index if not exists idx_invoices_epsilon_attention
on public.invoices (epsilon_status)
where epsilon_status in ('queued', 'error', 'rejected');


create unique index if not exists uq_invoices_epsilon_document_id
on public.invoices (epsilon_document_id)
where epsilon_document_id is not null;


create unique index if not exists uq_invoices_epsilon_uid
on public.invoices (epsilon_uid)
where epsilon_uid is not null;


create unique index if not exists uq_invoices_epsilon_mark
on public.invoices (epsilon_mark)
where epsilon_mark is not null;


create index if not exists idx_invoice_lines_invoice
on public.invoice_lines (invoice_id);


create index if not exists idx_invoice_lines_tenant
on public.invoice_lines (tenant_id);


create index if not exists idx_invoice_lines_plan
on public.invoice_lines (product_plan_id);


create unique index if not exists uq_discount_codes_global_ci
on public.discount_codes (lower(code))
where tenant_id is null;


create unique index if not exists uq_discount_codes_tenant_ci
on public.discount_codes (
    tenant_id,
    lower(code)
)
where tenant_id is not null;


create index if not exists idx_discount_codes_active
on public.discount_codes (
    is_active,
    valid_from,
    valid_until
);


create index if not exists idx_discount_redemptions_code
on public.discount_redemptions (discount_code_id);


create index if not exists idx_discount_redemptions_tenant
on public.discount_redemptions (tenant_id);


create index if not exists idx_discount_redemptions_invoice
on public.discount_redemptions (invoice_id);


create index if not exists idx_discount_redemptions_subscription
on public.discount_redemptions (subscription_id);


create unique index if not exists uq_discount_redemptions_invoice
on public.discount_redemptions (
    discount_code_id,
    invoice_id
)
where invoice_id is not null;


-- =====================================================
-- 13. SUBSCRIPTION PLAN REQUIRED
-- =====================================================
--
-- Active subscription states require a plan.
-- =====================================================

create or replace function public.enforce_subscription_plan_required()
returns trigger
language plpgsql
set search_path = ''
as $$
begin

    -- subscription_status enum: trial (not 'trialing').
    if new.status in (
        'active',
        'trial',
        'past_due'
    )
    and new.plan_id is null then

        raise exception
            'subscription plan_id is required for status %',
            new.status;

    end if;

    return new;

end;
$$;


-- =====================================================
-- 14. SYNC SUBSCRIPTION TIER FROM PLAN
-- =====================================================

create or replace function public.sync_subscription_tier_from_plan()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_tier public.subscription_tier;
begin

    if new.plan_id is null then
        return new;
    end if;

    select pp.tier
    into v_tier
    from public.product_plans pp
    where pp.id = new.plan_id;

    if not found then
        raise exception
            'subscription plan % not found',
            new.plan_id;
    end if;

    new.tier := v_tier;

    return new;

end;
$$;


-- =====================================================
-- 15. PREVENT SUBSCRIPTION TIER DRIFT
-- =====================================================

create or replace function public.prevent_subscription_tier_drift()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_tier public.subscription_tier;
begin

    if new.plan_id is null then
        return new;
    end if;

    select pp.tier
    into v_tier
    from public.product_plans pp
    where pp.id = new.plan_id;

    if not found then
        raise exception
            'subscription plan % not found',
            new.plan_id;
    end if;

    if new.tier <> v_tier then
        raise exception
            'subscription tier must match product plan tier';
    end if;

    return new;

end;
$$;


-- =====================================================
-- 16. PREVENT PRODUCT PLAN TIER DRIFT
-- =====================================================
--
-- Once a plan is used by subscriptions, its tier becomes
-- immutable. Create a new plan instead of changing the
-- commercial tier of an existing plan.
-- =====================================================

create or replace function public.prevent_product_plan_tier_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin

    if new.tier is distinct from old.tier
       and exists (
            select 1
            from public.subscriptions s
            where s.plan_id = old.id
       )
    then

        raise exception
            'product plan tier cannot change after the plan has been used by subscriptions';

    end if;

    return new;

end;
$$;


-- =====================================================
-- 17. INVOICE LINE TENANT CONSISTENCY
-- =====================================================

create or replace function public.enforce_invoice_line_tenant()
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

    if not found then
        raise exception
            'invoice % not found',
            new.invoice_id;
    end if;

    if new.tenant_id <> v_invoice_tenant then
        raise exception
            'invoice line tenant_id must match invoice tenant_id';
    end if;

    return new;

end;
$$;


-- =====================================================
-- 18. COMMERCE CHANGE SUBSCRIPTION PLAN
-- =====================================================

create or replace function public.commerce_change_subscription_plan(
    p_subscription_id uuid,
    p_plan_id uuid
)
returns public.subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_plan public.product_plans%rowtype;
    v_subscription public.subscriptions%rowtype;
begin

    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    select *
    into v_plan
    from public.product_plans pp
    where pp.id = p_plan_id
      and pp.is_active = true;

    if not found then
        raise exception
            'active product plan not found';
    end if;

    select *
    into v_subscription
    from public.subscriptions s
    where s.id = p_subscription_id
      and s.tenant_id = v_tid
    for update;

    if not found then
        raise exception
            'subscription not found';
    end if;

    update public.subscriptions
    set
        plan_id = v_plan.id
    where id = v_subscription.id
    returning *
    into v_subscription;

    perform platform.log_audit(
        'subscription.plan_changed',
        'subscription',
        v_subscription.id,
        jsonb_build_object(
            'plan_id', v_plan.id,
            'tier', v_plan.tier
        )
    );

    return v_subscription;

end;
$$;


-- =====================================================
-- 19. COMMERCE CREATE SUBSCRIPTION
-- =====================================================

create or replace function public.commerce_create_subscription(
    p_tenant_id uuid,
    p_plan_id uuid,
    p_status text default 'active'
)
returns public.subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_plan public.product_plans%rowtype;
    v_subscription public.subscriptions%rowtype;
begin

    if not public.is_platform_admin()
       and platform.current_tenant_id() is distinct from p_tenant_id then

        raise exception
            'tenant context mismatch';

    end if;

    select *
    into v_plan
    from public.product_plans pp
    where pp.id = p_plan_id
      and pp.is_active = true;

    if not found then
        raise exception
            'active product plan not found';
    end if;

    -- 002: exactly one subscription per tenant (provisioned when the
    -- tenant is created). Use change_subscription_plan to switch.
    if exists (
        select 1
        from public.subscriptions s
        where s.tenant_id = p_tenant_id
    ) then
        raise exception
            'tenant already has a subscription; use change_subscription_plan';
    end if;

    insert into public.subscriptions (
        tenant_id,
        plan_id,
        tier,
        status
    )
    values (
        p_tenant_id,
        v_plan.id,
        v_plan.tier,
        p_status::public.subscription_status
    )
    returning *
    into v_subscription;

    perform platform.log_audit(
        'subscription.created',
        'subscription',
        v_subscription.id,
        jsonb_build_object(
            'plan_id', v_plan.id,
            'tier', v_plan.tier
        )
    );

    return v_subscription;

end;
$$;


-- =====================================================
-- 19A. SUBSCRIPTION CANCELLATION (END OF MONTH)
-- =====================================================
--
-- Cancelling is only possible per end of the month: the
-- subscription stays 'active' (features and invoicing continue)
-- until cancel_effective_at, when the daily job
-- platform.expire_cancelled_subscriptions() sets 'cancelled'.
-- There is no mid-month cancellation.
--
-- Billing stops at cancel_effective_at; this is enforced in the
-- database (section 19B). Epsilon is not involved: it has no
-- subscription concept.
--
-- The month boundary is evaluated in platform.billing_timezone().
-- =====================================================

create or replace function platform.billing_timezone()
returns text
language sql
immutable
set search_path = ''
as $$
    select 'Europe/Athens'::text;
$$;


create or replace function public.commerce_cancel_subscription(
    p_reason text default null
)
returns public.subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_sub public.subscriptions%rowtype;
    v_effective timestamptz;
    v_effective_date date;
    v_drafts int;
begin

    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    select *
    into v_sub
    from public.subscriptions s
    where s.tenant_id = v_tid
    for update;

    if not found then
        raise exception 'subscription not found';
    end if;

    if v_sub.status not in ('active', 'trial', 'past_due') then
        raise exception
            'only an active, trial or past_due subscription can be cancelled (status: %)',
            v_sub.status;
    end if;

    if v_sub.cancel_requested_at is not null then
        raise exception
            'cancellation was already requested (effective %)',
            v_sub.cancel_effective_at;
    end if;

    -- First instant of next month in the billing time zone.
    v_effective := (
        date_trunc('month', timezone(platform.billing_timezone(), now()))
        + interval '1 month'
    ) at time zone platform.billing_timezone();

    update public.subscriptions
    set
        cancel_requested_at = now(),
        cancel_effective_at = v_effective,
        cancel_reason = nullif(btrim(coalesce(p_reason, '')), '')
    where id = v_sub.id
    returning *
    into v_sub;

    -- Draft invoices that were already generated for periods after the
    -- end date are cancelled (issued invoices are never touched).
    v_effective_date := (
        v_effective at time zone platform.billing_timezone()
    )::date;

    update public.invoices i
    set status = 'cancelled'
    where i.subscription_id = v_sub.id
      and i.status = 'draft'
      and i.document_type = 'invoice'
      and i.period_end >= v_effective_date;

    get diagnostics v_drafts = row_count;

    perform platform.log_audit(
        'subscription.cancellation_requested',
        'subscription',
        v_sub.id,
        jsonb_build_object(
            'effective_at', v_effective,
            'cancelled_draft_invoices', v_drafts
        )
    );

    return v_sub;

end;
$$;


create or replace function public.commerce_undo_cancel_subscription()
returns public.subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_sub public.subscriptions%rowtype;
begin

    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    select *
    into v_sub
    from public.subscriptions s
    where s.tenant_id = v_tid
    for update;

    if not found then
        raise exception 'subscription not found';
    end if;

    if v_sub.cancel_requested_at is null
       or v_sub.cancel_effective_at <= now() then
        raise exception 'there is no pending cancellation to undo';
    end if;

    update public.subscriptions
    set
        cancel_requested_at = null,
        cancel_effective_at = null,
        cancel_reason = null
    where id = v_sub.id
    returning *
    into v_sub;

    perform platform.log_audit(
        'subscription.cancellation_undone',
        'subscription',
        v_sub.id
    );

    return v_sub;

end;
$$;


-- Daily job (schedule outside this migration).
create or replace function platform.expire_cancelled_subscriptions()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_n int;
begin

    update public.subscriptions s
    set status = 'cancelled'
    where s.cancel_effective_at is not null
      and s.cancel_effective_at <= now()
      and s.status in ('active', 'trial', 'past_due');

    get diagnostics v_n = row_count;

    return v_n;

end;
$$;


-- =====================================================
-- 19B. NO BILLING AFTER THE CANCELLATION DATE
-- =====================================================
--
-- Enforced in the database, not only in the generator:
--   1. trigger on invoices: a subscription invoice must carry a
--      service period, and that period must end before
--      cancel_effective_at (local date in billing time zone).
--   2. the same check is repeated when an invoice is frozen for
--      Epsilon (platform.epsilon_enqueue_invoice), because a
--      draft may have been generated before the cancellation.
--   3. platform.billable_subscriptions() is the single list the
--      generator should use.
-- Credit notes are never blocked.
-- =====================================================

create or replace function public.enforce_invoice_subscription_term()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_effective timestamptz;
    v_effective_date date;
begin

    if new.subscription_id is null
       or new.document_type <> 'invoice' then
        return new;
    end if;

    if new.period_start is null or new.period_end is null then
        raise exception
            'a subscription invoice requires period_start and period_end';
    end if;

    select s.cancel_effective_at
    into v_effective
    from public.subscriptions s
    where s.id = new.subscription_id;

    if v_effective is null then
        return new;
    end if;

    v_effective_date := (
        v_effective at time zone platform.billing_timezone()
    )::date;

    if new.period_end >= v_effective_date then
        raise exception
            'subscription is cancelled as of %: the invoice period (% - %) extends past that date',
            v_effective_date, new.period_start, new.period_end;
    end if;

    return new;

end;
$$;


drop trigger if exists trg_invoices_subscription_term
on public.invoices;

create trigger trg_invoices_subscription_term
before insert or update of subscription_id, period_start, period_end, document_type
on public.invoices
for each row
execute function public.enforce_invoice_subscription_term();


-- Subscriptions the generator may bill for a given service period.
create or replace function platform.billable_subscriptions(
    p_period_start date,
    p_period_end date
)
returns setof public.subscriptions
language sql
stable
security definer
set search_path = ''
as $$
    select s.*
    from public.subscriptions s
    where s.status in ('active', 'past_due')
      and (
          s.cancel_effective_at is null
          or p_period_end < (
              s.cancel_effective_at at time zone platform.billing_timezone()
          )::date
      );
$$;


-- =====================================================
-- 20. DISCOUNT CALCULATION
-- =====================================================

create or replace function public.commerce_compute_discount_amount(
    p_discount_type text,
    p_discount_value numeric,
    p_subtotal numeric
)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
begin

    if p_subtotal is null or p_subtotal < 0 then
        raise exception 'subtotal must be non-negative';
    end if;

    if p_discount_value is null or p_discount_value < 0 then
        raise exception 'discount value must be non-negative';
    end if;

    if p_discount_type = 'percentage' then

        return least(
            p_subtotal,
            round(
                p_subtotal * (p_discount_value / 100),
                2
            )
        );

    elsif p_discount_type = 'fixed_amount' then

        return least(
            p_subtotal,
            round(p_discount_value, 2)
        );

    else

        raise exception
            'unsupported discount type: %',
            p_discount_type;

    end if;

end;
$$;


-- =====================================================
-- 21. FIND USABLE DISCOUNT CODE
-- =====================================================

create or replace function public.commerce_find_usable_discount_code(
    p_code text,
    p_plan_id uuid default null
)
returns public.discount_codes
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_code public.discount_codes%rowtype;
begin

    v_tid := platform.current_tenant_id();

    select dc.*
    into v_code
    from public.discount_codes dc
    where upper(btrim(dc.code)) = upper(btrim(p_code))

      and dc.is_active = true

      and (
          dc.tenant_id is null
          or dc.tenant_id = v_tid
      )

      and (
          dc.valid_from is null
          or dc.valid_from <= now()
      )

      and (
          dc.valid_until is null
          or dc.valid_until >= now()
      )

      and (
          dc.max_redemptions is null
          or dc.redeemed_count < dc.max_redemptions
      )

      and (
          dc.applies_to_plan_id is null
          or (
              p_plan_id is not null
              and dc.applies_to_plan_id = p_plan_id
          )
      )

    order by
        case
            when dc.tenant_id = v_tid then 0
            else 1
        end,
        dc.created_at

    limit 1
    for update;

    return v_code;

end;
$$;


-- =====================================================
-- 22. APPLY DISCOUNT TO INVOICE
-- =====================================================
--
-- Draft invoices only. The discount is distributed pro rata
-- over the invoice lines (rounding remainder on the last line)
-- and VAT is recomputed per line, so that lines and invoice
-- totals stay consistent for the Epsilon/myDATA submission.
-- Only one discount per invoice.
-- =====================================================

create or replace function public.commerce_apply_discount_to_invoice(
    p_invoice_id uuid,
    p_code text
)
returns public.invoices
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_invoice public.invoices%rowtype;
    v_subscription_plan uuid;
    v_discount public.discount_codes%rowtype;
    v_amount numeric(12,2);
    v_new_tax numeric(12,2);
begin

    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    select *
    into v_invoice
    from public.invoices i
    where i.id = p_invoice_id
      and i.tenant_id = v_tid
    for update;

    if not found then
        raise exception 'invoice not found';
    end if;

    if v_invoice.status not in ('draft') then
        raise exception
            'discounts can only be applied to draft invoices';
    end if;

    if v_invoice.document_type <> 'invoice' then
        raise exception
            'a discount cannot be applied to a credit note';
    end if;

    if v_invoice.locked_at is not null then
        raise exception
            'this invoice has already been issued';
    end if;

    if v_invoice.discount_amount > 0
       or exists (
            select 1
            from public.discount_redemptions r
            where r.invoice_id = v_invoice.id
       ) then
        raise exception
            'a discount was already applied to this invoice';
    end if;

    if v_invoice.subscription_id is not null then

        select s.plan_id
        into v_subscription_plan
        from public.subscriptions s
        where s.id = v_invoice.subscription_id
          and s.tenant_id = v_tid;

    end if;

    v_discount := public.commerce_find_usable_discount_code(
        p_code,
        v_subscription_plan
    );

    if v_discount.id is null then
        raise exception
            'usable discount code not found';
    end if;

    if v_discount.currency is not null
       and v_discount.currency <> v_invoice.currency then

        raise exception
            'discount currency does not match invoice currency';

    end if;

    v_amount := public.commerce_compute_discount_amount(
        v_discount.discount_type,
        v_discount.value,
        v_invoice.subtotal
    );

    if v_amount <= 0 then
        raise exception
            'discount code does not reduce this invoice';
    end if;

    if exists (
        select 1
        from public.invoice_lines il
        where il.invoice_id = v_invoice.id
    ) then

        -- Pro rata over the lines; remainder on the last line.
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
            where il.invoice_id = v_invoice.id
        ),
        alloc as (
            select
                o.id,
                o.line_amount,
                o.vat_rate,
                o.rn_last,
                case
                    when o.total_net > 0
                        then round(v_amount * o.line_amount / o.total_net, 2)
                    else 0
                end as share
            from ordered o
        ),
        fixed as (
            select
                a.id,
                a.line_amount,
                a.vat_rate,
                a.share + case
                    when a.rn_last = 1
                        then v_amount - sum(a.share) over ()
                    else 0
                end as disc
            from alloc a
        )
        update public.invoice_lines il
        set
            discount_amount = f.disc,
            vat_amount = round(
                (il.line_amount - f.disc) * coalesce(f.vat_rate, 0) / 100,
                2
            ),
            gross_amount = (il.line_amount - f.disc)
                + round(
                    (il.line_amount - f.disc) * coalesce(f.vat_rate, 0) / 100,
                    2
                )
        from fixed f
        where il.id = f.id;

        select coalesce(sum(il.vat_amount), 0)
        into v_new_tax
        from public.invoice_lines il
        where il.invoice_id = v_invoice.id;

    else

        -- Header-only invoice (no lines): scale tax proportionally
        -- (assumes a uniform tax rate on the invoice).
        v_new_tax := case
            when v_invoice.subtotal > 0
                then round(
                    v_invoice.tax_amount
                    * (v_invoice.subtotal - v_amount)
                    / v_invoice.subtotal,
                    2
                )
            else v_invoice.tax_amount
        end;

    end if;

    update public.invoices
    set
        discount_amount = v_amount,
        tax_amount = v_new_tax,
        total_amount = round(
            subtotal - v_amount + v_new_tax,
            2
        )
    where id = v_invoice.id
    returning *
    into v_invoice;

    insert into public.discount_redemptions (
        discount_code_id,
        tenant_id,
        invoice_id,
        subscription_id,
        amount_applied
    )
    values (
        v_discount.id,
        v_tid,
        v_invoice.id,
        v_invoice.subscription_id,
        v_amount
    );

    update public.discount_codes
    set
        redeemed_count = redeemed_count + 1
    where id = v_discount.id;

    perform platform.log_audit(
        'invoice.discount_applied',
        'invoice',
        v_invoice.id,
        jsonb_build_object(
            'discount_code_id', v_discount.id,
            'amount_applied', v_amount
        )
    );

    return v_invoice;

end;
$$;


-- =====================================================
-- 23. COMMERCE DOMAIN API
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
    v_inv record;
    v_plan public.product_plans%rowtype;
    v_result jsonb;
    v_limit int;
    v_offset int;
    v_plan_id uuid;
    v_target uuid;
    v_amount numeric(12,2);
    v_entitled boolean;
begin

    p_payload := coalesce(
        p_payload,
        '{}'::jsonb
    );

    case p_op


        -- =================================================
        -- PLAN: LIST
        -- =================================================

        when 'list_product_plans' then

            select coalesce(
                jsonb_agg(
                    jsonb_build_object(
                        'id', pp.id,
                        'name', pp.name,
                        'description', pp.description,
                        'tier', pp.tier,
                        'is_active', pp.is_active,
                        'is_default', pp.is_default,
                        'pricing', coalesce(
                            (
                                select jsonb_agg(
                                    jsonb_build_object(
                                        'id', px.id,
                                        'currency', px.currency,
                                        'monthly_price', px.monthly_price,
                                        'yearly_price', px.yearly_price,
                                        'effective_from', px.effective_from
                                    )
                                    order by px.effective_from desc
                                )
                                from public.plan_pricing px
                                where px.plan_id = pp.id
                            ),
                            '[]'::jsonb
                        ),
                        'entitlements', coalesce(
                            (
                                select jsonb_agg(
                                    jsonb_build_object(
                                        'feature_key', fe.feature_key,
                                        'enabled', fe.enabled
                                    )
                                    order by fe.feature_key
                                )
                                from public.feature_entitlements fe
                                where fe.plan_id = pp.id
                            ),
                            '[]'::jsonb
                        )
                    )
                    order by pp.tier, pp.name
                ),
                '[]'::jsonb
            )
            into v_result
            from public.product_plans pp
            where pp.is_active = true;

            return v_result;


        -- =================================================
        -- PLAN: GET
        -- =================================================

        when 'get_product_plan' then

            select jsonb_build_object(
                'id', pp.id,
                'name', pp.name,
                'description', pp.description,
                'tier', pp.tier,
                'is_active', pp.is_active,
                'is_default', pp.is_default,
                'pricing', coalesce(
                    (
                        select jsonb_agg(
                            jsonb_build_object(
                                'id', px.id,
                                'currency', px.currency,
                                'monthly_price', px.monthly_price,
                                'yearly_price', px.yearly_price,
                                'effective_from', px.effective_from
                            )
                            order by px.effective_from desc
                        )
                        from public.plan_pricing px
                        where px.plan_id = pp.id
                    ),
                    '[]'::jsonb
                ),
                'entitlements', coalesce(
                    (
                        select jsonb_agg(
                            jsonb_build_object(
                                'feature_key', fe.feature_key,
                                'enabled', fe.enabled
                            )
                            order by fe.feature_key
                        )
                        from public.feature_entitlements fe
                        where fe.plan_id = pp.id
                    ),
                    '[]'::jsonb
                )
            )
            into v_result
            from public.product_plans pp
            where pp.id = (p_payload->>'id')::uuid;

            if v_result is null then
                raise exception 'product plan not found';
            end if;

            return v_result;


        -- =================================================
        -- PLAN: CREATE
        -- PLATFORM ADMIN
        -- =================================================

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
                is_active,
                is_default
            )
            values (
                btrim(p_payload->>'name'),
                p_payload->>'description',
                (p_payload->>'tier')::public.subscription_tier,
                coalesce(
                    (p_payload->>'is_active')::boolean,
                    true
                ),
                coalesce(
                    (p_payload->>'is_default')::boolean,
                    false
                )
            )
            returning *
            into v_plan;

            if v_plan.is_default then

                update public.product_plans
                set is_default = false
                where id <> v_plan.id
                  and is_default = true;

            end if;

            perform platform.log_audit(
                'product_plan.created',
                'product_plan',
                v_plan.id
            );

            return to_jsonb(v_plan);


        -- =================================================
        -- PLAN: UPDATE
        -- PLATFORM ADMIN
        -- =================================================

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
                    when p_payload ? 'name'
                        then btrim(p_payload->>'name')
                    else pp.name
                end,

                description = case
                    when p_payload ? 'description'
                        then p_payload->>'description'
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
                end,

                is_default = case
                    when p_payload ? 'is_default'
                        then (p_payload->>'is_default')::boolean
                    else pp.is_default
                end

            where pp.id = (p_payload->>'id')::uuid

            returning *
            into v_plan;

            if not found then
                raise exception 'product plan not found';
            end if;

            if v_plan.is_default then

                update public.product_plans
                set is_default = false
                where id <> v_plan.id
                  and is_default = true;

            end if;

            perform platform.log_audit(
                'product_plan.updated',
                'product_plan',
                v_plan.id,
                p_payload - 'id'
            );

            return to_jsonb(v_plan);


        -- =================================================
        -- SUBSCRIPTION: CHANGE PLAN
        -- =================================================

        when 'change_subscription_plan', 'change_plan' then

            v_row := public.commerce_change_subscription_plan(
                (p_payload->>'subscription_id')::uuid,
                (p_payload->>'plan_id')::uuid
            );

            return to_jsonb(v_row);


        -- =================================================
        -- DISCOUNT: CREATE
        -- PLATFORM ADMIN
        -- =================================================

        when 'create_discount_code' then

            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;

            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            insert into public.discount_codes (
                tenant_id,
                code,
                discount_type,
                value,
                currency,
                applies_to_plan_id,
                max_redemptions,
                valid_from,
                valid_until,
                is_active
            )
            values (
                nullif(
                    p_payload->>'tenant_id',
                    ''
                )::uuid,

                upper(
                    btrim(p_payload->>'code')
                ),

                p_payload->>'discount_type',

                (p_payload->>'value')::numeric,

                case
                    when p_payload->>'currency' is null
                        then null
                    else upper(
                        btrim(p_payload->>'currency')
                    )
                end,

                nullif(
                    p_payload->>'applies_to_plan_id',
                    ''
                )::uuid,

                nullif(
                    p_payload->>'max_redemptions',
                    ''
                )::integer,

                nullif(
                    p_payload->>'valid_from',
                    ''
                )::timestamptz,

                nullif(
                    p_payload->>'valid_until',
                    ''
                )::timestamptz,

                coalesce(
                    (p_payload->>'is_active')::boolean,
                    true
                )
            )
            returning *
            into v_row;

            perform platform.log_audit(
                'discount_code.created',
                'discount_code',
                v_row.id
            );

            return to_jsonb(v_row);


        -- =================================================
        -- DISCOUNT: LIST
        -- PLATFORM ADMIN
        -- =================================================

        when 'list_discount_codes' then

            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;

            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            select coalesce(
                jsonb_agg(
                    to_jsonb(dc)
                    order by dc.created_at desc
                ),
                '[]'::jsonb
            )
            into v_result
            from public.discount_codes dc;

            return v_result;


        -- =================================================
        -- DISCOUNT: UPDATE
        -- PLATFORM ADMIN
        -- =================================================

        when 'update_discount_code' then

            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;

            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            update public.discount_codes dc
            set
                code = case
                    when p_payload ? 'code'
                        then upper(
                            btrim(p_payload->>'code')
                        )
                    else dc.code
                end,

                discount_type = case
                    when p_payload ? 'discount_type'
                        then p_payload->>'discount_type'
                    else dc.discount_type
                end,

                value = case
                    when p_payload ? 'value'
                        then (p_payload->>'value')::numeric
                    else dc.value
                end,

                currency = case
                    when p_payload ? 'currency'
                        then upper(
                            btrim(p_payload->>'currency')
                        )
                    else dc.currency
                end,

                applies_to_plan_id = case
                    when p_payload ? 'applies_to_plan_id'
                        then nullif(
                            p_payload->>'applies_to_plan_id',
                            ''
                        )::uuid
                    else dc.applies_to_plan_id
                end,

                max_redemptions = case
                    when p_payload ? 'max_redemptions'
                        then nullif(
                            p_payload->>'max_redemptions',
                            ''
                        )::integer
                    else dc.max_redemptions
                end,

                valid_from = case
                    when p_payload ? 'valid_from'
                        then nullif(
                            p_payload->>'valid_from',
                            ''
                        )::timestamptz
                    else dc.valid_from
                end,

                valid_until = case
                    when p_payload ? 'valid_until'
                        then nullif(
                            p_payload->>'valid_until',
                            ''
                        )::timestamptz
                    else dc.valid_until
                end,

                is_active = case
                    when p_payload ? 'is_active'
                        then (p_payload->>'is_active')::boolean
                    else dc.is_active
                end

            where dc.id = (p_payload->>'id')::uuid

            returning *
            into v_row;

            if not found then
                raise exception 'discount code not found';
            end if;

            perform platform.log_audit(
                'discount_code.updated',
                'discount_code',
                v_row.id,
                p_payload - 'id'
            );

            return to_jsonb(v_row);


        -- =================================================
        -- DISCOUNT: DEACTIVATE
        -- PLATFORM ADMIN
        -- =================================================

        when 'deactivate_discount_code' then

            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;

            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            update public.discount_codes
            set is_active = false
            where id = (p_payload->>'id')::uuid
            returning *
            into v_row;

            if not found then
                raise exception 'discount code not found';
            end if;

            perform platform.log_audit(
                'discount_code.deactivated',
                'discount_code',
                v_row.id
            );

            return to_jsonb(v_row);


        -- =================================================
        -- DISCOUNT: APPLY
        -- =================================================

        when 'apply_discount', 'apply_discount_to_invoice' then

            v_row := public.commerce_apply_discount_to_invoice(
                (p_payload->>'invoice_id')::uuid,
                p_payload->>'code'
            );

            return to_jsonb(v_row);


        -- =================================================
        -- ENTITLEMENTS: TENANT (READ ONLY)
        -- =================================================
        --
        -- Shape (Appsmith: {{ent.data.features.devices}}):
        --   {
        --     "plan": {"id", "name", "tier"} | null,
        --     "subscription_status": "<status>" | null,
        --     "cancel_effective_at": "<timestamp>" | null,
        --     "is_entitled": true | false,
        --     "features": {"<feature_key>": true | false}
        --   }
        --
        -- Features are granted only while the subscription status is
        -- active, trial or past_due. A cancellation requested for the
        -- end of the month keeps the status 'active' until the
        -- end-of-month job sets 'cancelled'.
        -- Otherwise is_entitled = false and features = {}.
        -- =================================================

        when 'get_tenant_entitlements' then

            v_tid := platform.current_tenant_id();

            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            -- Best subscription: entitled statuses first.
            select s.id, s.plan_id, s.status, s.cancel_effective_at
            into v_row
            from public.subscriptions s
            where s.tenant_id = v_tid
            order by
                case s.status
                    when 'active' then 1
                    when 'trial' then 2
                    when 'past_due' then 3
                    when 'pending' then 4
                    when 'suspended' then 5
                    when 'expired' then 6
                    when 'trial_expired' then 7
                    else 8
                end,
                s.id
            limit 1;

            v_entitled := v_row.id is not null
                and v_row.status in ('active', 'trial', 'past_due')
                and (
                    v_row.cancel_effective_at is null
                    or v_row.cancel_effective_at > now()
                );

            if v_row.id is null then
                return jsonb_build_object(
                    'plan', null,
                    'subscription_status', null,
                    'cancel_effective_at', null,
                    'is_entitled', false,
                    'features', '{}'::jsonb
                );
            end if;

            select jsonb_build_object(
                'plan', (
                    select jsonb_build_object(
                        'id', pp.id,
                        'name', pp.name,
                        'tier', pp.tier
                    )
                    from public.product_plans pp
                    where pp.id = v_row.plan_id
                ),
                'subscription_status', v_row.status,
                'cancel_effective_at', v_row.cancel_effective_at,
                'is_entitled', v_entitled,
                'features', case
                    when v_entitled
                        then coalesce(
                            (
                                select jsonb_object_agg(fe.feature_key, fe.enabled)
                                from public.feature_entitlements fe
                                where fe.plan_id = v_row.plan_id
                            ),
                            '{}'::jsonb
                        )
                    else '{}'::jsonb
                end
            )
            into v_result;

            return v_result;


        -- =================================================
        -- PLAN PRICING: LIST (tenants see active plans only)
        -- =================================================

        when 'list_plan_pricing' then

            select coalesce(
                jsonb_agg(
                    to_jsonb(t)
                    order by t.plan_id, t.currency, t.effective_from desc
                ),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    px.id,
                    px.plan_id,
                    px.currency,
                    px.monthly_price,
                    px.yearly_price,
                    px.effective_from
                from public.plan_pricing px
                join public.product_plans pp
                  on pp.id = px.plan_id
                where (public.is_platform_admin() or pp.is_active)
                  and (
                      nullif(p_payload->>'plan_id', '') is null
                      or px.plan_id = (p_payload->>'plan_id')::uuid
                  )
            ) t;

            return v_result;


        -- =================================================
        -- PLAN PRICING: CREATE / UPDATE / DELETE
        -- PLATFORM ADMIN
        -- History is retained: only FUTURE prices may be changed
        -- or removed; for a new price add a row with a later
        -- effective_from.
        -- =================================================

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
                upper(btrim(coalesce(p_payload->>'currency', 'EUR'))),
                nullif(p_payload->>'monthly_price', '')::numeric,
                nullif(p_payload->>'yearly_price', '')::numeric,
                coalesce(nullif(p_payload->>'effective_from', '')::timestamptz, now())
            )
            returning *
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

            if not exists (
                select 1
                from public.plan_pricing px
                where px.id = (p_payload->>'id')::uuid
                  and px.effective_from > now()
            ) then
                raise exception 'only future pricing can be changed; add a new price with a later effective_from';
            end if;

            update public.plan_pricing px
            set
                monthly_price = case
                    when p_payload ? 'monthly_price'
                        then nullif(p_payload->>'monthly_price', '')::numeric
                    else px.monthly_price
                end,

                yearly_price = case
                    when p_payload ? 'yearly_price'
                        then nullif(p_payload->>'yearly_price', '')::numeric
                    else px.yearly_price
                end,

                effective_from = case
                    when p_payload ? 'effective_from'
                        then (p_payload->>'effective_from')::timestamptz
                    else px.effective_from
                end

            where px.id = (p_payload->>'id')::uuid

            returning *
            into v_row;

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

            if not exists (
                select 1
                from public.plan_pricing px
                where px.id = (p_payload->>'id')::uuid
                  and px.effective_from > now()
            ) then
                raise exception 'only future pricing can be deleted';
            end if;

            delete from public.plan_pricing px
            where px.id = (p_payload->>'id')::uuid
            returning px.id
            into v_row;

            perform platform.log_audit(
                'plan_pricing.deleted',
                'plan_pricing',
                v_row.id
            );

            return jsonb_build_object('id', v_row.id, 'deleted', true);


        -- =================================================
        -- FEATURE ENTITLEMENTS: LIST (tenants: active plans only)
        -- =================================================

        when 'list_feature_entitlements' then

            select coalesce(
                jsonb_agg(
                    to_jsonb(t)
                    order by t.plan_id, t.feature_key
                ),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    fe.id,
                    fe.plan_id,
                    fe.feature_key,
                    fe.enabled
                from public.feature_entitlements fe
                join public.product_plans pp
                  on pp.id = fe.plan_id
                where (public.is_platform_admin() or pp.is_active)
                  and (
                      nullif(p_payload->>'plan_id', '') is null
                      or fe.plan_id = (p_payload->>'plan_id')::uuid
                  )
            ) t;

            return v_result;


        -- =================================================
        -- FEATURE ENTITLEMENTS: CREATE / UPDATE / DELETE
        -- PLATFORM ADMIN
        -- =================================================

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
                btrim(p_payload->>'feature_key'),
                coalesce((p_payload->>'enabled')::boolean, true)
            )
            returning *
            into v_row;

            perform platform.log_audit(
                'feature_entitlement.created',
                'feature_entitlement',
                v_row.id,
                jsonb_build_object('feature_key', v_row.feature_key)
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
                    when p_payload ? 'feature_key'
                        then btrim(p_payload->>'feature_key')
                    else fe.feature_key
                end,

                enabled = case
                    when p_payload ? 'enabled'
                        then (p_payload->>'enabled')::boolean
                    else fe.enabled
                end

            where fe.id = (p_payload->>'id')::uuid

            returning *
            into v_row;

            if not found then
                raise exception 'feature entitlement not found';
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
            where fe.id = (p_payload->>'id')::uuid
            returning fe.id, fe.feature_key
            into v_row;

            if not found then
                raise exception 'feature entitlement not found';
            end if;

            perform platform.log_audit(
                'feature_entitlement.deleted',
                'feature_entitlement',
                v_row.id,
                jsonb_build_object('feature_key', v_row.feature_key)
            );

            return jsonb_build_object('id', v_row.id, 'deleted', true);


        -- =================================================
        -- PLAN: DELETE
        -- PLATFORM ADMIN
        -- Plans that are in use are deactivated, never deleted.
        -- =================================================

        when 'delete_product_plan' then

            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;

            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            v_plan_id := (p_payload->>'id')::uuid;

            if exists (select 1 from public.subscriptions s where s.plan_id = v_plan_id) then
                raise exception 'plan is in use by subscriptions; deactivate it instead';
            end if;

            if exists (select 1 from public.invoice_lines il where il.product_plan_id = v_plan_id) then
                raise exception 'plan is referenced by invoice lines; deactivate it instead';
            end if;

            if exists (select 1 from public.upsell_rules ur where ur.recommended_plan_id = v_plan_id) then
                raise exception 'plan is used by upsell rules; remove those rules first';
            end if;

            if exists (select 1 from public.discount_codes dc where dc.applies_to_plan_id = v_plan_id) then
                raise exception 'plan is used by discount codes; deactivate it instead';
            end if;

            delete from public.product_plans pp
            where pp.id = v_plan_id
            returning pp.id, pp.name
            into v_row;

            if not found then
                raise exception 'product plan not found';
            end if;

            perform platform.log_audit(
                'product_plan.deleted',
                'product_plan',
                v_row.id,
                jsonb_build_object('name', v_row.name)
            );

            return jsonb_build_object('id', v_row.id, 'deleted', true);


        -- =================================================
        -- UPSELL RULES
        -- Tenant managers manage rules of their own tenant.
        -- Global rules (tenant_id null) are platform-admin only.
        -- =================================================

        when 'list_upsell_rules' then

            v_tid := platform.current_tenant_id();

            select coalesce(
                jsonb_agg(
                    to_jsonb(t)
                    order by t.created_at
                ),
                '[]'::jsonb
            )
            into v_result
            from (
                select
                    ur.id,
                    ur.tenant_id,
                    ur.trigger_event,
                    ur.recommended_plan_id,
                    ur.rule_config,
                    ur.is_active,
                    ur.created_at
                from public.upsell_rules ur
                where ur.is_active
                  and (
                      ur.tenant_id is null
                      or ur.tenant_id = v_tid
                  )
            ) t;

            return v_result;


        when 'create_upsell_rule' then

            v_tid := platform.current_tenant_id();

            if public.is_platform_admin() then
                v_target := nullif(p_payload->>'tenant_id', '')::uuid;
            else
                if v_tid is null then
                    raise exception 'no active tenant';
                end if;
                v_target := v_tid;
            end if;

            insert into public.upsell_rules (
                tenant_id,
                trigger_event,
                recommended_plan_id,
                rule_config,
                is_active
            )
            values (
                v_target,
                btrim(p_payload->>'trigger_event'),
                (p_payload->>'recommended_plan_id')::uuid,
                coalesce(p_payload->'rule_config', '{}'::jsonb),
                coalesce((p_payload->>'is_active')::boolean, true)
            )
            returning *
            into v_row;

            perform platform.log_audit(
                'upsell_rule.created',
                'upsell_rule',
                v_row.id
            );

            return to_jsonb(v_row);


        when 'update_upsell_rule' then

            v_tid := platform.current_tenant_id();

            update public.upsell_rules ur
            set
                trigger_event = case
                    when p_payload ? 'trigger_event'
                        then btrim(p_payload->>'trigger_event')
                    else ur.trigger_event
                end,

                recommended_plan_id = case
                    when p_payload ? 'recommended_plan_id'
                        then (p_payload->>'recommended_plan_id')::uuid
                    else ur.recommended_plan_id
                end,

                rule_config = case
                    when p_payload ? 'rule_config'
                        then coalesce(p_payload->'rule_config', '{}'::jsonb)
                    else ur.rule_config
                end,

                is_active = case
                    when p_payload ? 'is_active'
                        then (p_payload->>'is_active')::boolean
                    else ur.is_active
                end

            where ur.id = (p_payload->>'id')::uuid
              and (
                  public.is_platform_admin()
                  or ur.tenant_id = v_tid
              )

            returning *
            into v_row;

            if not found then
                raise exception 'upsell rule not found';
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

            delete from public.upsell_rules ur
            where ur.id = (p_payload->>'id')::uuid
              and (
                  public.is_platform_admin()
                  or ur.tenant_id = v_tid
              )
            returning ur.id
            into v_row;

            if not found then
                raise exception 'upsell rule not found';
            end if;

            perform platform.log_audit(
                'upsell_rule.deleted',
                'upsell_rule',
                v_row.id
            );

            return jsonb_build_object('id', v_row.id, 'deleted', true);


        -- =================================================
        -- DISCOUNT: VALIDATE (TENANT, no redemption)
        -- payload: code, optional plan_id, optional invoice_id
        -- (invoice_id adds the amount the discount would give)
        -- =================================================

        when 'validate_discount_code' then

            v_tid := platform.current_tenant_id();

            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            if nullif(btrim(coalesce(p_payload->>'code', '')), '') is null then
                raise exception 'code is required';
            end if;

            v_plan_id := coalesce(
                nullif(p_payload->>'plan_id', '')::uuid,
                (
                    select s.plan_id
                    from public.subscriptions s
                    where s.tenant_id = v_tid
                )
            );

            v_row := public.commerce_find_usable_discount_code(
                p_payload->>'code',
                v_plan_id
            );

            if v_row.id is null then
                return jsonb_build_object('valid', false);
            end if;

            v_amount := null;

            if nullif(p_payload->>'invoice_id', '') is not null then

                select public.commerce_compute_discount_amount(
                    v_row.discount_type,
                    v_row.value,
                    i.subtotal
                )
                into v_amount
                from public.invoices i
                where i.id = (p_payload->>'invoice_id')::uuid
                  and i.tenant_id = v_tid;

            end if;

            return jsonb_build_object(
                'valid', true,
                'discount_type', v_row.discount_type,
                'value', v_row.value,
                'currency', v_row.currency,
                'applies_to_plan_id', v_row.applies_to_plan_id,
                'amount', v_amount
            );


        -- =================================================
        -- DISCOUNT: REDEMPTIONS (TENANT)
        -- =================================================

        when 'list_discount_redemptions' then

            v_tid := platform.current_tenant_id();

            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            v_limit := least(greatest(coalesce(nullif(p_payload->>'limit', '')::int, 50), 1), 200);
            v_offset := greatest(coalesce(nullif(p_payload->>'offset', '')::int, 0), 0);

            select coalesce(
                jsonb_agg(
                    to_jsonb(t)
                    order by t.redeemed_at desc
                ),
                '[]'::jsonb
            )
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
                  and (
                      nullif(p_payload->>'invoice_id', '') is null
                      or r.invoice_id = (p_payload->>'invoice_id')::uuid
                  )
                order by r.redeemed_at desc
                limit v_limit
                offset v_offset
            ) t;

            return v_result;


        -- =================================================
        -- SUBSCRIPTION: CANCEL AT END OF MONTH (TENANT ADMIN)
        -- =================================================

        when 'cancel_subscription' then

            v_row := public.commerce_cancel_subscription(
                p_payload->>'reason'
            );

            return to_jsonb(v_row);


        when 'undo_cancel_subscription' then

            v_row := public.commerce_undo_cancel_subscription();

            return to_jsonb(v_row);


        -- =================================================
        -- INVOICES: LIST (TENANT, READ ONLY, drafts hidden)
        -- =================================================

        when 'list_invoices' then

            v_tid := platform.current_tenant_id();

            if v_tid is null then
                raise exception 'no active tenant';
            end if;

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
                    i.document_type,
                    i.credited_invoice_id,
                    i.credit_reason,
                    i.period_start,
                    i.period_end,
                    i.status,
                    i.payment_status,
                    i.currency,
                    i.subtotal,
                    i.discount_amount,
                    i.tax_amount,
                    i.total_amount,
                    i.issued_at,
                    i.due_at,
                    i.paid_at,
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


        -- =================================================
        -- INVOICES: GET (TENANT, READ ONLY)
        -- =================================================

        when 'get_invoice' then

            v_tid := platform.current_tenant_id();

            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            select jsonb_build_object(
                'invoice', to_jsonb(inv),
                'billing_customer', (
                    select jsonb_build_object(
                        'legal_name', bc.legal_name,
                        'trade_name', bc.trade_name,
                        'vat_number', bc.vat_number,
                        'tax_office', bc.tax_office,
                        'country_code', bc.country_code,
                        'address_line', bc.address_line,
                        'postal_code', bc.postal_code,
                        'city', bc.city
                    )
                    from public.billing_customers bc
                    where bc.id = inv.billing_customer_id
                ),
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
                    i.billing_customer_id,
                    i.invoice_number,
                    i.document_type,
                    i.credited_invoice_id,
                    i.credit_reason,
                    i.status,
                    i.payment_status,
                    i.currency,
                    i.subtotal,
                    i.discount_amount,
                    i.tax_amount,
                    i.total_amount,
                    i.issued_at,
                    i.due_at,
                    i.paid_at,
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
                raise exception 'invoice not found';
            end if;

            return v_result;


        -- =================================================
        -- BILLING CUSTOMER - TENANT
        -- =================================================

        when 'get_billing_customer' then

            v_tid := platform.current_tenant_id();

            if v_tid is null then
                raise exception 'no active tenant';
            end if;

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

            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            if nullif(btrim(coalesce(p_payload->>'legal_name', '')), '') is null then
                raise exception 'legal_name is required';
            end if;

            if coalesce(p_payload->>'customer_type', 'business') not in ('business', 'individual') then
                raise exception 'customer_type must be business or individual';
            end if;

            if coalesce(p_payload->>'customer_type', 'business') = 'business'
               and upper(coalesce(p_payload->>'country_code', 'GR')) = 'GR'
               and coalesce(p_payload->>'vat_number', '') !~ '^[0-9]{9}$' then
                raise exception 'a Greek business customer requires a 9-digit VAT number';
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
        -- =================================================

        when 'list_billing_item_mappings' then

            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;

            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

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

            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;

            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

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

            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;

            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            update public.billing_item_mappings bm
            set is_active = false
            where bm.id = (p_payload->>'id')::uuid
            returning bm.id, bm.item_key, bm.is_active
            into v_row;

            if not found then
                raise exception 'billing item mapping not found';
            end if;

            perform platform.log_audit(
                'billing_item_mapping.deactivated',
                'billing_item_mapping',
                v_row.id,
                jsonb_build_object('item_key', v_row.item_key)
            );

            return to_jsonb(v_row);


        when 'list_epsilon_issues' then

            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;

            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

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

            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;

            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            select i.id, i.document_type, i.epsilon_status
            into v_inv
            from public.invoices i
            where i.id = (p_payload->>'invoice_id')::uuid;

            if not found then
                raise exception 'invoice not found';
            end if;

            -- A rejection by AADE cannot be fixed by resending the same
            -- data; that requires a credit note / corrected invoice.
            if v_inv.epsilon_status <> 'error' then
                raise exception 'only invoices with Epsilon status error can be re-queued (status: %)', v_inv.epsilon_status;
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

            raise exception
                'unknown commerce operation: %',
                p_op;

    end case;

end;
$$;


-- =====================================================
-- 24. CURRENT SUBSCRIPTION OVERVIEW
-- =====================================================

create or replace view public.v_subscription_overview
with (security_invoker = true)
as
select
    s.id as subscription_id,
    s.tenant_id,
    s.status,
    s.tier,

    s.plan_id,

    pp.name as plan_name,

    pp.description as plan_description,

    pp.is_active as plan_is_active,

    pp.is_default as plan_is_default,

    pricing.currency,

    pricing.monthly_price,

    pricing.yearly_price,

    pricing.effective_from as pricing_effective_from

from public.subscriptions s

left join public.product_plans pp
    on pp.id = s.plan_id

left join lateral (
    select
        px.currency,
        px.monthly_price,
        px.yearly_price,
        px.effective_from

    from public.plan_pricing px

    where px.plan_id = s.plan_id
      and px.effective_from <= now()

    order by px.effective_from desc

    limit 1
) pricing
    on true;


-- =====================================================
-- 25. DEFAULT SUBSCRIPTION PROVISIONING
-- =====================================================
--
-- Called when a tenant is created.
--
-- The default commercial plan must already exist.
-- =====================================================

create or replace function public.provision_default_subscription()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_plan public.product_plans%rowtype;
begin

    select *
    into v_plan
    from public.product_plans
    where is_default = true
      and is_active = true
    limit 1;

    if not found then
        raise exception
            'cannot provision tenant subscription: no active default product plan exists';
    end if;

    insert into public.subscriptions (
        tenant_id,
        plan_id,
        tier,
        status
    )
    values (
        new.id,
        v_plan.id,
        v_plan.tier,
        'active'
    );

    return new;

end;
$$;


-- =====================================================
-- 26. TRIGGERS
-- =====================================================

drop trigger if exists trg_product_plans_updated_at
on public.product_plans;

create trigger trg_product_plans_updated_at
before update on public.product_plans
for each row
execute function platform.set_updated_at();


drop trigger if exists trg_product_plan_tier_immutable
on public.product_plans;

create trigger trg_product_plan_tier_immutable
before update on public.product_plans
for each row
execute function public.prevent_product_plan_tier_change();


drop trigger if exists trg_subscriptions_sync_tier_from_plan
on public.subscriptions;

create trigger trg_subscriptions_sync_tier_from_plan
before insert or update of plan_id
on public.subscriptions
for each row
execute function public.sync_subscription_tier_from_plan();


drop trigger if exists trg_subscriptions_prevent_tier_drift
on public.subscriptions;

create trigger trg_subscriptions_prevent_tier_drift
before insert or update
on public.subscriptions
for each row
execute function public.prevent_subscription_tier_drift();


drop trigger if exists trg_subscriptions_plan_required
on public.subscriptions;

create trigger trg_subscriptions_plan_required
before insert or update
on public.subscriptions
for each row
execute function public.enforce_subscription_plan_required();


drop trigger if exists trg_billing_customers_updated_at
on public.billing_customers;

create trigger trg_billing_customers_updated_at
before update on public.billing_customers
for each row
execute function platform.set_updated_at();


drop trigger if exists trg_invoices_updated_at
on public.invoices;

create trigger trg_invoices_updated_at
before update on public.invoices
for each row
execute function platform.set_updated_at();


drop trigger if exists trg_discount_codes_updated_at
on public.discount_codes;

create trigger trg_discount_codes_updated_at
before update on public.discount_codes
for each row
execute function platform.set_updated_at();


drop trigger if exists trg_invoice_lines_tenant_consistency
on public.invoice_lines;

create trigger trg_invoice_lines_tenant_consistency
before insert or update
on public.invoice_lines
for each row
execute function public.enforce_invoice_line_tenant();


-- =====================================================
-- 27. TENANT DEFAULT SUBSCRIPTION TRIGGER
-- =====================================================
--
-- This trigger is deliberately created only if the tenant
-- table does not already have an equivalent 012 trigger.
-- =====================================================

drop trigger if exists trg_tenants_provision_default_subscription
on public.tenants;

create trigger trg_tenants_provision_default_subscription
after insert on public.tenants
for each row
execute function public.provision_default_subscription();


-- =====================================================
-- 27A. EPSILON E-INVOICING
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
--   1. generator creates invoice + lines (status 'draft'; discounts allowed)
--   2. platform.epsilon_enqueue_invoice() validates, freezes (snapshot +
--      locked_at), sets status 'issued' and queues a submission
--   3. gateway: epsilon_claim_submissions -> HTTP call -> epsilon_record_result
--   4. later MARK/UID/rejection: epsilon_apply_status
-- No dynamic SQL is used in this section.
-- =====================================================

-- 27A.1 PLAN -> EPSILON ITEM / myDATA MAPPING
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


-- 27A.2 AUTO-FILL LINE DEFAULTS FROM THE MAPPING
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


-- 27A.3 IMMUTABLE SNAPSHOT

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


-- 27A.4 API TRACKING + IDEMPOTENCY

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


-- 27A.5 GUARDS: A FROZEN INVOICE IS A FISCAL DOCUMENT
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

    -- An issued invoice is a fiscal document: it is corrected with a
    -- credit note, never voided or cancelled by a status change.
    if new.status in ('void', 'cancelled') and old.status not in ('void', 'cancelled') then
        raise exception 'invoice % is issued: use a credit note instead of voiding it', old.id;
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


-- 27A.6 ENQUEUE: VALIDATE, FREEZE, QUEUE (idempotent)

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
    v_orig_total numeric;
    v_credited numeric;
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

        if v_inv.status <> 'draft' then
            raise exception 'invoice % has status %: only draft invoices can be issued',
                p_invoice_id, v_inv.status;
        end if;

        if v_inv.document_type = 'invoice' and v_inv.due_at is null then
            raise exception 'invoice %: due_at is required', p_invoice_id;
        end if;

        -- ---- subscription term (cancellation per end of month) ----
        if v_inv.subscription_id is not null
           and v_inv.document_type = 'invoice' then

            if exists (
                select 1
                from public.subscriptions s
                where s.id = v_inv.subscription_id
                  and s.cancel_effective_at is not null
                  and v_inv.period_end >= (
                      s.cancel_effective_at at time zone platform.billing_timezone()
                  )::date
            ) then
                raise exception 'invoice %: the subscription is cancelled before the end of the invoice period', p_invoice_id;
            end if;

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
            select i.epsilon_mark, i.total_amount
            into v_corr_mark, v_orig_total
            from public.invoices i
            where i.id = v_inv.credited_invoice_id
              and i.tenant_id = v_inv.tenant_id
              and i.document_type = 'invoice'
              and i.locked_at is not null;

            if not found then
                raise exception 'credit note %: the original invoice does not exist, is not an issued invoice, or belongs to another tenant', p_invoice_id;
            end if;

            if v_corr_mark is null then
                raise exception 'credit note %: the original invoice has no MARK yet', p_invoice_id;
            end if;

            select coalesce(sum(c.total_amount), 0)
            into v_credited
            from public.invoices c
            where c.credited_invoice_id = v_inv.credited_invoice_id
              and c.id <> v_inv.id
              and c.locked_at is not null
              and c.status not in ('void', 'cancelled');

            if v_credited + v_inv.total_amount > v_orig_total then
                raise exception 'credit note %: total credited (%) would exceed the original invoice total (%)',
                    p_invoice_id, v_credited + v_inv.total_amount, v_orig_total;
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
        v_inv.status := 'issued';
        v_inv.issued_at := coalesce(v_inv.issued_at, now());

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
            status = v_inv.status,
            issued_at = v_inv.issued_at,
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


-- 27A.7 CLAIM WORK (parallel workers are safe)

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


-- 27A.8 STUCK IN-FLIGHT: NEVER RETRY AUTOMATICALLY
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


-- 27A.9 RECORD THE RESULT OF AN API CALL

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


-- 27A.10 LATER STATUS UPDATE (polling / webhook): UID, MARK, rejection

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
-- 28. COMMENTS
-- =====================================================

comment on table public.product_plans is
    'Commerce subscription plan catalog. Physical products and inventory are not owned here.';

comment on table public.plan_pricing is
    'Historical and future commercial pricing for subscription plans.';

comment on table public.feature_entitlements is
    'Feature entitlements attached to subscription plans.';

comment on table public.upsell_rules is
    'Commercial subscription upgrade recommendation rules.';

comment on column public.subscriptions.plan_id is
    'Commercial subscription plan reference owned by Commerce 012; subscription identity remains owned by Core SaaS 002.';

comment on table public.billing_customers is
    'Fiscal billing identity a tenant is invoiced under. Epsilon matches customers on VAT number.';

comment on table public.invoices is
    'Commercial invoice SSOT (incl. credit notes). Supabase decides what is invoiced; Epsilon issues the official e-invoice towards AADE/myDATA.';

comment on table public.invoice_lines is
    'Commercial invoice line items with VAT and myDATA classification. Immutable once the invoice is issued.';

comment on table public.discount_codes is
    'Commercial discount definitions. Customer-account discount ownership remains outside Commerce.';

comment on table public.discount_redemptions is
    'Immutable commercial record of discounts applied to invoices/subscriptions.';

comment on table public.billing_item_mappings is
    'Plan to Epsilon item code and myDATA classification mapping. Confirmed by the accountant; not seeded.';

comment on table public.invoice_snapshots is
    'Immutable snapshot of an invoice as frozen for Epsilon. Insert-only.';

comment on table public.epsilon_submissions is
    'Epsilon e-invoicing outbox: API tracking, retries and idempotency keys.';

comment on function public.commerce_change_subscription_plan(uuid, uuid) is
    'Changes the commercial plan of a tenant subscription.';

comment on function public.commerce_apply_discount_to_invoice(uuid, text) is
    'Validates and applies a Commerce discount to a draft invoice, distributing it over the lines and recomputing VAT.';

comment on function platform.epsilon_enqueue_invoice(uuid, text) is
    'Validates, freezes (snapshot + lock) and queues an invoice for Epsilon. Idempotent. Backend only.';

comment on view public.v_subscription_overview is
    'Read-only commerce view combining subscription, plan and currently effective pricing.';


-- =====================================================
-- 29. EXECUTE PRIVILEGES
-- =====================================================
--
-- SECURITY DEFINER functions are explicitly granted only
-- to authenticated users. Authorization is enforced inside
-- the functions.
--
-- NOTE: the platform.epsilon_* functions (27A) are backend-only
-- and are intentionally NOT granted here; final execution
-- privileges are owned by 022 (service_role only).
-- =====================================================

revoke all
on function public.commerce_domain(text, jsonb)
from public;

grant execute
on function public.commerce_domain(text, jsonb)
to authenticated;


revoke all
on function public.commerce_change_subscription_plan(uuid, uuid)
from public;

grant execute
on function public.commerce_change_subscription_plan(uuid, uuid)
to authenticated;


revoke all
on function public.commerce_compute_discount_amount(text, numeric, numeric)
from public;

grant execute
on function public.commerce_compute_discount_amount(text, numeric, numeric)
to authenticated;


revoke all
on function public.commerce_find_usable_discount_code(text, uuid)
from public;

grant execute
on function public.commerce_find_usable_discount_code(text, uuid)
to authenticated;


revoke all
on function public.commerce_apply_discount_to_invoice(uuid, text)
from public;

grant execute
on function public.commerce_apply_discount_to_invoice(uuid, text)
to authenticated;


revoke all
on function public.commerce_cancel_subscription(text)
from public;

grant execute
on function public.commerce_cancel_subscription(text)
to authenticated;


revoke all
on function public.commerce_undo_cancel_subscription()
from public;

grant execute
on function public.commerce_undo_cancel_subscription()
to authenticated;


revoke all
on function public.commerce_create_subscription(uuid, uuid, text)
from public;

grant execute
on function public.commerce_create_subscription(uuid, uuid, text)
to authenticated;


-- =====================================================
-- 30. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (
    migration_name,
    version,
    rollback_available
)
values (
    '012_commerce_engine',
    'REV2',
    false
)
on conflict (migration_name)
do update
set
    version = excluded.version,
    rollback_available = excluded.rollback_available;


-- =====================================================
-- END 012 COMMERCE ENGINE
--
-- COMMERCE ONLY
--
-- Logistics     -> 011
-- Device/BOM    -> 010
-- Inventory     -> 018
-- Customer/CRM  -> 003
-- Payment exec  -> 000
-- =====================================================
