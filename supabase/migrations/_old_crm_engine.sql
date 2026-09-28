-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 003_CRM_ENGINE.SQL
-- =====================================================
--
-- NO EXECUTION / NO RUNTIME STATE / NO PLATFORM LOGIC
-- =====================================================
--
-- SSOT: contacts, companies, leads, pipelines, opportunities,
-- tasks, interactions, notes, tags, lists, campaigns, custom fields.
--
-- References only: tenants, profiles (002/000), customer tenants via FK.
-- Does NOT own: orders, subscriptions, payments, bookings, devices,
-- portal, onboarding, support cases (009).
-- Campaign SSOT: crm_campaigns (marketing acquisition) only.
-- In-product upsells → 015.upsell_campaigns. Plan upsells → 012.upsell_rules.
-- CRM domain enums SSOT: 001_core_types_rev19.sql (section 14).
-- =====================================================

-- =====================================================
-- 1. PIPELINES
-- =====================================================

create table if not exists public.crm_pipelines (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    name text not null,

    description text,

    is_default boolean not null default false,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    deleted_at timestamptz
);



-- =====================================================
-- 2. PIPELINE STAGES
-- =====================================================

create table if not exists public.crm_pipeline_stages (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    pipeline_id uuid not null references crm_pipelines(id) on delete cascade,

    name text not null,

    stage_order int not null,

    probability numeric(5,2) not null default 0,

    is_terminal boolean not null default false,

    terminal_outcome crm_terminal_outcome,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    deleted_at timestamptz,

    unique (pipeline_id, stage_order),

    constraint chk_crm_pipeline_stages_order check (stage_order > 0),

    constraint chk_crm_pipeline_stages_probability check (
        probability >= 0 and probability <= 100
    ),

    constraint chk_crm_pipeline_stages_terminal_outcome check (
        (not is_terminal and terminal_outcome is null)
        or (is_terminal and terminal_outcome is not null)
    )
);


-- =====================================================
-- 3. CAMPAIGNS
-- =====================================================

create table if not exists public.crm_campaigns (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    name text not null,

    description text,

    campaign_type crm_campaign_type not null default 'other',

    status crm_campaign_status not null default 'draft',

    start_date date,

    end_date date,

    budget numeric(12,2),

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    deleted_at timestamptz,

    constraint chk_crm_campaigns_date_range check (
        start_date is null
        or end_date is null
        or end_date >= start_date
    ),

    constraint chk_crm_campaigns_budget check (
        budget is null or budget >= 0
    )
);



-- =====================================================
-- 4. TAGS
-- =====================================================

create table if not exists public.crm_tags (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    name text not null,

    color text,

    created_at timestamptz not null default now(),

    deleted_at timestamptz
);



-- =====================================================
-- 5. COMPANIES
-- =====================================================

create table if not exists public.crm_companies (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    name text not null,

    legal_name text,

    website text,

    industry text,

    owner_user_id uuid references platform.profiles(id) on delete set null,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    deleted_at timestamptz
);


-- =====================================================
-- 6. CONTACTS
-- =====================================================

create table if not exists public.crm_contacts (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    first_name text,

    last_name text,

    display_name text,

    email text,

    phone text,

    language text default 'en',

    timezone text,

    marketing_consent boolean not null default false,

    marketing_consent_at timestamptz,

    gdpr_consent boolean not null default false,

    gdpr_consent_at timestamptz,

    status crm_contact_status not null default 'active',

    lead_source text,

    owner_user_id uuid references platform.profiles(id) on delete set null,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    deleted_at timestamptz,

    constraint chk_crm_contacts_has_identity check (
        display_name is not null
        or first_name is not null
        or last_name is not null
        or email is not null
    ),

    constraint chk_crm_contacts_marketing_consent_at check (
        (not marketing_consent and marketing_consent_at is null)
        or marketing_consent
    ),

    constraint chk_crm_contacts_gdpr_consent_at check (
        (not gdpr_consent and gdpr_consent_at is null)
        or gdpr_consent
    )
);


-- =====================================================
-- 9. COMPANY ↔ TENANT (M:N — REQUIRED FOR NORMALIZATION)
-- =====================================================

create table if not exists public.crm_company_tenants (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    company_id uuid not null references crm_companies(id) on delete cascade,

    linked_tenant_id uuid,

    relationship_type text,

    created_at timestamptz not null default now(),

    deleted_at timestamptz,

    unique (company_id, linked_tenant_id)
);



-- =====================================================
-- 7. LEADS
-- =====================================================

create table if not exists public.crm_leads (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    first_name text,

    last_name text,

    email text,

    phone text,

    status crm_lead_status not null default 'new',

    source text,

    score numeric(5,2),

    temperature crm_lead_temperature,

    owner_user_id uuid references platform.profiles(id) on delete set null,

    estimated_value numeric(12,2),

    campaign_id uuid references crm_campaigns(id) on delete set null,

    converted_contact_id uuid references crm_contacts(id) on delete set null,

    converted_company_id uuid references crm_companies(id) on delete set null,

    converted_tenant_id uuid,

    converted_at timestamptz,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    deleted_at timestamptz,

    constraint chk_crm_leads_score check (
        score is null or (score >= 0 and score <= 100)
    ),

    constraint chk_crm_leads_estimated_value check (
        estimated_value is null or estimated_value >= 0
    ),

    constraint chk_crm_leads_converted_state check (
        (status <> 'converted' and converted_at is null)
        or (status = 'converted' and converted_at is not null)
    )
);



-- =====================================================
-- 8. CONTACT ↔ COMPANY (M:N WITH ROLES)
-- =====================================================

create table if not exists public.crm_contact_company (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    contact_id uuid not null references crm_contacts(id) on delete cascade,

    company_id uuid not null references crm_companies(id) on delete cascade,

    role text not null,

    is_primary boolean not null default false,

    created_at timestamptz not null default now(),

    deleted_at timestamptz,

    unique (contact_id, company_id, role)
);



-- =====================================================
-- 10. CONTACT ↔ TENANT (M:N — REQUIRED FOR NORMALIZATION)
-- =====================================================

create table if not exists public.crm_contact_tenants (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    contact_id uuid not null references crm_contacts(id) on delete cascade,

    linked_tenant_id uuid,

    relationship_type text,

    created_at timestamptz not null default now(),

    deleted_at timestamptz,

    unique (contact_id, linked_tenant_id)
);



-- =====================================================
-- 11. OPPORTUNITIES
-- =====================================================

create table if not exists public.crm_opportunities (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    pipeline_id uuid not null references crm_pipelines(id) on delete restrict,

    stage_id uuid not null references crm_pipeline_stages(id) on delete restrict,

    contact_id uuid references crm_contacts(id) on delete set null,

    company_id uuid references crm_companies(id) on delete set null,

    linked_tenant_id uuid,

    name text not null,

    expected_revenue numeric(12,2),

    probability numeric(5,2),

    expected_close_date date,

    owner_user_id uuid references platform.profiles(id) on delete set null,

    status crm_opportunity_status not null default 'open',

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    deleted_at timestamptz,

    constraint chk_crm_opportunities_probability check (
        probability is null or (probability >= 0 and probability <= 100)
    ),

    constraint chk_crm_opportunities_expected_revenue check (
        expected_revenue is null or expected_revenue >= 0
    ),

    constraint chk_crm_opportunities_has_party check (
        contact_id is not null
        or company_id is not null
        or linked_tenant_id is not null
    )
);



-- =====================================================
-- 12. TASKS
-- =====================================================

create table if not exists public.crm_tasks (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    title text not null,

    description text,

    target_type crm_task_target_type not null,

    target_id uuid not null,

    priority priority_level not null default 'normal',

    due_at timestamptz,

    status crm_task_status not null default 'pending',

    owner_user_id uuid references platform.profiles(id) on delete set null,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    deleted_at timestamptz
);



-- =====================================================
-- 13. INTERACTIONS (APPEND-ONLY)
-- =====================================================

create table if not exists public.crm_interactions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    interaction_type crm_interaction_type not null,

    subject text,

    metadata jsonb not null default '{}'::jsonb,

    contact_id uuid references crm_contacts(id) on delete set null,

    company_id uuid references crm_companies(id) on delete set null,

    lead_id uuid references crm_leads(id) on delete set null,

    opportunity_id uuid references crm_opportunities(id) on delete set null,

    recorded_by uuid references platform.profiles(id) on delete set null,

    occurred_at timestamptz not null default now(),

    created_at timestamptz not null default now(),

    deleted_at timestamptz,

    constraint chk_crm_interactions_has_context check (
        contact_id is not null
        or company_id is not null
        or lead_id is not null
        or opportunity_id is not null
    )
);



-- =====================================================
-- 14. NOTES
-- =====================================================

create table if not exists public.crm_notes (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    entity_type crm_entity_type not null,

    entity_id uuid not null,

    body text not null,

    version int not null default 1,

    author_user_id uuid references platform.profiles(id) on delete set null,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    deleted_at timestamptz,

    constraint chk_crm_notes_version check (version > 0)
);




-- =====================================================
-- 15. TAG ASSIGNMENTS
-- =====================================================

create table if not exists public.crm_tag_assignments (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    tag_id uuid not null references crm_tags(id) on delete cascade,

    entity_type crm_entity_type not null,

    entity_id uuid not null,

    created_at timestamptz not null default now(),

    deleted_at timestamptz,

    unique (tag_id, entity_type, entity_id)
);



-- =====================================================
-- 16. LISTS
-- =====================================================

create table if not exists public.crm_lists (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    name text not null,

    description text,

    list_type crm_list_type not null default 'static',

    filter_config jsonb,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    deleted_at timestamptz,

    constraint chk_crm_lists_dynamic_filter check (
        list_type <> 'dynamic' or filter_config is not null
    )
);



-- =====================================================
-- 17. LIST MEMBERS
-- =====================================================

create table if not exists public.crm_list_members (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    list_id uuid not null references crm_lists(id) on delete cascade,

    contact_id uuid not null references crm_contacts(id) on delete cascade,

    added_at timestamptz not null default now(),

    deleted_at timestamptz,

    unique (list_id, contact_id)
);


-- =====================================================
-- 18. CUSTOM FIELDS
-- =====================================================

create table if not exists public.crm_custom_fields (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    field_key text not null,

    label text not null,

    field_type crm_custom_field_type not null,

    applies_to crm_entity_type not null,

    options jsonb,

    is_required boolean not null default false,

    display_order int not null default 0,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    deleted_at timestamptz,

    unique (tenant_id, field_key, applies_to),

    constraint chk_crm_custom_fields_options check (
        field_type not in ('select', 'multiselect') or options is not null
    )
);



-- =====================================================
-- 19. CUSTOM FIELD VALUES
-- =====================================================

create table if not exists public.crm_custom_field_values (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    custom_field_id uuid not null references crm_custom_fields(id) on delete cascade,

    entity_type crm_entity_type not null,

    entity_id uuid not null,

    value_text text,

    value_number numeric,

    value_boolean boolean,

    value_date date,

    value_datetime timestamptz,

    value_json jsonb,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    unique (custom_field_id, entity_id),

    constraint chk_crm_custom_field_values_has_value check (
        value_text is not null
        or value_number is not null
        or value_boolean is not null
        or value_date is not null
        or value_datetime is not null
        or value_json is not null
    )
);


-- ==========================
--  Triggers
-- ==========================

create index if not exists idx_crm_pipelines_tenant_created
on crm_pipelines (tenant_id, created_at desc);

create unique index if not exists uq_crm_pipelines_default_per_tenant
on crm_pipelines (tenant_id)
where is_default = true and deleted_at is null;

comment on table public.crm_pipelines is
    'Generic sales pipeline definitions (Sales, Partners, Enterprise, Upsell, etc.).';

create index if not exists idx_crm_pipeline_stages_pipeline
on crm_pipeline_stages (pipeline_id);

create index if not exists idx_crm_pipeline_stages_tenant_created
on crm_pipeline_stages (tenant_id, created_at desc);

create index if not exists idx_crm_campaigns_tenant_created
on crm_campaigns (tenant_id, created_at desc);

create index if not exists idx_crm_campaigns_tenant_status
on crm_campaigns (tenant_id, status)
where deleted_at is null;

comment on table public.crm_campaigns is
    'Marketing campaign definitions. Owns no contacts; relationships via leads and list membership.';

create index if not exists idx_crm_tags_tenant_created
on crm_tags (tenant_id, created_at desc);

create unique index if not exists uq_crm_tags_tenant_name
on crm_tags (tenant_id, lower(name))
where deleted_at is null;

create index if not exists idx_crm_companies_tenant_created
on crm_companies (tenant_id, created_at desc);

create index if not exists idx_crm_companies_owner
on crm_companies (tenant_id, owner_user_id)
where owner_user_id is not null and deleted_at is null;

