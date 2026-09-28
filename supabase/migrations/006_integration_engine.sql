-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 006_INTEGRRATION_ENGINE.SQL
-- =====================================================
--
-- =====================================================
-- 1. INTEGRATION PROVIDERS (CATALOG / SSOT)
-- =====================================================

create table if not exists public.integration_providers (

    id uuid primary key default gen_random_uuid(),

    code text not null,

    name text not null,

    category integration_provider_category not null,

    description text,

    website text,

    documentation_url text,

    api_version text,

    is_system boolean not null default true,

    is_active boolean not null default true,

    supports_webhooks boolean not null default false,

    supports_oauth boolean not null default false,

    supports_polling boolean not null default false,

    supports_push boolean not null default false,

    supports_real_time boolean not null default false,

    valid_from timestamptz not null default now(),

    valid_until timestamptz,

    configuration_schema jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    constraint uq_integration_providers_code unique (code)
);


-- =====================================================
-- 2.0 INTEGRATION OAUTH CONFIGURATION (SSOT)
-- =====================================================

create table if not exists public.integration_oauth_configs (
    id uuid primary key default gen_random_uuid(),

    provider_code text not null
        references public.integration_providers(code)
        on delete cascade,

    -- OAuth authorization endpoint.
    -- Required for authorization_code.
    -- Not applicable to password/ROPC.
    authorization_url text,

    -- OAuth token endpoint.
    token_url text not null,

    -- OAuth scopes requested from the provider.
    default_scopes text[] not null default '{}'::text[],

    -- OAuth response type.
    -- Only applicable to authorization_code.
    response_type text not null default 'code',

    -- Supported OAuth 2.0 grant types.
    --
    -- authorization_code
    --     OAuth 2.0 Authorization Code Grant
    --
    -- password
    --     OAuth 2.0 Resource Owner Password Credentials Grant (ROPC)
    grant_type text not null default 'authorization_code',

    -- Client authentication method at the token endpoint.
    client_auth_method text not null default 'client_secret_post',

    -- PKCE is not used by the currently supported integrations.
    pkce_required boolean not null default false,

    -- Required only when PKCE is enabled.
    pkce_method text,

    api_base_url_claim text,

    -- How the OAuth redirect is handled.
    --
    -- supabase_function:
    --     OAuth callback is handled by a Supabase Edge Function.
    --
    -- configured:
    --     Provider-specific configured redirect URI.
    redirect_uri_mode text not null default 'supabase_function',

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    -- One OAuth configuration per provider.
    constraint uq_integration_oauth_config_provider
        unique (provider_code),

    -- -------------------------------------------------
    -- RESPONSE TYPE
    -- -------------------------------------------------
    --
    -- Authorization Code Grant uses response_type=code.
    -- ROPC does not use an authorization response.
    constraint chk_integration_oauth_response_type
        check (
            (grant_type = 'authorization_code'
                and response_type = 'code')
            or
            (grant_type = 'password'
                and response_type = 'none')
        ),

    -- -------------------------------------------------
    -- GRANT TYPE
    -- -------------------------------------------------
    constraint chk_integration_oauth_grant_type
        check (
            grant_type in (
                'authorization_code',
                'password'
            )
        ),

    -- -------------------------------------------------
    -- CLIENT AUTHENTICATION
    -- -------------------------------------------------
    constraint chk_integration_oauth_client_auth_method
        check (
            client_auth_method in (
                'client_secret_basic',
                'client_secret_post',
                'none'
            )
        ),

    -- -------------------------------------------------
    -- PKCE
    -- -------------------------------------------------
    constraint chk_integration_oauth_pkce_method
        check (
            (pkce_required = false and pkce_method is null)
            or
            (pkce_required = true and pkce_method = 'S256')
        ),

    -- -------------------------------------------------
    -- AUTHORIZATION URL
    -- -------------------------------------------------
    --
    -- Authorization Code:
    --     authorization_url is mandatory.
    --
    -- ROPC:
    --     no authorization endpoint is required.
    constraint chk_integration_oauth_authorization_url
        check (
            (grant_type = 'authorization_code'
                and authorization_url is not null)
            or
            (grant_type = 'password'
                and authorization_url is null)
        ),

    -- -------------------------------------------------
    -- REDIRECT URI MODE
    -- -------------------------------------------------
    --
    -- ROPC has no browser redirect.
    -- Therefore redirect_uri_mode must be supabase_function
    -- for the current implementation model.
    constraint chk_integration_oauth_redirect_uri_mode
        check (
            redirect_uri_mode in (
                'supabase_function',
                'configured'
            )
        )
);


comment on table public.integration_oauth_configs is
    'OAuth protocol configuration SSOT per integration provider. Contains no secrets, tokens, tenant state or OAuth transaction state.';

comment on column public.integration_oauth_configs.authorization_url is
    'Provider OAuth authorization endpoint. Non-secret configuration.';

comment on column public.integration_oauth_configs.token_url is
    'Provider OAuth token endpoint. Non-secret configuration.';

comment on column public.integration_oauth_configs.default_scopes is
    'Default OAuth scopes requested by SmartHellas for this provider.';

comment on column public.integration_oauth_configs.client_auth_method is
    'OAuth client authentication method used at the token endpoint.';

comment on column public.integration_oauth_configs.pkce_required is
    'Whether the provider requires PKCE for the authorization-code flow.';

comment on column public.integration_oauth_configs.redirect_uri_mode is
    'Defines how the OAuth redirect  is resolved for the provider.';


-- =====================================================
-- 2. INTEGRATION CAPABILITIES (PROVIDER FEATURES)
-- =====================================================

create table if not exists public.integration_capabilities (

    id uuid primary key default gen_random_uuid(),

    provider_code text not null,

    capability_code text not null,

    description text,

    is_supported boolean not null default true,

    created_at timestamptz not null default now(),

    constraint uq_provider_capability
        unique (provider_code, capability_code)
);


-- =====================================================
-- 3. TENANT INTEGRATIONS (CONNECTION CONFIG ONLY)
-- =====================================================

create table if not exists public.tenant_integrations (

    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    provider_code text not null,

    credentials_ref text,

    provider_api_base_url text,

    config jsonb not null default '{}'::jsonb,

    is_enabled boolean not null default true,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    constraint uq_tenant_provider unique (tenant_id, provider_code)
);


-- =====================================================
-- 4. WEBHOOK DEFINITIONS (OUTBOUND ONLY)
-- =====================================================

create table if not exists public.webhook_definitions (

    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    provider_code text not null,

    event_type text not null,

    target_url text not null,

    signing_secret_ref text,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now()
);


-- =====================================================
-- 5. DEVICE INTEGRATION MAPPING (NO STATE, ONLY EXTERNAL IDS)
-- =====================================================

create table if not exists public.device_integration_map (

    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    device_id uuid not null references public.devices(id) on delete cascade,

    hardware_id text,
  
    provider_code text not null,

    external_id text not null,

    config jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),

    constraint uq_device_provider unique (device_id, provider_code)
);


-- =====================================================
-- 6. INTEGRATION OAUTH STATE (SSOT)
-- =====================================================

create table if not exists public.integration_oauth_states (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references public.tenants(id),
    user_id uuid not null,
    provider_code text not null,
    state_token text not null,
    redirect_uri text,
    code_verifier text,
    code_challenge_method text,
    expires_at timestamptz not null,
    consumed_at timestamptz,
    created_at timestamptz not null default now(),
    constraint integration_oauth_states_state_token_key unique (state_token)
);

create index if not exists integration_oauth_states_pending_idx
    on public.integration_oauth_states (expires_at)
    where consumed_at is null;

alter table public.integration_oauth_states
    drop constraint if exists chk_integration_oauth_state_pkce_method;

alter table public.integration_oauth_states
    add constraint chk_integration_oauth_state_pkce_method
    check (
        code_challenge_method is null
        or code_challenge_method = 'S256'
    );


-- =====================================================
-- 7. INTEGRATION WEBHOOK MAPPINGS
-- =====================================================

-- =====================================================
-- 7.1 WEBHOOK PAYLOAD MAPPINGS
--
-- Responsibility:
-- - Define how provider webhook payloads map to
--   integration-domain identifiers.
--
-- This is configuration / mapping metadata.
-- It is NOT device state and NOT telemetry.
--
-- 000 must never inspect these mappings.
-- 006 owns their interpretation.
-- =====================================================

create table if not exists public.integration_webhook_mappings (

    id uuid primary key default gen_random_uuid(),

    provider_code text not null
        references public.integration_providers(code),

    event_type text not null,

    mapping_code text not null,

    payload_path text[] not null,

    value_type text not null default 'text',

    is_required boolean not null default true,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    constraint uq_integration_webhook_mapping
        unique (
            provider_code,
            event_type,
            mapping_code
        )
);

comment on column public.device_integration_map.hardware_id is
    'Stable provider-side hardware identity used to reconcile changing external provider identifiers. Provider-agnostic.';


comment on column public.device_integration_map.external_id is
    'Current provider-side device identifier. May change when the provider reassigns or recreates the external identity.';


comment on table public.device_integration_map is
    'Provider device identity mapping. external_id is the current provider identifier; hardware_id is the stable provider hardware identity. No device state, telemetry or credentials.';

-- =====================================================
-- 9 — OAuth API signature cleanup
-- =====================================================

-- Legacy OAuth token exchange signature
drop function if exists public.integrations_exchange_oauth_tokens(
    uuid,
    text,
    text,
    text
);

-- Legacy/incorrect API alias, indien aanwezig
drop function if exists public.integrations_oauth_complete_api(
    text
);

drop function if exists public.integrations_complete_oauth(
    text,
    text
);

drop function if exists public.integrations_complete_oauth(
    uuid,
    text,
    text,
    text
);

-- =====================================================
-- 10. INDEXES AND TABLE COMMENTS
-- =====================================================

create index if not exists idx_integration_providers_active
    on public.integration_providers (is_active);

create index if not exists idx_device_integration_hardware
    on public.device_integration_map (tenant_id, provider_code, hardware_id)
      where hardware_id is not null;

create index if not exists idx_integration_providers_category
    on public.integration_providers (category);

comment on table public.integration_providers is
    'Integration provider catalog. code is the stable FK target for provider_code columns.';

create index if not exists idx_tenant_integrations_tenant
    on public.tenant_integrations (tenant_id);

create index if not exists idx_tenant_integrations_tenant_created
    on public.tenant_integrations (tenant_id, created_at desc);

create index if not exists idx_tenant_integrations_provider
    on public.tenant_integrations (provider_code);

comment on column public.tenant_integrations.credentials_ref is
    'Vault secret name. Never store secrets in config.';

create index if not exists idx_webhook_definitions_tenant
    on public.webhook_definitions (tenant_id);

create index if not exists idx_webhook_definitions_tenant_created
    on public.webhook_definitions (tenant_id, created_at desc);

