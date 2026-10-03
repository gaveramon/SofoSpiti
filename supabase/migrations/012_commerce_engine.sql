-- =====================================================
-- REV3 GREENFIELD BASELINE
-- 012_COMMERCE_ENGINE.SQL
-- =====================================================
-- COMMERCE DOMAIN
--
-- SSOT SPLIT 002 <-> 012 (REV3)
--
--   002 CORE SaaS owns (identity and state, never a price):
--     - customer accounts and tenants
--     - plan / subscription type            (product_plans)
--     - subscription instance               (subscriptions: plan,
--       status, term, trial expiry, end-of-month cancellation
--       state and its expiry job)
--     - subscription provisioning and plan changes
--
--   012 COMMERCE owns (everything that has a price):
--     - normal plan prices                  (plan_pricing)
--     - discount policy                     (discount_codes)
--     - customer-account discount tiers     (customer_account_discount_tiers:
--       1 tenant = 0 %, 2 = x %, 3+ = y %)
--     - applied discounts, historical snapshot (applied_discounts)
--     - feature entitlements, upsell rules
--     - billing customers, invoices, invoice lines
--     - Epsilon e-invoicing outbox, immutable invoice snapshots
--       and plan -> Epsilon item / myDATA classification mapping
--
--   012 reads 002 (plan, subscription, tenant count) and reacts to
--   it with triggers (for example: cancelling draft invoices when a
--   cancellation date is set). 012 never writes public.product_plans
--   or public.subscriptions; it calls the 002 functions
--   subscription_plan_*, subscription_create, subscription_change_plan,
--   subscription_cancel, subscription_undo_cancel and
--   platform.expire_cancelled_subscriptions / expire_trial_subscriptions
--   / billable_subscriptions.
--
-- 012 DOES NOT OWN:
--   - tenants / customer identity / customer accounts      (002)
--   - plans and subscription state                          (002)
--   - CRM companies and contacts                            (003)
--   - physical product catalog
--   - device bundles / BOM                                  (010)
--   - logistics, fulfilment, warehouses                     (011)
--   - inventory / stock / stock movements                   (018)
--   - payment execution, provider credentials, webhooks     (000)
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

if to_regclass('public.product_plans') is null then
    raise exception
        '012 requires public.product_plans from the core SaaS layer (002 REV2)';
end if;

if to_regclass('public.customer_accounts') is null then
    raise exception
        '012 requires public.customer_accounts from the core SaaS layer';
end if;

if to_regprocedure('public.subscription_change_plan(uuid,uuid)') is null
   or to_regprocedure('public.subscription_cancel(text)') is null
   or to_regprocedure('platform.billing_timezone()') is null
   or to_regprocedure('platform.expire_trial_subscriptions()') is null then
    raise exception
        '012 requires the subscription lifecycle functions from 002 REV2 (section 14C)';
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
-- 1. SUBSCRIPTION PRODUCT PLANS  (OWNED BY 002)
-- =====================================================
--
-- public.product_plans (plan / subscription type) is created and
-- maintained by 002 (section 4B and 14C). 012 only references it:
-- plan_pricing, feature_entitlements, upsell_rules, discount_codes
-- and invoice_lines point at product_plans(id).
-- =====================================================


-- =====================================================
-- 2. PLAN PRICING
-- =====================================================
--
-- Pricing history is retained: a price is valid from
-- effective_from up to (not including) effective_until.
-- effective_until null = open ended (the current price).
--
-- Multiple historical/future prices for the same plan and
-- currency are therefore allowed, but they must not overlap
-- (trigger plan_pricing_maintain_history, section 12B).
-- When a new open-ended price is added, the previous open-ended
-- price is closed automatically at the new effective_from.
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

    effective_until timestamptz,

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
        ),

    constraint chk_plan_pricing_validity
        check (
            effective_until is null
            or effective_until > effective_from
        )
);


-- Re-runnable on a database that already has the table.
alter table public.plan_pricing
    add column if not exists effective_until timestamptz;

do $$
begin
    alter table public.plan_pricing
        add constraint chk_plan_pricing_validity
        check (effective_until is null or effective_until > effective_from);
exception
    when duplicate_object then null;
end;
$$;


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
-- 5. SUBSCRIPTION -> PLAN RELATIONSHIP  (OWNED BY 002)
-- =====================================================
--
-- subscriptions.plan_id, the cancellation columns and their
-- constraints are part of the subscription instance and live in
-- 002 (section 5). 012 reads them.
-- =====================================================


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
-- 8B. CUSTOMER-ACCOUNT DISCOUNT TIERS
-- =====================================================
--
-- Discount POLICY based on the number of tenants a customer
-- account has (002: customer_accounts -> tenants):
--
--   1 tenant   -> 0 %
--   2 tenants  -> x %
--   3+ tenants -> y %
--
-- A row means: "from min_tenants tenants onwards, discount_percent".
-- The row with the highest min_tenants <= the tenant count wins.
--
-- customer_account_id null  -> global tiers (the default policy)
-- customer_account_id set   -> tiers that replace the global ones
--                              for that one customer account
--
-- This table is policy only. What was actually applied to an
-- invoice is recorded in applied_discounts (9B).
-- The tenant count itself is NOT stored: it is derived from
-- 002 (tenants) when the discount is applied.
-- =====================================================