comment on table public.crm_companies is
    'CRM company records. Customer tenant links via crm_company_tenants (M:N).';

create index if not exists idx_crm_contacts_tenant_created
on crm_contacts (tenant_id, created_at desc);

create index if not exists idx_crm_contacts_tenant_email
on crm_contacts (tenant_id, lower(email))
where email is not null and deleted_at is null;

create index if not exists idx_crm_contacts_owner
on crm_contacts (tenant_id, owner_user_id)
where owner_user_id is not null and deleted_at is null;

comment on table public.crm_contacts is
    'CRM contact SSOT. Free-text notes live in crm_notes; no duplicated tenant data.';

create index if not exists idx_crm_leads_tenant_created
on crm_leads (tenant_id, created_at desc);

create index if not exists idx_crm_leads_tenant_status
on crm_leads (tenant_id, status)
where deleted_at is null;

create index if not exists idx_crm_leads_campaign
on crm_leads (campaign_id)
where campaign_id is not null;

create index if not exists idx_crm_leads_converted_tenant
on crm_leads (converted_tenant_id)
where converted_tenant_id is not null;

comment on table public.crm_leads is
    'Prospect leads. May convert to contact, company, and/or customer tenant. CRM does not create tenants.';

comment on column public.crm_leads.converted_tenant_id is
    'Reference to 002 tenants after conversion. Set by application layer; CRM stores FK only.';

create index if not exists idx_crm_contact_company_contact
on crm_contact_company (contact_id)
where deleted_at is null;

create index if not exists idx_crm_contact_company_company
on crm_contact_company (company_id)
where deleted_at is null;

create index if not exists idx_crm_contact_company_tenant_created
on crm_contact_company (tenant_id, created_at desc);

create unique index if not exists uq_crm_contact_company_primary
on crm_contact_company (contact_id, company_id)
where is_primary = true and deleted_at is null;

create index if not exists idx_crm_company_tenants_company
on crm_company_tenants (company_id)
where deleted_at is null and linked_tenant_id is not null;

create index if not exists idx_crm_company_tenants_linked_tenant
on crm_company_tenants (linked_tenant_id)
where deleted_at is null;

create index if not exists idx_crm_company_tenants_tenant_created
on crm_company_tenants (tenant_id, created_at desc);

comment on table public.crm_company_tenants is
    'Links CRM companies to customer tenants (002). Required M:N; not duplicated on crm_companies.';

create index if not exists idx_crm_contact_tenants_contact
on crm_contact_tenants (contact_id)
where deleted_at is null and linked_tenant_id is not null;

create index if not exists idx_crm_contact_tenants_linked_tenant
on crm_contact_tenants (linked_tenant_id)
where deleted_at is null;

create index if not exists idx_crm_contact_tenants_tenant_created
on crm_contact_tenants (tenant_id, created_at desc);

comment on table public.crm_contact_tenants is
    'Links CRM contacts to customer tenants (002) they manage. Required M:N.';

create index if not exists idx_crm_opportunities_tenant_created
on crm_opportunities (tenant_id, created_at desc);

create index if not exists idx_crm_opportunities_pipeline_stage
on crm_opportunities (pipeline_id, stage_id)
where deleted_at is null;

create index if not exists idx_crm_opportunities_owner
on crm_opportunities (tenant_id, owner_user_id)
where owner_user_id is not null and deleted_at is null;

create index if not exists idx_crm_opportunities_linked_tenant
on crm_opportunities (linked_tenant_id)
where linked_tenant_id is not null;

comment on column public.crm_opportunities.linked_tenant_id is
    'Optional reference to 002 customer tenant associated with this deal.';

create index if not exists idx_crm_tasks_tenant_created
on crm_tasks (tenant_id, created_at desc);

create index if not exists idx_crm_tasks_target
on crm_tasks (tenant_id, target_type, target_id)
where deleted_at is null;

create index if not exists idx_crm_tasks_owner_due
on crm_tasks (tenant_id, owner_user_id, due_at)
where deleted_at is null and status in ('pending', 'in_progress');

comment on table public.crm_tasks is
    'Follow-up tasks bound to exactly one CRM or customer tenant target.';

create index if not exists idx_crm_interactions_tenant_created
on crm_interactions (tenant_id, created_at desc);

create index if not exists idx_crm_interactions_contact
on crm_interactions (contact_id, occurred_at desc)
where contact_id is not null;

create index if not exists idx_crm_interactions_lead
on crm_interactions (lead_id, occurred_at desc)
where lead_id is not null;

create index if not exists idx_crm_interactions_opportunity
on crm_interactions (opportunity_id, occurred_at desc)
where opportunity_id is not null;

comment on table public.crm_interactions is
    'Immutable interaction history. Metadata only — no email bodies. Append-only; soft-delete via deleted_at.';

create index if not exists idx_crm_notes_tenant_created
on crm_notes (tenant_id, created_at desc);

create index if not exists idx_crm_notes_entity
on crm_notes (tenant_id, entity_type, entity_id, created_at desc)
where deleted_at is null;

comment on column public.crm_notes.version is
    'Increment on edit for versioning-ready note history at application layer.';

create index if not exists idx_crm_tag_assignments_entity
on crm_tag_assignments (tenant_id, entity_type, entity_id)
where deleted_at is null;

create index if not exists idx_crm_tag_assignments_tenant_created
on crm_tag_assignments (tenant_id, created_at desc);

create index if not exists idx_crm_lists_tenant_created
on crm_lists (tenant_id, created_at desc);

create unique index if not exists uq_crm_lists_tenant_name
on crm_lists (tenant_id, lower(name))
where deleted_at is null;

create index if not exists idx_crm_list_members_list
on crm_list_members (list_id)
where deleted_at is null;

create index if not exists idx_crm_list_members_contact
on crm_list_members (contact_id)
where deleted_at is null;

create index if not exists idx_crm_list_members_tenant_created
on crm_list_members (tenant_id, added_at desc);

create index if not exists idx_crm_custom_fields_tenant_created
on crm_custom_fields (tenant_id, created_at desc);

create index if not exists idx_crm_custom_fields_applies_to
on crm_custom_fields (tenant_id, applies_to)
where deleted_at is null;

create index if not exists idx_crm_custom_field_values_entity
on crm_custom_field_values (tenant_id, entity_type, entity_id);

create index if not exists idx_crm_custom_field_values_tenant_created
on crm_custom_field_values (tenant_id, created_at desc);


-- =====================================================
-- 20. TENANT FKs (DEFERRED PATTERN)
-- =====================================================

do $$
begin
    alter table public.crm_pipelines
        add constraint fk_crm_pipelines_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_pipeline_stages
        add constraint fk_crm_pipeline_stages_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_campaigns
        add constraint fk_crm_campaigns_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_tags
        add constraint fk_crm_tags_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_companies
        add constraint fk_crm_companies_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_contacts
        add constraint fk_crm_contacts_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_leads
        add constraint fk_crm_leads_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_leads
        add constraint fk_crm_leads_converted_tenant
        foreign key (converted_tenant_id) references public.tenants(id) on delete set null;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_contact_company
        add constraint fk_crm_contact_company_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_company_tenants
        add constraint fk_crm_company_tenants_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_company_tenants
        add constraint fk_crm_company_tenants_linked_tenant
        foreign key (linked_tenant_id) references public.tenants(id) on delete set null;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_contact_tenants
        add constraint fk_crm_contact_tenants_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_contact_tenants
        add constraint fk_crm_contact_tenants_linked_tenant
        foreign key (linked_tenant_id) references public.tenants(id) on delete set null;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_opportunities
        add constraint fk_crm_opportunities_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_opportunities
        add constraint fk_crm_opportunities_linked_tenant
        foreign key (linked_tenant_id) references public.tenants(id) on delete set null;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_tasks
        add constraint fk_crm_tasks_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_interactions
        add constraint fk_crm_interactions_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_notes
        add constraint fk_crm_notes_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_tag_assignments
        add constraint fk_crm_tag_assignments_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_lists
        add constraint fk_crm_lists_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_list_members
        add constraint fk_crm_list_members_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_custom_fields
        add constraint fk_crm_custom_fields_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.crm_custom_field_values
        add constraint fk_crm_custom_field_values_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

drop trigger if exists trg_crm_contacts_consent_timestamps on public.crm_contacts;

drop trigger if exists trg_crm_leads_conversion_timestamp on public.crm_leads;

drop trigger if exists trg_crm_notes_version_increment on public.crm_notes;

-- ==========================
--  VIEW PIPELINE
-- ==========================

create or replace view public.v_crm_pipeline
with (security_invoker = true)
as
select
    o.id as opportunity_id,
    o.tenant_id,
    o.name as title,
    o.expected_revenue as amount,
    o.status,
    o.expected_close_date,
    ps.id as stage_id,
    ps.name as stage_name,
    ps.stage_order,
    pip.id as pipeline_id,
    pip.name as pipeline_name,
    co.id as company_id,
    co.name as company_name,
    ct.id as contact_id,
    ct.first_name,
    ct.last_name,
    ct.email as contact_email,
    o.created_at,
    o.updated_at
from public.crm_opportunities o
join public.crm_pipeline_stages ps on ps.id = o.stage_id
join public.crm_pipelines pip on pip.id = ps.pipeline_id
left join public.crm_companies co on co.id = o.company_id
left join public.crm_contacts ct on ct.id = o.contact_id
where o.deleted_at is null;

-- ==========================
--  CRM DOMAIN
-- ==========================