create index if not exists idx_webhook_definitions_provider
    on public.webhook_definitions (provider_code);

create index if not exists idx_webhook_definitions_tenant_provider
    on public.webhook_definitions (tenant_id, provider_code);

comment on table public.webhook_definitions is
    'Outbound webhook subscription targets. Inbound ingest lives in platform.external_webhooks (000).';

create index if not exists idx_capabilities_provider
    on public.integration_capabilities (provider_code);

create index if not exists idx_device_integration_device
    on public.device_integration_map (device_id);

create index if not exists idx_device_integration_tenant
    on public.device_integration_map (tenant_id);

create index if not exists idx_device_integration_provider
    on public.device_integration_map (provider_code);

create unique index if not exists uq_device_integration_tenant_provider_external
    on public.device_integration_map (tenant_id, provider_code, external_id);

comment on table public.device_integration_map is
    'Maps domain devices to provider external IDs. No credentials or runtime state.';

create unique index if not exists
    uq_integration_webhook_mapping_active_identity
on public.integration_webhook_mappings (
    provider_code,
    event_type,
    mapping_code
)
where is_active = true;

-- =====================================================
-- HARDWARE IDENTITY UNIQUENESS
--
-- One physical provider device may not map to multiple
-- SmartHellas devices within the same tenant/provider.
-- =====================================================

create unique index if not exists uq_device_integration_tenant_provider_hardware
    on public.device_integration_map (tenant_id, provider_code, hardware_id)
        where hardware_id is not null;

-- =====================================================
-- 11. FOREIGN KEYS (PROVIDER + TENANT SSOT)
-- =====================================================

do $$
begin
    alter table public.tenant_integrations
        add constraint fk_tenant_integrations_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.webhook_definitions
        add constraint fk_webhook_definitions_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.tenant_integrations
        add constraint fk_tenant_integrations_provider_code
        foreign key (provider_code) references public.integration_providers(code);
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.webhook_definitions
        add constraint fk_webhook_definitions_provider_code
        foreign key (provider_code) references public.integration_providers(code);
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.integration_capabilities
        add constraint fk_integration_capabilities_provider_code
        foreign key (provider_code) references public.integration_providers(code);
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.device_integration_map
        add constraint fk_device_integration_map_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.device_integration_map
        add constraint fk_device_integration_map_provider_code
        foreign key (provider_code) references public.integration_providers(code);
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.service_accounts
        add constraint fk_service_accounts_provider_code
        foreign key (provider_code) references public.integration_providers(code);
exception when duplicate_object then null;
end $$;

do $$
begin
    alter table public.access_credentials
        add constraint fk_access_credentials_provider_code
        foreign key (provider_code) references public.integration_providers(code);
exception when duplicate_object then null;
end $$;


-- =====================================================
-- 15. INTEGRATION DEVICE CONSISTENCY
-- =====================================================

-- -----------------------------------------------------
-- 006 Integrations: enforce active-tenant ownership on device-map writes
-- -----------------------------------------------------

create or replace function public.enforce_device_integration_consistency()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
begin
    if new.external_id is null or btrim(new.external_id) = '' then
        raise exception 'external_id required';
    end if;

    select d.tenant_id
    into new.tenant_id
    from public.devices d
    where d.id = new.device_id;

    if not found then
        raise exception 'device not found';
    end if;

    if not platform.is_platform_admin() then
        v_tid := platform.current_tenant_id();
        if v_tid is null then
            raise exception 'no active tenant';
        end if;
        if new.tenant_id is distinct from v_tid then
            raise exception 'device does not belong to active tenant';
        end if;
    end if;

    return new;
end;
$$;

-- =====================================================
-- 16. TRIGGERS
-- =====================================================

create trigger trg_integration_providers_updated_at
before update on public.integration_providers
for each row execute function platform.set_updated_at();

create trigger trg_tenant_integrations_updated_at
before update on public.tenant_integrations
for each row execute function platform.set_updated_at();

create trigger trg_webhook_definitions_updated_at
before update on public.webhook_definitions
for each row execute function platform.set_updated_at();

create trigger trg_device_integration_consistency
before insert or update on public.device_integration_map
for each row execute function public.enforce_device_integration_consistency();

-- =====================================================
-- 17. WEBHOOK MAPPING RESOLUTION
-- =====================================================