create table if not exists public.customer_account_discount_tiers (
    id uuid primary key default gen_random_uuid(),

    customer_account_id uuid
        references public.customer_accounts(id)
        on delete cascade,

    min_tenants integer not null,

    discount_percent numeric(5,2) not null,

    label text,

    effective_from timestamptz not null default now(),

    effective_to timestamptz,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    constraint chk_ca_discount_tiers_min_tenants
        check (min_tenants >= 1),

    constraint chk_ca_discount_tiers_percent
        check (discount_percent >= 0 and discount_percent <= 100),

    constraint chk_ca_discount_tiers_validity
        check (effective_to is null or effective_to > effective_from)
);


-- One tier per scope / threshold / start date.
create unique index if not exists uq_ca_discount_tiers_scope
on public.customer_account_discount_tiers (
    coalesce(customer_account_id, '00000000-0000-0000-0000-000000000000'::uuid),
    min_tenants,
    effective_from
);

create index if not exists idx_ca_discount_tiers_account
on public.customer_account_discount_tiers (customer_account_id)
where customer_account_id is not null;


-- =====================================================
-- 9B. APPLIED DISCOUNTS (HISTORICAL SNAPSHOT)
-- =====================================================
--
-- Insert-only record of every discount that was actually applied
-- to an invoice (and so to a subscription's billing), whatever its
-- source:
--
--   discount_code          -> a discount code (also counted in
--                             discount_redemptions)
--   customer_account_tier  -> the tenant-count tier (8B)
--
-- Policy changes later (a tier percentage, a code value) never
-- change history: the percentage, the base amount, the tenant
-- count and the policy as it was are copied into the row.
--
-- One discount per invoice. 002 stores no discounts; this table
-- is the only place where the applied discount is kept.
-- =====================================================

create table if not exists public.applied_discounts (
    id uuid primary key default gen_random_uuid(),

    source text not null,

    tenant_id uuid not null
        references public.tenants(id),

    -- Snapshot of the owning customer account at that moment.
    customer_account_id uuid not null
        references public.customer_accounts(id),

    subscription_id uuid
        references public.subscriptions(id)
        on delete restrict,

    invoice_id uuid
        references public.invoices(id)
        on delete restrict,

    discount_code_id uuid
        references public.discount_codes(id)
        on delete restrict,

    tier_id uuid
        references public.customer_account_discount_tiers(id)
        on delete restrict,

    discount_type text not null,

    discount_value numeric(12,2) not null,

    base_amount numeric(12,2) not null,

    amount_applied numeric(12,2) not null,

    currency text not null,

    -- Tier source: tenants of the customer account at that moment.
    tenant_count integer,

    -- Policy as it was (tier label / threshold / scope, code, ...).
    policy_snapshot jsonb not null default '{}'::jsonb,

    applied_by uuid,

    applied_at timestamptz not null default now(),

    constraint chk_applied_discounts_source
        check (source in ('discount_code', 'customer_account_tier')),

    constraint chk_applied_discounts_type
        check (discount_type in ('percentage', 'fixed_amount')),

    constraint chk_applied_discounts_amounts
        check (
            discount_value >= 0
            and base_amount >= 0
            and amount_applied >= 0
        ),

    constraint chk_applied_discounts_currency
        check (char_length(currency) = 3 and currency = upper(currency)),

    constraint chk_applied_discounts_target
        check (invoice_id is not null or subscription_id is not null),

    constraint chk_applied_discounts_source_ref
        check (
            (
                source = 'discount_code'
                and discount_code_id is not null
                and tier_id is null
            )
            or (
                source = 'customer_account_tier'
                and tier_id is not null
                and discount_code_id is null
                and tenant_count is not null
            )
        )
);


-- One discount per invoice.
create unique index if not exists uq_applied_discounts_invoice
on public.applied_discounts (invoice_id)
where invoice_id is not null;

create index if not exists idx_applied_discounts_tenant
on public.applied_discounts (tenant_id, applied_at desc);

create index if not exists idx_applied_discounts_subscription
on public.applied_discounts (subscription_id)
where subscription_id is not null;

create index if not exists idx_applied_discounts_account
on public.applied_discounts (customer_account_id);


-- History is never edited or removed.
create or replace function platform.deny_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    raise exception '% on % is not allowed (immutable)', tg_op, tg_table_name;
end;
$$;


drop trigger if exists trg_applied_discounts_immutable
on public.applied_discounts;

create trigger trg_applied_discounts_immutable
before update or delete on public.applied_discounts
for each row execute function platform.deny_mutation();


-- =====================================================
-- 10. NORMALIZE EXISTING COMMERCE CONSTRAINTS
-- =====================================================

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


-- idx_subscriptions_plan and the product_plans indexes: 002.


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
-- 12B. PLAN PRICING HISTORY
-- =====================================================
--
-- Keeps the price history gap-free and overlap-free per plan
-- and currency:
--   insert (open ended)  -> the previous open-ended price is
--                           closed at the new effective_from
--   update of effective_from -> the previous price follows
--   delete of a price    -> the price it had closed is reopened
--   every change         -> periods of one plan/currency may not
--                           overlap
-- Which price is valid at moment t:
--   effective_from <= t and (effective_until is null or t < effective_until)
-- =====================================================

create or replace function public.plan_pricing_maintain_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin

    if tg_op = 'DELETE' then

        update public.plan_pricing px
        set effective_until = null
        where px.plan_id = old.plan_id
          and px.currency = old.currency
          and px.effective_until = old.effective_from;

        return old;

    end if;

    -- Changes made by this trigger to neighbouring rows.
    if pg_trigger_depth() > 1 then
        return new;
    end if;

    if tg_op = 'INSERT' and new.effective_until is null then

        update public.plan_pricing px
        set effective_until = new.effective_from
        where px.plan_id = new.plan_id
          and px.currency = new.currency
          and px.effective_until is null
          and px.effective_from < new.effective_from;

    elsif tg_op = 'UPDATE'
          and new.effective_from is distinct from old.effective_from then

        update public.plan_pricing px
        set effective_until = new.effective_from
        where px.plan_id = old.plan_id
          and px.currency = old.currency
          and px.effective_until = old.effective_from
          and px.id <> old.id;

    end if;

    if exists (
        select 1
        from public.plan_pricing px
        where px.id <> new.id
          and px.plan_id = new.plan_id
          and px.currency = new.currency
          and tstzrange(px.effective_from, px.effective_until)
              && tstzrange(new.effective_from, new.effective_until)
    ) then
        raise exception
            'plan pricing periods may not overlap (plan %, currency %)',
            new.plan_id, new.currency;
    end if;

    return new;

end;
$$;


drop trigger if exists trg_plan_pricing_history
on public.plan_pricing;

create trigger trg_plan_pricing_history
before insert or update of plan_id, currency, effective_from, effective_until
on public.plan_pricing
for each row
execute function public.plan_pricing_maintain_history();


drop trigger if exists trg_plan_pricing_history_delete
on public.plan_pricing;

create trigger trg_plan_pricing_history_delete
after delete
on public.plan_pricing
for each row
execute function public.plan_pricing_maintain_history();


revoke all on function public.plan_pricing_maintain_history()
from public, anon, authenticated;


-- =====================================================
-- 13-19. PLAN / SUBSCRIPTION INVARIANTS AND LIFECYCLE  (OWNED BY 002)
-- =====================================================
--
-- Moved to 002 (section 14C), because they change the
-- subscription instance, not a price:
--
--   plan required for active states, tier follows the plan,
--   tier drift guard, plan tier immutability
--   subscription_change_plan, subscription_create
--   provision_default_subscription (+ tenant trigger)
--   subscription_cancel, subscription_undo_cancel
--   platform.expire_cancelled_subscriptions
--   platform.billing_timezone
-- =====================================================


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
--   3. platform.billable_subscriptions() (002) is the single list
--      the generator should use.
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


-- The list of subscriptions the generator may bill
-- (platform.billable_subscriptions) is owned by 002.


-- =====================================================
-- 19C. OVERDUE INVOICES
-- =====================================================
--
-- Daily job (schedule outside this migration): issued/sent
-- invoices past their due date become 'overdue'. Allowed on
-- locked invoices (status is one of the fields that may still
-- change). Credit notes are never overdue.
-- =====================================================

create or replace function platform.mark_overdue_invoices()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_n int;
begin

    update public.invoices i
    set status = 'overdue'
    where i.document_type = 'invoice'
      and i.status in ('issued', 'sent')
      and i.due_at is not null
      and i.due_at < now();

    get diagnostics v_n = row_count;

    return v_n;

end;
$$;


-- =====================================================
-- 19D. TRIAL EXPIRY  (OWNED BY 002)
-- =====================================================
--
-- platform.expire_trial_subscriptions() is defined in 002
-- (section 014B) and returns (subscriptions_expired, seconds_elapsed).
-- The cron engine (027) calls it.
-- =====================================================


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
-- 22. DISCOUNT DISTRIBUTION OVER THE INVOICE LINES (SHARED)
-- =====================================================
--
-- The single place where a discount amount is booked on a draft
-- invoice, for every discount source (code or customer-account
-- tier). The discount is distributed pro rata over the invoice
-- lines (rounding remainder on the last line) and VAT is
-- recomputed per line, so that lines and invoice totals stay
-- consistent for the Epsilon/myDATA submission.
--
-- Only one discount per invoice. Draft invoices only.
-- Internal: no tenant check; callers validate access.
-- =====================================================

create or replace function platform.invoice_distribute_discount(
    p_invoice_id uuid,
    p_amount numeric
)
returns public.invoices
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_invoice public.invoices%rowtype;
    v_amount numeric(12,2) := round(p_amount, 2);
    v_new_tax numeric(12,2);
begin

    select *
    into v_invoice
    from public.invoices i
    where i.id = p_invoice_id
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
            from public.applied_discounts ad
            where ad.invoice_id = v_invoice.id
       )
       or exists (
            select 1
            from public.discount_redemptions r
            where r.invoice_id = v_invoice.id
       ) then
        raise exception
            'a discount was already applied to this invoice';
    end if;

    if v_amount is null or v_amount <= 0 then
        raise exception 'discount amount must be positive';
    end if;

    if v_amount > v_invoice.subtotal then
        raise exception 'discount exceeds the invoice subtotal';
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

    return v_invoice;

