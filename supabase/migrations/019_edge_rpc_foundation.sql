-- =====================================================
-- REV1 GREENFIELD BASELINE 
-- 019_EDGE_RPC_FOUNDATION.SQL
-- =====================================================
--
-- Consolidated / hardened API foundation
--
-- SECURITY MODEL
-- =====================================================
-- Portal / authenticated clients
--        ↓
-- Approved {module}_api RPC
--        ↓
-- edge_require_* authorization
--        ↓
-- Domain / service layer
--        ↓
-- Business tables
--
-- BACKEND-ONLY MODEL
-- =====================================================
-- Backend / worker / service-role execution
--        ↓
-- Backend-only function
--        ↓
-- Domain / service layer
--        ↓
-- Technical / business tables
--
-- IMPORTANT
-- =====================================================
-- Public schema placement does NOT make a function a portal API.
--
-- A function is portal-accessible only when:
--   1. it is explicitly classified as an approved *_api contract;
--   2. its operation is authorized by edge_require_*;
--   3. 022 explicitly grants authenticated execution.
--
-- Backend-only functions:
--   - are not portal APIs;
--   - are not authenticated grants;
--   - are intended for service_role / workers;
--   - may use edge_require_backend() for defense-in-depth;
--   - receive their final execution privileges exclusively in 022.
--
-- 020 RESPONSIBILITY
-- =====================================================
-- 1. Legacy public privilege hardening
-- 2. Tenant authority
-- 3. Role authority
-- 4. Platform admin authority
-- 5. Internal event helper
-- 6. Approved named RPC contracts
-- 7. Domain API contracts
-- 8. Migration registration
--
-- 020 RESPONSIBILITY
-- =====================================================
-- RLS policies only.
--
-- 022 RESPONSIBILITY
-- =====================================================
-- GRANT / REVOKE only.
-- Authenticated portal access is an explicit allowlist.
-- Security helpers and domain functions are not portal grants.
-- Backend-only functions are service_role / worker grants only.
--
-- IMPORTANT
-- =====================================================
-- This migration intentionally contains NO GRANT / REVOKE
-- statements for the final security model.
-- Final execution privileges are owned by 022.
--
-- All portal business access must go through an approved
-- {module}_api RPC.
--
-- Domain functions, security helpers, internal helpers,
-- event helpers and technical functions are NOT portal APIs.
-- =====================================================


-- =====================================================
-- 1. LEGACY PUBLIC PRIVILEGE HARDENING
-- =====================================================
--
-- FINAL EXECUTION PRIVILEGES ARE OWNED BY 020.
--
-- Therefore this migration intentionally performs NO
-- GRANT / REVOKE operations.
--
-- 020 MUST:
--
--   1. revoke PUBLIC execution from security-sensitive
--      functions;
--
--   2. revoke authenticated execution from all
--      backend-only/internal functions;
--
--   3. grant authenticated execution ONLY to the approved
--      *_api allowlist;
--
--   4. grant service_role / designated worker execution
--      ONLY to registered backend-only functions;
--
--   5. keep security helpers outside the portal grant set.
--
-- Historical functions that MUST be handled by 020 include:
--
--   auth_api
--   automation_api
--   booking_api
--   commerce_api
--   crm_api
--   devices_api
--   integrations_api
--   logistics_api
--   locks_api
--   monetization_api
--   notification_api
--   onboarding_api
--   operations_api
--   optimization_api
--   payment_api
--   portal_api
--   preconfig_api
--
-- Legacy standalone wrappers:
--
--   assign_device
--   assign_device_to_room
--   calculate_optimization_score
--   change_subscription_plan
--   create_booking
--   create_property
--   create_subscription
--   dispatch_fulfilment_order
--   generate_lock_code
--   generate_monetization_proposal
--   get_onboarding_lifecycle
--   integrations_oauth_complete
--   list_onboarding_lifecycle_transitions
--   onboarding_lifecycle_transition
--   onboarding_step_update
--
-- Internal/security helpers:
--
--   insert_event
--   log_event
--   platform.is_platform_admin
--   edge_require_tenant
--   edge_require_manager
--   edge_require_admin
--   edge_require_backend
--   edge_require_platform_admin
--   edge_is_platform_admin
--   is_platform_admin
--
-- None of the above are automatically portal-accessible.
--
-- =====================================================


-- =====================================================
-- 2. TENANT AUTHORITY
-- =====================================================
--
-- Single tenant authority for authenticated Edge/API calls.
--
-- Rule:
--
--     resolve_active_tenant(auth.uid()) IS NOT NULL
--
-- No API may invent or independently resolve the active
-- tenant identity.
--
-- =====================================================

create or replace function public.edge_require_tenant()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
begin
    v_tid := public.resolve_active_tenant((select auth.uid()));

    if v_tid is null then
        raise exception 'NO_ACTIVE_TENANT';
    end if;
end;
$$;