create or replace function public.resolve_integration_webhook_mapping(
    p_provider_code text,
    p_event_type text,
    p_mapping_code text,
    p_payload jsonb
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_path text[];
    v_value text;
    v_value_type text;
begin

    if p_provider_code is null then
        raise exception 'provider_code is required';
    end if;

    if p_event_type is null then
        raise exception 'event_type is required';
    end if;

    if p_mapping_code is null then
        raise exception 'mapping_code is required';
    end if;

    if p_payload is null then
        return null;
    end if;

    select
        m.payload_path,
        m.value_type
    into
        v_path,
        v_value_type
    from public.integration_webhook_mappings m
    where m.provider_code = p_provider_code
      and m.event_type = p_event_type
      and m.mapping_code = p_mapping_code
      and m.is_active = true
    order by
        case
            when m.event_type = p_event_type then 0
            else 1
        end,
        length(m.event_type) desc
    limit 1;

    if not found then
        return null;
    end if;

    v_value := p_payload #>> v_path;

    if v_value is null or btrim(v_value) = '' then
        return null;
    end if;

    v_value := btrim(v_value);

    case coalesce(v_value_type, 'text')

        when 'text' then
            return v_value;

        when 'uuid' then
            return v_value;

        when 'timestamptz' then
            return v_value;

        when 'epoch_seconds' then
            return extract(
                epoch from to_timestamp(v_value::double precision)
            )::text;

        when 'epoch_milliseconds' then
            return extract(
                epoch from to_timestamp(
                    v_value::double precision / 1000.0
                )
            )::text;

        else
            raise exception
                'Unsupported integration webhook mapping value_type: %',
                v_value_type;
    end case;

exception
    when invalid_text_representation then
        raise exception
            'Invalid value for mapping %, provider %, event %: %',
            p_mapping_code,
            p_provider_code,
            p_event_type,
            v_value;
end;
$$;

-- =====================================================
-- GENERIC PROVIDER DEVICE LOOKUP
-- =====================================================

create or replace function public.resolve_provider_device_by_external_id(
    p_tenant_id uuid,
    p_provider_code text,
    p_external_id text
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
    select dim.device_id
    from public.device_integration_map dim
    where dim.tenant_id = p_tenant_id
      and dim.provider_code = p_provider_code
      and dim.external_id = p_external_id
    limit 1;
$$;

comment on function public.resolve_provider_device_by_external_id(
    uuid,
    text,
    text
) is
    'Generic provider device lookup by current external provider identifier.';

-- =====================================================
-- GENERIC PROVIDER HARDWARE LOOKUP
-- =====================================================

create or replace function public.resolve_provider_device_by_hardware_id(
    p_tenant_id uuid,
    p_provider_code text,
    p_hardware_id text
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
    select dim.device_id
    from public.device_integration_map dim
    where dim.tenant_id = p_tenant_id
      and dim.provider_code = p_provider_code
      and dim.hardware_id = p_hardware_id
    limit 1;
$$;

comment on function public.resolve_provider_device_by_hardware_id(
    uuid,
    text,
    text
) is
    'Generic provider device lookup by stable provider hardware identity.';

-- =====================================================
-- GENERIC PROVIDER DEVICE RECONCILIATION
--
-- Purpose:
-- Replace the current provider external_id when the
-- provider-side identifier changes.
--
-- Example:
--
-- old external_id = OLD123
-- hardware_id     = HW001
--
-- provider reports:
--
-- new external_id = NEW456
-- hardware_id     = HW001
--
-- Result:
--
-- external_id = NEW456
-- hardware_id = HW001
--
-- device_id remains unchanged.
-- =====================================================

create or replace function public.reconcile_provider_device(
    p_tenant_id uuid,
    p_provider_code text,
    p_external_id text,
    p_hardware_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_map_id uuid;
    v_device_id uuid;
    v_previous_external_id text;
begin

    if p_tenant_id is null then
        raise exception
            'tenant_id is required';
    end if;

    if p_provider_code is null
       or btrim(p_provider_code) = '' then
        raise exception
            'provider_code is required';
    end if;

    if p_external_id is null
       or btrim(p_external_id) = '' then
        raise exception
            'external_id is required';
    end if;

    if p_hardware_id is null
       or btrim(p_hardware_id) = '' then
        raise exception
            'hardware_id is required';
    end if;


    -- =================================================
    -- FIND EXISTING PHYSICAL DEVICE
    -- =================================================

    select
        dim.id,
        dim.device_id,
        dim.external_id
    into
        v_map_id,
        v_device_id,
        v_previous_external_id
    from public.device_integration_map dim
    where dim.tenant_id = p_tenant_id
      and dim.provider_code = p_provider_code
      and dim.hardware_id = p_hardware_id
    for update;


    if not found then

        raise exception
            'No provider device mapping found for provider % and hardware identity %',
            p_provider_code,
            p_hardware_id;

    end if;


    -- =================================================
    -- PROTECT AGAINST CROSS-DEVICE COLLISION
    --
    -- The new external ID may not already belong to a
    -- different SmartHellas device.
    -- =================================================

    if exists (
        select 1
        from public.device_integration_map dim
        where dim.tenant_id = p_tenant_id
          and dim.provider_code = p_provider_code
          and dim.external_id = p_external_id
          and dim.id <> v_map_id
    ) then

        raise exception
            'External provider identifier % already belongs to another device',
            p_external_id;

    end if;


    -- =================================================
    -- UPDATE CURRENT PROVIDER IDENTITY
    -- =================================================

    update public.device_integration_map
    set
        external_id = btrim(p_external_id)
    where id = v_map_id;


    -- =================================================
    -- AUDIT
    -- =================================================

    perform platform.log_audit(
        'provider.device_identity_reconciled',
        'device_integration_map',
        v_map_id,
        jsonb_build_object(
            'provider_code', p_provider_code,
            'device_id', v_device_id,
            'hardware_id', p_hardware_id,
            'previous_external_id', v_previous_external_id,
            'current_external_id', btrim(p_external_id)
        )
    );


    return jsonb_build_object(
        'reconciled', true,
        'device_map_id', v_map_id,
        'device_id', v_device_id,
        'provider_code', p_provider_code,
        'hardware_id', p_hardware_id,
        'previous_external_id', v_previous_external_id,
        'external_id', btrim(p_external_id)
    );

end;
$$;

comment on function public.reconcile_provider_device(
    uuid,
    text,
    text,
    text
) is
    'Generic provider device identity reconciliation. Stable hardware identity resolves a device when the current provider external identifier changes.';

-- =====================================================
-- 18. INTEGRATION DOMAIN FUNCTIONS
-- =====================================================

-- -----------------------------------------------------
-- 006 Integrations: domain authorization hardening
-- -----------------------------------------------------
--
-- SSOT ownership:
--
-- provider_api_base_url
--     MUST ONLY be written by:
--         public.integrations_complete_oauth()
--
-- This domain function may:
--     - read provider_api_base_url
--     - never create it
--     - never update it
--     - never accept it from portal callers
--
-- The value is provider-confirmed connection metadata
-- and therefore belongs to the OAuth completion flow.
-- -----------------------------------------------------

create or replace function public.integrations_domain(
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
    v_existing uuid;
begin

    p_payload := coalesce(
        p_payload,
        '{}'::jsonb
    );


    case p_op


    -- =================================================
    -- PROVIDERS
    -- =================================================

    when 'list_providers' then

        select
            coalesce(
                jsonb_agg(
                    to_jsonb(t)
                    order by t.name
                ),
                '[]'::jsonb
            )
        into v_result

        from (
            select
                ip.code,
                ip.name,
                ip.category,
                ip.description,
                ip.supports_webhooks,
                ip.supports_oauth,
                ip.supports_polling,
                ip.is_active,
                ip.configuration_schema

            from public.integration_providers ip

            where ip.is_active = true
        ) t;


    when 'get_provider' then

        select to_jsonb(t)
        into v_result

        from (
            select
                ip.code,
                ip.name,
                ip.category,
                ip.description,
                ip.supports_webhooks,
                ip.supports_oauth,
                ip.supports_polling,
                ip.is_active,
                ip.configuration_schema

            from public.integration_providers ip

            where ip.code = p_payload->>'code'
        ) t;


        if v_result is null then

            raise exception
                'Integration provider not found';

        end if;


    when 'list_capabilities' then

        select
            coalesce(
                jsonb_agg(
                    to_jsonb(t)
                    order by t.provider_code
                ),
                '[]'::jsonb
            )
        into v_result

        from (
            select
                ic.provider_code,
                ic.capability_code,
                ic.description,
                ic.is_supported

            from public.integration_capabilities ic

            where ic.is_supported = true

              and (
                    p_payload->>'provider_code' is null
                    or ic.provider_code =
                       p_payload->>'provider_code'
                  )
        ) t;


    -- =================================================
    -- TENANT INTEGRATIONS
    -- =================================================

    when 'list_tenant_integrations' then

        v_tid :=
            platform.current_tenant_id();


        select
            coalesce(
                jsonb_agg(
                    to_jsonb(t)
                    order by t.provider_code
                ),
                '[]'::jsonb
            )
        into v_result

        from (
            select
                ti.id,
                ti.tenant_id,
                ti.provider_code,

                -- READ ONLY FROM THE DOMAIN.
                --
                -- This value is written exclusively by
                -- integrations_complete_oauth().
                ti.provider_api_base_url,

                ti.credentials_ref,
                ti.config,
                ti.is_enabled,
                ti.created_at,
                ti.updated_at

            from public.tenant_integrations ti

            where ti.tenant_id = v_tid
        ) t;


    when 'get_tenant_integration' then

        v_tid :=
            platform.current_tenant_id();


        select to_jsonb(t)
        into v_result

        from (
            select
                ti.id,
                ti.tenant_id,
                ti.provider_code,

                -- READ ONLY FROM THE DOMAIN.
                ti.provider_api_base_url,

                ti.credentials_ref,
                ti.config,
                ti.is_enabled,
                ti.created_at,
                ti.updated_at

            from public.tenant_integrations ti

            where ti.tenant_id = v_tid

              and ti.provider_code =
                  p_payload->>'provider_code'
        ) t;


    -- =================================================
    -- MANUAL INTEGRATION CONNECTION
    -- =================================================

    when 'connect_integration' then

        perform public.edge_require_manager();


        -- provider_api_base_url is NOT accepted here.
        --
        -- OAuth completion owns this field.
        if p_payload ? 'provider_api_base_url' then

            raise exception
                'provider_api_base_url is managed exclusively by OAuth completion';

        end if;


        v_tid :=
            platform.current_tenant_id();


        if not exists (
            select 1
            from public.integration_providers ip

            where ip.code =
                  p_payload->>'provider_code'

              and ip.is_active = true
        ) then

            raise exception
                'Integration provider not found';

        end if;


        select ti.id
        into v_existing

        from public.tenant_integrations ti

        where ti.tenant_id = v_tid

          and ti.provider_code =
              p_payload->>'provider_code';


        if found then

            update public.tenant_integrations ti

            set

                credentials_ref =
                    coalesce(
                        p_payload->>'credentials_ref',
                        ti.credentials_ref
                    ),

                config =
                    coalesce(
                        p_payload->'config',
                        ti.config
                    ),

                is_enabled =
                    coalesce(
                        (p_payload->>'is_enabled')::boolean,
                        ti.is_enabled
                    ),

                updated_at = now()

            where ti.id = v_existing

            returning
                ti.id,
                ti.tenant_id,
                ti.provider_code,

                -- Existing provider API URL is preserved.
                -- It cannot be changed by this operation.
                ti.provider_api_base_url,

                ti.credentials_ref,
                ti.config,
                ti.is_enabled,
                ti.created_at,
                ti.updated_at

            into v_row;


            perform platform.log_audit(
                'integration.updated',
                'tenant_integration',
                v_row.id
            );


        else

            insert into public.tenant_integrations (
                tenant_id,
                provider_code,
                credentials_ref,
                config,
                is_enabled
            )

            values (
                v_tid,

                p_payload->>'provider_code',

                p_payload->>'credentials_ref',

                coalesce(
                    p_payload->'config',
                    '{}'::jsonb
                ),

                coalesce(
                    (p_payload->>'is_enabled')::boolean,
                    true
                )
            )

            returning
                id,
                tenant_id,
                provider_code,

                -- Will normally be NULL until OAuth completion
                -- receives provider-confirmed metadata.
                provider_api_base_url,

                credentials_ref,
                config,
                is_enabled,
                created_at,
                updated_at

            into v_row;


            perform platform.log_audit(
                'integration.connected',
                'tenant_integration',
                v_row.id,
                jsonb_build_object(
                    'provider_code',
                    p_payload->>'provider_code'
                )
            );

        end if;


        v_result :=
            to_jsonb(v_row);


    -- =================================================
    -- UPDATE INTEGRATION
    -- =================================================

    when 'update_integration' then

        perform public.edge_require_manager();


        -- provider_api_base_url is NOT accepted here.
        --
        -- This is an explicit SSOT ownership check.
        if p_payload ? 'provider_api_base_url' then

            raise exception
                'provider_api_base_url is managed exclusively by OAuth completion';

        end if;


        v_tid :=
            platform.current_tenant_id();


        update public.tenant_integrations ti

        set

            credentials_ref =
                case
                    when p_payload ? 'credentials_ref'
                    then p_payload->>'credentials_ref'
                    else ti.credentials_ref
                end,

            config =
                case
                    when p_payload ? 'config'
                    then p_payload->'config'
                    else ti.config
                end,

            is_enabled =
                case
                    when p_payload ? 'is_enabled'
                    then (p_payload->>'is_enabled')::boolean
                    else ti.is_enabled
                end,

            updated_at = now()

        where ti.tenant_id = v_tid

          and ti.provider_code =
              p_payload->>'provider_code'

        returning
            ti.id,
            ti.tenant_id,
            ti.provider_code,

            -- Read only.
            ti.provider_api_base_url,

            ti.credentials_ref,
            ti.config,
            ti.is_enabled,
            ti.created_at,
            ti.updated_at

        into v_row;


        if not found then

            raise exception
                'Integration not found';

        end if;


        perform platform.log_audit(
            'integration.updated',
            'tenant_integration',
            v_row.id,
            p_payload
        );


        v_result :=
            to_jsonb(v_row);


    -- =================================================
    -- DISCONNECT INTEGRATION
    -- =================================================

    when 'disconnect_integration' then

        perform public.edge_require_manager();


        v_tid :=
            platform.current_tenant_id();


        select ti.id
        into v_existing

        from public.tenant_integrations ti

        where ti.tenant_id = v_tid

          and ti.provider_code =
              p_payload->>'provider_code';


        if not found then

            raise exception
                'Integration not found';

        end if;


        delete from public.tenant_integrations ti

        where ti.tenant_id = v_tid

          and ti.provider_code =
              p_payload->>'provider_code';


        perform platform.log_audit(
            'integration.disconnected',
            'tenant_integration',
            v_existing,
            jsonb_build_object(
                'provider_code',
                p_payload->>'provider_code'
            )
        );


        v_result :=
            jsonb_build_object(
                'disconnected',
                true,

                'provider_code',
                p_payload->>'provider_code'
            );


    -- =================================================
    -- WEBHOOK DEFINITIONS
    -- =================================================

    when 'list_webhook_definitions' then

        v_tid :=
            platform.current_tenant_id();


        select
            coalesce(
                jsonb_agg(
                    to_jsonb(t)
                    order by t.created_at
                ),
                '[]'::jsonb
            )
        into v_result

        from (
            select
                wd.id,
                wd.tenant_id,
                wd.provider_code,
                wd.event_type,
                wd.target_url,
                wd.signing_secret_ref,
                wd.is_active,
                wd.created_at,
                wd.updated_at

            from public.webhook_definitions wd

            where wd.tenant_id = v_tid

              and (
                    p_payload->>'provider_code' is null
                    or wd.provider_code =
                       p_payload->>'provider_code'
                  )
        ) t;


    when 'create_webhook_definition' then

        perform public.edge_require_manager();


        v_tid :=
            platform.current_tenant_id();


        insert into public.webhook_definitions (
            tenant_id,
            provider_code,
            event_type,
            target_url,
            signing_secret_ref,
            is_active
        )

        values (
            v_tid,
            p_payload->>'provider_code',
            p_payload->>'event_type',
            p_payload->>'target_url',
            p_payload->>'signing_secret_ref',
            coalesce(
                (p_payload->>'is_active')::boolean,
                true
            )
        )

        returning
            id,
            tenant_id,
            provider_code,
            event_type,
            target_url,
            signing_secret_ref,
            is_active,
            created_at,
            updated_at

        into v_row;


        perform platform.log_audit(
            'webhook_definition.created',
            'webhook_definition',
            v_row.id
        );


        v_result :=
            to_jsonb(v_row);


    when 'update_webhook_definition' then

        perform public.edge_require_manager();


        v_tid :=
            platform.current_tenant_id();


        update public.webhook_definitions wd

        set

            event_type =
                case
                    when p_payload ? 'event_type'
                    then p_payload->>'event_type'
                    else wd.event_type
                end,

            target_url =
                case
                    when p_payload ? 'target_url'
                    then p_payload->>'target_url'
                    else wd.target_url
                end,

            signing_secret_ref =
                case
                    when p_payload ? 'signing_secret_ref'
                    then p_payload->>'signing_secret_ref'
                    else wd.signing_secret_ref
                end,

            is_active =
                case
                    when p_payload ? 'is_active'
                    then (p_payload->>'is_active')::boolean
                    else wd.is_active
                end,

            updated_at = now()

        where wd.id =
              (p_payload->>'id')::uuid

          and wd.tenant_id = v_tid

        returning
            wd.id,
            wd.tenant_id,
            wd.provider_code,
            wd.event_type,
            wd.target_url,
            wd.signing_secret_ref,
            wd.is_active,
            wd.created_at,
            wd.updated_at

        into v_row;


        if not found then

            raise exception
                'Webhook definition not found';

        end if;


        perform platform.log_audit(
            'webhook_definition.updated',
            'webhook_definition',
            v_row.id,
            p_payload
        );


        v_result :=
            to_jsonb(v_row);


    when 'delete_webhook_definition' then

        perform public.edge_require_manager();


        v_tid :=
            platform.current_tenant_id();


        delete from public.webhook_definitions wd

        where wd.id =
              (p_payload->>'id')::uuid

          and wd.tenant_id = v_tid;


        if not found then

            raise exception
                'Webhook definition not found';

        end if;


        perform platform.log_audit(
            'webhook_definition.deleted',
            'webhook_definition',
            (p_payload->>'id')::uuid
        );


        v_result :=
            jsonb_build_object(
                'deleted',
                true,

                'id',
                p_payload->>'id'
            );


    -- =================================================
    -- DEVICE MAPS
    -- =================================================

    when 'list_device_maps' then

        v_tid :=
            platform.current_tenant_id();


        select
            coalesce(
                jsonb_agg(
                    to_jsonb(t)
                    order by t.created_at
                ),
                '[]'::jsonb
            )
        into v_result

        from (
            select
                dim.id,
                dim.tenant_id,
                dim.device_id,
                dim.provider_code,
                dim.external_id,
                dim.hardware_id,
                dim.config,
                dim.created_at

            from public.device_integration_map dim

            where dim.tenant_id = v_tid

              and (
                    p_payload->>'device_id' is null
                    or dim.device_id =
                       (p_payload->>'device_id')::uuid
                  )

              and (
                    p_payload->>'provider_code' is null
                    or dim.provider_code =
                       p_payload->>'provider_code'
                  )
        ) t;


    when 'create_device_map' then

        perform public.edge_require_manager();


        v_tid :=
            platform.current_tenant_id();


        insert into public.device_integration_map (
            device_id,
            provider_code,
            external_id,
            hardware_id,
            config
        )

        values (
            (p_payload->>'device_id')::uuid,

            lower(
                trim(
                    p_payload->>'provider_code'
                )
            ),

            p_payload->>'external_id',

            nullif(
                trim(
                    p_payload->>'hardware_id'
                ),
                ''
            ),

            coalesce(
                p_payload->'config',
                '{}'::jsonb
            )
        )

        returning
            id,
            tenant_id,
            device_id,
            provider_code,
            external_id,
            hardware_id,
            config,
            created_at

        into v_row;


        perform platform.log_audit(
            'device_integration_map.created',
            'device_integration_map',
            v_row.id
        );


        v_result :=
            to_jsonb(v_row);


    when 'update_device_map' then

        perform public.edge_require_manager();


        v_tid :=
            platform.current_tenant_id();


        update public.device_integration_map dim

        set

            external_id =
                case
                    when p_payload ? 'external_id'
                    then p_payload->>'external_id'
                    else dim.external_id
                end,

            hardware_id =
                case
                    when p_payload ? 'hardware_id'
                    then nullif(
                        trim(
                            p_payload->>'hardware_id'
                        ),
                        ''
                    )
                    else dim.hardware_id
                end,

            config =
                case
                    when p_payload ? 'config'
                    then p_payload->'config'
                    else dim.config
                end

        where dim.id =
              (p_payload->>'id')::uuid

          and dim.tenant_id = v_tid

        returning
            dim.id,
            dim.tenant_id,
            dim.device_id,
            dim.provider_code,
            dim.external_id,
            dim.hardware_id,
            dim.config,
            dim.created_at

        into v_row;


        if not found then

            raise exception
                'Device map not found';

        end if;


        perform platform.log_audit(
            'device_integration_map.updated',
            'device_integration_map',
            v_row.id
        );


        v_result :=
            to_jsonb(v_row);


    when 'delete_device_map' then

        perform public.edge_require_manager();


        v_tid :=
            platform.current_tenant_id();


        delete from public.device_integration_map dim

        where dim.id =
              (p_payload->>'id')::uuid

          and dim.tenant_id = v_tid;


        if not found then

            raise exception
                'Device map not found';

        end if;


        perform platform.log_audit(
            'device_integration_map.deleted',
            'device_integration_map',
            (p_payload->>'id')::uuid
        );


        v_result :=
            jsonb_build_object(
                'deleted',
                true,

                'id',
                p_payload->>'id'
            );


    -- =================================================
    -- FALLBACK / EXTENSIONS
    -- =================================================

    else

        return public.integrations_domain_ext(
            p_op,
            p_payload
        );

    end case;


    return v_result;

end;
$$;

-- =====================================================
-- 19. INTEGRATION DOMAIN EXTENSIONS
-- =====================================================

-- -----------------------------------------------------
-- 006: extend integrations_domain_ext with start_oauth
-- -----------------------------------------------------

create or replace function public.integrations_domain_ext(
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
    v_uid uuid;
    v_result jsonb;
    v_state_token text;
    v_expires_at timestamptz;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op
    when 'start_oauth' then
        return public.integrations_start_oauth(p_payload);

    when 'register_oauth_state' then
        v_tid := platform.current_tenant_id();
        v_uid := auth.uid();
        if p_payload->>'provider_code' is null then
            raise exception 'provider_code is required';
        end if;
        if not exists (
            select 1 from public.integration_providers ip
            where ip.code = p_payload->>'provider_code'
              and ip.supports_oauth = true
              and ip.is_active = true
        ) then
            raise exception 'Integration provider not found or does not support OAuth';
        end if;
        v_state_token := encode(extensions.gen_random_bytes(32), 'hex');
        v_expires_at := now() + interval '10 minutes';
        insert into public.integration_oauth_states (
            tenant_id, user_id, provider_code, state_token, expires_at
        )
        values (
            v_tid, v_uid, p_payload->>'provider_code', v_state_token, v_expires_at
        );
        v_result := jsonb_build_object(
            'state_token', v_state_token,
            'expires_at', v_expires_at,
            'provider_code', p_payload->>'provider_code'
        );

    when 'request_sync' then
        v_tid := platform.current_tenant_id();
        v_uid := auth.uid();
        if p_payload->>'provider_code' is null then
            raise exception 'provider_code is required';
        end if;
        if not exists (
            select 1 from public.tenant_integrations ti
            where ti.tenant_id = v_tid
              and ti.provider_code = p_payload->>'provider_code'
              and ti.is_enabled = true
        ) then
            raise exception 'Integration not connected or disabled';
        end if;
        perform platform.push_integration_event(
            p_payload->>'provider_code',
            'sync_state',
            jsonb_build_object(
                'tenant_id', v_tid,
                'triggered_by', v_uid,
                'scope', coalesce(p_payload->'scope', '{}'::jsonb)
            )
        );
        perform platform.log_audit(
            'integration.sync_requested',
            'tenant_integration',
            (
                select ti.id from public.tenant_integrations ti
                where ti.tenant_id = v_tid and ti.provider_code = p_payload->>'provider_code'
            ),
            jsonb_build_object('provider_code', p_payload->>'provider_code')
        );
        v_result := jsonb_build_object(
            'queued', true,
            'provider_code', p_payload->>'provider_code'
        );


    else
        raise exception 'unknown integrations_domain operation: %', p_op;
    end case;

    return v_result;
end;
$$;

-- =====================================================
-- OAuth state completion
-- =====================================================

drop function if exists public.integrations_complete_oauth(
    text
);

-- =====================================================
-- 006 Integrations: OAuth completion (SSOT hardened)
-- =====================================================
---------------------------------------------------------

-- Responsibility:
-- - Resolve OAuth transaction from state
-- - Resolve tenant/provider from OAuth state
-- - Derive credentials reference deterministically
-- - Validate OAuth credentials in Vault
-- - Derive non-secret token metadata
-- - Resolve provider API base URL from OAuth token claim
-- - Consume the OAuth state transaction
-- - Upsert tenant integration
-- - Audit successful OAuth completion
-- - Audit provider API base URL changes
---------------------------------------------------------

-- SSOT:
-- integration_oauth_states = OAuth transaction
-- integration_providers    = provider catalog
-- tenant_integrations      = tenant integration SSOT
-- Vault                    = OAuth credentials/tokens
---------------------------------------------------------

-- MUST NOT:
-- - accept tenant_id from caller
-- - accept provider_code from caller
-- - accept credentials_ref from caller
-- - accept OAuth tokens from caller
-- - store OAuth tokens in PostgreSQL
-- =====================================================

create or replace function public.integrations_complete_oauth(
    p_state_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare

    v_state public.integration_oauth_states;
    v_row public.tenant_integrations;

    v_tenant_id uuid;
    v_provider_code text;
    v_credentials_ref text;

    v_token_response jsonb;

    v_expires_in bigint;
    v_token_expires_at timestamptz;
    v_token_type text;
    v_scope text;

    v_config jsonb;

    -- OAuth provider API base URL metadata
    v_api_base_url_claim text;
    v_provider_api_base_url text;
    v_previous_api_base_url text;

begin

    -- =================================================
    -- 1. INPUT VALIDATION
    -- =================================================

    if p_state_token is null
       or length(trim(p_state_token)) = 0 then

        raise exception
            'OAuth state token is required';

    end if;


    -- =================================================
    -- 2. RESOLVE OAUTH TRANSACTION
    --
    -- OAuth state is authoritative for:
    -- - tenant
    -- - provider
    -- - transaction validity
    --
    -- State can only be consumed once.
    -- =================================================

    select *
    into v_state
    from public.integration_oauth_states s
    where s.state_token = trim(p_state_token)
      and s.consumed_at is null
      and s.expires_at > now()
    for update;


    if not found then

        raise exception
            'Invalid, expired, or already consumed OAuth state';

    end if;


    -- =================================================
    -- 3. RESOLVE TENANT / PROVIDER FROM STATE
    -- =================================================

    v_state :=
        public._integrations_resolve_oauth_state_internal(
            trim(p_state_token)
        );

    v_tenant_id :=
        v_state.tenant_id;

    v_provider_code :=
        lower(trim(v_state.provider_code));


    if v_tenant_id is null then

        raise exception
            'OAuth state does not contain tenant_id';

    end if;


    if v_provider_code is null
       or v_provider_code = '' then

        raise exception
            'OAuth state does not contain provider_code';

    end if;


    -- =================================================
    -- 4. VALIDATE PROVIDER
    -- =================================================

    if not exists (
        select 1
        from public.integration_providers ip
        where ip.code = v_provider_code
          and ip.is_active = true
    ) then

        raise exception
            'Active integration provider not found: %',
            v_provider_code;

    end if;


    -- =================================================
    -- 5. RESOLVE OAUTH CONFIGURATION
    --
    -- api_base_url_claim defines which OAuth token claim
    -- contains the provider-specific API base URL.
    --
    -- Example for Shelly:
    -- api_base_url_claim = 'user_api_url'
    --
    -- This keeps provider-specific claim names in the
    -- provider configuration rather than in procedural
    -- IF/ELSE provider logic.
    -- =================================================

    select
        c.api_base_url_claim
    into
        v_api_base_url_claim
    from public.integration_oauth_configs c
    where c.provider_code = v_provider_code
      and c.is_active = true;


    -- =================================================
    -- 6. DERIVE CREDENTIALS REFERENCE
    --
    -- Never accept this from the caller.
    -- Must match the reference generated by
    -- integrations_exchange_oauth_tokens().
    -- =================================================

    v_credentials_ref :=
        format(
            'integrations/%s/%s',
            v_tenant_id,
            v_provider_code
        );


    -- =================================================
    -- 7. VERIFY CREDENTIALS EXIST IN VAULT
    -- =================================================

    if not platform.vault_secret_exists(
        v_credentials_ref
    ) then

        raise exception
            'OAuth credentials not found in Vault for provider %',
            v_provider_code;

    end if;


    -- =================================================
    -- 8. READ TOKEN METADATA FROM VAULT
    --
    -- The complete token response remains in Vault.
    --
    -- Only non-secret metadata is copied into
    -- tenant_integrations.config.
    -- =================================================

    v_token_response :=
        platform.get_vault_secret(
            v_credentials_ref
        )::jsonb;


    if v_token_response is null then

        raise exception
            'OAuth credentials could not be resolved from Vault';

    end if;


    -- =================================================
    -- 9. RESOLVE EXPIRY METADATA
    --
    -- expires_in is a relative lifetime in seconds.
    -- We convert it into an absolute timestamp.
    --
    -- If the provider does not return expires_in,
    -- no expiry timestamp is stored.
    -- =================================================

    if v_token_response ? 'expires_in' then

        begin

            v_expires_in :=
                (v_token_response->>'expires_in')::bigint;

        exception
            when others then

                raise exception
                    'Invalid OAuth expires_in value for provider %',
                    v_provider_code;

        end;


        if v_expires_in < 0 then

            raise exception
                'Invalid negative OAuth expires_in value for provider %',
                v_provider_code;

        end if;


        v_token_expires_at :=
            now()
            + make_interval(
                secs => v_expires_in
            );

    end if;


    -- =================================================
    -- 10. RESOLVE NON-SECRET TOKEN METADATA
    -- =================================================

    v_token_type :=
        nullif(
            btrim(
                v_token_response->>'token_type'
            ),
            ''
        );

    v_scope :=
        nullif(
            btrim(
                v_token_response->>'scope'
            ),
            ''
        );


    -- =================================================
    -- 11. RESOLVE PROVIDER API BASE URL
    --
    -- The claim name is provider configuration.
    --
    -- Example:
    -- Shelly:
    -- api_base_url_claim = 'user_api_url'
    --
    -- The actual URL is extracted from the provider-
    -- issued access token.
    --
    -- This value is NOT a secret. It is stored as
    -- tenant/provider connection metadata.
    -- =================================================

    v_provider_api_base_url := null;


    if nullif(
        btrim(v_api_base_url_claim),
        ''
    ) is not null then

        v_provider_api_base_url :=
            public.extract_oauth_jwt_claim(
                v_token_response->>'access_token',
                v_api_base_url_claim
            );

    end if;


    -- =================================================
    -- 12. VALIDATE / NORMALIZE PROVIDER API BASE URL
    --
    -- Only HTTPS host URLs are accepted.
    --
    -- Examples accepted:
    -- https://shelly-31-eu.shelly.cloud
    -- https://shelly-31-eu.shelly.cloud/
    --
    -- Stored canonical form:
    -- https://shelly-31-eu.shelly.cloud
    -- =================================================

    if v_provider_api_base_url is not null then

        v_provider_api_base_url :=
            nullif(
                btrim(v_provider_api_base_url),
                ''
            );


        if v_provider_api_base_url is not null then

            if v_provider_api_base_url !~ '^https://[^/?#]+/?$' then

                raise exception
                    'Invalid provider API base URL returned by provider %',
                    v_provider_code;

            end if;


            v_provider_api_base_url :=
                rtrim(
                    v_provider_api_base_url,
                    '/'
                );

        end if;

    end if;


    -- =================================================
    -- 13. BUILD INTEGRATION CONFIG
    --
    -- NEVER copy:
    -- - access_token
    -- - refresh_token
    --
    -- Only non-secret OAuth metadata is stored.
    --
    -- provider_api_base_url is deliberately NOT stored
    -- in config JSONB. It has its own first-class column
    -- in tenant_integrations because it is connection-
    -- level routing metadata.
    -- =================================================

    v_config :=
        jsonb_build_object(
            'oauth',
            jsonb_strip_nulls(
                jsonb_build_object(
                    'token_type',
                    v_token_type,

                    'scope',
                    v_scope,

                    'token_expires_at',
                    v_token_expires_at,

                    'token_received_at',
                    now()
                )
            )
        );


    -- =================================================
    -- 14. READ PREVIOUS PROVIDER API BASE URL
    --
    -- This is needed to detect a provider-side URL
    -- change.
    --
    -- FOR UPDATE keeps the existing tenant integration
    -- locked until the upsert completes.
    -- =================================================

    select
        ti.provider_api_base_url
    into
        v_previous_api_base_url
    from public.tenant_integrations ti
    where ti.tenant_id = v_tenant_id
      and ti.provider_code = v_provider_code
    for update;


    -- =================================================
    -- 15. CONSUME OAUTH STATE
    --
    -- Only after:
    -- - state validation
    -- - provider validation
    -- - Vault credential validation
    -- - token metadata validation
    -- - provider API URL validation
    -- =================================================

    update public.integration_oauth_states
    set consumed_at = now()
    where id = v_state.id;


    -- =================================================
    -- 16. UPSERT TENANT INTEGRATION
    --
    -- tenant_integrations is the SSOT for the current
    -- tenant/provider connection.
    --
    -- If the provider returns no API base URL, preserve
    -- an existing known URL.
    -- =================================================

    insert into public.tenant_integrations (
        tenant_id,
        provider_code,
        credentials_ref,
        provider_api_base_url,
        config,
        is_enabled
    )

    values (
        v_tenant_id,
        v_provider_code,
        v_credentials_ref,
        v_provider_api_base_url,
        v_config,
        true
    )

    on conflict (
        tenant_id,
        provider_code
    )

    do update

    set
        credentials_ref =
            excluded.credentials_ref,

        provider_api_base_url =
            coalesce(
                excluded.provider_api_base_url,
                public.tenant_integrations.provider_api_base_url
            ),

        config =
            excluded.config,

        is_enabled =
            true,

        updated_at =
            now()

    returning
        id,
        tenant_id,
        provider_code,
        credentials_ref,
        provider_api_base_url,
        config,
        is_enabled,
        created_at,
        updated_at

    into v_row;


    -- =================================================
    -- 17. AUDIT PROVIDER API BASE URL CHANGE
    --
    -- This is separate from the generic OAuth completion
    -- event because the URL is operational routing
    -- metadata and may change independently over time.
    -- =================================================

    if v_provider_api_base_url is not null
       and v_previous_api_base_url is not null
       and v_provider_api_base_url <>
           v_previous_api_base_url then

        perform platform.log_audit(
            'integration.provider_api_base_url_changed',
            'tenant_integration',
            v_row.id,
            jsonb_build_object(
                'provider_code',
                v_provider_code,

                'previous_provider_api_base_url',
                v_previous_api_base_url,

                'new_provider_api_base_url',
                v_provider_api_base_url
            )
        );

    end if;


    -- =================================================
    -- 18. AUDIT SUCCESSFUL OAUTH COMPLETION
    -- =================================================

    perform platform.log_audit(
        'integration.oauth_completed',
        'tenant_integration',
        v_row.id,
        jsonb_build_object(
            'provider_code',
            v_provider_code,

            'token_expires_at',
            v_token_expires_at,

            'provider_api_base_url',
            v_provider_api_base_url
        )
    );


    -- =================================================
    -- 19. RETURN
    --
    -- Never return:
    -- - credentials_ref
    -- - access_token
    -- - refresh_token
    --
    -- provider_api_base_url is non-secret connection
    -- metadata and may be returned.
    -- =================================================

    return jsonb_build_object(

        'id',
        v_row.id,

        'tenant_id',
        v_row.tenant_id,

        'provider_code',
        v_row.provider_code,

        'is_enabled',
        v_row.is_enabled,

        'provider_api_base_url',
        v_row.provider_api_base_url,

        'oauth',
        jsonb_strip_nulls(
            jsonb_build_object(

                'token_type',
                v_token_type,

                'scope',
                v_scope,

                'token_expires_at',
                v_token_expires_at

            )
        )
    );

end;
$$;


-- =====================================================
-- 006: GENERIC OAUTH START
--
-- Responsibility:
-- - Validate provider OAuth capability
-- - Resolve OAuth protocol configuration
-- - Resolve client credentials from Vault
-- - Resolve redirect 
-- - Generate OAuth state
-- - Generate PKCE when required
-- - Persist complete OAuth transaction state
-- - Build provider authorization URL
--
-- SSOT:
-- - integration_providers       = provider capability
-- - integration_oauth_configs   = OAuth protocol config
-- - integration_oauth_states    = OAuth transaction state
-- - Vault                       = client credentials
--
-- MUST NOT:
-- - contain provider-specific IF branches
-- - store client secrets in PostgreSQL
-- - trust tenant_id from caller
-- - trust user_id from caller
-- - return code_verifier
-- - return client_secret
-- =====================================================

create or replace function public.integrations_start_oauth(
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_uid uuid;

    v_provider_code text;

    v_oauth_config record;

    v_state_token text;
    v_expires_at timestamptz;

    v_redirect_uri text;

    v_supabase_url text;
    v_client_id text;

    v_code_verifier text;
    v_code_challenge text;

    v_authorize_url text;
    v_scope text;

    v_scope_params text := '';

    v_state_id uuid;
begin

    p_payload := coalesce(
        p_payload,
        '{}'::jsonb
    );


    -- =================================================
    -- 1. CURRENT USER / TENANT
    -- =================================================

    v_tid := platform.current_tenant_id();
    v_uid := auth.uid();


    if v_uid is null then
        raise exception
            'Authentication required';
    end if;


    if v_tid is null then
        raise exception
            'Active tenant context required';
    end if;


    -- =================================================
    -- 2. PROVIDER
    -- =================================================

    v_provider_code :=
        lower(
            trim(
                p_payload->>'provider_code'
            )
        );


    if v_provider_code is null
       or v_provider_code = '' then

        raise exception
            'provider_code is required';

    end if;


    -- =================================================
    -- 3. PROVIDER + OAUTH CONFIG
    --
    -- integration_providers:
    -- provider capability
    --
    -- integration_oauth_configs:
    -- OAuth protocol configuration
    -- =================================================

    select
        ip.code,
        ip.supports_oauth,
        ip.is_active as provider_is_active,

        oc.authorization_url,
        oc.token_url,
        oc.default_scopes,
        oc.response_type,
        oc.grant_type,
        oc.client_auth_method,
        oc.pkce_required,
        oc.pkce_method,
        oc.api_base_url_claim,
        oc.redirect_uri_mode,
        oc.is_active as oauth_config_is_active

    into v_oauth_config

    from public.integration_providers ip

    join public.integration_oauth_configs oc
        on oc.provider_code = ip.code

    where ip.code = v_provider_code
      and ip.is_active = true
      and ip.supports_oauth = true
      and oc.is_active = true

    limit 1;


    if not found then

        raise exception
            'OAuth provider configuration not found or inactive for %',
            v_provider_code;

    end if;


    -- =================================================
    -- 4. CLIENT ID
    --
    -- Client ID remains outside PostgreSQL business
    -- tables and is resolved from Vault.
    -- =================================================

    v_client_id :=
        platform.get_vault_secret(
            'oauth_client_id_' || v_provider_code
        );


    if v_client_id is null
       or btrim(v_client_id) = '' then

        raise exception
            'OAuth client ID not configured for provider %',
            v_provider_code;

    end if;


    -- =================================================
    -- 5. REDIRECT 
    --
    -- The redirect  becomes part of the OAuth
    -- transaction state and MUST be reused dng
    -- token exchange.
    -- =================================================

    case v_oauth_config.redirect_uri_mode

        when 'supabase_function' then

            v_supabase_url :=
                platform.get_vault_secret(
                    'supabase_url'
                );


            if v_supabase_url is null
               or btrim(v_supabase_url) = '' then

                raise exception
                    'supabase_url not configured in Vault';

            end if;


            v_redirect_uri :=
                rtrim(
                    v_supabase_url,
                    '/'
                )
                || '/functions/v1/integrations-oauth-callback';


        when 'configured' then

            v_redirect_uri :=
                nullif(
                    btrim(
                        p_payload->>'redirect_uri'
                    ),
                    ''
                );


            if v_redirect_uri is null then

                raise exception
                    'redirect_uri is required for configured OAuth redirect mode';

            end if;


        else

            raise exception
                'Unsupported OAuth redirect_uri_mode: %',
                v_oauth_config.redirect_uri_mode;

    end case;


    -- =================================================
    -- 6. GENERATE STATE
    --
    -- State is the transaction identifier.
    -- It is stored before the authorization URL is
    -- returned to the caller.
    -- =================================================

    v_state_token :=
        encode(
            extensions.gen_random_bytes(32),
            'hex'
        );


    v_expires_at :=
        now() + interval '10 minutes';


    -- =================================================
    -- 7. GENERATE PKCE
    -- =================================================

    if v_oauth_config.pkce_required then

        if v_oauth_config.pkce_method <> 'S256' then

            raise exception
                'Unsupported PKCE method for provider %: %',
                v_provider_code,
                v_oauth_config.pkce_method;

        end if;


        v_code_verifier :=
            encode(
                extensions.gen_random_bytes(32),
                'base64'
            );


        -- Base64 → Base64URL
        v_code_verifier :=
            rtrim(
                replace(
                    replace(
                        v_code_verifier,
                        '+',
                        '-'
                    ),
                    '/',
                    '_'
                ),
                '='
            );


        v_code_challenge :=
            encode(
                extensions.digest(
                    convert_to(
                        v_code_verifier,
                        'UTF8'
                    ),
                    'sha256'
                ),
                'base64'
            );


        -- Base64 → Base64URL
        v_code_challenge :=
            rtrim(
                replace(
                    replace(
                        v_code_challenge,
                        '+',
                        '-'
                    ),
                    '/',
                    '_'
                ),
                '='
            );

    end if;


    -- =================================================
    -- 8. BUILD SCOPE
    -- =================================================

    if coalesce(
        array_length(
            v_oauth_config.default_scopes,
            1
        ),
        0
    ) > 0 then

        foreach v_scope in
            array v_oauth_config.default_scopes
        loop

            if v_scope_params <> '' then
                v_scope_params :=
                    v_scope_params || ' ';
            end if;


            v_scope_params :=
                v_scope_params || v_scope;

        end loop;

    end if;


    -- =================================================
    -- 9. PERSIST COMPLETE OAUTH TRANSACTION
    --
    -- integration_oauth_states is the SSOT for the
    -- complete OAuth transaction.
    -- =================================================

    insert into public.integration_oauth_states (
        tenant_id,
        user_id,
        provider_code,
        state_token,
        redirect_uri,
        code_verifier,
        code_challenge_method,
        expires_at
    )

    values (
        v_tid,
        v_uid,
        v_provider_code,
        v_state_token,
        v_redirect_uri,
        v_code_verifier,

        case
            when v_oauth_config.pkce_required
            then v_oauth_config.pkce_method
            else null
        end,

        v_expires_at
    )

    returning id
    into v_state_id;


    -- =================================================
    -- 10. BUILD AUTHORIZATION URL
    -- =================================================

    v_authorize_url :=
        rtrim(
            v_oauth_config.authorization_url,
            '?&'
        )
        || '?'
        || 'response_type='
        || public.integrations_oauth_url_encode(
            v_oauth_config.response_type
        )
        || '&client_id='
        || public.integrations_oauth_url_encode(
            v_client_id
        )
        || '&redirect_uri='
        || public.integrations_oauth_url_encode(
            v_redirect_uri
        )
        || '&state='
        || public.integrations_oauth_url_encode(
            v_state_token
        );


    -- =================================================
    -- 11. OPTIONAL SCOPE
    -- =================================================

    if v_scope_params <> '' then

        v_authorize_url :=
            v_authorize_url
            || '&scope='
            || public.integrations_oauth_url_encode(
                v_scope_params
            );

    end if;


    -- =================================================
    -- 12. PKCE PARAMETERS
    -- =================================================

    if v_oauth_config.pkce_required then

        v_authorize_url :=
            v_authorize_url
            || '&code_challenge='
            || public.integrations_oauth_url_encode(
                v_code_challenge
            )
            || '&code_challenge_method='
            || public.integrations_oauth_url_encode(
                v_oauth_config.pkce_method
            );

    end if;


    -- =================================================
    -- 13. AUDIT
    --
    -- Do not log:
    -- - client_id
    -- - code_verifier
    -- - authorization code
    -- - client_secret
    -- =================================================

    perform platform.log_audit(
        'integration.oauth_started',
        'integration_oauth_state',
        v_state_id,
        jsonb_build_object(
            'provider_code',
            v_provider_code,

            'pkce_required',
            v_oauth_config.pkce_required,

            'redirect_uri_mode',
            v_oauth_config.redirect_uri_mode
        )
    );


    -- =================================================
    -- 14. RETURN
    --
    -- State is intentionally returned because the
    -- browser must carry it through the OAuth flow.
    --
    -- Never return:
    -- - code_verifier
    -- - client_secret
    -- =================================================

    return jsonb_build_object(
        'authorize_url',
        v_authorize_url,

        'state',
        v_state_token,

        'provider_code',
        v_provider_code,

        'expires_at',
        v_expires_at
    );

end;
$$;

-- =====================================================
-- 006 Integrations: Internal OAuth state resolution
--
-- Responsibility:
-- - Validate an OAuth transaction state
-- - Resolve the original tenant/user/provider context
-- - Return the complete transaction state to trusted
--   server-side OAuth functions only
--
-- MUST NOT:
-- - be callable by tenant/browser clients
-- - return OAuth state as JSON to clients
-- - perform tenant authorization for portal requests
-- - consume the OAuth state
-- - exchange authorization codes
-- - create/update tenant_integrations
-- - accept tenant/provider context from the caller
--
-- Security:
-- - SECURITY DEFINER
-- - complete OAuth state remains server-side
-- - code_verifier is never exposed through a
--   client-facing resolver
--
-- SSOT:
-- integration_oauth_states
-- =====================================================

drop function if exists public.integrations_resolve_oauth_state(
    text
);

drop function if exists public._integrations_resolve_oauth_state_internal(
    text
);


create or replace function public._integrations_resolve_oauth_state_internal(
    p_state_token text
)
returns public.integration_oauth_states
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_state public.integration_oauth_states;
begin

    -- =================================================
    -- 1. INPUT VALIDATION
    -- =================================================

    if p_state_token is null
       or length(trim(p_state_token)) = 0 then

        raise exception
            'OAuth state token is required';

    end if;


    -- =================================================
    -- 2. RESOLVE ACTIVE OAUTH TRANSACTION
    --
    -- The state token is the only lookup key supplied
    -- to this function.
    --
    -- Tenant/provider/user context is NEVER accepted
    -- from the caller.
    --
    -- FOR UPDATE ensures that the OAuth transaction
    -- cannot be concurrently consumed/processed.
    -- =================================================

    select *
    into v_state

    from public.integration_oauth_states s

    where s.state_token = trim(p_state_token)

      and s.consumed_at is null

      and s.expires_at > now()

    for update;


    -- =================================================
    -- 3. STATE VALIDATION
    -- =================================================

    if not found then

        raise exception
            'Invalid or expired OAuth state';

    end if;


    -- =================================================
    -- 4. RETURN INTERNAL TRANSACTION STATE
    --
    -- The complete row is returned because this function
    -- is exclusively an internal dependency of trusted
    -- OAuth server-side functions.
    --
    -- This includes code_verifier.
    --
    -- code_verifier MUST NEVER be returned directly to
    -- an authenticated browser/client.
    --
    -- The function itself is therefore NOT a public API.
    -- =================================================

    return v_state;

end;
$$;


comment on function public._integrations_resolve_oauth_state_internal(
    text
) is
'Internal OAuth transaction-state resolver. 
 Returns the complete integration_oauth_states row,
 including PKCE code_verifier, exclusively for trusted server-side OAuth functions. 
 Must not be exposed to tenant/browser clients.';
-- =====================================================

-- OAuth token exchange
-- =====================================================

drop function if exists public.integrations_exchange_oauth_tokens(
    uuid,
    text,
    text,
    text
);


-- -----------------------------------------------------
-- 006 Integrations: Generic OAuth token exchange (SSOT)
-- -----------------------------------------------------
--
-- Responsibility:
-- - Resolve OAuth transaction from state
-- - Resolve provider OAuth configuration
-- - Resolve client credentials from Vault
-- - Exchange authorization code for tokens
-- - Store provider token response in Vault
--
-- SSOT:
-- integration_oauth_states  = OAuth transaction
-- integration_oauth_configs = OAuth protocol configuration
-- Vault                     = client credentials/tokens
--
-- MUST NOT:
-- - accept tenant_id from caller
-- - accept provider_code from caller
-- - accept redirect_uri from caller
-- - contain provider-specific branches
-- - store tokens in PostgreSQL
-- -----------------------------------------------------

create or replace function public.integrations_exchange_oauth_tokens(
    p_code text,
    p_state_token text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_state public.integration_oauth_states;
    v_config record;

    v_tenant_id uuid;
    v_provider_code text;

    v_redirect_uri text;
    v_code_verifier text;
    v_code_challenge_method text;

    v_credentials_ref text;

    v_client_id text;
    v_client_secret text;

    v_form_body text;

    v_http_result jsonb;
    v_status_code int;
    v_response_body text;

    v_token_json jsonb;
begin

    -- =================================================
    -- 1. INPUT VALIDATION
    -- =================================================

    if p_code is null
       or length(trim(p_code)) = 0 then

        raise exception 'code is required';

    end if;

    if p_state_token is null
       or length(trim(p_state_token)) = 0 then

        raise exception 'state_token is required';

    end if;


    -- =================================================
    -- 2. RESOLVE OAUTH TRANSACTION
    --
    -- The state is the authoritative source for:
    -- - tenant
    -- - provider
    -- - redirect 
    -- - PKCE verifier
    -- =================================================

    v_state :=
        public._integrations_resolve_oauth_state_internal(
            trim(p_state_token)
        );

    v_tenant_id :=
    v_state.tenant_id;

    v_provider_code :=
        lower(trim(v_state.provider_code));

    v_redirect_uri :=
        nullif(
            trim(v_state.redirect_uri),
            ''
        );
    
    v_code_verifier :=
        nullif(
            trim(v_state.code_verifier),
            ''
        );
    
    v_code_challenge_method :=
        nullif(
            trim(v_state.code_challenge_method),
            ''
        );


    if v_tenant_id is null then
        raise exception
            'OAuth state does not contain tenant_id';
    end if;

    if v_provider_code is null then
        raise exception
            'OAuth state does not contain provider_code';
    end if;

    if v_redirect_uri is null then
        raise exception
            'OAuth state does not contain redirect_uri';
    end if;


    -- =================================================
    -- 3. RESOLVE OAUTH CONFIGURATION
    -- =================================================

    select
        oc.provider_code,
        oc.token_url,
        oc.grant_type,
        oc.client_auth_method,
        oc.pkce_required,
        oc.pkce_method,
        oc.is_active

    into v_config

    from public.integration_oauth_configs oc

    where oc.provider_code = v_provider_code
      and oc.is_active = true

    limit 1;


    if not found then
        raise exception
            'Active OAuth configuration not found for provider %',
            v_provider_code;
    end if;


    -- =================================================
    -- 4. VALIDATE PKCE STATE AGAINST CONFIG
    -- =================================================

    if v_config.pkce_required then

        if v_code_verifier is null then
            raise exception
                'PKCE code_verifier missing for provider %',
                v_provider_code;
        end if;

        if v_code_challenge_method is null then
            raise exception
                'PKCE challenge method missing for provider %',
                v_provider_code;
        end if;

        if v_code_challenge_method <> v_config.pkce_method then
            raise exception
                'OAuth PKCE method mismatch for provider %',
                v_provider_code;
        end if;

    else

        if v_code_verifier is not null
           or v_code_challenge_method is not null then

            raise exception
                'Unexpected PKCE state for provider %',
                v_provider_code;

        end if;

    end if;


    -- =================================================
    -- 5. RESOLVE CLIENT CREDENTIALS FROM VAULT
    -- =================================================

    v_client_id :=
        platform.get_vault_secret(
            'oauth_client_id_' || v_provider_code
        );

    if v_client_id is null
       or btrim(v_client_id) = '' then

        raise exception
            'OAuth client id not configured for %',
            v_provider_code;

    end if;


    -- Client secret is not required for public clients
    -- using client_auth_method = none.

    if v_config.client_auth_method
       in ('client_secret_basic', 'client_secret_post') then

        v_client_secret :=
            platform.get_vault_secret(
                'oauth_client_secret_' || v_provider_code
            );

        if v_client_secret is null
           or btrim(v_client_secret) = '' then

            raise exception
                'OAuth client secret not configured for %',
                v_provider_code;

        end if;

    end if;


    -- =================================================
    -- 6. BUILD TOKEN REQUEST
    -- =================================================

    v_form_body :=
          'grant_type='
        || public.integrations_oauth_url_encode(
            v_config.grant_type
        )

        || '&code='
        || public.integrations_oauth_url_encode(
            trim(p_code)
        )

        || '&redirect_uri='
        || public.integrations_oauth_url_encode(
            v_redirect_uri
        );


    -- =================================================
    -- 7. CLIENT AUTHENTICATION
    -- =================================================

    case v_config.client_auth_method

        when 'client_secret_post' then

            v_form_body :=
                v_form_body
                || '&client_id='
                || public.integrations_oauth_url_encode(
                    v_client_id
                )
                || '&client_secret='
                || public.integrations_oauth_url_encode(
                    v_client_secret
                );


        when 'none' then

            v_form_body :=
                v_form_body
                || '&client_id='
                || public.integrations_oauth_url_encode(
                    v_client_id
                );


        when 'client_secret_basic' then

            raise exception
                'client_secret_basic is not supported by the current sync_http_request abstraction for provider %',
                v_provider_code;


        else

            raise exception
                'Unsupported OAuth client authentication method: %',
                v_config.client_auth_method;

    end case;


    -- =================================================
    -- 8. PKCE
    -- =================================================

    if v_config.pkce_required then

        v_form_body :=
            v_form_body
            || '&code_verifier='
            || public.integrations_oauth_url_encode(
                v_code_verifier
            );

    end if;


    -- =================================================
    -- 9. TOKEN EXCHANGE
    -- =================================================

    v_http_result :=
        platform.sync_http_request(
            'POST',
            v_config.token_url,
            'application/x-www-form-urlencoded',
            v_form_body
        );


    -- =================================================
    -- 10. VALIDATE HTTP RESPONSE
    -- =================================================

    v_status_code :=
        (v_http_result->>'status_code')::int;

    v_response_body :=
        v_http_result->>'body';


    if v_status_code is null then

        raise exception
            'OAuth token exchange returned no HTTP status for provider %',
            v_provider_code;

    end if;


    if v_status_code < 200
       or v_status_code >= 300 then

        raise exception
            'OAuth token exchange failed for provider % (HTTP %): %',
            v_provider_code,
            v_status_code,
            v_response_body;

    end if;


    -- =================================================
    -- 11. VALIDATE TOKEN RESPONSE JSON
    -- =================================================

    begin

        v_token_json :=
            v_response_body::jsonb;

    exception
        when others then

            raise exception
                'OAuth token exchange returned invalid JSON for provider %',
                v_provider_code;

    end;


    if v_token_json->>'access_token' is null
       or btrim(v_token_json->>'access_token') = '' then

        raise exception
            'OAuth token response did not contain access_token for provider %',
            v_provider_code;

    end if;


    -- =================================================
    -- 12. CREDENTIALS REFERENCE
    -- =================================================

    v_credentials_ref :=
        format(
            'integrations/%s/%s',
            v_tenant_id,
            v_provider_code
        );


    -- =================================================
    -- 13. STORE TOKEN RESPONSE IN VAULT
    --
    -- Store the complete provider token response.
    -- Never expose it to the caller.
    -- =================================================

    perform platform.upsert_vault_secret(
        v_response_body,
        v_credentials_ref,
        format(
            'OAuth credentials for %s tenant %s',
            v_provider_code,
            v_tenant_id
        )
    );


    -- =================================================
    -- 14. RETURN ONLY VAULT REFERENCE
    -- =================================================

    return v_credentials_ref;

end;
$$;



-- =====================================================
-- 006 Integrations: provider access token resolution
-- =====================================================
--
-- Responsibility:
-- - Resolve the tenant's active provider integration
-- - Resolve its Vault credentials reference
-- - Retrieve the provider access token from Vault
--
-- SSOT:
-- tenant_integrations = tenant/provider integration
-- Vault               = OAuth credentials/tokens
--
-- MUST NOT:
-- - accept credentials_ref from caller
-- - accept access_token from caller
-- - store tokens in PostgreSQL
-- - create/update integrations
-- - contain provider-specific branches
-- =====================================================

create or replace function public.get_provider_access_token(
    p_tenant_id uuid,
    p_provider_code text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_credentials_ref text;
    v_token_response jsonb;
    v_access_token text;
begin

    -- =================================================
    -- 1. INPUT VALIDATION
    -- =================================================

    if p_tenant_id is null
       or p_provider_code is null
       or btrim(p_provider_code) = '' then

        raise exception
            'tenant_id and provider_code are required';

    end if;


    -- =================================================
    -- 2. RESOLVE TENANT INTEGRATION
    --
    -- credentials_ref is resolved from the integration
    -- SSOT. The caller cannot supply it.
    -- =================================================

    select ti.credentials_ref
    into v_credentials_ref
    from public.tenant_integrations ti
    where ti.tenant_id = p_tenant_id
      and ti.provider_code = lower(trim(p_provider_code))
      and ti.is_enabled = true
    limit 1;


    if not found then

        raise exception
            'Active integration not found for tenant/provider';

    end if;


    if v_credentials_ref is null
       or btrim(v_credentials_ref) = '' then

        raise exception
            'Integration has no credentials reference';

    end if;


    -- =================================================
    -- 3. RESOLVE CREDENTIALS FROM VAULT
    -- =================================================

    v_token_response :=
        platform.get_vault_secret(
            v_credentials_ref
        )::jsonb;


    if v_token_response is null then

        raise exception
            'OAuth credentials not found in Vault';

    end if;


    -- =================================================
    -- 4. RESOLVE ACCESS TOKEN
    -- =================================================

    v_access_token :=
        nullif(
            btrim(
                v_token_response->>'access_token'
            ),
            ''
        );


    if v_access_token is null then

        raise exception
            'OAuth credentials contain no access_token';

    end if;


    -- =================================================
    -- 5. RETURN ACCESS TOKEN
    -- =================================================

    return v_access_token;

end;
$$;

-- =====================================================
-- 20. RESOLVE OR RECONCILE PROVIDER DEVICE
--
-- Purpose:
-- Resolve a provider device to a SmartHellas device.
--
-- Resolution order:
--
-- 1. Current external_id
-- 2. Stable hardware_id
--
-- 006 owns provider identity.
-- 004 remains device SSOT.
-- =====================================================

create or replace function public.resolve_or_reconcile_provider_device(
    p_tenant_id uuid,
    p_provider_code text,
    p_external_id text,
    p_hardware_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_device_id uuid;
    v_map_id uuid;
begin

    if p_tenant_id is null then
        raise exception 'tenant_id is required';
    end if;

    if p_provider_code is null
       or btrim(p_provider_code) = '' then
        raise exception 'provider_code is required';
    end if;

    if p_external_id is null
       or btrim(p_external_id) = '' then
        raise exception 'external_id is required';
    end if;

    -- =================================================
    -- 1. CURRENT EXTERNAL ID
    -- =================================================

    select dim.device_id
    into v_device_id
    from public.device_integration_map dim
    where dim.tenant_id = p_tenant_id
      and dim.provider_code = p_provider_code
      and dim.external_id = p_external_id
    limit 1;

    if v_device_id is not null then
        return v_device_id;
    end if;

    -- =================================================
    -- 2. STABLE HARDWARE ID
    -- =================================================

    if p_hardware_id is null
       or btrim(p_hardware_id) = '' then

        raise exception
            'Provider device % is unknown and no hardware identity was supplied',
            p_external_id;
    end if;

    select
        dim.id,
        dim.device_id
    into
        v_map_id,
        v_device_id
    from public.device_integration_map dim
    where dim.tenant_id = p_tenant_id
      and dim.provider_code = p_provider_code
      and dim.hardware_id = p_hardware_id
    limit 1
    for update;

    if v_device_id is null then

        raise exception
            'No SmartHellas device mapping found for provider % and hardware identity %',
            p_provider_code,
            p_hardware_id;
    end if;

    -- =================================================
    -- 3. RECONCILE CURRENT EXTERNAL ID
    -- =================================================

    if exists (
        select 1
        from public.device_integration_map dim
        where dim.tenant_id = p_tenant_id
          and dim.provider_code = p_provider_code
          and dim.external_id = p_external_id
          and dim.id <> v_map_id
    ) then
        raise exception
            'External provider identifier % already belongs to another device',
            p_external_id;
    end if;

    update public.device_integration_map
    set external_id = btrim(p_external_id)
    where id = v_map_id;

    perform platform.log_audit(
        'provider.device_identity_reconciled',
        'device_integration_map',
        v_map_id,
        jsonb_build_object(
            'provider_code',
            p_provider_code,

            'device_id',
            v_device_id,

            'hardware_id',
            p_hardware_id,

            'external_id',
            p_external_id
        )
    );
    return v_device_id;
end;
$$;

-- =====================================================
-- 21. INBOUND WEBHOOK PROCESSOR
-- =====================================================

-- =====================================================
-- 006 INTEGRATION ENGINE
-- INBOUND WEBHOOK PROCESSOR
--
-- Responsibility:
-- - Resolve external webhook provider
-- - Resolve provider event type
-- - Resolve provider event ID
-- - Resolve provider device identity
-- - Resolve tenant
-- - Resolve SmartHellas device
-- - Resolve event timestamp
-- - Route resolved telemetry to 007
--
-- 006 MUST NOT:
-- - interpret telemetry metrics
-- - calculate device state
-- - calculate derived metrics
-- - make automation decisions
-- - own device_telemetry_raw
-- - modify platform webhook lifecycle
--
-- 000 owns:
--   platform.external_webhooks
--   webhook processing lifecycle
--   retry handling
--
-- 007 owns:
--   device_telemetry_raw
--   immutable raw telemetry storage
--
-- 008 owns:
--   device_telemetry_processing
--   processed raw data from 007
--
-- =====================================================


create or replace function public.process_integration_webhook(
    p_webhook_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_webhook record;

    v_provider_code text;
    v_event_type text;
    v_tenant_id uuid;

    v_device_external_id text;
    v_device_id uuid;

    v_provider_event_id text;

    v_observed_at_text text;
    v_observed_at timestamptz;

    v_payload jsonb;

    v_telemetry_result jsonb;
begin

    -- =====================================================
    -- 1. LOAD PLATFORM WEBHOOK
    -- =====================================================

    select
        ew.id,
        ew.source,
        ew.external_event_id,
        ew.event_type,
        ew.tenant_id,
        ew.payload,
        ew.received_at
    into v_webhook
    from platform.external_webhooks ew
    where ew.id = p_webhook_id;

    if not found then
        raise exception
            'external webhook % not found',
            p_webhook_id;
    end if;


    v_provider_code :=
        lower(trim(v_webhook.source));

    v_event_type :=
        nullif(trim(v_webhook.event_type), '');

    v_tenant_id :=
        v_webhook.tenant_id;

    v_payload :=
        coalesce(
            v_webhook.payload,
            '{}'::jsonb
        );


    -- =====================================================
    -- 2. PROVIDER VALIDATION
    -- =====================================================

    if not exists (
        select 1
        from public.integration_providers ip
        where ip.code = v_provider_code
          and ip.is_active = true
    ) then

        raise exception
            'Unknown or inactive integration provider: %',
            v_provider_code;

    end if;


    -- =====================================================
    -- 3. EVENT TYPE
    -- =====================================================

    if v_event_type is null then

        raise exception
            'event_type is required for integration webhook %',
            p_webhook_id;

    end if;


    -- =====================================================
    -- 4. PROVIDER EVENT ID
    -- =====================================================

    v_provider_event_id :=
        coalesce(
            nullif(
                public.resolve_integration_webhook_mapping(
                    v_provider_code,
                    v_event_type,
                    'provider_event_id',
                    v_payload
                ),
                ''
            ),
            nullif(
                trim(v_webhook.external_event_id),
                ''
            )
        );


    if v_provider_event_id is null then

        raise exception
            'provider_event_id could not be resolved for webhook %',
            p_webhook_id;

    end if;


    -- =====================================================
    -- 5. DEVICE EXTERNAL ID
    -- =====================================================

    v_device_external_id :=
        nullif(
            trim(
                public.resolve_integration_webhook_mapping(
                    v_provider_code,
                    v_event_type,
                    'device_external_id',
                    v_payload
                )
            ),
            ''
        );


    -- =====================================================
    -- 6. TENANT RESOLUTION
    --
    -- Tenant must be authoritative.
    --
    -- If 000 already resolved the tenant, use it.
    -- Otherwise a unique provider/device mapping must
    -- resolve it.
    --
    -- NEVER use LIMIT 1 for ambiguous tenant resolution.
    -- =====================================================

    if v_tenant_id is null
       and v_device_external_id is not null then

        select min(dim.tenant_id)
        into v_tenant_id
        from public.device_integration_map dim
        where dim.provider_code = v_provider_code
          and dim.external_id = v_device_external_id
        having count(distinct dim.tenant_id) = 1;

        if v_tenant_id is null then
            raise exception
                'Unable to deterministically resolve tenant for provider % and external device %',
                v_provider_code,
                v_device_external_id;
        end if;

    end if;


    -- =====================================================
    -- 7. DEVICE RESOLUTION
    -- =====================================================

    if v_device_external_id is not null then

        select dim.device_id
        into v_device_id
        from public.device_integration_map dim
        where dim.provider_code = v_provider_code
          and dim.external_id = v_device_external_id
          and dim.tenant_id = v_tenant_id;

        if v_device_id is null then
            raise exception
                'No SmartHellas device mapping found for provider %, tenant %, external device %',
                v_provider_code,
                v_tenant_id,
                v_device_external_id;
        end if;

    end if;


    -- =====================================================
    -- 8. DEVICE TELEMETRY ROUTING
    -- =====================================================

    if v_device_id is not null then

        -- -------------------------------------------------
        -- 8A. Resolve observed timestamp
        -- -------------------------------------------------

        v_observed_at_text :=
            nullif(
                trim(
                    public.resolve_integration_webhook_mapping(
                        v_provider_code,
                        v_event_type,
                        'observed_at',
                        v_payload
                    )
                ),
                ''
            );


        -- -------------------------------------------------
        -- 8B. Convert provider timestamp
        -- -------------------------------------------------

        if v_observed_at_text is not null then

            if exists (
                select 1
                from public.integration_webhook_mappings m
                where m.provider_code = v_provider_code
                  and m.event_type = v_event_type
                  and m.mapping_code = 'observed_at'
                  and m.is_active = true
                  and m.value_type = 'epoch_milliseconds'
            ) then

                v_observed_at :=
                    to_timestamp(
                        v_observed_at_text::double precision
                        / 1000.0
                    );

            elsif exists (
                select 1
                from public.integration_webhook_mappings m
                where m.provider_code = v_provider_code
                  and m.event_type = v_event_type
                  and m.mapping_code = 'observed_at'
                  and m.is_active = true
                  and m.value_type = 'epoch_seconds'
            ) then

                v_observed_at :=
                    to_timestamp(
                        v_observed_at_text::double precision
                    );

            else

                v_observed_at :=
                    v_observed_at_text::timestamptz;

            end if;

        end if;


        -- -------------------------------------------------
        -- 8C. Send resolved raw event to 007
        -- -------------------------------------------------

        v_telemetry_result :=
            public.ingest_device_telemetry_raw(
                v_tenant_id,
                v_device_id,
                v_provider_code,
                v_provider_event_id,
                v_observed_at,
                v_webhook.received_at,
                v_payload
            );


        return jsonb_build_object(
            'handled', true,
            'route', 'device_telemetry',
            'webhook_id', p_webhook_id,
            'provider_code', v_provider_code,
            'event_type', v_event_type,
            'tenant_id', v_tenant_id,
            'device_id', v_device_id,
            'provider_event_id', v_provider_event_id,
            'telemetry', coalesce(
                v_telemetry_result,
                '{}'::jsonb
            )
        );

    end if;


    -- =====================================================
    -- 9. NO DEVICE ROUTE
    -- =====================================================

    return jsonb_build_object(
        'handled', false,
        'route', 'unhandled_domain_event',
        'webhook_id', p_webhook_id,
        'provider_code', v_provider_code,
        'event_type', v_event_type,
        'tenant_id', v_tenant_id
    );

end;
$$;


comment on function public.process_integration_webhook(uuid)
is
'Integration Engine webhook processor. 
 Resolves provider, event, tenant and device identity and routes 
 resolved device telemetry to the Device Telemetry Raw module (007). 
 Does not own raw telemetry storage or platform webhook lifecycle.';


-- =====================================================
-- 22. FUNCTION security HARDENING
-- =====================================================

alter function public.process_integration_webhook(uuid)
set search_path = '';

-- alter function public.integrations_resolve_oauth_state(text) set search_path = '';

-- =====================================================
-- 24. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('006_integration_engine', 'REV1', false)
on conflict (version) do nothing;