end;
$$;


-- =====================================================
-- 22A. APPLY A DISCOUNT CODE TO AN INVOICE
-- =====================================================
--
-- Tenant-scoped. Validates the code, books the discount through
-- platform.invoice_distribute_discount, counts the redemption and
-- writes the applied-discount snapshot (9B).
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
    v_account uuid;
    v_discount public.discount_codes%rowtype;
    v_amount numeric(12,2);
    v_base numeric(12,2);
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

    v_base := v_invoice.subtotal;

    v_amount := public.commerce_compute_discount_amount(
        v_discount.discount_type,
        v_discount.value,
        v_base
    );

    if v_amount <= 0 then
        raise exception
            'discount code does not reduce this invoice';
    end if;

    -- Validates draft / not locked / no earlier discount.
    v_invoice := platform.invoice_distribute_discount(
        v_invoice.id,
        v_amount
    );

    select t.customer_account_id
    into v_account
    from public.tenants t
    where t.id = v_tid;

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

    insert into public.applied_discounts (
        source,
        tenant_id,
        customer_account_id,
        subscription_id,
        invoice_id,
        discount_code_id,
        discount_type,
        discount_value,
        base_amount,
        amount_applied,
        currency,
        policy_snapshot,
        applied_by
    )
    values (
        'discount_code',
        v_tid,
        v_account,
        v_invoice.subscription_id,
        v_invoice.id,
        v_discount.id,
        v_discount.discount_type,
        v_discount.value,
        v_base,
        v_amount,
        v_invoice.currency,
        jsonb_build_object(
            'code', v_discount.code,
            'applies_to_plan_id', v_discount.applies_to_plan_id,
            'valid_from', v_discount.valid_from,
            'valid_until', v_discount.valid_until
        ),
        (select auth.uid())
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
            'source', 'discount_code',
            'discount_code_id', v_discount.id,
            'amount_applied', v_amount
        )
    );

    return v_invoice;