create or replace function public.crm_domain(
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
    v_result jsonb;
    v_row record;
    v_stages jsonb;
    v_limit int;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

    -- =================================================
    -- PIPELINES
    -- =================================================

    when 'list_pipelines' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.name), '[]'::jsonb)
        into v_result
        from (
            select
                p.id, p.tenant_id, p.name, p.description, p.is_default, p.is_active,
                p.created_at, p.updated_at, p.deleted_at
            from public.crm_pipelines p
            where p.tenant_id = v_tid and p.deleted_at is null
        ) t;

    when 'get_pipeline' then
        v_tid := platform.current_tenant_id();
        select to_jsonb(t) into v_result
        from (
            select
                p.id, p.tenant_id, p.name, p.description, p.is_default, p.is_active,
                p.created_at, p.updated_at, p.deleted_at
            from public.crm_pipelines p
            where p.id = (p_payload->>'id')::uuid
              and p.tenant_id = v_tid
              and p.deleted_at is null
        ) t;
        if v_result is null then
            raise exception 'Pipeline not found';
        end if;
        select coalesce(jsonb_agg(to_jsonb(s) order by s.stage_order), '[]'::jsonb)
        into v_stages
        from (
            select
                ps.id, ps.tenant_id, ps.pipeline_id, ps.name, ps.stage_order, ps.probability,
                ps.is_terminal, ps.terminal_outcome, ps.created_at, ps.updated_at, ps.deleted_at
            from public.crm_pipeline_stages ps
            where ps.pipeline_id = (p_payload->>'id')::uuid
              and ps.tenant_id = v_tid
              and ps.deleted_at is null
        ) s;
        v_result := jsonb_build_object('pipeline', v_result, 'stages', v_stages);

    when 'create_pipeline' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_pipelines (tenant_id, name, description, is_default, is_active)
        values (
            v_tid,
            p_payload->>'name',
            case when p_payload ? 'description' then p_payload->>'description' else null end,
            coalesce((p_payload->>'is_default')::boolean, false),
            coalesce((p_payload->>'is_active')::boolean, true)
        )
        returning
            id, tenant_id, name, description, is_default, is_active,
            created_at, updated_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_pipeline.created', 'crm_pipeline', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_pipeline' then
        v_tid := platform.current_tenant_id();
        update public.crm_pipelines p set
            name = case when p_payload ? 'name' then p_payload->>'name' else p.name end,
            description = case when p_payload ? 'description' then p_payload->>'description' else p.description end,
            is_default = case when p_payload ? 'is_default' then (p_payload->>'is_default')::boolean else p.is_default end,
            is_active = case when p_payload ? 'is_active' then (p_payload->>'is_active')::boolean else p.is_active end
        where p.id = (p_payload->>'id')::uuid
          and p.tenant_id = v_tid
          and p.deleted_at is null
        returning
            p.id, p.tenant_id, p.name, p.description, p.is_default, p.is_active,
            p.created_at, p.updated_at, p.deleted_at
        into v_row;
        if not found then raise exception 'Pipeline not found'; end if;
        perform platform.log_audit('crm_pipeline.updated', 'crm_pipeline', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_pipeline' then
        v_result := public.crm_soft_delete_row('public.crm_pipelines'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_pipeline.deleted', 'crm_pipeline', (p_payload->>'id')::uuid);

    -- =================================================
    -- PIPELINE STAGES
    -- =================================================

    when 'list_pipeline_stages' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.stage_order), '[]'::jsonb)
        into v_result
        from (
            select
                ps.id, ps.tenant_id, ps.pipeline_id, ps.name, ps.stage_order, ps.probability,
                ps.is_terminal, ps.terminal_outcome, ps.created_at, ps.updated_at, ps.deleted_at
            from public.crm_pipeline_stages ps
            where ps.pipeline_id = (p_payload->>'pipeline_id')::uuid
              and ps.tenant_id = v_tid
              and ps.deleted_at is null
        ) t;

    when 'create_pipeline_stage' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_pipeline_stages (
            tenant_id, pipeline_id, name, stage_order, probability, is_terminal, terminal_outcome
        )
        values (
            v_tid,
            (p_payload->>'pipeline_id')::uuid,
            p_payload->>'name',
            (p_payload->>'stage_order')::int,
            coalesce((p_payload->>'probability')::numeric, 0),
            coalesce((p_payload->>'is_terminal')::boolean, false),
            case
                when p_payload ? 'terminal_outcome' and p_payload->>'terminal_outcome' is not null
                then (p_payload->>'terminal_outcome')::public.crm_terminal_outcome
                else null
            end
        )
        returning
            id, tenant_id, pipeline_id, name, stage_order, probability,
            is_terminal, terminal_outcome, created_at, updated_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_pipeline_stage.created', 'crm_pipeline_stage', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_pipeline_stage' then
        v_tid := platform.current_tenant_id();
        update public.crm_pipeline_stages ps set
            name = case when p_payload ? 'name' then p_payload->>'name' else ps.name end,
            stage_order = case when p_payload ? 'stage_order' then (p_payload->>'stage_order')::int else ps.stage_order end,
            probability = case when p_payload ? 'probability' then (p_payload->>'probability')::numeric else ps.probability end,
            is_terminal = case when p_payload ? 'is_terminal' then (p_payload->>'is_terminal')::boolean else ps.is_terminal end,
            terminal_outcome = case
                when p_payload ? 'terminal_outcome' then
                    case when p_payload->>'terminal_outcome' is null then null
                    else (p_payload->>'terminal_outcome')::public.crm_terminal_outcome end
                else ps.terminal_outcome
            end
        where ps.id = (p_payload->>'id')::uuid
          and ps.tenant_id = v_tid
          and ps.deleted_at is null
        returning
            ps.id, ps.tenant_id, ps.pipeline_id, ps.name, ps.stage_order, ps.probability,
            ps.is_terminal, ps.terminal_outcome, ps.created_at, ps.updated_at, ps.deleted_at
        into v_row;
        if not found then raise exception 'Pipeline stage not found'; end if;
        perform platform.log_audit('crm_pipeline_stage.updated', 'crm_pipeline_stage', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_pipeline_stage' then
        v_result := public.crm_soft_delete_row('public.crm_pipeline_stages'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_pipeline_stage.deleted', 'crm_pipeline_stage', (p_payload->>'id')::uuid);

    -- =================================================
    -- CAMPAIGNS
    -- =================================================

    when 'list_campaigns' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb)
        into v_result
        from (
            select
                c.id, c.tenant_id, c.name, c.description, c.campaign_type, c.status,
                c.start_date, c.end_date, c.budget, c.created_at, c.updated_at, c.deleted_at
            from public.crm_campaigns c
            where c.tenant_id = v_tid
              and c.deleted_at is null
              and (not p_payload ? 'status' or c.status = (p_payload->>'status')::public.crm_campaign_status)
        ) t;

    when 'get_campaign' then
        v_tid := platform.current_tenant_id();
        select to_jsonb(t) into v_result
        from (
            select
                c.id, c.tenant_id, c.name, c.description, c.campaign_type, c.status,
                c.start_date, c.end_date, c.budget, c.created_at, c.updated_at, c.deleted_at
            from public.crm_campaigns c
            where c.id = (p_payload->>'id')::uuid
              and c.tenant_id = v_tid
              and c.deleted_at is null
        ) t;
        if v_result is null then raise exception 'Campaign not found'; end if;

    when 'create_campaign' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_campaigns (
            tenant_id, name, description, campaign_type, status, start_date, end_date, budget
        )
        values (
            v_tid,
            p_payload->>'name',
            case when p_payload ? 'description' then p_payload->>'description' else null end,
            coalesce((p_payload->>'campaign_type')::public.crm_campaign_type, 'other'::public.crm_campaign_type),
            coalesce((p_payload->>'status')::public.crm_campaign_status, 'draft'::public.crm_campaign_status),
            case when p_payload ? 'start_date' and p_payload->>'start_date' is not null then (p_payload->>'start_date')::date else null end,
            case when p_payload ? 'end_date' and p_payload->>'end_date' is not null then (p_payload->>'end_date')::date else null end,
            case when p_payload ? 'budget' and p_payload->>'budget' is not null then (p_payload->>'budget')::numeric else null end
        )
        returning
            id, tenant_id, name, description, campaign_type, status,
            start_date, end_date, budget, created_at, updated_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_campaign.created', 'crm_campaign', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_campaign' then
        v_tid := platform.current_tenant_id();
        update public.crm_campaigns c set
            name = case when p_payload ? 'name' then p_payload->>'name' else c.name end,
            description = case when p_payload ? 'description' then p_payload->>'description' else c.description end,
            campaign_type = case when p_payload ? 'campaign_type' then (p_payload->>'campaign_type')::public.crm_campaign_type else c.campaign_type end,
            status = case when p_payload ? 'status' then (p_payload->>'status')::public.crm_campaign_status else c.status end,
            start_date = case when p_payload ? 'start_date' then case when p_payload->>'start_date' is null then null else (p_payload->>'start_date')::date end else c.start_date end,
            end_date = case when p_payload ? 'end_date' then case when p_payload->>'end_date' is null then null else (p_payload->>'end_date')::date end else c.end_date end,
            budget = case when p_payload ? 'budget' then case when p_payload->>'budget' is null then null else (p_payload->>'budget')::numeric end else c.budget end
        where c.id = (p_payload->>'id')::uuid
          and c.tenant_id = v_tid
          and c.deleted_at is null
        returning
            c.id, c.tenant_id, c.name, c.description, c.campaign_type, c.status,
            c.start_date, c.end_date, c.budget, c.created_at, c.updated_at, c.deleted_at
        into v_row;
        if not found then raise exception 'Campaign not found'; end if;
        perform platform.log_audit('crm_campaign.updated', 'crm_campaign', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_campaign' then
        v_result := public.crm_soft_delete_row('public.crm_campaigns'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_campaign.deleted', 'crm_campaign', (p_payload->>'id')::uuid);

    -- =================================================
    -- TAGS
    -- =================================================

    when 'list_tags' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.name), '[]'::jsonb)
        into v_result
        from (
            select t2.id, t2.tenant_id, t2.name, t2.color, t2.created_at, t2.deleted_at
            from public.crm_tags t2
            where t2.tenant_id = v_tid and t2.deleted_at is null
        ) t;

    when 'create_tag' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_tags (tenant_id, name, color)
        values (
            v_tid,
            p_payload->>'name',
            case when p_payload ? 'color' then p_payload->>'color' else null end
        )
        returning id, tenant_id, name, color, created_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_tag.created', 'crm_tag', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_tag' then
        v_tid := platform.current_tenant_id();
        update public.crm_tags t set
            name = case when p_payload ? 'name' then p_payload->>'name' else t.name end,
            color = case when p_payload ? 'color' then p_payload->>'color' else t.color end
        where t.id = (p_payload->>'id')::uuid
          and t.tenant_id = v_tid
          and t.deleted_at is null
        returning id, tenant_id, name, color, created_at, deleted_at
        into v_row;
        if not found then raise exception 'Tag not found'; end if;
        perform platform.log_audit('crm_tag.updated', 'crm_tag', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_tag' then
        v_result := public.crm_soft_delete_row('public.crm_tags'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_tag.deleted', 'crm_tag', (p_payload->>'id')::uuid);

    -- =================================================
    -- COMPANIES
    -- =================================================

    when 'list_companies' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.name), '[]'::jsonb)
        into v_result
        from (
            select
                co.id, co.tenant_id, co.name, co.legal_name, co.website, co.industry,
                co.owner_user_id, co.created_at, co.updated_at, co.deleted_at
            from public.crm_companies co
            where co.tenant_id = v_tid and co.deleted_at is null
        ) t;

    when 'get_company' then
        v_tid := platform.current_tenant_id();
        select to_jsonb(t) into v_result
        from (
            select
                co.id, co.tenant_id, co.name, co.legal_name, co.website, co.industry,
                co.owner_user_id, co.created_at, co.updated_at, co.deleted_at
            from public.crm_companies co
            where co.id = (p_payload->>'id')::uuid
              and co.tenant_id = v_tid
              and co.deleted_at is null
        ) t;
        if v_result is null then raise exception 'Company not found'; end if;

    when 'create_company' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_companies (tenant_id, name, legal_name, website, industry, owner_user_id)
        values (
            v_tid,
            p_payload->>'name',
            case when p_payload ? 'legal_name' then p_payload->>'legal_name' else null end,
            case when p_payload ? 'website' then p_payload->>'website' else null end,
            case when p_payload ? 'industry' then p_payload->>'industry' else null end,
            case when p_payload ? 'owner_user_id' and p_payload->>'owner_user_id' is not null then (p_payload->>'owner_user_id')::uuid else null end
        )
        returning
            id, tenant_id, name, legal_name, website, industry,
            owner_user_id, created_at, updated_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_company.created', 'crm_company', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_company' then
        v_tid := platform.current_tenant_id();
        update public.crm_companies co set
            name = case when p_payload ? 'name' then p_payload->>'name' else co.name end,
            legal_name = case when p_payload ? 'legal_name' then p_payload->>'legal_name' else co.legal_name end,
            website = case when p_payload ? 'website' then p_payload->>'website' else co.website end,
            industry = case when p_payload ? 'industry' then p_payload->>'industry' else co.industry end,
            owner_user_id = case
                when p_payload ? 'owner_user_id' then
                    case when p_payload->>'owner_user_id' is null then null else (p_payload->>'owner_user_id')::uuid end
                else co.owner_user_id
            end
        where co.id = (p_payload->>'id')::uuid
          and co.tenant_id = v_tid
          and co.deleted_at is null
        returning
            co.id, co.tenant_id, co.name, co.legal_name, co.website, co.industry,
            co.owner_user_id, co.created_at, co.updated_at, co.deleted_at
        into v_row;
        if not found then raise exception 'Company not found'; end if;
        perform platform.log_audit('crm_company.updated', 'crm_company', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_company' then
        v_result := public.crm_soft_delete_row('public.crm_companies'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_company.deleted', 'crm_company', (p_payload->>'id')::uuid);

    -- =================================================
    -- CONTACTS
    -- =================================================

    when 'list_contacts' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb)
        into v_result
        from (
            select
                c.id, c.tenant_id, c.first_name, c.last_name, c.display_name, c.email, c.phone,
                c.language, c.timezone, c.marketing_consent, c.marketing_consent_at,
                c.gdpr_consent, c.gdpr_consent_at, c.status, c.lead_source, c.owner_user_id,
                c.created_at, c.updated_at, c.deleted_at
            from public.crm_contacts c
            where c.tenant_id = v_tid
              and c.deleted_at is null
              and (not p_payload ? 'status' or c.status = (p_payload->>'status')::public.crm_contact_status)
        ) t;

    when 'get_contact' then
        v_tid := platform.current_tenant_id();
        select to_jsonb(t) into v_result
        from (
            select
                c.id, c.tenant_id, c.first_name, c.last_name, c.display_name, c.email, c.phone,
                c.language, c.timezone, c.marketing_consent, c.marketing_consent_at,
                c.gdpr_consent, c.gdpr_consent_at, c.status, c.lead_source, c.owner_user_id,
                c.created_at, c.updated_at, c.deleted_at
            from public.crm_contacts c
            where c.id = (p_payload->>'id')::uuid
              and c.tenant_id = v_tid
              and c.deleted_at is null
        ) t;
        if v_result is null then raise exception 'Contact not found'; end if;

    when 'create_contact' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_contacts (
            tenant_id, first_name, last_name, display_name, email, phone, language, timezone,
            marketing_consent, gdpr_consent, status, lead_source, owner_user_id
        )
        values (
            v_tid,
            case when p_payload ? 'first_name' then p_payload->>'first_name' else null end,
            case when p_payload ? 'last_name' then p_payload->>'last_name' else null end,
            case when p_payload ? 'display_name' then p_payload->>'display_name' else null end,
            case when p_payload ? 'email' then p_payload->>'email' else null end,
            case when p_payload ? 'phone' then p_payload->>'phone' else null end,
            coalesce(p_payload->>'language', 'en'),
            case when p_payload ? 'timezone' then p_payload->>'timezone' else null end,
            coalesce((p_payload->>'marketing_consent')::boolean, false),
            coalesce((p_payload->>'gdpr_consent')::boolean, false),
            coalesce((p_payload->>'status')::public.crm_contact_status, 'active'::public.crm_contact_status),
            case when p_payload ? 'lead_source' then p_payload->>'lead_source' else null end,
            case when p_payload ? 'owner_user_id' and p_payload->>'owner_user_id' is not null then (p_payload->>'owner_user_id')::uuid else null end
        )
        returning
            id, tenant_id, first_name, last_name, display_name, email, phone,
            language, timezone, marketing_consent, marketing_consent_at,
            gdpr_consent, gdpr_consent_at, status, lead_source, owner_user_id,
            created_at, updated_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_contact.created', 'crm_contact', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_contact' then
        v_tid := platform.current_tenant_id();
        update public.crm_contacts c set
            first_name = case when p_payload ? 'first_name' then p_payload->>'first_name' else c.first_name end,
            last_name = case when p_payload ? 'last_name' then p_payload->>'last_name' else c.last_name end,
            display_name = case when p_payload ? 'display_name' then p_payload->>'display_name' else c.display_name end,
            email = case when p_payload ? 'email' then p_payload->>'email' else c.email end,
            phone = case when p_payload ? 'phone' then p_payload->>'phone' else c.phone end,
            language = case when p_payload ? 'language' then p_payload->>'language' else c.language end,
            timezone = case when p_payload ? 'timezone' then p_payload->>'timezone' else c.timezone end,
            marketing_consent = case when p_payload ? 'marketing_consent' then (p_payload->>'marketing_consent')::boolean else c.marketing_consent end,
            gdpr_consent = case when p_payload ? 'gdpr_consent' then (p_payload->>'gdpr_consent')::boolean else c.gdpr_consent end,
            status = case when p_payload ? 'status' then (p_payload->>'status')::public.crm_contact_status else c.status end,
            lead_source = case when p_payload ? 'lead_source' then p_payload->>'lead_source' else c.lead_source end,
            owner_user_id = case
                when p_payload ? 'owner_user_id' then
                    case when p_payload->>'owner_user_id' is null then null else (p_payload->>'owner_user_id')::uuid end
                else c.owner_user_id
            end
        where c.id = (p_payload->>'id')::uuid
          and c.tenant_id = v_tid
          and c.deleted_at is null
        returning
            c.id, c.tenant_id, c.first_name, c.last_name, c.display_name, c.email, c.phone,
            c.language, c.timezone, c.marketing_consent, c.marketing_consent_at,
            c.gdpr_consent, c.gdpr_consent_at, c.status, c.lead_source, c.owner_user_id,
            c.created_at, c.updated_at, c.deleted_at
        into v_row;
        if not found then raise exception 'Contact not found'; end if;
        perform platform.log_audit('crm_contact.updated', 'crm_contact', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_contact' then
        v_result := public.crm_soft_delete_row('public.crm_contacts'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_contact.deleted', 'crm_contact', (p_payload->>'id')::uuid);

    -- =================================================
    -- LEADS
    -- =================================================

    when 'list_leads' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb)
        into v_result
        from (
            select
                l.id, l.tenant_id, l.first_name, l.last_name, l.email, l.phone, l.status, l.source,
                l.score, l.temperature, l.owner_user_id, l.estimated_value, l.campaign_id,
                l.converted_contact_id, l.converted_company_id, l.converted_tenant_id, l.converted_at,
                l.created_at, l.updated_at, l.deleted_at
            from public.crm_leads l
            where l.tenant_id = v_tid
              and l.deleted_at is null
              and (not p_payload ? 'status' or l.status = (p_payload->>'status')::public.crm_lead_status)
              and (not p_payload ? 'campaign_id' or l.campaign_id = (p_payload->>'campaign_id')::uuid)
        ) t;

    when 'get_lead' then
        v_tid := platform.current_tenant_id();
        select to_jsonb(t) into v_result
        from (
            select
                l.id, l.tenant_id, l.first_name, l.last_name, l.email, l.phone, l.status, l.source,
                l.score, l.temperature, l.owner_user_id, l.estimated_value, l.campaign_id,
                l.converted_contact_id, l.converted_company_id, l.converted_tenant_id, l.converted_at,
                l.created_at, l.updated_at, l.deleted_at
            from public.crm_leads l
            where l.id = (p_payload->>'id')::uuid
              and l.tenant_id = v_tid
              and l.deleted_at is null
        ) t;
        if v_result is null then raise exception 'Lead not found'; end if;

    when 'create_lead' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_leads (
            tenant_id, first_name, last_name, email, phone, status, source, score, temperature,
            owner_user_id, estimated_value, campaign_id
        )
        values (
            v_tid,
            case when p_payload ? 'first_name' then p_payload->>'first_name' else null end,
            case when p_payload ? 'last_name' then p_payload->>'last_name' else null end,
            case when p_payload ? 'email' then p_payload->>'email' else null end,
            case when p_payload ? 'phone' then p_payload->>'phone' else null end,
            coalesce((p_payload->>'status')::public.crm_lead_status, 'new'::public.crm_lead_status),
            case when p_payload ? 'source' then p_payload->>'source' else null end,
            case when p_payload ? 'score' and p_payload->>'score' is not null then (p_payload->>'score')::numeric else null end,
            case when p_payload ? 'temperature' and p_payload->>'temperature' is not null then (p_payload->>'temperature')::public.crm_lead_temperature else null end,
            case when p_payload ? 'owner_user_id' and p_payload->>'owner_user_id' is not null then (p_payload->>'owner_user_id')::uuid else null end,
            case when p_payload ? 'estimated_value' and p_payload->>'estimated_value' is not null then (p_payload->>'estimated_value')::numeric else null end,
            case when p_payload ? 'campaign_id' and p_payload->>'campaign_id' is not null then (p_payload->>'campaign_id')::uuid else null end
        )
        returning
            id, tenant_id, first_name, last_name, email, phone, status, source,
            score, temperature, owner_user_id, estimated_value, campaign_id,
            converted_contact_id, converted_company_id, converted_tenant_id, converted_at,
            created_at, updated_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_lead.created', 'crm_lead', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_lead' then
        v_tid := platform.current_tenant_id();
        update public.crm_leads l set
            first_name = case when p_payload ? 'first_name' then p_payload->>'first_name' else l.first_name end,
            last_name = case when p_payload ? 'last_name' then p_payload->>'last_name' else l.last_name end,
            email = case when p_payload ? 'email' then p_payload->>'email' else l.email end,
            phone = case when p_payload ? 'phone' then p_payload->>'phone' else l.phone end,
            source = case when p_payload ? 'source' then p_payload->>'source' else l.source end,
            score = case when p_payload ? 'score' then case when p_payload->>'score' is null then null else (p_payload->>'score')::numeric end else l.score end,
            temperature = case when p_payload ? 'temperature' then case when p_payload->>'temperature' is null then null else (p_payload->>'temperature')::public.crm_lead_temperature end else l.temperature end,
            owner_user_id = case when p_payload ? 'owner_user_id' then case when p_payload->>'owner_user_id' is null then null else (p_payload->>'owner_user_id')::uuid end else l.owner_user_id end,
            estimated_value = case when p_payload ? 'estimated_value' then case when p_payload->>'estimated_value' is null then null else (p_payload->>'estimated_value')::numeric end else l.estimated_value end,
            campaign_id = case when p_payload ? 'campaign_id' then case when p_payload->>'campaign_id' is null then null else (p_payload->>'campaign_id')::uuid end else l.campaign_id end,
            converted_contact_id = case when p_payload ? 'converted_contact_id' then case when p_payload->>'converted_contact_id' is null then null else (p_payload->>'converted_contact_id')::uuid end else l.converted_contact_id end,
            converted_company_id = case when p_payload ? 'converted_company_id' then case when p_payload->>'converted_company_id' is null then null else (p_payload->>'converted_company_id')::uuid end else l.converted_company_id end,
            converted_tenant_id = case when p_payload ? 'converted_tenant_id' then case when p_payload->>'converted_tenant_id' is null then null else (p_payload->>'converted_tenant_id')::uuid end else l.converted_tenant_id end,
            status = case when p_payload ? 'status' then (p_payload->>'status')::public.crm_lead_status else l.status end
        where l.id = (p_payload->>'id')::uuid
          and l.tenant_id = v_tid
          and l.deleted_at is null
        returning
            l.id, l.tenant_id, l.first_name, l.last_name, l.email, l.phone, l.status, l.source,
            l.score, l.temperature, l.owner_user_id, l.estimated_value, l.campaign_id,
            l.converted_contact_id, l.converted_company_id, l.converted_tenant_id, l.converted_at,
            l.created_at, l.updated_at, l.deleted_at
        into v_row;
        if not found then raise exception 'Lead not found'; end if;
        perform platform.log_audit('crm_lead.updated', 'crm_lead', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_lead' then
        v_result := public.crm_soft_delete_row('public.crm_leads'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_lead.deleted', 'crm_lead', (p_payload->>'id')::uuid);

    -- =================================================
    -- CONTACT ↔ COMPANY
    -- =================================================

    when 'list_contact_companies' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb)
        into v_result
        from (
            select cc.id, cc.tenant_id, cc.contact_id, cc.company_id, cc.role, cc.is_primary, cc.created_at, cc.deleted_at
            from public.crm_contact_company cc
            where cc.tenant_id = v_tid
              and cc.deleted_at is null
              and (not p_payload ? 'contact_id' or cc.contact_id = (p_payload->>'contact_id')::uuid)
              and (not p_payload ? 'company_id' or cc.company_id = (p_payload->>'company_id')::uuid)
        ) t;

    when 'create_contact_company' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_contact_company (tenant_id, contact_id, company_id, role, is_primary)
        values (
            v_tid,
            (p_payload->>'contact_id')::uuid,
            (p_payload->>'company_id')::uuid,
            p_payload->>'role',
            coalesce((p_payload->>'is_primary')::boolean, false)
        )
        returning id, tenant_id, contact_id, company_id, role, is_primary, created_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_contact_company.created', 'crm_contact_company', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_contact_company' then
        v_tid := platform.current_tenant_id();
        update public.crm_contact_company cc set
            role = case when p_payload ? 'role' then p_payload->>'role' else cc.role end,
            is_primary = case when p_payload ? 'is_primary' then (p_payload->>'is_primary')::boolean else cc.is_primary end
        where cc.id = (p_payload->>'id')::uuid
          and cc.tenant_id = v_tid
          and cc.deleted_at is null
        returning id, tenant_id, contact_id, company_id, role, is_primary, created_at, deleted_at
        into v_row;
        if not found then raise exception 'Contact company link not found'; end if;
        perform platform.log_audit('crm_contact_company.updated', 'crm_contact_company', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_contact_company' then
        v_result := public.crm_soft_delete_row('public.crm_contact_company'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_contact_company.deleted', 'crm_contact_company', (p_payload->>'id')::uuid);

    -- =================================================
    -- COMPANY ↔ TENANT
    -- =================================================

    when 'list_company_tenants' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb)
        into v_result
        from (
            select ct.id, ct.tenant_id, ct.company_id, ct.linked_tenant_id, ct.relationship_type, ct.created_at, ct.deleted_at
            from public.crm_company_tenants ct
            where ct.tenant_id = v_tid
              and ct.deleted_at is null
              and (not p_payload ? 'company_id' or ct.company_id = (p_payload->>'company_id')::uuid)
        ) t;

    when 'create_company_tenant' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_company_tenants (tenant_id, company_id, linked_tenant_id, relationship_type)
        values (
            v_tid,
            (p_payload->>'company_id')::uuid,
            case when p_payload ? 'linked_tenant_id' and p_payload->>'linked_tenant_id' is not null then (p_payload->>'linked_tenant_id')::uuid else null end,
            case when p_payload ? 'relationship_type' then p_payload->>'relationship_type' else null end
        )
        returning id, tenant_id, company_id, linked_tenant_id, relationship_type, created_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_company_tenant.created', 'crm_company_tenant', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_company_tenant' then
        v_tid := platform.current_tenant_id();
        update public.crm_company_tenants ct set
            linked_tenant_id = case when p_payload ? 'linked_tenant_id' then case when p_payload->>'linked_tenant_id' is null then null else (p_payload->>'linked_tenant_id')::uuid end else ct.linked_tenant_id end,
            relationship_type = case when p_payload ? 'relationship_type' then p_payload->>'relationship_type' else ct.relationship_type end
        where ct.id = (p_payload->>'id')::uuid
          and ct.tenant_id = v_tid
          and ct.deleted_at is null
        returning id, tenant_id, company_id, linked_tenant_id, relationship_type, created_at, deleted_at
        into v_row;
        if not found then raise exception 'Company tenant link not found'; end if;
        perform platform.log_audit('crm_company_tenant.updated', 'crm_company_tenant', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_company_tenant' then
        v_result := public.crm_soft_delete_row('public.crm_company_tenants'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_company_tenant.deleted', 'crm_company_tenant', (p_payload->>'id')::uuid);

    -- =================================================
    -- CONTACT ↔ TENANT
    -- =================================================

    when 'list_contact_tenants' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb)
        into v_result
        from (
            select ct.id, ct.tenant_id, ct.contact_id, ct.linked_tenant_id, ct.relationship_type, ct.created_at, ct.deleted_at
            from public.crm_contact_tenants ct
            where ct.tenant_id = v_tid
              and ct.deleted_at is null
              and (not p_payload ? 'contact_id' or ct.contact_id = (p_payload->>'contact_id')::uuid)
        ) t;

    when 'create_contact_tenant' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_contact_tenants (tenant_id, contact_id, linked_tenant_id, relationship_type)
        values (
            v_tid,
            (p_payload->>'contact_id')::uuid,
            case when p_payload ? 'linked_tenant_id' and p_payload->>'linked_tenant_id' is not null then (p_payload->>'linked_tenant_id')::uuid else null end,
            case when p_payload ? 'relationship_type' then p_payload->>'relationship_type' else null end
        )
        returning id, tenant_id, contact_id, linked_tenant_id, relationship_type, created_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_contact_tenant.created', 'crm_contact_tenant', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_contact_tenant' then
        v_tid := platform.current_tenant_id();
        update public.crm_contact_tenants ct set
            linked_tenant_id = case when p_payload ? 'linked_tenant_id' then case when p_payload->>'linked_tenant_id' is null then null else (p_payload->>'linked_tenant_id')::uuid end else ct.linked_tenant_id end,
            relationship_type = case when p_payload ? 'relationship_type' then p_payload->>'relationship_type' else ct.relationship_type end
        where ct.id = (p_payload->>'id')::uuid
          and ct.tenant_id = v_tid
          and ct.deleted_at is null
        returning id, tenant_id, contact_id, linked_tenant_id, relationship_type, created_at, deleted_at
        into v_row;
        if not found then raise exception 'Contact tenant link not found'; end if;
        perform platform.log_audit('crm_contact_tenant.updated', 'crm_contact_tenant', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_contact_tenant' then
        v_result := public.crm_soft_delete_row('public.crm_contact_tenants'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_contact_tenant.deleted', 'crm_contact_tenant', (p_payload->>'id')::uuid);

    -- =================================================
    -- OPPORTUNITIES
    -- =================================================

    when 'list_opportunities' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb)
        into v_result
        from (
            select
                o.id, o.tenant_id, o.pipeline_id, o.stage_id, o.contact_id, o.company_id, o.linked_tenant_id,
                o.name, o.expected_revenue, o.probability, o.expected_close_date, o.owner_user_id, o.status,
                o.created_at, o.updated_at, o.deleted_at
            from public.crm_opportunities o
            where o.tenant_id = v_tid
              and o.deleted_at is null
              and (not p_payload ? 'pipeline_id' or o.pipeline_id = (p_payload->>'pipeline_id')::uuid)
              and (not p_payload ? 'stage_id' or o.stage_id = (p_payload->>'stage_id')::uuid)
              and (not p_payload ? 'status' or o.status = (p_payload->>'status')::public.crm_opportunity_status)
        ) t;

    when 'get_opportunity' then
        v_tid := platform.current_tenant_id();
        select to_jsonb(t) into v_result
        from (
            select
                o.id, o.tenant_id, o.pipeline_id, o.stage_id, o.contact_id, o.company_id, o.linked_tenant_id,
                o.name, o.expected_revenue, o.probability, o.expected_close_date, o.owner_user_id, o.status,
                o.created_at, o.updated_at, o.deleted_at
            from public.crm_opportunities o
            where o.id = (p_payload->>'id')::uuid
              and o.tenant_id = v_tid
              and o.deleted_at is null
        ) t;
        if v_result is null then raise exception 'Opportunity not found'; end if;

    when 'create_opportunity' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_opportunities (
            tenant_id, pipeline_id, stage_id, name, contact_id, company_id, linked_tenant_id,
            expected_revenue, probability, expected_close_date, owner_user_id, status
        )
        values (
            v_tid,
            (p_payload->>'pipeline_id')::uuid,
            (p_payload->>'stage_id')::uuid,
            p_payload->>'name',
            case when p_payload ? 'contact_id' and p_payload->>'contact_id' is not null then (p_payload->>'contact_id')::uuid else null end,
            case when p_payload ? 'company_id' and p_payload->>'company_id' is not null then (p_payload->>'company_id')::uuid else null end,
            case when p_payload ? 'linked_tenant_id' and p_payload->>'linked_tenant_id' is not null then (p_payload->>'linked_tenant_id')::uuid else null end,
            case when p_payload ? 'expected_revenue' and p_payload->>'expected_revenue' is not null then (p_payload->>'expected_revenue')::numeric else null end,
            case when p_payload ? 'probability' and p_payload->>'probability' is not null then (p_payload->>'probability')::numeric else null end,
            case when p_payload ? 'expected_close_date' and p_payload->>'expected_close_date' is not null then (p_payload->>'expected_close_date')::date else null end,
            case when p_payload ? 'owner_user_id' and p_payload->>'owner_user_id' is not null then (p_payload->>'owner_user_id')::uuid else null end,
            coalesce((p_payload->>'status')::public.crm_opportunity_status, 'open'::public.crm_opportunity_status)
        )
        returning
            id, tenant_id, pipeline_id, stage_id, contact_id, company_id, linked_tenant_id,
            name, expected_revenue, probability, expected_close_date, owner_user_id, status,
            created_at, updated_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_opportunity.created', 'crm_opportunity', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_opportunity' then
        v_tid := platform.current_tenant_id();
        update public.crm_opportunities o set
            pipeline_id = case when p_payload ? 'pipeline_id' then (p_payload->>'pipeline_id')::uuid else o.pipeline_id end,
            stage_id = case when p_payload ? 'stage_id' then (p_payload->>'stage_id')::uuid else o.stage_id end,
            name = case when p_payload ? 'name' then p_payload->>'name' else o.name end,
            contact_id = case when p_payload ? 'contact_id' then case when p_payload->>'contact_id' is null then null else (p_payload->>'contact_id')::uuid end else o.contact_id end,
            company_id = case when p_payload ? 'company_id' then case when p_payload->>'company_id' is null then null else (p_payload->>'company_id')::uuid end else o.company_id end,
            linked_tenant_id = case when p_payload ? 'linked_tenant_id' then case when p_payload->>'linked_tenant_id' is null then null else (p_payload->>'linked_tenant_id')::uuid end else o.linked_tenant_id end,
            expected_revenue = case when p_payload ? 'expected_revenue' then case when p_payload->>'expected_revenue' is null then null else (p_payload->>'expected_revenue')::numeric end else o.expected_revenue end,
            probability = case when p_payload ? 'probability' then case when p_payload->>'probability' is null then null else (p_payload->>'probability')::numeric end else o.probability end,
            expected_close_date = case when p_payload ? 'expected_close_date' then case when p_payload->>'expected_close_date' is null then null else (p_payload->>'expected_close_date')::date end else o.expected_close_date end,
            owner_user_id = case when p_payload ? 'owner_user_id' then case when p_payload->>'owner_user_id' is null then null else (p_payload->>'owner_user_id')::uuid end else o.owner_user_id end,
            status = case when p_payload ? 'status' then (p_payload->>'status')::public.crm_opportunity_status else o.status end
        where o.id = (p_payload->>'id')::uuid
          and o.tenant_id = v_tid
          and o.deleted_at is null
        returning
            o.id, o.tenant_id, o.pipeline_id, o.stage_id, o.contact_id, o.company_id, o.linked_tenant_id,
            o.name, o.expected_revenue, o.probability, o.expected_close_date, o.owner_user_id, o.status,
            o.created_at, o.updated_at, o.deleted_at
        into v_row;
        if not found then raise exception 'Opportunity not found'; end if;
        perform platform.log_audit('crm_opportunity.updated', 'crm_opportunity', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_opportunity' then
        v_result := public.crm_soft_delete_row('public.crm_opportunities'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_opportunity.deleted', 'crm_opportunity', (p_payload->>'id')::uuid);

    -- =================================================
    -- TASKS
    -- =================================================

    when 'list_tasks' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.due_at asc nulls last), '[]'::jsonb)
        into v_result
        from (
            select
                tk.id, tk.tenant_id, tk.title, tk.description, tk.target_type, tk.target_id,
                tk.priority, tk.due_at, tk.status, tk.owner_user_id,
                tk.created_at, tk.updated_at, tk.deleted_at
            from public.crm_tasks tk
            where tk.tenant_id = v_tid
              and tk.deleted_at is null
              and (not p_payload ? 'target_type' or tk.target_type = (p_payload->>'target_type')::public.crm_task_target_type)
              and (not p_payload ? 'target_id' or tk.target_id = (p_payload->>'target_id')::uuid)
              and (not p_payload ? 'status' or tk.status = (p_payload->>'status')::public.crm_task_status)
        ) t;

    when 'get_task' then
        v_tid := platform.current_tenant_id();
        select to_jsonb(t) into v_result
        from (
            select
                tk.id, tk.tenant_id, tk.title, tk.description, tk.target_type, tk.target_id,
                tk.priority, tk.due_at, tk.status, tk.owner_user_id,
                tk.created_at, tk.updated_at, tk.deleted_at
            from public.crm_tasks tk
            where tk.id = (p_payload->>'id')::uuid
              and tk.tenant_id = v_tid
              and tk.deleted_at is null
        ) t;
        if v_result is null then raise exception 'Task not found'; end if;

    when 'create_task' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_tasks (
            tenant_id, title, description, target_type, target_id, priority, due_at, status, owner_user_id
        )
        values (
            v_tid,
            p_payload->>'title',
            case when p_payload ? 'description' then p_payload->>'description' else null end,
            (p_payload->>'target_type')::public.crm_task_target_type,
            (p_payload->>'target_id')::uuid,
            coalesce((p_payload->>'priority')::public.priority_level, 'normal'::public.priority_level),
            case when p_payload ? 'due_at' and p_payload->>'due_at' is not null then (p_payload->>'due_at')::timestamptz else null end,
            coalesce((p_payload->>'status')::public.crm_task_status, 'pending'::public.crm_task_status),
            case when p_payload ? 'owner_user_id' and p_payload->>'owner_user_id' is not null then (p_payload->>'owner_user_id')::uuid else null end
        )
        returning
            id, tenant_id, title, description, target_type, target_id,
            priority, due_at, status, owner_user_id,
            created_at, updated_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_task.created', 'crm_task', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_task' then
        v_tid := platform.current_tenant_id();
        update public.crm_tasks tk set
            title = case when p_payload ? 'title' then p_payload->>'title' else tk.title end,
            description = case when p_payload ? 'description' then p_payload->>'description' else tk.description end,
            target_type = case when p_payload ? 'target_type' then (p_payload->>'target_type')::public.crm_task_target_type else tk.target_type end,
            target_id = case when p_payload ? 'target_id' then (p_payload->>'target_id')::uuid else tk.target_id end,
            priority = case when p_payload ? 'priority' then (p_payload->>'priority')::public.priority_level else tk.priority end,
            due_at = case when p_payload ? 'due_at' then case when p_payload->>'due_at' is null then null else (p_payload->>'due_at')::timestamptz end else tk.due_at end,
            status = case when p_payload ? 'status' then (p_payload->>'status')::public.crm_task_status else tk.status end,
            owner_user_id = case when p_payload ? 'owner_user_id' then case when p_payload->>'owner_user_id' is null then null else (p_payload->>'owner_user_id')::uuid end else tk.owner_user_id end
        where tk.id = (p_payload->>'id')::uuid
          and tk.tenant_id = v_tid
          and tk.deleted_at is null
        returning
            tk.id, tk.tenant_id, tk.title, tk.description, tk.target_type, tk.target_id,
            tk.priority, tk.due_at, tk.status, tk.owner_user_id,
            tk.created_at, tk.updated_at, tk.deleted_at
        into v_row;
        if not found then raise exception 'Task not found'; end if;
        perform platform.log_audit('crm_task.updated', 'crm_task', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_task' then
        v_result := public.crm_soft_delete_row('public.crm_tasks'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_task.deleted', 'crm_task', (p_payload->>'id')::uuid);

    -- =================================================
    -- INTERACTIONS
    -- =================================================

    when 'list_interactions' then
        v_tid := platform.current_tenant_id();
        v_limit := least(coalesce((p_payload->>'limit')::int, 100), 500);
        select coalesce(jsonb_agg(to_jsonb(t) order by t.occurred_at desc), '[]'::jsonb)
        into v_result
        from (
            select
                i.id, i.tenant_id, i.interaction_type, i.subject, i.metadata,
                i.contact_id, i.company_id, i.lead_id, i.opportunity_id, i.recorded_by,
                i.occurred_at, i.created_at, i.deleted_at
            from public.crm_interactions i
            where i.tenant_id = v_tid
              and i.deleted_at is null
              and (not p_payload ? 'contact_id' or i.contact_id = (p_payload->>'contact_id')::uuid)
              and (not p_payload ? 'lead_id' or i.lead_id = (p_payload->>'lead_id')::uuid)
              and (not p_payload ? 'opportunity_id' or i.opportunity_id = (p_payload->>'opportunity_id')::uuid)
              and (not p_payload ? 'company_id' or i.company_id = (p_payload->>'company_id')::uuid)
            limit v_limit
        ) t;

    when 'create_interaction' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_interactions (
            tenant_id, interaction_type, subject, metadata,
            contact_id, company_id, lead_id, opportunity_id, recorded_by, occurred_at
        )
        values (
            v_tid,
            (p_payload->>'interaction_type')::public.crm_interaction_type,
            case when p_payload ? 'subject' then p_payload->>'subject' else null end,
            coalesce(p_payload->'metadata', '{}'::jsonb),
            case when p_payload ? 'contact_id' and p_payload->>'contact_id' is not null then (p_payload->>'contact_id')::uuid else null end,
            case when p_payload ? 'company_id' and p_payload->>'company_id' is not null then (p_payload->>'company_id')::uuid else null end,
            case when p_payload ? 'lead_id' and p_payload->>'lead_id' is not null then (p_payload->>'lead_id')::uuid else null end,
            case when p_payload ? 'opportunity_id' and p_payload->>'opportunity_id' is not null then (p_payload->>'opportunity_id')::uuid else null end,
            (select auth.uid()),
            coalesce((p_payload->>'occurred_at')::timestamptz, now())
        )
        returning
            id, tenant_id, interaction_type, subject, metadata,
            contact_id, company_id, lead_id, opportunity_id, recorded_by,
            occurred_at, created_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_interaction.created', 'crm_interaction', v_row.id);
        v_result := to_jsonb(v_row);

    when 'soft_delete_interaction' then
        v_result := public.crm_soft_delete_row('public.crm_interactions'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_interaction.soft_deleted', 'crm_interaction', (p_payload->>'id')::uuid);

    -- =================================================
    -- NOTES
    -- =================================================

    when 'list_notes' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb)
        into v_result
        from (
            select
                n.id, n.tenant_id, n.entity_type, n.entity_id, n.body, n.version,
                n.author_user_id, n.created_at, n.updated_at, n.deleted_at
            from public.crm_notes n
            where n.tenant_id = v_tid
              and n.deleted_at is null
              and n.entity_type = (p_payload->>'entity_type')::public.crm_entity_type
              and n.entity_id = (p_payload->>'entity_id')::uuid
        ) t;

    when 'create_note' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_notes (tenant_id, entity_type, entity_id, body, author_user_id)
        values (
            v_tid,
            (p_payload->>'entity_type')::public.crm_entity_type,
            (p_payload->>'entity_id')::uuid,
            p_payload->>'body',
            (select auth.uid())
        )
        returning
            id, tenant_id, entity_type, entity_id, body, version,
            author_user_id, created_at, updated_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_note.created', 'crm_note', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_note' then
        v_tid := platform.current_tenant_id();
        update public.crm_notes n set
            body = case when p_payload ? 'body' then p_payload->>'body' else n.body end
        where n.id = (p_payload->>'id')::uuid
          and n.tenant_id = v_tid
          and n.deleted_at is null
        returning
            n.id, n.tenant_id, n.entity_type, n.entity_id, n.body, n.version,
            n.author_user_id, n.created_at, n.updated_at, n.deleted_at
        into v_row;
        if not found then raise exception 'Note not found'; end if;
        perform platform.log_audit('crm_note.updated', 'crm_note', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_note' then
        v_result := public.crm_soft_delete_row('public.crm_notes'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_note.deleted', 'crm_note', (p_payload->>'id')::uuid);

    -- =================================================
    -- TAG ASSIGNMENTS
    -- =================================================

    when 'list_tag_assignments' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb)
        into v_result
        from (
            select ta.id, ta.tenant_id, ta.tag_id, ta.entity_type, ta.entity_id, ta.created_at, ta.deleted_at
            from public.crm_tag_assignments ta
            where ta.tenant_id = v_tid
              and ta.deleted_at is null
              and (not p_payload ? 'entity_type' or ta.entity_type = (p_payload->>'entity_type')::public.crm_entity_type)
              and (not p_payload ? 'entity_id' or ta.entity_id = (p_payload->>'entity_id')::uuid)
        ) t;

    when 'create_tag_assignment' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_tag_assignments (tenant_id, tag_id, entity_type, entity_id)
        values (
            v_tid,
            (p_payload->>'tag_id')::uuid,
            (p_payload->>'entity_type')::public.crm_entity_type,
            (p_payload->>'entity_id')::uuid
        )
        returning id, tenant_id, tag_id, entity_type, entity_id, created_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_tag_assignment.created', 'crm_tag_assignment', v_row.id);
        v_result := to_jsonb(v_row);

    when 'delete_tag_assignment' then
        v_result := public.crm_soft_delete_row('public.crm_tag_assignments'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_tag_assignment.deleted', 'crm_tag_assignment', (p_payload->>'id')::uuid);

    -- =================================================
    -- LISTS
    -- =================================================

    when 'list_lists' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.name), '[]'::jsonb)
        into v_result
        from (
            select
                ls.id, ls.tenant_id, ls.name, ls.description, ls.list_type, ls.filter_config,
                ls.created_at, ls.updated_at, ls.deleted_at
            from public.crm_lists ls
            where ls.tenant_id = v_tid and ls.deleted_at is null
        ) t;

    when 'get_list' then
        v_tid := platform.current_tenant_id();
        select to_jsonb(t) into v_result
        from (
            select
                ls.id, ls.tenant_id, ls.name, ls.description, ls.list_type, ls.filter_config,
                ls.created_at, ls.updated_at, ls.deleted_at
            from public.crm_lists ls
            where ls.id = (p_payload->>'id')::uuid
              and ls.tenant_id = v_tid
              and ls.deleted_at is null
        ) t;
        if v_result is null then raise exception 'List not found'; end if;

    when 'create_list' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_lists (tenant_id, name, description, list_type, filter_config)
        values (
            v_tid,
            p_payload->>'name',
            case when p_payload ? 'description' then p_payload->>'description' else null end,
            coalesce((p_payload->>'list_type')::public.crm_list_type, 'static'::public.crm_list_type),
            case when p_payload ? 'filter_config' then p_payload->'filter_config' else null end
        )
        returning
            id, tenant_id, name, description, list_type, filter_config,
            created_at, updated_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_list.created', 'crm_list', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_list' then
        v_tid := platform.current_tenant_id();
        update public.crm_lists ls set
            name = case when p_payload ? 'name' then p_payload->>'name' else ls.name end,
            description = case when p_payload ? 'description' then p_payload->>'description' else ls.description end,
            list_type = case when p_payload ? 'list_type' then (p_payload->>'list_type')::public.crm_list_type else ls.list_type end,
            filter_config = case when p_payload ? 'filter_config' then p_payload->'filter_config' else ls.filter_config end
        where ls.id = (p_payload->>'id')::uuid
          and ls.tenant_id = v_tid
          and ls.deleted_at is null
        returning
            ls.id, ls.tenant_id, ls.name, ls.description, ls.list_type, ls.filter_config,
            ls.created_at, ls.updated_at, ls.deleted_at
        into v_row;
        if not found then raise exception 'List not found'; end if;
        perform platform.log_audit('crm_list.updated', 'crm_list', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_list' then
        v_result := public.crm_soft_delete_row('public.crm_lists'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_list.deleted', 'crm_list', (p_payload->>'id')::uuid);

    -- =================================================
    -- LIST MEMBERS
    -- =================================================

    when 'list_list_members' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.added_at), '[]'::jsonb)
        into v_result
        from (
            select lm.id, lm.tenant_id, lm.list_id, lm.contact_id, lm.added_at, lm.deleted_at
            from public.crm_list_members lm
            where lm.tenant_id = v_tid
              and lm.list_id = (p_payload->>'list_id')::uuid
              and lm.deleted_at is null
        ) t;

    when 'create_list_member' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_list_members (tenant_id, list_id, contact_id)
        values (
            v_tid,
            (p_payload->>'list_id')::uuid,
            (p_payload->>'contact_id')::uuid
        )
        returning id, tenant_id, list_id, contact_id, added_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_list_member.created', 'crm_list_member', v_row.id);
        v_result := to_jsonb(v_row);

    when 'delete_list_member' then
        v_result := public.crm_soft_delete_row('public.crm_list_members'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_list_member.deleted', 'crm_list_member', (p_payload->>'id')::uuid);

    -- =================================================
    -- CUSTOM FIELDS
    -- =================================================

    when 'list_custom_fields' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.display_order), '[]'::jsonb)
        into v_result
        from (
            select
                cf.id, cf.tenant_id, cf.field_key, cf.label, cf.field_type, cf.applies_to,
                cf.options, cf.is_required, cf.display_order,
                cf.created_at, cf.updated_at, cf.deleted_at
            from public.crm_custom_fields cf
            where cf.tenant_id = v_tid
              and cf.deleted_at is null
              and (not p_payload ? 'applies_to' or cf.applies_to = (p_payload->>'applies_to')::public.crm_entity_type)
        ) t;

    when 'create_custom_field' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_custom_fields (
            tenant_id, field_key, label, field_type, applies_to, options, is_required, display_order
        )
        values (
            v_tid,
            p_payload->>'field_key',
            p_payload->>'label',
            (p_payload->>'field_type')::public.crm_custom_field_type,
            (p_payload->>'applies_to')::public.crm_entity_type,
            case when p_payload ? 'options' then p_payload->'options' else null end,
            coalesce((p_payload->>'is_required')::boolean, false),
            coalesce((p_payload->>'display_order')::int, 0)
        )
        returning
            id, tenant_id, field_key, label, field_type, applies_to,
            options, is_required, display_order,
            created_at, updated_at, deleted_at
        into v_row;
        perform platform.log_audit('crm_custom_field.created', 'crm_custom_field', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_custom_field' then
        v_tid := platform.current_tenant_id();
        update public.crm_custom_fields cf set
            field_key = case when p_payload ? 'field_key' then p_payload->>'field_key' else cf.field_key end,
            label = case when p_payload ? 'label' then p_payload->>'label' else cf.label end,
            field_type = case when p_payload ? 'field_type' then (p_payload->>'field_type')::public.crm_custom_field_type else cf.field_type end,
            applies_to = case when p_payload ? 'applies_to' then (p_payload->>'applies_to')::public.crm_entity_type else cf.applies_to end,
            options = case when p_payload ? 'options' then p_payload->'options' else cf.options end,
            is_required = case when p_payload ? 'is_required' then (p_payload->>'is_required')::boolean else cf.is_required end,
            display_order = case when p_payload ? 'display_order' then (p_payload->>'display_order')::int else cf.display_order end
        where cf.id = (p_payload->>'id')::uuid
          and cf.tenant_id = v_tid
          and cf.deleted_at is null
        returning
            cf.id, cf.tenant_id, cf.field_key, cf.label, cf.field_type, cf.applies_to,
            cf.options, cf.is_required, cf.display_order,
            cf.created_at, cf.updated_at, cf.deleted_at
        into v_row;
        if not found then raise exception 'Custom field not found'; end if;
        perform platform.log_audit('crm_custom_field.updated', 'crm_custom_field', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_custom_field' then
        v_result := public.crm_soft_delete_row('public.crm_custom_fields'::regclass, (p_payload->>'id')::uuid);
        perform platform.log_audit('crm_custom_field.deleted', 'crm_custom_field', (p_payload->>'id')::uuid);

    -- =================================================
    -- CUSTOM FIELD VALUES
    -- =================================================

    when 'list_custom_field_values' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb)
        into v_result
        from (
            select
                cfv.id, cfv.tenant_id, cfv.custom_field_id, cfv.entity_type, cfv.entity_id,
                cfv.value_text, cfv.value_number, cfv.value_boolean, cfv.value_date, cfv.value_datetime, cfv.value_json,
                cfv.created_at, cfv.updated_at
            from public.crm_custom_field_values cfv
            where cfv.tenant_id = v_tid
              and (not p_payload ? 'entity_type' or cfv.entity_type = (p_payload->>'entity_type')::public.crm_entity_type)
              and (not p_payload ? 'entity_id' or cfv.entity_id = (p_payload->>'entity_id')::uuid)
              and (not p_payload ? 'custom_field_id' or cfv.custom_field_id = (p_payload->>'custom_field_id')::uuid)
        ) t;

    when 'upsert_custom_field_value' then
        v_tid := platform.current_tenant_id();
        insert into public.crm_custom_field_values (
            tenant_id, custom_field_id, entity_type, entity_id,
            value_text, value_number, value_boolean, value_date, value_datetime, value_json
        )
        values (
            v_tid,
            (p_payload->>'custom_field_id')::uuid,
            (p_payload->>'entity_type')::public.crm_entity_type,
            (p_payload->>'entity_id')::uuid,
            case when p_payload ? 'value_text' then p_payload->>'value_text' else null end,
            case when p_payload ? 'value_number' and p_payload->>'value_number' is not null then (p_payload->>'value_number')::numeric else null end,
            case when p_payload ? 'value_boolean' and p_payload->>'value_boolean' is not null then (p_payload->>'value_boolean')::boolean else null end,
            case when p_payload ? 'value_date' and p_payload->>'value_date' is not null then (p_payload->>'value_date')::date else null end,
            case when p_payload ? 'value_datetime' and p_payload->>'value_datetime' is not null then (p_payload->>'value_datetime')::timestamptz else null end,
            case when p_payload ? 'value_json' then p_payload->'value_json' else null end
        )
        on conflict (custom_field_id, entity_id) do update set
            value_text = excluded.value_text,
            value_number = excluded.value_number,
            value_boolean = excluded.value_boolean,
            value_date = excluded.value_date,
            value_datetime = excluded.value_datetime,
            value_json = excluded.value_json
        returning
            id, tenant_id, custom_field_id, entity_type, entity_id,
            value_text, value_number, value_boolean, value_date, value_datetime, value_json,
            created_at, updated_at
        into v_row;
        perform platform.log_audit('crm_custom_field_value.upserted', 'crm_custom_field_value', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_custom_field_value' then
        v_tid := platform.current_tenant_id();
        update public.crm_custom_field_values cfv set
            value_text = case when p_payload ? 'value_text' then p_payload->>'value_text' else cfv.value_text end,
            value_number = case when p_payload ? 'value_number' then case when p_payload->>'value_number' is null then null else (p_payload->>'value_number')::numeric end else cfv.value_number end,
            value_boolean = case when p_payload ? 'value_boolean' then case when p_payload->>'value_boolean' is null then null else (p_payload->>'value_boolean')::boolean end else cfv.value_boolean end,
            value_date = case when p_payload ? 'value_date' then case when p_payload->>'value_date' is null then null else (p_payload->>'value_date')::date end else cfv.value_date end,
            value_datetime = case when p_payload ? 'value_datetime' then case when p_payload->>'value_datetime' is null then null else (p_payload->>'value_datetime')::timestamptz end else cfv.value_datetime end,
            value_json = case when p_payload ? 'value_json' then p_payload->'value_json' else cfv.value_json end
        where cfv.id = (p_payload->>'id')::uuid
          and cfv.tenant_id = v_tid
        returning
            id, tenant_id, custom_field_id, entity_type, entity_id,
            value_text, value_number, value_boolean, value_date, value_datetime, value_json,
            created_at, updated_at
        into v_row;
        if not found then raise exception 'Custom field value not found'; end if;
        perform platform.log_audit('crm_custom_field_value.updated', 'crm_custom_field_value', v_row.id, p_payload - 'id');
        v_result := to_jsonb(v_row);

    when 'delete_custom_field_value' then
        v_tid := platform.current_tenant_id();
        delete from public.crm_custom_field_values cfv
        where cfv.id = (p_payload->>'id')::uuid
          and cfv.tenant_id = v_tid;
        if not found then raise exception 'Custom field value not found'; end if;
        perform platform.log_audit('crm_custom_field_value.deleted', 'crm_custom_field_value', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    else
        raise exception 'unknown crm_api operation: %', p_op;
    end case;

    return v_result;
end;
$$;




-- -----------------------------------------------------
-- 003 CRM: whitelist soft-delete targets
-- -----------------------------------------------------

create or replace function public.crm_soft_delete_row(
    p_table regclass,
    p_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_count int;
    v_tid uuid;
begin
    v_tid := platform.current_tenant_id();
    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    if p_table::text not in (
        'public.crm_pipelines',
        'public.crm_pipeline_stages',
        'public.crm_campaigns',
        'public.crm_tags',
        'public.crm_companies',
        'public.crm_contacts',
        'public.crm_leads',
        'public.crm_contact_company',
        'public.crm_company_tenants',
        'public.crm_contact_tenants',
        'public.crm_opportunities',
        'public.crm_tasks',
        'public.crm_interactions',
        'public.crm_notes',
        'public.crm_tag_assignments',
        'public.crm_lists',
        'public.crm_list_members',
        'public.crm_custom_fields'
    ) then
        raise exception 'table not allowed for CRM soft delete';
    end if;

    execute format(
        'update %s set deleted_at = now() where id = $1 and tenant_id = $2',
        p_table
    ) using p_id, v_tid;

    get diagnostics v_count = row_count;
    if v_count = 0 then
        raise exception 'record not found or not accessible';
    end if;

    return jsonb_build_object('deleted', true, 'id', p_id);
end;
$$;




create or replace function public.edge_soft_delete_row(
    p_table regclass,
    p_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_manager();
    return public.crm_soft_delete_row(p_table, p_id);
end;
$$;



create or replace function public.enforce_crm_child_tenant_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_parent_tenant uuid;
begin
    if tg_table_name = 'crm_pipeline_stages' then
        select p.tenant_id into v_parent_tenant
        from public.crm_pipelines p
        where p.id = new.pipeline_id;
    elsif tg_table_name = 'crm_contact_company' then
        select c.tenant_id into v_parent_tenant
        from public.crm_contacts c
        where c.id = new.contact_id;

        if v_parent_tenant is distinct from (
            select co.tenant_id from public.crm_companies co where co.id = new.company_id
        ) then
            raise exception 'contact and company must belong to the same tenant';
        end if;
    elsif tg_table_name = 'crm_company_tenants' then
        select c.tenant_id into v_parent_tenant
        from public.crm_companies c
        where c.id = new.company_id;
    elsif tg_table_name = 'crm_contact_tenants' then
        select c.tenant_id into v_parent_tenant
        from public.crm_contacts c
        where c.id = new.contact_id;
    elsif tg_table_name = 'crm_list_members' then
        select l.tenant_id into v_parent_tenant
        from public.crm_lists l
        where l.id = new.list_id;

        if v_parent_tenant is distinct from (
            select ct.tenant_id from public.crm_contacts ct where ct.id = new.contact_id
        ) then
            raise exception 'list and contact must belong to the same tenant';
        end if;
    elsif tg_table_name = 'crm_tag_assignments' then
        select t.tenant_id into v_parent_tenant
        from public.crm_tags t
        where t.id = new.tag_id;
    elsif tg_table_name = 'crm_custom_field_values' then
        select cf.tenant_id into v_parent_tenant
        from public.crm_custom_fields cf
        where cf.id = new.custom_field_id;

        if new.entity_type <> (
            select cf.applies_to from public.crm_custom_fields cf where cf.id = new.custom_field_id
        ) then
            raise exception 'custom field value entity_type must match field applies_to';
        end if;
    else
        return new;
    end if;

    if not found then
        raise exception 'parent record not found';
    end if;

    if v_parent_tenant <> new.tenant_id then
        raise exception 'tenant_id must match parent record tenant_id';
    end if;

    return new;
end;
$$;



create or replace function public.enforce_crm_custom_field_value_shape()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_field_type public.crm_custom_field_type;
begin
    select cf.field_type
    into v_field_type
    from public.crm_custom_fields cf
    where cf.id = new.custom_field_id;

    if not found then
        raise exception 'custom field not found';
    end if;

    case v_field_type
        when 'text' then
            if new.value_text is null
               or new.value_number is not null
               or new.value_boolean is not null
               or new.value_date is not null
               or new.value_datetime is not null
               or new.value_json is not null then
                raise exception 'invalid value columns for text custom field';
            end if;
        when 'number' then
            if new.value_number is null
               or new.value_text is not null
               or new.value_boolean is not null
               or new.value_date is not null
               or new.value_datetime is not null
               or new.value_json is not null then
                raise exception 'invalid value columns for number custom field';
            end if;
        when 'boolean' then
            if new.value_boolean is null
               or new.value_text is not null
               or new.value_number is not null
               or new.value_date is not null
               or new.value_datetime is not null
               or new.value_json is not null then
                raise exception 'invalid value columns for boolean custom field';
            end if;
        when 'date' then
            if new.value_date is null
               or new.value_text is not null
               or new.value_number is not null
               or new.value_boolean is not null
               or new.value_datetime is not null
               or new.value_json is not null then
                raise exception 'invalid value columns for date custom field';
            end if;
        when 'datetime' then
            if new.value_datetime is null
               or new.value_text is not null
               or new.value_number is not null
               or new.value_boolean is not null
               or new.value_date is not null
               or new.value_json is not null then
                raise exception 'invalid value columns for datetime custom field';
            end if;
        when 'select' then
            if new.value_text is null
               or new.value_number is not null
               or new.value_boolean is not null
               or new.value_date is not null
               or new.value_datetime is not null
               or new.value_json is not null then
                raise exception 'invalid value columns for select custom field';
            end if;
        when 'multiselect' then
            if new.value_json is null
               or new.value_text is not null
               or new.value_number is not null
               or new.value_boolean is not null
               or new.value_date is not null
               or new.value_datetime is not null then
                raise exception 'invalid value columns for multiselect custom field';
            end if;
    end case;

    return new;
end;
$$;



create or replace function public.enforce_crm_interaction_immutability()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if tg_op = 'DELETE' then
        raise exception 'crm_interactions cannot be hard-deleted; set deleted_at instead';
    end if;

    if new.tenant_id is distinct from old.tenant_id
       or new.interaction_type is distinct from old.interaction_type
       or new.subject is distinct from old.subject
       or new.metadata is distinct from old.metadata
       or new.contact_id is distinct from old.contact_id
       or new.company_id is distinct from old.company_id
       or new.lead_id is distinct from old.lead_id
       or new.opportunity_id is distinct from old.opportunity_id
       or new.recorded_by is distinct from old.recorded_by
       or new.occurred_at is distinct from old.occurred_at
       or new.created_at is distinct from old.created_at then
        raise exception 'crm_interactions are append-only; only deleted_at may change';
    end if;

    return new;
end;
$$;



create or replace function public.enforce_crm_interaction_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_entity_tenant uuid;
begin
    if new.contact_id is not null then
        select c.tenant_id into v_entity_tenant from public.crm_contacts c where c.id = new.contact_id;
        if v_entity_tenant <> new.tenant_id then
            raise exception 'interaction contact tenant mismatch';
        end if;
    end if;

    if new.company_id is not null then
        select c.tenant_id into v_entity_tenant from public.crm_companies c where c.id = new.company_id;
        if v_entity_tenant <> new.tenant_id then
            raise exception 'interaction company tenant mismatch';
        end if;
    end if;

    if new.lead_id is not null then
        select l.tenant_id into v_entity_tenant from public.crm_leads l where l.id = new.lead_id;
        if v_entity_tenant <> new.tenant_id then
            raise exception 'interaction lead tenant mismatch';
        end if;
    end if;

    if new.opportunity_id is not null then
        select o.tenant_id into v_entity_tenant from public.crm_opportunities o where o.id = new.opportunity_id;
        if v_entity_tenant <> new.tenant_id then
            raise exception 'interaction opportunity tenant mismatch';
        end if;
    end if;

    return new;
end;
$$;



create or replace function public.enforce_crm_lead_campaign_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_campaign_tenant uuid;
begin
    if new.campaign_id is null then
        return new;
    end if;

    select c.tenant_id
    into v_campaign_tenant
    from public.crm_campaigns c
    where c.id = new.campaign_id;

    if not found then
        raise exception 'campaign not found';
    end if;

    if v_campaign_tenant <> new.tenant_id then
        raise exception 'lead campaign must belong to the same tenant';
    end if;

    return new;
end;
$$;



create or replace function public.enforce_crm_lead_conversion_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_contact_tenant uuid;
    v_company_tenant uuid;
begin
    if new.converted_contact_id is not null then
        select c.tenant_id into v_contact_tenant
        from public.crm_contacts c
        where c.id = new.converted_contact_id;

        if v_contact_tenant <> new.tenant_id then
            raise exception 'converted contact must belong to the same tenant';
        end if;
    end if;

    if new.converted_company_id is not null then
        select c.tenant_id into v_company_tenant
        from public.crm_companies c
        where c.id = new.converted_company_id;

        if v_company_tenant <> new.tenant_id then
            raise exception 'converted company must belong to the same tenant';
        end if;
    end if;

    return new;
end;
$$;



create or replace function public.enforce_crm_note_entity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_entity_tenant uuid;
    v_found boolean := false;
begin
    case new.entity_type
        when 'lead' then
            select l.tenant_id, true into v_entity_tenant, v_found
            from public.crm_leads l where l.id = new.entity_id;
        when 'opportunity' then
            select o.tenant_id, true into v_entity_tenant, v_found
            from public.crm_opportunities o where o.id = new.entity_id;
        when 'contact' then
            select c.tenant_id, true into v_entity_tenant, v_found
            from public.crm_contacts c where c.id = new.entity_id;
        when 'company' then
            select c.tenant_id, true into v_entity_tenant, v_found
            from public.crm_companies c where c.id = new.entity_id;
        when 'tenant' then
            select t.id, true into v_entity_tenant, v_found
            from public.tenants t where t.id = new.entity_id;
    end case;

    if not coalesce(v_found, false) then
        raise exception 'note entity not found for type %', new.entity_type;
    end if;

    if new.entity_type = 'tenant' then
        if new.tenant_id <> new.entity_id then
            raise exception 'note on tenant must use matching tenant_id';
        end if;
    elsif v_entity_tenant <> new.tenant_id then
        raise exception 'note entity must belong to the same tenant';
    end if;

    return new;
end;
$$;



create or replace function public.enforce_crm_opportunity_party_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_contact_tenant uuid;
    v_company_tenant uuid;
begin
    if new.contact_id is not null then
        select c.tenant_id into v_contact_tenant
        from public.crm_contacts c
        where c.id = new.contact_id;

        if v_contact_tenant <> new.tenant_id then
            raise exception 'opportunity contact must belong to the same tenant';
        end if;
    end if;

    if new.company_id is not null then
        select c.tenant_id into v_company_tenant
        from public.crm_companies c
        where c.id = new.company_id;

        if v_company_tenant <> new.tenant_id then
            raise exception 'opportunity company must belong to the same tenant';
        end if;
    end if;

    return new;
end;
$$;



-- =====================================================
-- 21. INTEGRITY TRIGGERS
-- =====================================================

create or replace function public.enforce_crm_owner_membership()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.owner_user_id is null then
        return new;
    end if;

    if not exists (
        select 1
        from public.tenant_memberships tm
        where tm.tenant_id = new.tenant_id
          and tm.user_id = new.owner_user_id
          and tm.is_active = true
    ) then
        raise exception 'owner_user_id must be an active member of tenant_id';
    end if;

    return new;
end;
$$;

create or replace function public.enforce_crm_pipeline_stage_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_stage_pipeline uuid;
    v_stage_tenant uuid;
    v_pipeline_tenant uuid;
begin
    select ps.pipeline_id, ps.tenant_id
    into v_stage_pipeline, v_stage_tenant
    from public.crm_pipeline_stages ps
    where ps.id = new.stage_id;

    if not found then
        raise exception 'pipeline stage not found';
    end if;

    if v_stage_pipeline <> new.pipeline_id then
        raise exception 'opportunity stage must belong to the selected pipeline';
    end if;

    select p.tenant_id
    into v_pipeline_tenant
    from public.crm_pipelines p
    where p.id = new.pipeline_id;

    if v_stage_tenant <> new.tenant_id or v_pipeline_tenant <> new.tenant_id then
        raise exception 'pipeline, stage, and opportunity tenant_id must match';
    end if;

    return new;
end;
$$;

create or replace function public.enforce_crm_tag_assignment_entity()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_entity_tenant uuid;
    v_found boolean := false;
begin
    case new.entity_type
        when 'lead' then
            select l.tenant_id, true into v_entity_tenant, v_found
            from public.crm_leads l where l.id = new.entity_id;
        when 'opportunity' then
            select o.tenant_id, true into v_entity_tenant, v_found
            from public.crm_opportunities o where o.id = new.entity_id;
        when 'contact' then
            select c.tenant_id, true into v_entity_tenant, v_found
            from public.crm_contacts c where c.id = new.entity_id;
        when 'company' then
            select c.tenant_id, true into v_entity_tenant, v_found
            from public.crm_companies c where c.id = new.entity_id;
        when 'tenant' then
            select t.id, true into v_entity_tenant, v_found
            from public.tenants t where t.id = new.entity_id;
    end case;

    if not coalesce(v_found, false) then
        raise exception 'tag assignment entity not found for type %', new.entity_type;
    end if;

    if new.entity_type = 'tenant' then
        if new.tenant_id <> new.entity_id then
            raise exception 'tag on tenant must use matching tenant_id';
        end if;
    elsif v_entity_tenant <> new.tenant_id then
        raise exception 'tagged entity must belong to the same tenant';
    end if;

    return new;
end;
$$;


create or replace function public.enforce_crm_task_target()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_target_tenant uuid;
    v_found boolean := false;
begin
    case new.target_type
        when 'lead' then
            select l.tenant_id, true into v_target_tenant, v_found
            from public.crm_leads l where l.id = new.target_id;
        when 'opportunity' then
            select o.tenant_id, true into v_target_tenant, v_found
            from public.crm_opportunities o where o.id = new.target_id;
        when 'contact' then
            select c.tenant_id, true into v_target_tenant, v_found
            from public.crm_contacts c where c.id = new.target_id;
        when 'company' then
            select c.tenant_id, true into v_target_tenant, v_found
            from public.crm_companies c where c.id = new.target_id;
        when 'tenant' then
            select t.id, true into v_target_tenant, v_found
            from public.tenants t where t.id = new.target_id;
    end case;

    if not coalesce(v_found, false) then
        raise exception 'task target not found for type %', new.target_type;
    end if;

    if new.target_type = 'tenant' then
        if new.tenant_id <> new.target_id then
            raise exception 'task with target_type=tenant must reference the same tenant_id';
        end if;
    elsif v_target_tenant <> new.tenant_id then
        raise exception 'task target must belong to the same tenant';
    end if;

    return new;
end;
$$;


-- -----------------------------------------------------
-- 003 CRM: domain triggers (lifecycle timestamps / versioning)
-- -----------------------------------------------------

create or replace function public.trg_crm_contacts_consent_timestamps()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if tg_op = 'INSERT' then
        if new.marketing_consent then
            new.marketing_consent_at := coalesce(new.marketing_consent_at, now());
        end if;
        if new.gdpr_consent then
            new.gdpr_consent_at := coalesce(new.gdpr_consent_at, now());
        end if;
    elsif tg_op = 'UPDATE' then
        if new.marketing_consent is distinct from old.marketing_consent then
            new.marketing_consent_at := case
                when new.marketing_consent then coalesce(new.marketing_consent_at, now())
                else null
            end;
        end if;
        if new.gdpr_consent is distinct from old.gdpr_consent then
            new.gdpr_consent_at := case
                when new.gdpr_consent then coalesce(new.gdpr_consent_at, now())
                else null
            end;
        end if;
    end if;
    return new;
end;
$$;

create or replace function public.trg_crm_leads_conversion_timestamp()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.status is distinct from old.status then
        if new.status = 'converted'::public.crm_lead_status then
            new.converted_at := coalesce(new.converted_at, now());
        elsif old.status = 'converted'::public.crm_lead_status
              and new.status <> 'converted'::public.crm_lead_status then
            new.converted_at := null;
        end if;
    end if;
    return new;
end;
$$;

create or replace function public.trg_crm_notes_version_increment()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.body is distinct from old.body then
        new.version := old.version + 1;
    end if;
    return new;
end;
$$;

create trigger trg_crm_pipelines_updated_at
before update on crm_pipelines
for each row execute function platform.set_updated_at();

create trigger trg_crm_pipeline_stages_updated_at
before update on crm_pipeline_stages
for each row execute function platform.set_updated_at();

create trigger trg_crm_campaigns_updated_at
before update on crm_campaigns
for each row execute function platform.set_updated_at();

create trigger trg_crm_companies_updated_at
before update on crm_companies
for each row execute function platform.set_updated_at();

create trigger trg_crm_contacts_updated_at
before update on crm_contacts
for each row execute function platform.set_updated_at();

create trigger trg_crm_leads_updated_at
before update on crm_leads
for each row execute function platform.set_updated_at();

create trigger trg_crm_opportunities_updated_at
before update on crm_opportunities
for each row execute function platform.set_updated_at();

create trigger trg_crm_tasks_updated_at
before update on crm_tasks
for each row execute function platform.set_updated_at();

create trigger trg_crm_notes_updated_at
before update on crm_notes
for each row execute function platform.set_updated_at();

create trigger trg_crm_lists_updated_at
before update on crm_lists
for each row execute function platform.set_updated_at();

create trigger trg_crm_custom_fields_updated_at
before update on crm_custom_fields
for each row execute function platform.set_updated_at();

create trigger trg_crm_custom_field_values_updated_at
before update on crm_custom_field_values
for each row execute function platform.set_updated_at();

create trigger trg_crm_contacts_owner_membership
before insert or update on public.crm_contacts
for each row execute function public.enforce_crm_owner_membership();

create trigger trg_crm_companies_owner_membership
before insert or update on public.crm_companies
for each row execute function public.enforce_crm_owner_membership();

create trigger trg_crm_leads_owner_membership
before insert or update on public.crm_leads
for each row execute function public.enforce_crm_owner_membership();

create trigger trg_crm_opportunities_owner_membership
before insert or update on public.crm_opportunities
for each row execute function public.enforce_crm_owner_membership();

create trigger trg_crm_tasks_owner_membership
before insert or update on public.crm_tasks
for each row execute function public.enforce_crm_owner_membership();

create trigger trg_crm_opportunities_pipeline_stage_scope
before insert or update on public.crm_opportunities
for each row execute function public.enforce_crm_pipeline_stage_scope();

create trigger trg_crm_pipeline_stages_tenant_consistency
before insert or update on public.crm_pipeline_stages
for each row execute function public.enforce_crm_child_tenant_consistency();

create trigger trg_crm_contact_company_tenant_consistency
before insert or update on public.crm_contact_company
for each row execute function public.enforce_crm_child_tenant_consistency();

create trigger trg_crm_company_tenants_tenant_consistency
before insert or update on public.crm_company_tenants
for each row execute function public.enforce_crm_child_tenant_consistency();

create trigger trg_crm_contact_tenants_tenant_consistency
before insert or update on public.crm_contact_tenants
for each row execute function public.enforce_crm_child_tenant_consistency();

create trigger trg_crm_list_members_tenant_consistency
before insert or update on public.crm_list_members
for each row execute function public.enforce_crm_child_tenant_consistency();

create trigger trg_crm_tag_assignments_tenant_consistency
before insert or update on public.crm_tag_assignments
for each row execute function public.enforce_crm_child_tenant_consistency();

create trigger trg_crm_custom_field_values_tenant_consistency
before insert or update on public.crm_custom_field_values
for each row execute function public.enforce_crm_child_tenant_consistency();

create trigger trg_crm_leads_campaign_scope
before insert or update on public.crm_leads
for each row execute function public.enforce_crm_lead_campaign_scope();

create trigger trg_crm_leads_conversion_scope
before insert or update on public.crm_leads
for each row execute function public.enforce_crm_lead_conversion_scope();

create trigger trg_crm_opportunities_party_scope
before insert or update on public.crm_opportunities
for each row execute function public.enforce_crm_opportunity_party_scope();

create trigger trg_crm_interactions_scope
before insert on public.crm_interactions
for each row execute function public.enforce_crm_interaction_scope();

create trigger trg_crm_interactions_immutability
before update or delete on public.crm_interactions
for each row execute function public.enforce_crm_interaction_immutability();

create trigger trg_crm_tasks_target
before insert or update on public.crm_tasks
for each row execute function public.enforce_crm_task_target();

create trigger trg_crm_notes_entity
before insert or update on public.crm_notes
for each row execute function public.enforce_crm_note_entity();

create trigger trg_crm_tag_assignments_entity
before insert or update on public.crm_tag_assignments
for each row execute function public.enforce_crm_tag_assignment_entity();

create trigger trg_crm_custom_field_values_shape
before insert or update on public.crm_custom_field_values
for each row execute function public.enforce_crm_custom_field_value_shape();

create trigger trg_crm_contacts_consent_timestamps
before insert or update on public.crm_contacts
for each row execute function public.trg_crm_contacts_consent_timestamps();

create trigger trg_crm_leads_conversion_timestamp
before update of status on public.crm_leads
for each row execute function public.trg_crm_leads_conversion_timestamp();

create trigger trg_crm_notes_version_increment
before update of body on public.crm_notes
for each row execute function public.trg_crm_notes_version_increment();


-- =====================================================
-- END 003 CRM ENGINE
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('003_crm_engine', 'REV1.CRM', false)
on conflict (version) do nothing;