-- =====================================================
-- 3. ROLE AUTHORITY
-- =====================================================
--
-- Central Edge authorization guards.
--
-- Tenant authority is always established before role
-- authority for tenant-scoped operations.
--
-- Platform administrators are allowed through the normal
-- admin/manager gates as an explicit platform authority.
--
-- =====================================================

create or replace function public.edge_require_admin()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_tenant();

    if not (
        platform.is_platform_admin()
        or platform.is_admin()
    ) then
        raise exception 'admin or owner role required';
    end if;
end;
$$;


create or replace function public.edge_require_manager()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_tenant();

    if not (
        platform.is_platform_admin()
        or platform.is_admin()
        or platform.has_role('manager')
    ) then
        raise exception 'manager, admin, or owner role required';
    end if;
end;
$$;


-- =====================================================
-- 4. PLATFORM ADMIN AUTHORITY
-- =====================================================
--
-- Platform Admin is a platform-level authority and is NOT
-- a tenant role.
--
-- platform.platform_admins is the SSOT.
--
-- All platform-admin-only API operations must use:
--
--     public.edge_require_platform_admin()
--
-- No individual API should duplicate the underlying
-- platform-admin lookup.
--
-- IMPORTANT:
-- edge_require_platform_admin() intentionally does NOT
-- require an active tenant.
--
-- =====================================================

create or replace function platform.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from platform.platform_admins pa
        where pa.user_id = (select auth.uid())
    );
$$;


create or replace function public.edge_is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select platform.is_platform_admin();
$$;


create or replace function public.edge_require_platform_admin()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    if not public.edge_is_platform_admin() then
        raise exception 'PLATFORM_ADMIN_REQUIRED';
    end if;
end;
$$;


-- Optional compatibility/helper surface.
--
-- NOT a portal API.
-- 022 must keep execution restricted.

create or replace function public.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select public.edge_is_platform_admin();
$$;


-- =====================================================
-- 4.1 BACKEND-ONLY AUTHORITY
-- =====================================================
--
-- Backend-only is an execution class, NOT a portal API class.
--
-- This guard provides defense-in-depth for functions that
-- must only be executed by Supabase service_role / trusted
-- backend workers.
--
-- Primary protection remains 022:
--
--     authenticated  -> NO GRANT
--     anon           -> NO GRANT
--     public         -> NO GRANT
--     service_role   -> explicit GRANT where required
--
-- The guard additionally ensures that accidental execution
-- through an authenticated session cannot succeed.
--
-- =====================================================

create or replace function public.edge_require_backend()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    if coalesce((select auth.role()), '') <> 'service_role' then
        raise exception 'BACKEND_EXECUTION_REQUIRED';
    end if;
end;
$$;


-- =====================================================
-- BACKEND-ONLY SECURITY RULES
-- =====================================================
--
-- The following classes are explicitly backend-only:
--
--   INTERNAL_DOMAIN
--   BACKEND_WORKER
--   SECURITY_INTERNAL
--   TECHNICAL_INTERNAL
--
-- Typical examples:
--
--   - webhook processors
--   - telemetry ingestion
--   - telemetry processing
--   - provider synchronization
--   - OAuth token/state processing
--   - reconciliation
--   - automation executors
--   - fulfillment executors
--   - payment-provider handlers
--   - integration routing
--   - worker-maintained projections
--   - raw technical state
--   - internal event processing
--   - security helpers
--
-- These functions:
--
--   Portal:
--       NO
--
--   authenticated:
--       NO
--
--   anon:
--       NO
--
--   service_role:
--       YES, where required
--
--   workers:
--       YES, where required
--
--   RLS:
--       019
--
--   GRANT / REVOKE:
--       022
--
-- The existence of a function in public schema does NOT
-- create a portal contract.
--
-- =====================================================


-- =====================================================
-- 5. INTERNAL EVENT HELPER
-- =====================================================
--
-- Event logging is an internal security/business-event
-- mechanism.
--
-- It is NOT a generic portal data-write API.
--
-- API/domain functions may call this helper internally.
-- The helper itself must not be exposed as a portal RPC.
--
-- IMPORTANT:
-- This helper is intentionally tenant-aware because it can
-- be called from SECURITY DEFINER API execution while retaining
-- the authenticated user's tenant authority.
--
-- =====================================================