end;
$$;


-- =====================================================
-- 22B. CUSTOMER-ACCOUNT TIER DISCOUNT
-- =====================================================
--
-- Which tier applies to a customer account right now:
--
--   tenant count = PAYING tenants of the account: tenant status
--                  'active' with a subscription in status active or
--                  past_due (002: tenants -> subscriptions)
--   tiers        = active, within their validity window,
--                  min_tenants <= tenant count
--   scope        = the account's own tiers if it has any,
--                  otherwise the global tiers
--   winner       = highest min_tenants, then latest effective_from
--
-- No tier (or 0 %) means no discount. Internal function.
-- =====================================================

create or replace function platform.resolve_account_discount(
    p_customer_account_id uuid,
    p_at timestamptz default now()
)
returns table (
    customer_account_id uuid,
    tenant_count integer,
    tier_id uuid,
    min_tenants integer,
    discount_percent numeric,
    label text,
    account_specific boolean,
    effective_from timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_count integer;
    v_specific boolean;
begin

    -- Only paying tenants count: an active tenant with a subscription
    -- in a billable status (same rule as platform.billable_subscriptions).
    -- A tenant without a subscription, or with a trial / cancelled /
    -- suspended / expired one, is not counted.
    select count(*)::integer
    into v_count
    from public.tenants t
    join public.subscriptions s
      on s.tenant_id = t.id
    where t.customer_account_id = p_customer_account_id
      and t.status::text = 'active'
      and s.status in ('active', 'past_due');

    select exists (
        select 1
        from public.customer_account_discount_tiers d
        where d.customer_account_id = p_customer_account_id
          and d.is_active
          and d.effective_from <= p_at
          and (d.effective_to is null or d.effective_to > p_at)
    )
    into v_specific;

    return query
    select
        p_customer_account_id,
        v_count,
        d.id,
        d.min_tenants,
        d.discount_percent,
        d.label,
        (d.customer_account_id is not null),
        d.effective_from
    from public.customer_account_discount_tiers d
    where d.is_active
      and d.effective_from <= p_at
      and (d.effective_to is null or d.effective_to > p_at)
      and d.min_tenants <= v_count
      and (
          d.customer_account_id = p_customer_account_id
          or (d.customer_account_id is null and not v_specific)
      )
    order by d.min_tenants desc, d.effective_from desc
    limit 1;

    -- No tier matched: still report the tenant count.
    if not found then
        return query
        select
            p_customer_account_id,
            v_count,
            null::uuid,
            null::integer,
            0::numeric,
            null::text,
            v_specific,
            null::timestamptz;
    end if;

end;
$$;


-- Applies the tier discount of the invoice's customer account to a
-- draft invoice and records the snapshot. Idempotent: returns the
-- invoice unchanged when there is nothing to apply (no tier, 0 %,
-- or the invoice already carries a discount). Used by the invoice
-- generator (no tenant context) and by the tenant wrapper below.
create or replace function platform.apply_account_tier_discount(
    p_invoice_id uuid
)
returns public.invoices
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_invoice public.invoices%rowtype;
    v_account uuid;
    v_tier record;
    v_amount numeric(12,2);
begin

    select *
    into v_invoice
    from public.invoices i
    where i.id = p_invoice_id
    for update;

    if not found then
        raise exception 'invoice not found';
    end if;

    if v_invoice.status <> 'draft'
       or v_invoice.document_type <> 'invoice'
       or v_invoice.locked_at is not null then
        raise exception
            'tier discounts can only be applied to draft invoices';
    end if;

    -- One discount per invoice: an existing one (code or tier) wins.
    if v_invoice.discount_amount > 0
       or exists (
            select 1
            from public.applied_discounts ad
            where ad.invoice_id = v_invoice.id
       ) then
        return v_invoice;
    end if;

    select t.customer_account_id
    into v_account
    from public.tenants t
    where t.id = v_invoice.tenant_id;

    select *
    into v_tier
    from platform.resolve_account_discount(v_account, now());

    if v_tier.tier_id is null or v_tier.discount_percent <= 0 then
        return v_invoice;
    end if;

    v_amount := public.commerce_compute_discount_amount(
        'percentage',
        v_tier.discount_percent,
        v_invoice.subtotal
    );

    if v_amount <= 0 then
        return v_invoice;
    end if;

    v_invoice := platform.invoice_distribute_discount(
        v_invoice.id,
        v_amount
    );

    insert into public.applied_discounts (
        source,
        tenant_id,
        customer_account_id,
        subscription_id,
        invoice_id,
        tier_id,
        discount_type,
        discount_value,
        base_amount,
        amount_applied,
        currency,
        tenant_count,
        policy_snapshot,
        applied_by
    )
    values (
        'customer_account_tier',
        v_invoice.tenant_id,
        v_account,
        v_invoice.subscription_id,
        v_invoice.id,
        v_tier.tier_id,
        'percentage',
        v_tier.discount_percent,
        v_invoice.subtotal,
        v_amount,
        v_invoice.currency,
        v_tier.tenant_count,
        jsonb_build_object(
            'label', v_tier.label,
            'min_tenants', v_tier.min_tenants,
            'account_specific', v_tier.account_specific,
            'tier_effective_from', v_tier.effective_from
        ),
        (select auth.uid())
    );

    perform platform.log_audit(
        'invoice.discount_applied',
        'invoice',
        v_invoice.id,
        jsonb_build_object(
            'source', 'customer_account_tier',
            'tier_id', v_tier.tier_id,
            'tenant_count', v_tier.tenant_count,
            'discount_percent', v_tier.discount_percent,
            'amount_applied', v_amount
        )
    );

    return v_invoice;

end;
$$;


-- Tenant-scoped wrapper (portal).
create or replace function public.commerce_apply_account_discount_to_invoice(
    p_invoice_id uuid
)
returns public.invoices
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
        select 1
        from public.invoices i
        where i.id = p_invoice_id
          and i.tenant_id = v_tid
    ) then
        raise exception 'invoice not found';
    end if;

    return platform.apply_account_tier_discount(p_invoice_id);

end;
$$;


-- =====================================================
-- 22C. CANCELLATION -> DRAFT INVOICES
-- =====================================================
--
-- 002 owns the cancellation state of a subscription. When
-- cancel_effective_at is set, draft invoices that were already
-- generated for periods on or after that date are cancelled.
-- Issued invoices are never touched.
-- =====================================================

create or replace function public.cancel_draft_invoices_after_cancellation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_effective_date date;
    v_n int;
begin

    if new.cancel_effective_at is null
       or new.cancel_effective_at is not distinct from old.cancel_effective_at then
        return new;
    end if;

    v_effective_date := (
        new.cancel_effective_at at time zone platform.billing_timezone()
    )::date;

    update public.invoices i
    set status = 'cancelled'
    where i.subscription_id = new.id
      and i.status = 'draft'
      and i.document_type = 'invoice'
      and i.period_end >= v_effective_date;

    get diagnostics v_n = row_count;

    if v_n > 0 then
        perform platform.log_audit(
            'subscription.draft_invoices_cancelled',
            'subscription',
            new.id,
            jsonb_build_object('count', v_n)
        );
    end if;

    return new;

end;
$$;


drop trigger if exists trg_subscriptions_cancel_draft_invoices
on public.subscriptions;

create trigger trg_subscriptions_cancel_draft_invoices
after update of cancel_effective_at
on public.subscriptions
for each row
execute function public.cancel_draft_invoices_after_cancellation();