create or replace function public.insert_event(
    p_event_type text,
    p_payload jsonb default '{}'::jsonb,
    p_severity text default 'info',
    p_device_id uuid default null,
    p_correlation_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_event_id uuid;
    v_tid uuid;
begin
    perform public.edge_require_tenant();

    v_tid := platform.current_tenant_id();

    if v_tid is null then
        raise exception 'NO_ACTIVE_TENANT';
    end if;

    insert into platform.event_log (
        tenant_id,
        user_id,
        event_type,
        source,
        payload,
        severity,
        device_id,
        correlation_id
    )
    values (
        v_tid,
        (select auth.uid()),
        p_event_type,
        'edge_or_rpc',
        coalesce(p_payload, '{}'::jsonb),
        coalesce(p_severity, 'info'),
        p_device_id,
        coalesce(p_correlation_id, gen_random_uuid())
    )
    returning id
    into v_event_id;

    return v_event_id;
end;
$$;


create or replace function public.log_event(
    p_event_type text,
    p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_tenant();

    return public.insert_event(
        p_event_type,
        p_payload
    );
end;
$$;


-- =====================================================
-- 6. APPROVED NAMED RPC CONTRACTS
-- =====================================================
--
-- These are compatibility/convenience operations that have
-- a legitimate internal execution use case.
--
-- IMPORTANT:
-- They are NOT separate portal access channels when an
-- equivalent module *_api exists.
--
-- Where a module *_api already exists, the *_api operation
-- is the canonical portal contract.
--
-- These named functions therefore remain INTERNAL / BACKEND
-- contracts unless explicitly registered as an approved
-- authenticated API exception in 022.
--
-- DEFAULT SECURITY CLASS:
--
--     INTERNAL_DOMAIN
--
-- =====================================================


-- =====================================================
-- 6.1 DEVICE ASSIGNMENT
-- =====================================================

create or replace function public.assign_device(
    p_device_id uuid,
    p_room_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_manager();

    return public.devices_assign_device_to_room(
        p_device_id,
        p_room_id
    );
end;
$$;


create or replace function public.assign_device_to_room(
    p_device_id uuid,
    p_room_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_manager();

    return public.devices_assign_device_to_room(
        p_device_id,
        p_room_id
    );
end;
$$;


-- =====================================================
-- 6.2 OPTIMIZATION SCORE
-- =====================================================

create or replace function public.calculate_optimization_score(
    p_property_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_tenant();

    return public.optimization_domain(
        'calculate_property_score',
        jsonb_build_object(
            'property_id',
            p_property_id
        )
    );
end;
$$;


-- =====================================================
-- 6.3 SUBSCRIPTION PLAN
-- =====================================================

create or replace function public.change_subscription_plan(
    p_plan_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_admin();

    return public.commerce_change_subscription_plan(
        p_plan_id
    );
end;
$$;


-- =====================================================
-- 6.4 BOOKING
-- =====================================================

create or replace function public.create_booking(
    p_property_id uuid,
    p_start_date date,
    p_end_date date,
    p_guest_name text default null,
    p_guest_email text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_manager();

    return public.booking_domain(
        'create_booking',
        jsonb_build_object(
            'property_id', p_property_id,
            'start_date', p_start_date,
            'end_date', p_end_date,
            'guest_name', p_guest_name,
            'guest_email', p_guest_email
        )
    );
end;
$$;


-- =====================================================
-- 6.5 PROPERTY
-- =====================================================

create or replace function public.create_property(
    p_name text,
    p_property_type public.property_type,
    p_address text default null,
    p_timezone text default 'UTC'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_manager();

    return public.devices_domain(
        'create_property',
        jsonb_build_object(
            'name', p_name,
            'property_type', p_property_type,
            'address', p_address,
            'timezone', p_timezone
        )
    );
end;
$$;


-- =====================================================
-- 6.6 SUBSCRIPTION CREATION
-- =====================================================

create or replace function public.create_subscription(
    p_plan_id uuid,
    p_tier public.subscription_tier default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_row jsonb;
begin
    perform public.edge_require_admin();

    v_row := public.commerce_create_subscription(
        p_plan_id,
        p_tier
    );

    perform public.insert_event(
        'subscription.created',
        jsonb_build_object(
            'subscription_id',
            v_row->>'id',
            'plan_id',
            p_plan_id
        )
    );

    return v_row;
end;
$$;


-- =====================================================
-- 6.7 FULFILMENT DISPATCH
-- =====================================================

create or replace function public.dispatch_fulfilment_order(
    p_fulfilment_order_id uuid,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_manager();

    return public.logistics_dispatch_fulfilment_order(
        p_fulfilment_order_id,
        p_payload
    );
end;
$$;


-- =====================================================
-- 6.8 LOCK CREDENTIAL
-- =====================================================

create or replace function public.generate_lock_code(
    p_lock_device_id uuid,
    p_booking_id uuid default null,
    p_valid_from timestamptz default null,
    p_valid_until timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_manager();

    return public.locks_domain(
        'issue_credential',
        jsonb_build_object(
            'lock_device_id', p_lock_device_id,
            'booking_id', p_booking_id,
            'valid_from', p_valid_from,
            'valid_until', p_valid_until
        )
    );
end;
$$;


-- =====================================================
-- 6.9 MONETIZATION PROPOSAL
-- =====================================================

create or replace function public.generate_monetization_proposal(
    p_property_id uuid default null,
    p_source_campaign_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_proposal jsonb;
begin
    perform public.edge_require_manager();

    v_proposal := public.monetization_domain(
        'create_proposal',
        jsonb_build_object(
            'property_id',
            p_property_id,
            'source_campaign_id',
            p_source_campaign_id
        )
    );

    perform public.insert_event(
        'monetization.proposal.generated',
        jsonb_build_object(
            'proposal_id',
            v_proposal->>'id',
            'property_id',
            p_property_id
        )
    );

    return v_proposal;
end;
$$;


-- =====================================================
-- 6.10 ONBOARDING
-- =====================================================

create or replace function public.get_onboarding_lifecycle(
    p_property_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_tenant();

    return public.onboarding_lifecycle_get(
        p_property_id
    );
end;
$$;


create or replace function public.list_onboarding_lifecycle_transitions(
    p_property_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_tenant();

    return public.onboarding_lifecycle_list_transitions(
        p_property_id
    );
end;
$$;


create or replace function public.onboarding_lifecycle_transition(
    p_property_id uuid,
    p_to_state public.onboarding_lifecycle_state,
    p_metadata jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_manager();

    return public.onboarding_lifecycle_apply_transition(
        p_property_id,
        p_to_state,
        p_metadata
    );
end;
$$;


create or replace function public.onboarding_step_update(
    p_session_id uuid,
    p_step_type public.onboarding_step_type,
    p_status public.onboarding_step_status
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_manager();

    return public.onboarding_domain(
        'update_step_state',
        jsonb_build_object(
            'session_id', p_session_id,
            'step_type', p_step_type,
            'status', p_status
        )
    );
end;
$$;


-- =====================================================
-- 6.11 OAUTH COMPLETION
-- =====================================================
--
-- Internal bridge only.
--
-- Canonical portal route:
--
--     integrations_api('oauth_complete', ...)
--
-- This function must NOT become an authenticated portal
-- entry point.
--
-- =====================================================

create or replace function public.integrations_oauth_complete(
    p_tenant_id uuid,
    p_provider_code text,
    p_credentials_ref text,
    p_state_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.edge_require_tenant();

    return public.integrations_complete_oauth(
        p_tenant_id,
        p_provider_code,
        p_credentials_ref,
        p_state_token
    );
end;
$$;


-- =====================================================
-- 6.12 BACKEND-ONLY EXECUTION RULE
-- =====================================================
--
-- The named RPCs in section 6 are NOT automatically granted
-- to authenticated.
--
-- They are internal compatibility/domain entry points.
--
-- If a function is purely worker/backend execution, its
-- implementation should additionally call:
--
--     perform public.edge_require_backend();
--
-- before performing the backend-only operation.
--
-- This is defense-in-depth.
--
-- The primary execution boundary remains 022.
--
-- =====================================================


-- =====================================================
-- 7. DOMAIN API CONTRACTS
-- =====================================================
--
-- These are the canonical portal-facing business APIs.
--
-- No direct business-table access is assumed.
--
-- Every operation explicitly declares its authorization
-- level before calling the domain/service layer.
--
-- ONLY THESE API FUNCTIONS are candidates for authenticated
-- portal execution in 022.
--
-- =====================================================


-- =====================================================
-- 7.1 AUTH API
-- =====================================================

create or replace function public.auth_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when 'switch_tenant' then
            return public.auth_switch_tenant(p_payload);

        when 'invite_member' then
            perform public.edge_require_admin();
            return public.auth_invite_member(p_payload);

        when
            'get_auth_context',
            'list_user_tenants',
            'create_tenant',
            'validate_tenant_switch'
        then
            null;

        when 'resolve_user_by_email' then
            perform public.edge_require_admin();

        when
            'get_current_tenant',
            'list_memberships',
            'revoke_membership',
            'get_subscription',
            'list_service_accounts'
        then
            perform public.edge_require_tenant();

        when 'update_membership' then
            perform public.edge_require_tenant();

        when
            'update_tenant',
            'create_service_account',
            'update_service_account',
            'delete_service_account'
        then
            perform public.edge_require_admin();

        -- Billing state (status, period) is platform-controlled.
        -- A tenant admin must not be able to reactivate an expired or
        -- suspended subscription or extend its period without payment.
        when 'update_subscription' then
            perform public.edge_require_platform_admin();

        else
            raise exception
                'unknown auth_api operation: %',
                p_op;
    end case;

    return public.auth_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.2 AUTOMATION API
-- =====================================================

create or replace function public.automation_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when
            'list_runs',
            'get_run',
            'list_run_steps',
            'list_subscriptions'
        then
            perform public.edge_require_tenant();

        when
            'dispatch_event',
            'start_run',
            'cancel_run',
            'upsert_subscription',
            'delete_subscription'
        then
            perform public.edge_require_manager();

        else
            raise exception
                'unknown automation_api operation: %',
                p_op;
    end case;

    return public.automation_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.3 BOOKING API
-- =====================================================

create or replace function public.booking_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when 'calculate_access_window' then
            perform public.edge_require_tenant();

            return public.booking_calculate_access_window(
                (p_payload->>'booking_id')::uuid
            );

        when
            'generate_booking_access',
            'regenerate_booking_access'
        then
            perform public.edge_require_manager();

            if p_op = 'generate_booking_access' then
                return public.booking_generate_booking_access(
                    (p_payload->>'booking_id')::uuid
                );
            end if;

            return public.booking_regenerate_booking_access(
                (p_payload->>'booking_id')::uuid
            );

        when 'create_booking_access' then
            perform public.edge_require_manager();

            return public.booking_create_booking_access(
                p_payload
            );

        when
            'list_bookings',
            'get_booking',
            'get_access_schedule',
            'get_booking_access',
            'list_access_policies',
            'list_access_rules'
        then
            perform public.edge_require_tenant();

            return public.booking_domain(
                p_op,
                p_payload
            );

        when
            'create_booking',
            'update_booking',
            'delete_booking',
            'upsert_access_schedule',
            'delete_booking_access',
            'create_access_policy',
            'update_access_policy',
            'delete_access_policy',
            'create_access_rule',
            'update_access_rule',
            'delete_access_rule'
        then
            perform public.edge_require_manager();

            return public.booking_domain(
                p_op,
                p_payload
            );

        else
            raise exception
                'unknown booking_api operation: %',
                p_op;
    end case;
end;
$$;


-- =====================================================
-- 7.4 COMMERCE API
-- =====================================================

create or replace function public.commerce_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when
            'list_product_plans',
            'get_product_plan',
            'list_plan_pricing',
            'list_feature_entitlements',
            'list_upsell_rules',
            'get_tenant_entitlements'
        then
            perform public.edge_require_tenant();

        when
            'create_product_plan',
            'update_product_plan',
            'delete_product_plan',
            'create_plan_pricing',
            'update_plan_pricing',
            'delete_plan_pricing',
            'create_feature_entitlement',
            'update_feature_entitlement',
            'delete_feature_entitlement'
        then
            perform public.edge_require_platform_admin();

        when
            'create_upsell_rule',
            'update_upsell_rule',
            'delete_upsell_rule',
            'change_plan'
        then
            perform public.edge_require_manager();

        when
            'list_discount_codes',
            'create_discount_code',
            'update_discount_code',
            'deactivate_discount_code'
        then
            perform public.edge_require_platform_admin();

        when
            'validate_discount_code',
            'apply_discount_to_invoice',
            'list_discount_redemptions',
            'list_invoices',
            'get_invoice',
            'get_billing_customer',
            'update_billing_customer'
        then
            perform public.edge_require_manager();

        -- Epsilon e-invoicing administration (012 section 16).
        -- Tables are backend-only; platform admins manage them by RPC only.
        when
            'list_billing_item_mappings',
            'upsert_billing_item_mapping',
            'deactivate_billing_item_mapping',
            'list_epsilon_issues',
            'requeue_epsilon_invoice'
        then
            perform public.edge_require_platform_admin();

        else
            raise exception
                'unknown commerce_api operation: %',
                p_op;
    end case;

    return public.commerce_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.5 CRM API
-- =====================================================

create or replace function public.crm_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when
            'list_pipelines',
            'get_pipeline',
            'list_pipeline_stages',
            'list_campaigns',
            'get_campaign',
            'list_tags',
            'list_companies',
            'get_company',
            'list_contacts',
            'get_contact',
            'list_leads',
            'get_lead',
            'list_contact_companies',
            'list_company_tenants',
            'list_contact_tenants',
            'list_opportunities',
            'get_opportunity',
            'list_tasks',
            'get_task',
            'list_interactions',
            'list_notes',
            'list_tag_assignments',
            'list_lists',
            'get_list',
            'list_list_members',
            'list_custom_fields',
            'list_custom_field_values'
        then
            perform public.edge_require_tenant();

        when
            'create_pipeline',
            'update_pipeline',
            'create_pipeline_stage',
            'update_pipeline_stage',
            'create_campaign',
            'update_campaign',
            'create_tag',
            'update_tag',
            'create_company',
            'update_company',
            'create_contact',
            'update_contact',
            'create_lead',
            'update_lead',
            'create_contact_company',
            'update_contact_company',
            'create_company_tenant',
            'update_company_tenant',
            'create_contact_tenant',
            'update_contact_tenant',
            'create_opportunity',
            'update_opportunity',
            'create_task',
            'update_task',
            'create_interaction',
            'create_note',
            'update_note',
            'create_tag_assignment',
            'create_list',
            'update_list',
            'create_list_member',
            'create_custom_field',
            'update_custom_field',
            'upsert_custom_field_value',
            'update_custom_field_value',
            'delete_custom_field_value',
            'delete_pipeline',
            'delete_pipeline_stage',
            'delete_campaign',
            'delete_tag',
            'delete_company',
            'delete_contact',
            'delete_lead',
            'delete_contact_company',
            'delete_company_tenant',
            'delete_contact_tenant',
            'delete_opportunity',
            'delete_task',
            'soft_delete_interaction',
            'delete_note',
            'delete_tag_assignment',
            'delete_list',
            'delete_list_member',
            'delete_custom_field'
        then
            perform public.edge_require_manager();

        else
            raise exception
                'unknown crm_api operation: %',
                p_op;
    end case;

    return public.crm_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.6 DEVICES API
-- =====================================================

create or replace function public.devices_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when
            'list_properties',
            'get_property',
            'list_rooms',
            'get_room',
            'list_device_categories',
            'list_devices',
            'get_device',
            'get_device_config',
            'list_device_metrics',
            'get_device_current_state',
            'list_tenant_device_current_state'
        then
            perform public.edge_require_tenant();

        when
            'create_property',
            'update_property',
            'delete_property',
            'create_room',
            'update_room',
            'delete_room',
            'create_device',
            'update_device',
            'delete_device',
            'assign_device',
            'unassign_device',
            'upsert_device_config'
        then
            perform public.edge_require_manager();

        else
            raise exception
                'unknown devices_api operation: %',
                p_op;
    end case;

    return public.devices_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.7 INTEGRATIONS API
-- =====================================================

create or replace function public.integrations_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when 'oauth_complete' then
            return public.integrations_oauth_complete_api(
                p_payload
            );

        when 'complete_oauth' then
            raise exception
                'complete_oauth is not available; use oauth_complete';

        when
            'list_providers',
            'get_provider',
            'list_capabilities',
            'list_webhook_definitions',
            'list_device_maps'
        then
            perform public.edge_require_tenant();

        when
            'list_tenant_integrations',
            'get_tenant_integration'
        then
            perform public.edge_require_manager();

        when
            'connect_integration',
            'update_integration',
            'disconnect_integration',
            'create_webhook_definition',
            'update_webhook_definition',
            'delete_webhook_definition',
            'create_device_map',
            'update_device_map',
            'delete_device_map',
            'register_oauth_state',
            'start_oauth',
            'request_sync'
        then
            perform public.edge_require_manager();

        when 'resolve_oauth_state' then
            perform public.edge_require_tenant();

            if not exists (
                select 1
                from public.integration_oauth_states s
                where s.state_token = p_payload->>'state_token'
                  and s.consumed_at is null
                  and s.expires_at > now()
                  and s.user_id = (select auth.uid())
                  and s.tenant_id = platform.current_tenant_id()
            ) then
                raise exception 'unauthorized';
            end if;

        else
            raise exception
                'unknown integrations_api operation: %',
                p_op;
    end case;

    return public.integrations_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.8 LOGISTICS API
-- =====================================================

create or replace function public.logistics_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when
            'list_logistics_templates',
            'get_logistics_template',
            'list_package_definitions',
            'list_carriers',
            'get_carrier',
            'list_warehouses',
            'get_warehouse',
            'list_label_templates',
            'list_shipping_rules',
            'list_fulfilment_orders',
            'get_fulfilment_order'
        then
            perform public.edge_require_tenant();

        when
            'create_logistics_template',
            'update_logistics_template',
            'delete_logistics_template',
            'create_package_definition',
            'update_package_definition',
            'delete_package_definition',
            'create_warehouse',
            'update_warehouse',
            'delete_warehouse',
            'create_shipping_rule',
            'update_shipping_rule',
            'delete_shipping_rule',
            'create_fulfilment_order',
            'update_fulfilment_order',
            'delete_fulfilment_order',
            'dispatch_fulfilment_order'
        then
            perform public.edge_require_manager();

        when
            'create_carrier',
            'update_carrier',
            'delete_carrier',
            'create_label_template',
            'update_label_template',
            'delete_label_template'
        then
            perform public.edge_require_platform_admin();

        else
            raise exception
                'unknown logistics_api operation: %',
                p_op;
    end case;

    return public.logistics_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.9 LOCKS API
-- =====================================================

create or replace function public.locks_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when
            'list_lock_devices',
            'get_lock_device'
        then
            perform public.edge_require_tenant();

        when
            'list_credentials',
            'get_credential',
            'create_lock_device',
            'update_lock_device',
            'delete_lock_device',
            'issue_credential',
            'revoke_credential'
        then
            perform public.edge_require_manager();

        else
            raise exception
                'unknown locks_api operation: %',
                p_op;
    end case;

    return public.locks_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.10 MONETIZATION API
-- =====================================================

create or replace function public.monetization_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when
            'list_proposals',
            'get_proposal',
            'list_proposal_items',
            'list_packages',
            'get_package',
            'list_upsell_campaigns',
            'get_upsell_campaign',
            'list_activation_state',
            'list_conversion_events',
            'list_conversion_scores'
        then
            perform public.edge_require_tenant();

        when
            'create_proposal',
            'update_proposal',
            'delete_proposal',
            'create_proposal_item',
            'update_proposal_item',
            'delete_proposal_item'
        then
            perform public.edge_require_manager();

        when
            'create_package',
            'update_package',
            'delete_package'
        then
            perform public.edge_require_platform_admin();

        when
            'create_upsell_campaign',
            'update_upsell_campaign',
            'delete_upsell_campaign'
        then
            perform public.edge_require_manager();

        else
            raise exception
                'unknown monetization_api operation: %',
                p_op;
    end case;

    return public.monetization_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.11 NOTIFICATION API
-- =====================================================

create or replace function public.notification_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when
            'list_templates',
            'get_template',
            'list_preferences',
            'list_queue',
            'get_notification',
            'list_history'
        then
            perform public.edge_require_tenant();

        when
            'create_template',
            'update_template',
            'delete_template',
            'upsert_preference',
            'enqueue_notification',
            'cancel_notification'
        then
            perform public.edge_require_manager();

        else
            raise exception
                'unknown notification_api operation: %',
                p_op;
    end case;

    return public.notification_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.12 ONBOARDING API
-- =====================================================

create or replace function public.onboarding_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when 'get_lifecycle' then
            perform public.edge_require_tenant();

            return public.onboarding_lifecycle_get(
                (p_payload->>'property_id')::uuid
            );

        when 'list_lifecycle_transitions' then
            perform public.edge_require_tenant();

            return public.onboarding_lifecycle_list_transitions(
                (p_payload->>'property_id')::uuid
            );

        when 'lifecycle_transition' then
            perform public.edge_require_manager();

            return public.onboarding_lifecycle_apply_transition(
                (p_payload->>'property_id')::uuid,
                (p_payload->>'to_state')::public.onboarding_lifecycle_state,
                coalesce(
                    p_payload->'metadata',
                    '{}'::jsonb
                )
            );

        when
            'list_sessions',
            'get_session',
            'list_step_states',
            'list_room_mappings',
            'list_device_mappings',
            'list_checklist_items',
            'list_notes'
        then
            perform public.edge_require_tenant();

            return public.onboarding_domain(
                p_op,
                p_payload
            );

        when
            'create_session',
            'update_session',
            'delete_session',
            'update_step_state',
            'create_room_mapping',
            'update_room_mapping',
            'delete_room_mapping',
            'create_device_mapping',
            'update_device_mapping',
            'delete_device_mapping',
            'upsert_checklist_item',
            'update_checklist_item',
            'delete_checklist_item',
            'create_note',
            'delete_note'
        then
            perform public.edge_require_manager();

            return public.onboarding_domain(
                p_op,
                p_payload
            );

        else
            raise exception
                'unknown onboarding_api operation: %',
                p_op;
    end case;
end;
$$;


-- =====================================================
-- 7.13 OPERATIONS API
-- =====================================================

create or replace function public.operations_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when
            'list_templates',
            'get_template',
            'list_workflows',
            'get_workflow',
            'list_workflow_steps',
            'list_workflow_triggers',
            'list_support_tickets',
            'get_support_ticket',
            'create_support_ticket',
            'list_support_messages',
            'create_support_message'
        then
            perform public.edge_require_tenant();

        when
            'update_support_ticket',
            'delete_support_ticket',
            'create_template',
            'update_template',
            'delete_template',
            'create_workflow',
            'update_workflow',
            'delete_workflow',
            'create_workflow_step',
            'update_workflow_step',
            'delete_workflow_step',
            'create_workflow_trigger',
            'update_workflow_trigger',
            'delete_workflow_trigger'
        then
            perform public.edge_require_manager();

        else
            raise exception
                'unknown operations_api operation: %',
                p_op;
    end case;

    return public.operations_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.14 OPTIMIZATION API
-- =====================================================

create or replace function public.optimization_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when
            'list_rules',
            'get_rule',
            'list_insight_events',
            'get_insight_event',
            'list_recommendations',
            'get_recommendation',
            'list_device_usage_scores',
            'list_energy_profiles',
            'get_energy_profile',
            'calculate_property_score'
        then
            perform public.edge_require_tenant();

        when
            'create_rule',
            'update_rule',
            'delete_rule',
            'update_recommendation',
            'delete_recommendation'
        then
            perform public.edge_require_manager();

        else
            raise exception
                'unknown optimization_api operation: %',
                p_op;
    end case;

    return public.optimization_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.15 PAYMENT API
-- =====================================================

create or replace function public.payment_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when
            'get_payment',
            'list_payments',
            'payment_history'
        then
            perform public.edge_require_tenant();

        when 'create_checkout_session' then
            perform public.edge_require_tenant();

        when 'cancel_payment' then
            perform public.edge_require_manager();

        else
            raise exception
                'unknown payment_api operation: %',
                p_op;
    end case;

    return public.payment_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.16 PORTAL API
-- =====================================================
--
-- portal_api is intentionally limited to portal metadata,
-- bootstrap, preferences and UI-facing configuration.
--
-- It is NOT a generic business-table gateway.
--
-- =====================================================

create or replace function public.portal_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when
            'get_portal_bootstrap',
            'get_portal_settings',
            'list_dashboards',
            'get_dashboard',
            'list_user_preferences',
            'get_user_preference',
            'upsert_user_preference',
            'update_user_preference',
            'delete_user_preference',
            'list_feature_flags'
        then
            perform public.edge_require_tenant();

        when
            'upsert_portal_settings',
            'create_dashboard',
            'update_dashboard',
            'delete_dashboard'
        then
            perform public.edge_require_manager();

        when
            'create_feature_flag',
            'update_feature_flag',
            'delete_feature_flag'
        then
            perform public.edge_require_platform_admin();

        else
            raise exception
                'unknown portal_api operation: %',
                p_op;
    end case;

    return public.portal_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.17 PRECONFIG API
-- =====================================================

create or replace function public.preconfig_api(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op

        when
            'list_device_bundles',
            'get_device_bundle',
            'list_bundle_devices',
            'list_onboarding_blueprints',
            'get_onboarding_blueprint',
            'list_blueprint_steps',
            'list_preconfig_templates',
            'get_preconfig_template',
            'list_preconfig_device_map'
        then
            perform public.edge_require_tenant();

        when
            'create_device_bundle',
            'update_device_bundle',
            'delete_device_bundle',
            'create_bundle_device',
            'update_bundle_device',
            'delete_bundle_device',
            'create_onboarding_blueprint',
            'update_onboarding_blueprint',
            'delete_onboarding_blueprint',
            'create_blueprint_step',
            'update_blueprint_step',
            'delete_blueprint_step',
            'create_preconfig_template',
            'update_preconfig_template',
            'delete_preconfig_template',
            'create_preconfig_device_map',
            'update_preconfig_device_map',
            'delete_preconfig_device_map'
        then
            perform public.edge_require_platform_admin();

        else
            raise exception
                'unknown preconfig_api operation: %',
                p_op;
    end case;

    return public.preconfig_domain(
        p_op,
        p_payload
    );
end;
$$;


-- =====================================================
-- 7.18 API / BACKEND BOUNDARY
-- =====================================================
--
-- The final architecture is:
--
--                    PORTAL / APPSMITH
--                           |
--                           v
--                  approved *_api
--                           |
--                           v
--                  edge_require_*
--                           |
--                           v
--                   domain/service
--                           |
--                           v
--                     business SSOT
--
--
-- Backend:
--
--                    SERVICE ROLE / WORKER
--                           |
--                           v
--                  backend-only function
--                           |
--                           v
--                   edge_require_backend()
--                           |
--                           v
--                   domain/service layer
--                           |
--                           v
--                technical/business SSOT
--
--
-- DIRECT PORTAL TABLE ACCESS:
--
--                    NOT ALLOWED
--
--
-- The portal does not receive:
--
--   - direct table grants;
--   - direct view grants unless explicitly registered;
--   - direct domain-function grants;
--   - security-helper grants;
--   - worker-function grants;
--   - raw telemetry access;
--   - OAuth credential/token access;
--   - internal execution state;
--   - backend-only projections.
--
-- =====================================================


-- =====================================================
-- 7.19 SECURITY CONTRACT FOR 022
-- =====================================================
--
-- 022 must treat this migration as the source of truth for
-- the execution boundary:
--
-- AUTHENTICATED ALLOWLIST:
--
--   auth_api
--   automation_api
--   booking_api
--   commerce_api
--   crm_api
--   devices_api
--   integrations_api
--   logistics_api
--   locks_api
--   monetization_api
--   notification_api
--   onboarding_api
--   operations_api
--   optimization_api
--   payment_api
--   portal_api
--   preconfig_api
--
--
-- NEVER automatically grant authenticated:
--
--   edge_require_tenant
--   edge_require_manager
--   edge_require_admin
--   edge_require_backend
--   edge_require_platform_admin
--   edge_is_platform_admin
--   platform.is_platform_admin
--   public.is_platform_admin
--   insert_event
--   log_event
--
-- Nor the standalone named/internal functions unless an
-- explicit exception has been registered.
--
--
-- BACKEND-ONLY:
--
--   service_role / designated workers only.
--
-- =====================================================


-- =====================================================
-- 8. MIGRATION REGISTRATION
-- =====================================================
--
-- 017 EDGE RPC FOUNDATION
--
-- Security/API foundation only.
--
-- RLS belongs to 020.
-- Grants/revokes belong to 022.
-- =====================================================

insert into platform.schema_migrations (migration_name,version,rollback_available)
values ('019_edge_rpc_foundation','REV1',false)
on conflict (migration_name) do nothing;


-- =====================================================
-- END 019 EDGE RPC FOUNDATION
-- =====================================================