revoke all on function platform.invoice_distribute_discount(uuid, numeric)
from public, anon, authenticated;

revoke all on function platform.resolve_account_discount(uuid, timestamptz)
from public, anon, authenticated;

revoke all on function platform.apply_account_tier_discount(uuid)
from public, anon, authenticated;

revoke all on function public.cancel_draft_invoices_after_cancellation()
from public, anon, authenticated;


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
                                        'effective_from', px.effective_from,
                                        'effective_until', px.effective_until
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
                                'effective_from', px.effective_from,
                                'effective_until', px.effective_until
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

            -- Plans belong to 002; role check inside the function.
            return to_jsonb(public.subscription_plan_create(p_payload));


        -- =================================================
        -- PLAN: UPDATE
        -- PLATFORM ADMIN
        -- =================================================

        when 'update_product_plan' then

            return to_jsonb(public.subscription_plan_update(p_payload));


        -- =================================================
        -- SUBSCRIPTION: CHANGE PLAN
        -- =================================================

        when 'change_subscription_plan', 'change_plan' then

            v_row := public.subscription_change_plan(
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
        -- A trial past current_period_end is not entitled either.
        -- Otherwise is_entitled = false and features = {}.
        -- =================================================

        when 'get_tenant_entitlements' then

            v_tid := platform.current_tenant_id();

            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            -- Best subscription: entitled statuses first.
            select s.id, s.plan_id, s.status, s.cancel_effective_at, s.current_period_end
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
                )
                and not (
                    v_row.status = 'trial'
                    and v_row.current_period_end is not null
                    and v_row.current_period_end <= now()
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
                    px.effective_from,
                    px.effective_until
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
                effective_from,
                effective_until
            )
            values (
                (p_payload->>'plan_id')::uuid,
                upper(btrim(coalesce(p_payload->>'currency', 'EUR'))),
                nullif(p_payload->>'monthly_price', '')::numeric,
                nullif(p_payload->>'yearly_price', '')::numeric,
                coalesce(nullif(p_payload->>'effective_from', '')::timestamptz, now()),
                nullif(p_payload->>'effective_until', '')::timestamptz
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
                end,

                effective_until = case
                    when p_payload ? 'effective_until'
                        then nullif(p_payload->>'effective_until', '')::timestamptz
                    else px.effective_until
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

            return public.subscription_plan_delete(
                (p_payload->>'id')::uuid
            );


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

            v_row := public.subscription_cancel(
                p_payload->>'reason'
            );

            return to_jsonb(v_row);


        when 'undo_cancel_subscription' then

            v_row := public.subscription_undo_cancel();

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


        -- =================================================
        -- CUSTOMER-ACCOUNT DISCOUNT: TIERS (READ)
        -- Tenant: global tiers + the tiers of its own account.
        -- Platform admin with {"all": true}: every tier.
        -- =================================================

        when 'list_customer_account_discount_tiers' then

            if public.is_platform_admin()
               and coalesce((p_payload->>'all')::boolean, false) then

                select coalesce(jsonb_agg(to_jsonb(d) order by d.customer_account_id nulls first, d.min_tenants, d.effective_from), '[]'::jsonb)
                into v_result
                from public.customer_account_discount_tiers d;

                return v_result;

            end if;

            v_tid := platform.current_tenant_id();

            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            select t.customer_account_id
            into v_target
            from public.tenants t
            where t.id = v_tid;

            select coalesce(jsonb_agg(to_jsonb(x) order by x.min_tenants), '[]'::jsonb)
            into v_result
            from (
                select
                    d.id,
                    d.customer_account_id,
                    d.min_tenants,
                    d.discount_percent,
                    d.label,
                    d.effective_from,
                    d.effective_to
                from public.customer_account_discount_tiers d
                where d.is_active
                  and (
                      d.customer_account_id is null
                      or d.customer_account_id = v_target
                  )
            ) x;

            return v_result;


        -- =================================================
        -- CUSTOMER-ACCOUNT DISCOUNT: WHAT APPLIES TO ME NOW
        -- {customer_account_id, tenant_count, tier_id, min_tenants,
        --  discount_percent, label, account_specific, effective_from}
        -- =================================================

        when 'get_customer_account_discount' then

            v_tid := platform.current_tenant_id();

            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            select t.customer_account_id
            into v_target
            from public.tenants t
            where t.id = v_tid;

            select to_jsonb(r)
            into v_result
            from platform.resolve_account_discount(v_target, now()) r;

            return v_result;


        -- =================================================
        -- CUSTOMER-ACCOUNT DISCOUNT: TIER UPSERT (PLATFORM ADMIN)
        -- Without "id": create. With "id": partial update.
        -- customer_account_id null = global tier.
        -- =================================================

        when 'upsert_customer_account_discount_tier' then

            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;

            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            if nullif(p_payload->>'id', '') is null then

                insert into public.customer_account_discount_tiers (
                    customer_account_id,
                    min_tenants,
                    discount_percent,
                    label,
                    effective_from,
                    effective_to,
                    is_active
                )
                values (
                    nullif(p_payload->>'customer_account_id', '')::uuid,
                    (p_payload->>'min_tenants')::integer,
                    (p_payload->>'discount_percent')::numeric,
                    nullif(btrim(coalesce(p_payload->>'label', '')), ''),
                    coalesce(nullif(p_payload->>'effective_from', '')::timestamptz, now()),
                    nullif(p_payload->>'effective_to', '')::timestamptz,
                    coalesce((p_payload->>'is_active')::boolean, true)
                )
                returning id into v_target;

            else

                update public.customer_account_discount_tiers d
                set
                    customer_account_id = case
                        when p_payload ? 'customer_account_id'
                            then nullif(p_payload->>'customer_account_id', '')::uuid
                        else d.customer_account_id
                    end,
                    min_tenants = case
                        when p_payload ? 'min_tenants'
                            then (p_payload->>'min_tenants')::integer
                        else d.min_tenants
                    end,
                    discount_percent = case
                        when p_payload ? 'discount_percent'
                            then (p_payload->>'discount_percent')::numeric
                        else d.discount_percent
                    end,
                    label = case
                        when p_payload ? 'label'
                            then nullif(btrim(coalesce(p_payload->>'label', '')), '')
                        else d.label
                    end,
                    effective_from = case
                        when p_payload ? 'effective_from'
                            then (p_payload->>'effective_from')::timestamptz
                        else d.effective_from
                    end,
                    effective_to = case
                        when p_payload ? 'effective_to'
                            then nullif(p_payload->>'effective_to', '')::timestamptz
                        else d.effective_to
                    end,
                    is_active = case
                        when p_payload ? 'is_active'
                            then (p_payload->>'is_active')::boolean
                        else d.is_active
                    end
                where d.id = (p_payload->>'id')::uuid
                returning d.id into v_target;

                if not found then
                    raise exception 'discount tier not found';
                end if;

            end if;

            perform platform.log_audit(
                'customer_account_discount_tier.saved',
                'customer_account_discount_tier',
                v_target,
                p_payload
            );

            select to_jsonb(d)
            into v_result
            from public.customer_account_discount_tiers d
            where d.id = v_target;

            return v_result;


        when 'deactivate_customer_account_discount_tier' then

            if (select auth.uid()) is null then
                raise exception 'authentication required';
            end if;

            if not public.is_platform_admin() then
                raise exception 'platform admin role required';
            end if;

            update public.customer_account_discount_tiers d
            set is_active = false
            where d.id = (p_payload->>'id')::uuid
            returning d.id into v_target;

            if not found then
                raise exception 'discount tier not found';
            end if;

            perform platform.log_audit(
                'customer_account_discount_tier.deactivated',
                'customer_account_discount_tier',
                v_target
            );

            return jsonb_build_object('id', v_target, 'is_active', false);


        -- =================================================
        -- CUSTOMER-ACCOUNT DISCOUNT: APPLY TO A DRAFT INVOICE
        -- =================================================

        when 'apply_account_discount_to_invoice' then

            v_row := public.commerce_apply_account_discount_to_invoice(
                (p_payload->>'invoice_id')::uuid
            );

            return to_jsonb(v_row);


        -- =================================================
        -- APPLIED DISCOUNTS (HISTORY, TENANT, READ ONLY)
        -- =================================================

        when 'list_applied_discounts' then

            v_tid := platform.current_tenant_id();

            if v_tid is null then
                raise exception 'no active tenant';
            end if;

            v_limit := least(greatest(coalesce(nullif(p_payload->>'limit', '')::int, 50), 1), 200);
            v_offset := greatest(coalesce(nullif(p_payload->>'offset', '')::int, 0), 0);

            select coalesce(jsonb_agg(to_jsonb(t) order by t.applied_at desc), '[]'::jsonb)
            into v_result
            from (
                select
                    ad.id,
                    ad.source,
                    dc.code,
                    ad.invoice_id,
                    ad.subscription_id,
                    ad.discount_type,
                    ad.discount_value,
                    ad.base_amount,
                    ad.amount_applied,
                    ad.currency,
                    ad.tenant_count,
                    ad.policy_snapshot,
                    ad.applied_at
                from public.applied_discounts ad
                left join public.discount_codes dc
                  on dc.id = ad.discount_code_id
                where ad.tenant_id = v_tid
                  and (
                      nullif(p_payload->>'invoice_id', '') is null
                      or ad.invoice_id = (p_payload->>'invoice_id')::uuid
                  )
                order by ad.applied_at desc
                limit v_limit
                offset v_offset
            ) t;

            return v_result;


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

    pricing.effective_from as pricing_effective_from,

    pricing.effective_until as pricing_effective_until

from public.subscriptions s

left join public.product_plans pp
    on pp.id = s.plan_id

left join lateral (
    select
        px.currency,
        px.monthly_price,
        px.yearly_price,
        px.effective_from,
        px.effective_until

    from public.plan_pricing px

    where px.plan_id = s.plan_id
      and px.effective_from <= now()
      and (px.effective_until is null or px.effective_until > now())

    order by px.effective_from desc

    limit 1
) pricing
    on true;


-- =====================================================
-- 25. DEFAULT SUBSCRIPTION PROVISIONING  (OWNED BY 002)
-- =====================================================
--
-- provision_default_subscription and its tenant trigger are part
-- of the subscription lifecycle in 002 (section 14C).
-- =====================================================


-- =====================================================
-- 26. TRIGGERS
-- =====================================================

-- Plan and subscription triggers: 002 (section 14C and 16).

drop trigger if exists trg_ca_discount_tiers_updated_at
on public.customer_account_discount_tiers;

create trigger trg_ca_discount_tiers_updated_at
before update on public.customer_account_discount_tiers
for each row
execute function platform.set_updated_at();


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

comment on table public.plan_pricing is
    'Historical and future commercial pricing for subscription plans.';

comment on table public.feature_entitlements is
    'Feature entitlements attached to subscription plans.';

comment on table public.upsell_rules is
    'Commercial subscription upgrade recommendation rules.';

comment on table public.billing_customers is
    'Fiscal billing identity a tenant is invoiced under. Epsilon matches customers on VAT number.';

comment on table public.invoices is
    'Commercial invoice SSOT (incl. credit notes). Supabase decides what is invoiced; Epsilon issues the official e-invoice towards AADE/myDATA.';

comment on table public.invoice_lines is
    'Commercial invoice line items with VAT and myDATA classification. Immutable once the invoice is issued.';

comment on table public.discount_codes is
    'Discount code policy (Commerce 012).';

comment on table public.customer_account_discount_tiers is
    'Discount policy by number of tenants of a customer account (1 tenant = 0 %, 2 = x %, 3+ = y %). Null customer_account_id = global tiers. Tenant count is derived from 002.';

comment on table public.applied_discounts is
    'Insert-only history of discounts that were actually applied to invoices (code or customer-account tier), with percentage, base amount, tenant count and policy as they were.';

comment on table public.discount_redemptions is
    'Immutable commercial record of discounts applied to invoices/subscriptions.';

comment on table public.billing_item_mappings is
    'Plan to Epsilon item code and myDATA classification mapping. Confirmed by the accountant; not seeded.';

comment on table public.invoice_snapshots is
    'Immutable snapshot of an invoice as frozen for Epsilon. Insert-only.';

comment on table public.epsilon_submissions is
    'Epsilon e-invoicing outbox: API tracking, retries and idempotency keys.';

comment on function public.commerce_apply_discount_to_invoice(uuid, text) is
    'Validates and applies a discount code to a draft invoice, distributing it over the lines and recomputing VAT; writes the applied-discount snapshot.';

comment on function platform.apply_account_tier_discount(uuid) is
    'Applies the tenant-count tier discount of the invoice''s customer account to a draft invoice (idempotent) and writes the applied-discount snapshot.';

comment on function platform.resolve_account_discount(uuid, timestamptz) is
    'Resolves the tier that applies to a customer account: tenant count from 002 against customer_account_discount_tiers.';

comment on function platform.epsilon_enqueue_invoice(uuid, text) is
    'Validates, freezes (snapshot + lock) and queues an invoice for Epsilon. Idempotent. Backend only.';

comment on view public.v_subscription_overview is
    'Read-only view combining the 002 subscription and plan with the currently effective 012 pricing.';


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
on function public.commerce_apply_account_discount_to_invoice(uuid)
from public;

grant execute
on function public.commerce_apply_account_discount_to_invoice(uuid)
to authenticated;


revoke all
on function public.commerce_apply_discount_to_invoice(uuid, text)
from public;

grant execute
on function public.commerce_apply_discount_to_invoice(uuid, text)
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
    'REV3',
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
-- Plans, subscription state, customer accounts -> 002
-- CRM companies/contacts                       -> 003
-- Device/BOM                                   -> 010
-- Logistics                                    -> 011
-- Inventory                                    -> 018
-- Payment exec                                 -> 000
-- =====================================================