-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 021_GRANT_MATRIX.SQL
-- =====================================================
--
-- Enterprise Security Grant Boundary
--
-- AUTHORITY
-- ----------
-- Enterprise Auditor
-- KGS-001 Principles
-- SECURITY RULES
-- SSOT RULES
--
-- PURPOSE
-- -------
-- Single source of truth for:
--
--   - schema privileges
--   - table privileges
--   - sequence privileges
--   - function EXECUTE privileges
--   - approved API/RPC exposure
--   - service_role backend access
--   - final privilege validation
--
--
-- SECURITY MODEL
-- --------------
--
-- PORTAL
--    |
--    v
-- API / RPC
--    |
--    v
-- AUTHORIZATION
--    |
--    v
-- DOMAIN / BACKEND
--    |
--    v
-- TABLES
--
--
-- IMPORTANT
-- ---------
--
-- 018b owns:
--   - RLS
--   - FORCE RLS
--   - SECURITY DEFINER hardening
--   - search_path hardening
--   - policy removal
--
-- 021 owns:
--   - GRANT
--   - REVOKE
--   - EXECUTE privileges
--   - schema privileges
--   - table privileges
--   - sequence privileges
--   - final privilege validation
--
-- The platform.security_table_registry is the authority
-- for registered table security classification.
--
-- 021 deliberately contains NO RLS policy creation.
-- =====================================================


begin;

-- =====================================================
-- 1. SECURITY ACTORS
-- =====================================================

create table if not exists platform.security_actor (
    id uuid primary key default gen_random_uuid(),

    actor_code text not null unique,

    actor_type text not null
        check (
            actor_type in (
                'portal',
                'platform',
                'integration',
                'worker',
                'system'
            )
        ),

    auth_role text
        check (
            auth_role is null
            or auth_role in (
                'anon',
                'authenticated',
                'service_role'
            )
        ),

    privilege_profile text not null
        check (
            privilege_profile in (
                'none',
                'api_only',
                'read',
                'append',
                'write',
                'full'
            )
        ),

    description text not null,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    constraint security_actor_code_format
        check (
            actor_code ~ '^[a-z][a-z0-9_]*$'
        )
);


-- =====================================================
-- 2. SECURITY ACTORS SEED
-- =====================================================

insert into platform.security_actor (
    actor_code,
    actor_type,
    auth_role,
    privilege_profile,
    description
)
values

(
    'anonymous',
    'system',
    'anon',
    'none',
    'Unauthenticated public request context. May reach explicitly public HTTP boundaries but has no direct database access.'
),

(
    'portal_user',
    'portal',
    'authenticated',
    'api_only',
    'Authenticated portal user. Business access is exclusively through authorized API/RPC contracts; no direct table access.'
),

(
    'platform_admin',
    'platform',
    'authenticated',
    'api_only',
    'Authenticated platform administrator. Platform capabilities are exposed through explicitly authorized API/RPC contracts; no direct table access.'
),

(
    'aqara_webhook',
    'integration',
    'service_role',
    'append',
    'Server-side Aqara integration webhook execution context. Provider-authenticated inbound events may append data through the integration boundary.'
),

(
    'shelly_webhook',
    'integration',
    'service_role',
    'append',
    'Server-side Shelly integration webhook execution context. Provider-authenticated inbound events may append data through the integration boundary.'
),

(
    'ttlock_webhook',
    'integration',
    'service_role',
    'append',
    'Server-side TTLock integration webhook execution context. Provider-authenticated inbound events may append data through the integration boundary.'
),

(
    'integration_worker',
    'worker',
    'service_role',
    'write',
    'Server-side integration worker context for asynchronous integration processing and maintenance.'
),

(
    'telemetry_worker',
    'worker',
    'service_role',
    'append',
    'Server-side telemetry processing context for raw telemetry ingestion and downstream telemetry processing.'
),

(
    'automation_worker',
    'worker',
    'service_role',
    'write',
    'Server-side automation execution context for backend automation and scheduled processing.'
),

(
    'system',
    'system',
    'service_role',
    'full',
    'Internal server-side system context for explicitly authorized technical and maintenance operations.'
),

(
    'pg_partman',
    'system',
    null,
    'none',
    'Technical system actor representing pg_partman-managed backend configuration and partition-management metadata.'
)

on conflict (actor_code) do update
set
    actor_type       = excluded.actor_type,
    auth_role        = excluded.auth_role,
    privilege_profile = excluded.privilege_profile,
    description      = excluded.description,
    is_active        = true;



--- =====================================================
-- 3. SECURITY TABLE ACTOR
-- =====================================================
--
-- Defines which security actors are associated with
-- which registered security objects.
--
-- This table does NOT define PostgreSQL privileges.
-- The privilege profile is defined centrally on
-- platform.security_actor.privilege_profile.
--
-- The relationship answers:
--
--   "Which actor needs this security object?"
--
-- while security_actor answers:
--
--   "What privilege profile does this actor have?"
-- =====================================================

create table if not exists platform.security_table_actor (

    table_schema text not null,

    table_name text not null,

    actor_id uuid not null
        references platform.security_actor(id)
        on delete cascade,

    description text not null,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    constraint security_table_actor_pk
        primary key (
            table_schema,
            table_name,
            actor_id
        ),

    constraint security_table_actor_registry_fk
        foreign key (
            table_schema,
            table_name
        )
        references platform.security_table_registry (
            table_schema,
            table_name
        )
        on delete cascade
);

comment on table platform.security_table_actor is
'Defines which security actors are associated with a registered security object. PostgreSQL privilege scope is determined centrally by platform.security_actor.privilege_profile and is not defined per table relationship.';


comment on column platform.security_table_actor.table_name is
'Reference to the security classification of the protected tablename.';


comment on column platform.security_table_actor.actor_id is
'Reference to the security actor that requires an authorized relationship with this object. The actor privilege profile is defined on platform.security_actor.';


comment on column platform.security_table_actor.description is
'Human-readable explanation of why this actor requires access to the security object.';


comment on column platform.security_table_actor.is_active is
'Allows an actor-object relationship to be retired without deleting its security history.';


--- =====================================================
-- 4. SECURITY TABLE ACTOR SEED
-- =====================================================
--
-- Purpose:
--   Define which security actors are allowed to operate
--   on which governed tables.
--
-- SSOT:
--   platform.security_table_registry
--   platform.security_actor
--   platform.security_table_actor
--
-- The relationship is:
--
--   security_table_actor
--       ├── (table_schema, table_name)
--       │       → security_table_registry
--       │
--       └── actor_id
--           → security_actor.id
--
-- No security_table_id is used because
-- platform.security_table_registry is identified by the
-- composite key (table_schema, table_name).
-- =====================================================


with seed (
    table_schema,
    table_name,
    actor_code,
    description
) as (
    values

    -- =================================================
    -- SUPABASE
    -- =================================================

    (
        'public',
        'part_config',
        'pg_partman',
        'pg_partman-managed backend configuration table. Managed by the pg_partman system actor; no portal or direct authenticated access.'
    ),
    (
        'public',
        'part_config_sub',
        'pg_partman',
        'pg_partman-managed backend configuration table. Managed by the pg_partman system actor; no portal or direct authenticated access.'
    ),

    -- =================================================
    -- 000 PLATFORM / IDENTITY
    -- =================================================

    (
        'platform',
        'profiles',
        'portal_user',
        'Portal users require tenant-scoped access through approved API/RPC contracts.'
    ),
    (
        'platform',
        'profiles',
        'platform_admin',
        'Platform administrators require controlled administrative visibility.'
    ),

    (
        'platform',
        'platform_admins',
        'platform_admin',
        'Platform administrators require controlled access to platform administration records.'
    ),
    (
        'platform',
        'platform_admins',
        'system',
        'System processes require access to resolve platform administration context.'
    ),

    -- =================================================
    -- 000 PLATFORM / AUDIT + COMPLIANCE
    -- =================================================

    (
        'platform',
        'audit_log',
        'platform_admin',
        'Platform administrators require controlled access for audit and compliance review.'
    ),
    (
        'platform',
        'audit_log',
        'system',
        'System processes require access to record and maintain audit events.'
    ),

    (
        'platform',
        'constants',
        'system',
        'System processes require access to platform constants.'
    ),

    (
        'platform',
        'soft_delete_log',
        'platform_admin',
        'Platform administrators require controlled visibility into soft-delete activity.'
    ),
    (
        'platform',
        'soft_delete_log',
        'system',
        'System processes require access to record soft-delete activity.'
    ),

    (
        'platform',
        'error_log',
        'platform_admin',
        'Platform administrators require controlled access for error investigation and support.'
    ),
    (
        'platform',
        'error_log',
        'system',
        'System processes require access to record application and platform errors.'
    ),

    -- =================================================
    -- 000 PLATFORM / EVENT + EXECUTION
    -- =================================================

    (
        'platform',
        'internal_events',
        'system',
        'System processes require access to create and process internal platform events.'
    ),

    (
        'platform',
        'event_log',
        'platform_admin',
        'Platform administrators require controlled visibility into platform event history.'
    ),
    (
        'platform',
        'event_log',
        'system',
        'System processes require access to record platform events.'
    ),

    (
        'platform',
        'event_outbox',
        'system',
        'System processes require access to publish and process transactional outbox events.'
    ),

    (
        'platform',
        'execution_supervisor',
        'platform_admin',
        'Platform administrators require controlled visibility into execution supervision.'
    ),
    (
        'platform',
        'execution_supervisor',
        'system',
        'System processes require access to supervise backend execution.'
    ),

    (
        'platform',
        'operation_contexts',
        'system',
        'System processes require access to create and resolve operation execution contexts.'
    ),

    (
        'platform',
        'operation_log',
        'platform_admin',
        'Platform administrators require controlled visibility into operation history.'
    ),
    (
        'platform',
        'operation_log',
        'system',
        'System processes require access to record operation execution.'
    ),

    (
        'platform',
        'dead_letter_archive',
        'platform_admin',
        'Platform administrators require controlled access to archived failed operations.'
    ),
    (
        'platform',
        'dead_letter_archive',
        'system',
        'System processes require access to archive failed operations.'
    ),

    (
        'platform',
        'retry_tasks',
        'platform_admin',
        'Platform administrators require controlled visibility into retry tasks.'
    ),
    (
        'platform',
        'retry_tasks',
        'system',
        'System processes require access to schedule and execute retry tasks.'
    ),

    -- =================================================
    -- 000 PLATFORM / DEVICE EXECUTION
    -- =================================================

    (
        'platform',
        'device_commands',
        'platform_admin',
        'Platform administrators require controlled visibility into device command execution.'
    ),
    (
        'platform',
        'device_commands',
        'system',
        'System processes require access to create and execute device commands.'
    ),

    (
        'platform',
        'device_commands_dlq',
        'platform_admin',
        'Platform administrators require controlled access to failed device commands.'
    ),
    (
        'platform',
        'device_commands_dlq',
        'system',
        'System processes require access to archive failed device commands.'
    ),

    -- =================================================
    -- 000 PLATFORM / INTEGRATION + WEBHOOK
    -- =================================================

    (
        'platform',
        'external_webhooks',
        'aqara_webhook',
        'Aqara webhook processing requires controlled access to the external webhook boundary.'
    ),
    (
        'platform',
        'external_webhooks',
        'shelly_webhook',
        'Shelly webhook processing requires controlled access to the external webhook boundary.'
    ),
    (
        'platform',
        'external_webhooks',
        'ttlock_webhook',
        'TTLock webhook processing requires controlled access to the external webhook boundary.'
    ),
    (
        'platform',
        'external_webhooks',
        'integration_worker',
        'Integration workers require access to process validated external webhook events.'
    ),
    (
        'platform',
        'external_webhooks',
        'platform_admin',
        'Platform administrators require controlled visibility into external webhook activity.'
    ),

    (
        'platform',
        'webhook_provider_tenant_map',
        'aqara_webhook',
        'Aqara webhook processing requires controlled tenant/provider identity resolution.'
    ),
    (
        'platform',
        'webhook_provider_tenant_map',
        'shelly_webhook',
        'Shelly webhook processing requires controlled tenant/provider identity resolution.'
    ),
    (
        'platform',
        'webhook_provider_tenant_map',
        'ttlock_webhook',
        'TTLock webhook processing requires controlled tenant/provider identity resolution.'
    ),
    (
        'platform',
        'webhook_provider_tenant_map',
        'integration_worker',
        'Integration workers require controlled tenant/provider identity resolution.'
    ),
    (
        'platform',
        'webhook_provider_tenant_map',
        'platform_admin',
        'Platform administrators require controlled visibility into webhook tenant mappings.'
    ),

    (
        'platform',
        'integration_queue',
        'aqara_webhook',
        'Aqara webhook processing requires controlled enqueue access for integration events.'
    ),
    (
        'platform',
        'integration_queue',
        'shelly_webhook',
        'Shelly webhook processing requires controlled enqueue access for integration events.'
    ),
    (
        'platform',
        'integration_queue',
        'ttlock_webhook',
        'TTLock webhook processing requires controlled enqueue access for integration events.'
    ),
    (
        'platform',
        'integration_queue',
        'integration_worker',
        'Integration workers require access to process integration queue entries.'
    ),
    (
        'platform',
        'integration_queue',
        'platform_admin',
        'Platform administrators require controlled visibility into integration queue activity.'
    ),

    -- =================================================
    -- 000 PLATFORM / LOGISTICS
    -- =================================================

    (
        'platform',
        'shipment_dispatch_queue',
        'system',
        'System processes require access to dispatch shipment operations.'
    ),
    (
        'platform',
        'shipment_dispatch_queue',
        'platform_admin',
        'Platform administrators require controlled visibility into shipment dispatch operations.'
    ),

    (
        'platform',
        'shipment_tracking_events',
        'system',
        'System processes require access to process shipment tracking events.'
    ),
    (
        'platform',
        'shipment_tracking_events',
        'platform_admin',
        'Platform administrators require controlled visibility into shipment tracking events.'
    ),

    -- =================================================
    -- 000 PLATFORM / PAYMENT
    -- =================================================

    (
        'platform',
        'payment_intents',
        'portal_user',
        'Portal users require tenant-scoped payment intent access through approved API/RPC contracts.'
    ),
    (
        'platform',
        'payment_intents',
        'platform_admin',
        'Platform administrators require controlled payment administration access.'
    ),
    (
        'platform',
        'payment_intents',
        'system',
        'System processes require access to create and process payment intents.'
    ),

    (
        'platform',
        'payment_events',
        'portal_user',
        'Portal users require tenant-scoped visibility into relevant payment events through approved API/RPC contracts.'
    ),
    (
        'platform',
        'payment_events',
        'platform_admin',
        'Platform administrators require controlled visibility into payment events.'
    ),
    (
        'platform',
        'payment_events',
        'system',
        'System processes require access to process payment provider events.'
    ),

    (
        'platform',
        'payment_provider_refs',
        'platform_admin',
        'Platform administrators require controlled access to payment provider references.'
    ),
    (
        'platform',
        'payment_provider_refs',
        'system',
        'System processes require access to maintain payment provider references.'
    ),

    -- =================================================
    -- 000 PLATFORM / SCHEDULING + NODES
    -- =================================================

    (
        'platform',
        'scheduled_jobs',
        'platform_admin',
        'Platform administrators require controlled visibility into scheduled jobs.'
    ),
    (
        'platform',
        'scheduled_jobs',
        'system',
        'System processes require access to schedule and manage backend jobs.'
    ),

    (
        'platform',
        'job_executions',
        'platform_admin',
        'Platform administrators require controlled visibility into job executions.'
    ),
    (
        'platform',
        'job_executions',
        'system',
        'System processes require access to record and manage job executions.'
    ),

    (
        'platform',
        'system_nodes',
        'platform_admin',
        'Platform administrators require controlled access to platform node administration.'
    ),
    (
        'platform',
        'system_nodes',
        'system',
        'System processes require access to register and manage system nodes.'
    ),

    (
        'platform',
        'node_heartbeats',
        'platform_admin',
        'Platform administrators require controlled visibility into system node health.'
    ),
    (
        'platform',
        'node_heartbeats',
        'system',
        'System processes require access to publish and process node heartbeats.'
    ),

    -- =================================================
    -- 000 PLATFORM / OBSERVABILITY
    -- =================================================

    (
        'platform',
        'query_performance_log',
        'platform_admin',
        'Platform administrators require controlled access to query performance diagnostics.'
    ),
    (
        'platform',
        'query_performance_log',
        'system',
        'System processes require access to record query performance diagnostics.'
    ),

    (
        'platform',
        'queue_processor_logs',
        'platform_admin',
        'Platform administrators require controlled access to queue processor diagnostics.'
    ),
    (
        'platform',
        'queue_processor_logs',
        'system',
        'System processes require access to record queue processor diagnostics.'
    ),

    (
        'platform',
        'event_lag_monitor',
        'platform_admin',
        'Platform administrators require controlled visibility into event processing lag.'
    ),
    (
        'platform',
        'event_lag_monitor',
        'system',
        'System processes require access to record and evaluate event processing lag.'
    ),

    (
        'platform',
        'system_metrics',
        'platform_admin',
        'Platform administrators require controlled visibility into system metrics.'
    ),
    (
        'platform',
        'system_metrics',
        'system',
        'System processes require access to record system metrics.'
    ),

    (
        'platform',
        'system_metrics_aggregated',
        'platform_admin',
        'Platform administrators require controlled visibility into aggregated system metrics.'
    ),
    (
        'platform',
        'system_metrics_aggregated',
        'system',
        'System processes require access to maintain aggregated system metrics.'
    ),

    (
        'platform',
        'performance_snapshots',
        'platform_admin',
        'Platform administrators require controlled access to platform performance snapshots.'
    ),
    (
        'platform',
        'performance_snapshots',
        'system',
        'System processes require access to generate performance snapshots.'
    ),

    (
        'platform',
        'index_usage_stats',
        'platform_admin',
        'Platform administrators require controlled access to index usage diagnostics.'
    ),
    (
        'platform',
        'index_usage_stats',
        'system',
        'System processes require access to collect index usage diagnostics.'
    ),

    (
        'platform',
        'slow_query_flags',
        'platform_admin',
        'Platform administrators require controlled access to slow-query diagnostics.'
    ),
    (
        'platform',
        'slow_query_flags',
        'system',
        'System processes require access to identify and record slow queries.'
    ),

    -- =================================================
    -- 000 PLATFORM / ARCHITECTURE CONTROL
    -- =================================================

    (
        'platform',
        'table_contracts',
        'platform_admin',
        'Platform administrators require controlled access to table contract governance.'
    ),
    (
        'platform',
        'table_contracts',
        'system',
        'System processes require access to validate and maintain table contracts.'
    ),

    (
        'platform',
        'utility_function_registry',
        'platform_admin',
        'Platform administrators require controlled visibility into registered utility functions.'
    ),
    (
        'platform',
        'utility_function_registry',
        'system',
        'System processes require access to maintain the utility function registry.'
    ),

    (
        'platform',
        'schema_change_log',
        'platform_admin',
        'Platform administrators require controlled visibility into schema changes.'
    ),
    (
        'platform',
        'schema_change_log',
        'system',
        'System processes require access to record schema changes.'
    ),

    (
        'platform',
        'schema_migrations',
        'platform_admin',
        'Platform administrators require controlled visibility into schema migrations.'
    ),
    (
        'platform',
        'schema_migrations',
        'system',
        'System processes require access to maintain migration state.'
    ),

    (
        'platform',
        'migration_execution_log',
        'platform_admin',
        'Platform administrators require controlled visibility into migration execution.'
    ),
    (
        'platform',
        'migration_execution_log',
        'system',
        'System processes require access to record migration execution.'
    ),

    (
        'platform',
        'realtime_streams',
        'platform_admin',
        'Platform administrators require controlled visibility into realtime stream configuration.'
    ),
    (
        'platform',
        'realtime_streams',
        'system',
        'System processes require access to manage realtime stream configuration.'
    ),

    -- =================================================
    -- 002 CORE SAAS
    -- =================================================

    (
        'public',
        'tenants',
        'portal_user',
        'Portal users require tenant-scoped access through approved API/RPC contracts.'
    ),
    (
        'public',
        'tenants',
        'platform_admin',
        'Platform administrators require controlled tenant administration access.'
    ),

    (
        'public',
        'tenant_memberships',
        'portal_user',
        'Portal users require tenant-scoped membership access through approved API/RPC contracts.'
    ),
    (
        'public',
        'tenant_memberships',
        'platform_admin',
        'Platform administrators require controlled membership administration access.'
    ),

    (
        'public',
        'subscriptions',
        'portal_user',
        'Portal users require tenant-scoped subscription access through approved API/RPC contracts.'
    ),
    (
        'public',
        'subscriptions',
        'platform_admin',
        'Platform administrators require controlled subscription administration access.'
    ),

    (
        'public',
        'service_accounts',
        'system',
        'System processes require access to service account records for backend execution.'
    ),

    -- =================================================
    -- 003 CRM
    -- =================================================

    (
        'public',
        'crm_pipelines',
        'portal_user',
        'Portal users require tenant-scoped CRM pipeline access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_pipelines',
        'platform_admin',
        'Platform administrators require controlled CRM pipeline administration access.'
    ),

    (
        'public',
        'crm_pipeline_stages',
        'portal_user',
        'Portal users require tenant-scoped CRM pipeline stage access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_pipeline_stages',
        'platform_admin',
        'Platform administrators require controlled CRM pipeline stage administration access.'
    ),

    (
        'public',
        'crm_campaigns',
        'portal_user',
        'Portal users require tenant-scoped CRM campaign access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_campaigns',
        'platform_admin',
        'Platform administrators require controlled CRM campaign administration access.'
    ),

    (
        'public',
        'crm_tags',
        'portal_user',
        'Portal users require tenant-scoped CRM tag access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_tags',
        'platform_admin',
        'Platform administrators require controlled CRM tag administration access.'
    ),

    (
        'public',
        'crm_companies',
        'portal_user',
        'Portal users require tenant-scoped CRM company access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_companies',
        'platform_admin',
        'Platform administrators require controlled CRM company administration access.'
    ),

    (
        'public',
        'crm_contacts',
        'portal_user',
        'Portal users require tenant-scoped CRM contact access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_contacts',
        'platform_admin',
        'Platform administrators require controlled CRM contact administration access.'
    ),

    (
        'public',
        'crm_leads',
        'portal_user',
        'Portal users require tenant-scoped CRM lead access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_leads',
        'platform_admin',
        'Platform administrators require controlled CRM lead administration access.'
    ),

    (
        'public',
        'crm_contact_company',
        'portal_user',
        'Portal users require tenant-scoped CRM contact-company relationship access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_contact_company',
        'platform_admin',
        'Platform administrators require controlled CRM relationship administration access.'
    ),

    (
        'public',
        'crm_company_tenants',
        'portal_user',
        'Portal users require tenant-scoped CRM company relationship access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_company_tenants',
        'platform_admin',
        'Platform administrators require controlled CRM tenant relationship administration access.'
    ),

    (
        'public',
        'crm_contact_tenants',
        'portal_user',
        'Portal users require tenant-scoped CRM contact relationship access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_contact_tenants',
        'platform_admin',
        'Platform administrators require controlled CRM tenant relationship administration access.'
    ),

    (
        'public',
        'crm_opportunities',
        'portal_user',
        'Portal users require tenant-scoped CRM opportunity access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_opportunities',
        'platform_admin',
        'Platform administrators require controlled CRM opportunity administration access.'
    ),

    (
        'public',
        'crm_tasks',
        'portal_user',
        'Portal users require tenant-scoped CRM task access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_tasks',
        'platform_admin',
        'Platform administrators require controlled CRM task administration access.'
    ),

    (
        'public',
        'crm_interactions',
        'portal_user',
        'Portal users require tenant-scoped CRM interaction access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_interactions',
        'platform_admin',
        'Platform administrators require controlled CRM interaction administration access.'
    ),

    (
        'public',
        'crm_notes',
        'portal_user',
        'Portal users require tenant-scoped CRM note access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_notes',
        'platform_admin',
        'Platform administrators require controlled CRM note administration access.'
    ),

    (
        'public',
        'crm_tag_assignments',
        'portal_user',
        'Portal users require tenant-scoped CRM tag assignment access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_tag_assignments',
        'platform_admin',
        'Platform administrators require controlled CRM tag assignment administration access.'
    ),

    (
        'public',
        'crm_lists',
        'portal_user',
        'Portal users require tenant-scoped CRM list access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_lists',
        'platform_admin',
        'Platform administrators require controlled CRM list administration access.'
    ),

    (
        'public',
        'crm_list_members',
        'portal_user',
        'Portal users require tenant-scoped CRM list membership access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_list_members',
        'platform_admin',
        'Platform administrators require controlled CRM list membership administration access.'
    ),

    (
        'public',
        'crm_custom_fields',
        'portal_user',
        'Portal users require tenant-scoped CRM custom field access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_custom_fields',
        'platform_admin',
        'Platform administrators require controlled CRM custom field administration access.'
    ),

    (
        'public',
        'crm_custom_field_values',
        'portal_user',
        'Portal users require tenant-scoped CRM custom field value access through approved API/RPC contracts.'
    ),
    (
        'public',
        'crm_custom_field_values',
        'platform_admin',
        'Platform administrators require controlled CRM custom field value administration access.'
    ),

    -- =================================================
    -- 004 PROPERTY / DEVICE
    -- =================================================

    (
        'public',
        'properties',
        'portal_user',
        'Portal users require tenant-scoped property access through approved API/RPC contracts.'
    ),
    (
        'public',
        'properties',
        'platform_admin',
        'Platform administrators require controlled property administration access.'
    ),

    (
        'public',
        'rooms',
        'portal_user',
        'Portal users require tenant-scoped room access through approved API/RPC contracts.'
    ),
    (
        'public',
        'rooms',
        'platform_admin',
        'Platform administrators require controlled room administration access.'
    ),

    (
        'public',
        'device_categories',
        'portal_user',
        'Portal users require tenant-scoped device category access through approved API/RPC contracts.'
    ),
    (
        'public',
        'device_categories',
        'platform_admin',
        'Platform administrators require controlled device category administration access.'
    ),

    (
        'public',
        'devices',
        'portal_user',
        'Portal users require tenant-scoped device access through approved API/RPC contracts.'
    ),
    (
        'public',
        'devices',
        'platform_admin',
        'Platform administrators require controlled device administration access.'
    ),

    (
        'public',
        'device_assignments',
        'portal_user',
        'Portal users require tenant-scoped device assignment access through approved API/RPC contracts.'
    ),
    (
        'public',
        'device_assignments',
        'platform_admin',
        'Platform administrators require controlled device assignment administration access.'
    ),

    (
        'public',
        'device_configurations',
        'portal_user',
        'Portal users require tenant-scoped device configuration access through approved API/RPC contracts.'
    ),
    (
        'public',
        'device_configurations',
        'platform_admin',
        'Platform administrators require controlled device configuration administration access.'
    ),

    -- =================================================
    -- 005 BOOKING / LOCK
    -- =================================================

    (
        'public',
        'bookings',
        'portal_user',
        'Portal users require tenant-scoped booking access through approved API/RPC contracts.'
    ),
    (
        'public',
        'bookings',
        'platform_admin',
        'Platform administrators require controlled booking administration access.'
    ),

    (
        'public',
        'property_access_schedules',
        'portal_user',
        'Portal users require tenant-scoped property access schedule access through approved API/RPC contracts.'
    ),
    (
        'public',
        'property_access_schedules',
        'platform_admin',
        'Platform administrators require controlled property access schedule administration.'
    ),

    (
        'public',
        'booking_access',
        'portal_user',
        'Portal users require tenant-scoped booking access records through approved API/RPC contracts.'
    ),
    (
        'public',
        'booking_access',
        'platform_admin',
        'Platform administrators require controlled booking access administration.'
    ),

    (
        'public',
        'access_policies',
        'portal_user',
        'Portal users require tenant-scoped access policy management through approved API/RPC contracts.'
    ),
    (
        'public',
        'access_policies',
        'platform_admin',
        'Platform administrators require controlled access policy administration.'
    ),

    (
        'public',
        'access_rules',
        'portal_user',
        'Portal users require tenant-scoped access rule management through approved API/RPC contracts.'
    ),
    (
        'public',
        'access_rules',
        'platform_admin',
        'Platform administrators require controlled access rule administration.'
    ),

    (
        'public',
        'lock_devices',
        'portal_user',
        'Portal users require tenant-scoped lock device access through approved API/RPC contracts.'
    ),
    (
        'public',
        'lock_devices',
        'platform_admin',
        'Platform administrators require controlled lock device administration.'
    ),

    (
        'public',
        'access_credentials',
        'portal_user',
        'Portal users require controlled tenant-scoped credential management through approved API/RPC contracts; plaintext credentials are never directly exposed.'
    ),
    (
        'public',
        'access_credentials',
        'platform_admin',
        'Platform administrators require controlled credential administration; plaintext credentials are never directly exposed.'
    ),

    -- =================================================
    -- 006 INTEGRATION
    -- =================================================

    (
        'public',
        'integration_providers',
        'portal_user',
        'Portal users require tenant-scoped visibility into available integration providers through approved API/RPC contracts.'
    ),
    (
        'public',
        'integration_providers',
        'platform_admin',
        'Platform administrators require controlled integration provider administration.'
    ),

    (
        'public',
        'integration_capabilities',
        'portal_user',
        'Portal users require tenant-scoped visibility into integration capabilities through approved API/RPC contracts.'
    ),
    (
        'public',
        'integration_capabilities',
        'platform_admin',
        'Platform administrators require controlled integration capability administration.'
    ),

    (
        'public',
        'integration_oauth_configs',
        'system',
        'System processes require access to OAuth configuration for integration execution.'
    ),
    (
        'public',
        'integration_oauth_configs',
        'platform_admin',
        'Platform administrators require controlled administration of OAuth configuration.'
    ),

    (
        'public',
        'integration_oauth_states',
        'system',
        'System processes require access to OAuth state during controlled authorization flows.'
    ),

    (
        'public',
        'tenant_integrations',
        'portal_user',
        'Portal users require tenant-scoped integration management through approved API/RPC contracts.'
    ),
    (
        'public',
        'tenant_integrations',
        'platform_admin',
        'Platform administrators require controlled tenant integration administration.'
    ),

    (
        'public',
        'webhook_definitions',
        'portal_user',
        'Portal users require tenant-scoped visibility into configured webhook definitions through approved API/RPC contracts.'
    ),
    (
        'public',
        'webhook_definitions',
        'platform_admin',
        'Platform administrators require controlled webhook definition administration.'
    ),

    (
        'public',
        'integration_webhook_mappings',
        'integration_worker',
        'Integration system actor responsible for backend webhook mapping resolution.'
    ),

    (
        'public',
        'device_integration_map',
        'portal_user',
        'Portal users require tenant-scoped device integration mapping through approved API/RPC contracts.'
    ),
    (
        'public',
        'device_integration_map',
        'platform_admin',
        'Platform administrators require controlled device integration mapping administration.'
    ),
    (
        'public',
        'device_integration_map',
        'aqara_webhook',
        'Aqara webhook processing requires controlled provider device identity resolution.'
    ),
    (
        'public',
        'device_integration_map',
        'shelly_webhook',
        'Shelly webhook processing requires controlled provider device identity resolution.'
    ),
    (
        'public',
        'device_integration_map',
        'ttlock_webhook',
        'TTLock webhook processing requires controlled provider device identity resolution.'
    ),
    (
        'public',
        'device_integration_map',
        'integration_worker',
        'Integration workers require controlled access to resolve provider device mappings.'
    ),

    -- =================================================
    -- 007 RAW TELEMETRY
    -- =================================================

    (
        'public',
        'device_telemetry_raw',
        'telemetry_worker',
        'Telemetry workers require backend write access for raw telemetry ingestion and processing.'
    ),
    (
        'public',
        'device_telemetry_raw',
        'aqara_webhook',
        'Aqara webhook processing requires controlled raw telemetry ingestion access.'
    ),
    (
        'public',
        'device_telemetry_raw',
        'shelly_webhook',
        'Shelly webhook processing requires controlled raw telemetry ingestion access.'
    ),
    (
        'public',
        'device_telemetry_raw',
        'ttlock_webhook',
        'TTLock webhook processing requires controlled raw telemetry ingestion access.'
    ),
    (
        'public',
        'device_telemetry_raw',
        'platform_admin',
        'Platform administrators require controlled visibility into raw telemetry for support and diagnostics.'
    ),

    -- =================================================
    -- 009 OPERATIONS
    -- =================================================

    (
        'public',
        'operation_templates',
        'portal_user',
        'Portal users require tenant-scoped operation template access through approved API/RPC contracts.'
    ),
    (
        'public',
        'operation_templates',
        'platform_admin',
        'Platform administrators require controlled operation template administration.'
    ),

    (
        'public',
        'operation_workflows',
        'portal_user',
        'Portal users require tenant-scoped operation workflow access through approved API/RPC contracts.'
    ),
    (
        'public',
        'operation_workflows',
        'platform_admin',
        'Platform administrators require controlled operation workflow administration.'
    ),

    (
        'public',
        'workflow_steps',
        'portal_user',
        'Portal users require tenant-scoped workflow step access through approved API/RPC contracts.'
    ),
    (
        'public',
        'workflow_steps',
        'platform_admin',
        'Platform administrators require controlled workflow step administration.'
    ),

    (
        'public',
        'workflow_triggers',
        'portal_user',
        'Portal users require tenant-scoped workflow trigger access through approved API/RPC contracts.'
    ),
    (
        'public',
        'workflow_triggers',
        'platform_admin',
        'Platform administrators require controlled workflow trigger administration.'
    ),

    (
        'public',
        'notification_templates',
        'portal_user',
        'Portal users require tenant-scoped notification template access through approved API/RPC contracts.'
    ),
    (
        'public',
        'notification_templates',
        'platform_admin',
        'Platform administrators require controlled notification template administration.'
    ),

    (
        'public',
        'notification_preferences',
        'portal_user',
        'Portal users require tenant-scoped notification preference access through approved API/RPC contracts.'
    ),
    (
        'public',
        'notification_preferences',
        'platform_admin',
        'Platform administrators require controlled notification preference administration.'
    ),

    (
        'public',
        'notification_queue',
        'system',
        'System processes require access to enqueue and process notifications.'
    ),
    (
        'public',
        'notification_queue',
        'portal_user',
        'Portal users require controlled tenant-scoped notification queue access through approved RPC contracts.'
    ),
    (
        'public',
        'notification_queue',
        'platform_admin',
        'Platform administrators require controlled visibility into notification queue activity.'
    ),

    (
        'public',
        'notification_history',
        'system',
        'System processes require access to record notification delivery history.'
    ),
    (
        'public',
        'notification_history',
        'portal_user',
        'Portal users require controlled tenant-scoped notification history access through approved RPC contracts.'
    ),
    (
        'public',
        'notification_history',
        'platform_admin',
        'Platform administrators require controlled visibility into notification history.'
    ),

    (
        'public',
        'support_tickets',
        'portal_user',
        'Portal users require tenant-scoped support ticket access through approved API/RPC contracts.'
    ),
    (
        'public',
        'support_tickets',
        'platform_admin',
        'Platform administrators require controlled support ticket administration.'
    ),

    (
        'public',
        'support_messages',
        'portal_user',
        'Portal users require tenant-scoped support message access through approved API/RPC contracts.'
    ),
    (
        'public',
        'support_messages',
        'platform_admin',
        'Platform administrators require controlled support message administration.'
    ),

    -- =================================================
    -- 010 PRECONFIG
    -- =================================================

    (
        'public',
        'device_bundles',
        'portal_user',
        'Portal users require tenant-scoped device bundle access through approved API/RPC contracts.'
    ),
    (
        'public',
        'device_bundles',
        'platform_admin',
        'Platform administrators require controlled device bundle administration.'
    ),

    (
        'public',
        'bundle_devices',
        'portal_user',
        'Portal users require tenant-scoped bundle device access through approved API/RPC contracts.'
    ),
    (
        'public',
        'bundle_devices',
        'platform_admin',
        'Platform administrators require controlled bundle device administration.'
    ),

    (
        'public',
        'onboarding_blueprints',
        'portal_user',
        'Portal users require tenant-scoped onboarding blueprint access through approved API/RPC contracts.'
    ),
    (
        'public',
        'onboarding_blueprints',
        'platform_admin',
        'Platform administrators require controlled onboarding blueprint administration.'
    ),

    (
        'public',
        'onboarding_blueprint_steps',
        'portal_user',
        'Portal users require tenant-scoped onboarding blueprint step access through approved API/RPC contracts.'
    ),
    (
        'public',
        'onboarding_blueprint_steps',
        'platform_admin',
        'Platform administrators require controlled onboarding blueprint step administration.'
    ),

    (
        'public',
        'preconfig_templates',
        'portal_user',
        'Portal users require tenant-scoped preconfiguration template access through approved API/RPC contracts.'
    ),
    (
        'public',
        'preconfig_templates',
        'platform_admin',
        'Platform administrators require controlled preconfiguration template administration.'
    ),

    (
        'public',
        'preconfig_device_map',
        'portal_user',
        'Portal users require tenant-scoped preconfiguration device mapping through approved API/RPC contracts.'
    ),
    (
        'public',
        'preconfig_device_map',
        'platform_admin',
        'Platform administrators require controlled preconfiguration device mapping administration.'
    ),

    -- =================================================
    -- 011 LOGISTICS
    -- =================================================

    (
        'public',
        'shipping_carriers',
        'portal_user',
        'Portal users require controlled access to shipping carrier configuration through approved API/RPC contracts.'
    ),
    (
        'public',
        'shipping_carriers',
        'platform_admin',
        'Platform administrators require controlled shipping carrier administration.'
    ),

    (
        'public',
        'shipping_label_templates',
        'portal_user',
        'Portal users require controlled access to shipping label templates through approved API/RPC contracts.'
    ),
    (
        'public',
        'shipping_label_templates',
        'platform_admin',
        'Platform administrators require controlled shipping label template administration.'
    ),

    (
        'public',
        'logistics_templates',
        'portal_user',
        'Portal users require controlled logistics template access through approved API/RPC contracts.'
    ),

    (
        'public',
        'warehouses',
        'portal_user',
        'Portal users require controlled warehouse access through approved API/RPC contracts.'
    ),

    (
        'public',
        'shipping_rules',
        'portal_user',
        'Portal users require controlled shipping rule access through approved API/RPC contracts.'
    ),

    (
        'public',
        'package_definitions',
        'portal_user',
        'Portal users require controlled package definition access through approved API/RPC contracts.'
    ),

    (
        'public',
        'fulfilment_orders',
        'portal_user',
        'Portal users require controlled fulfilment order access through approved API/RPC contracts.'
    ),

    -- =================================================
    -- 012 COMMERCE
    -- =================================================

    (
        'public',
        'product_plans',
        'portal_user',
        'Portal users require controlled product plan access through approved API/RPC contracts.'
    ),
    (
        'public',
        'product_plans',
        'platform_admin',
        'Platform administrators require controlled product plan administration.'
    ),

    (
        'public',
        'plan_pricing',
        'portal_user',
        'Portal users require controlled plan pricing visibility through approved API/RPC contracts.'
    ),
    (
        'public',
        'plan_pricing',
        'platform_admin',
        'Platform administrators require controlled plan pricing administration.'
    ),

    (
        'public',
        'feature_entitlements',
        'portal_user',
        'Portal users require controlled feature entitlement visibility through approved API/RPC contracts.'
    ),
    (
        'public',
        'feature_entitlements',
        'platform_admin',
        'Platform administrators require controlled feature entitlement administration.'
    ),

    (
        'public',
        'upsell_rules',
        'portal_user',
        'Portal users require controlled upsell rule visibility through approved API/RPC contracts.'
    ),
    (
        'public',
        'upsell_rules',
        'platform_admin',
        'Platform administrators require controlled upsell rule administration.'
    ),

    -- =================================================
    -- 013 SERVICE PORTAL
    -- =================================================

    (
        'public',
        'tenant_portal_settings',
        'portal_user',
        'Portal users require tenant-scoped portal settings access through approved API/RPC contracts.'
    ),
    (
        'public',
        'tenant_portal_settings',
        'platform_admin',
        'Platform administrators require controlled tenant portal settings administration.'
    ),

    (
        'public',
        'dashboard_configs',
        'portal_user',
        'Portal users require tenant-scoped dashboard configuration access through approved API/RPC contracts.'
    ),
    (
        'public',
        'dashboard_configs',
        'platform_admin',
        'Platform administrators require controlled dashboard configuration administration.'
    ),

    (
        'public',
        'portal_user_preferences',
        'portal_user',
        'Portal users require controlled access to their tenant-scoped portal preferences through approved API/RPC contracts.'
    ),
    (
        'public',
        'portal_user_preferences',
        'platform_admin',
        'Platform administrators require controlled visibility into portal user preferences for support.'
    ),

    (
        'public',
        'portal_feature_flags',
        'portal_user',
        'Portal users require controlled visibility into applicable portal feature flags through approved API/RPC contracts.'
    ),
    (
        'public',
        'portal_feature_flags',
        'platform_admin',
        'Platform administrators require controlled portal feature flag administration.'
    ),

    -- =================================================
    -- 014 ONBOARDING
    -- =================================================

    (
        'public',
        'onboarding_sessions',
        'portal_user',
        'Portal users require tenant-scoped onboarding session access through approved API/RPC contracts.'
    ),
    (
        'public',
        'onboarding_sessions',
        'platform_admin',
        'Platform administrators require controlled onboarding session administration.'
    ),

    (
        'public',
        'onboarding_step_state',
        'portal_user',
        'Portal users require tenant-scoped onboarding step state access through approved API/RPC contracts.'
    ),
    (
        'public',
        'onboarding_step_state',
        'platform_admin',
        'Platform administrators require controlled onboarding step state administration.'
    ),

    (
        'public',
        'onboarding_room_mapping',
        'portal_user',
        'Portal users require tenant-scoped onboarding room mapping access through approved API/RPC contracts.'
    ),
    (
        'public',
        'onboarding_room_mapping',
        'platform_admin',
        'Platform administrators require controlled onboarding room mapping administration.'
    ),

    (
        'public',
        'onboarding_device_mapping',
        'portal_user',
        'Portal users require tenant-scoped onboarding device mapping access through approved API/RPC contracts.'
    ),
    (
        'public',
        'onboarding_device_mapping',
        'platform_admin',
        'Platform administrators require controlled onboarding device mapping administration.'
    ),

    (
        'public',
        'onboarding_checklist',
        'portal_user',
        'Portal users require tenant-scoped onboarding checklist access through approved API/RPC contracts.'
    ),
    (
        'public',
        'onboarding_checklist',
        'platform_admin',
        'Platform administrators require controlled onboarding checklist administration.'
    ),

    (
        'public',
        'onboarding_notes',
        'portal_user',
        'Portal users require tenant-scoped onboarding note access through approved API/RPC contracts.'
    ),
    (
        'public',
        'onboarding_notes',
        'platform_admin',
        'Platform administrators require controlled onboarding note administration.'
    ),

    (
        'public',
        'onboarding_lifecycle',
        'portal_user',
        'Portal users require tenant-scoped onboarding lifecycle visibility through approved API/RPC contracts.'
    ),
    (
        'public',
        'onboarding_lifecycle',
        'platform_admin',
        'Platform administrators require controlled onboarding lifecycle administration.'
    ),

    (
        'public',
        'onboarding_lifecycle_transitions',
        'portal_user',
        'Portal users require tenant-scoped onboarding lifecycle transition visibility through approved API/RPC contracts.'
    ),
    (
        'public',
        'onboarding_lifecycle_transitions',
        'platform_admin',
        'Platform administrators require controlled onboarding lifecycle transition administration.'
    ),

    -- =================================================
    -- 015 OPTIMIZATION
    -- =================================================

    (
        'public',
        'optimization_rules',
        'portal_user',
        'Portal users require tenant-scoped optimization rule access through approved API/RPC contracts.'
    ),
    (
        'public',
        'optimization_rules',
        'platform_admin',
        'Platform administrators require controlled optimization rule administration.'
    ),

    (
        'public',
        'insight_events',
        'portal_user',
        'Portal users require tenant-scoped insight visibility through approved API/RPC contracts.'
    ),
    (
        'public',
        'insight_events',
        'platform_admin',
        'Platform administrators require controlled insight event administration.'
    ),
    (
        'public',
        'insight_events',
        'system',
        'System processes require access to generate and process optimization insight events.'
    ),

    (
        'public',
        'optimization_recommendations',
        'portal_user',
        'Portal users require tenant-scoped optimization recommendation access through approved API/RPC contracts.'
    ),
    (
        'public',
        'optimization_recommendations',
        'platform_admin',
        'Platform administrators require controlled optimization recommendation administration.'
    ),
    (
        'public',
        'optimization_recommendations',
        'system',
        'System processes require access to generate and maintain optimization recommendations.'
    ),

    (
        'public',
        'device_usage_scores',
        'portal_user',
        'Portal users require tenant-scoped device usage score visibility through approved API/RPC contracts.'
    ),
    (
        'public',
        'device_usage_scores',
        'platform_admin',
        'Platform administrators require controlled device usage score administration.'
    ),
    (
        'public',
        'device_usage_scores',
        'system',
        'System processes require access to calculate and maintain device usage scores.'
    ),

    (
        'public',
        'energy_profiles',
        'portal_user',
        'Portal users require tenant-scoped energy profile visibility through approved API/RPC contracts.'
    ),
    (
        'public',
        'energy_profiles',
        'platform_admin',
        'Platform administrators require controlled energy profile administration.'
    ),
    (
        'public',
        'energy_profiles',
        'system',
        'System processes require access to calculate and maintain energy profiles.'
    ),

    -- =================================================
    -- 016 CUSTOMER PROPOSAL / MONETIZATION
    -- =================================================

    (
        'public',
        'customer_proposals',
        'portal_user',
        'Portal users require tenant-scoped customer proposal access through approved API/RPC contracts.'
    ),
    (
        'public',
        'customer_proposals',
        'platform_admin',
        'Platform administrators require controlled customer proposal administration.'
    ),

    (
        'public',
        'proposal_items',
        'portal_user',
        'Portal users require tenant-scoped proposal item access through approved API/RPC contracts.'
    ),
    (
        'public',
        'proposal_items',
        'platform_admin',
        'Platform administrators require controlled proposal item administration.'
    ),

    (
        'public',
        'monetization_packages',
        'portal_user',
        'Portal users require controlled monetization package visibility through approved API/RPC contracts.'
    ),
    (
        'public',
        'monetization_packages',
        'platform_admin',
        'Platform administrators require controlled monetization package administration.'
    ),

    (
        'public',
        'upsell_campaigns',
        'portal_user',
        'Portal users require controlled upsell campaign visibility through approved API/RPC contracts.'
    ),
    (
        'public',
        'upsell_campaigns',
        'platform_admin',
        'Platform administrators require controlled upsell campaign administration.'
    ),

    (
        'public',
        'conversion_events',
        'portal_user',
        'Portal users require tenant-scoped conversion event visibility through approved API/RPC contracts.'
    ),
    (
        'public',
        'conversion_events',
        'platform_admin',
        'Platform administrators require controlled conversion event administration.'
    ),
    (
        'public',
        'conversion_events',
        'system',
        'System processes require access to record and process conversion events.'
    ),

    (
        'public',
        'conversion_scores',
        'portal_user',
        'Portal users require tenant-scoped conversion score visibility through approved API/RPC contracts.'
    ),
    (
        'public',
        'conversion_scores',
        'platform_admin',
        'Platform administrators require controlled conversion score administration.'
    ),
    (
        'public',
        'conversion_scores',
        'system',
        'System processes require access to calculate and maintain conversion scores.'
    ),

    (
        'public',
        'service_activation_state',
        'platform_admin',
        'Platform administrators require controlled access to service activation state.'
    ),
    (
        'public',
        'service_activation_state',
        'system',
        'System processes require access to maintain service activation state.'
    ),

    -- =================================================
    -- 017 AUTOMATION
    -- =================================================

    (
        'public',
        'automation_runs',
        'portal_user',
        'Portal users require tenant-scoped automation run visibility through approved API/RPC contracts.'
    ),
    (
        'public',
        'automation_runs',
        'platform_admin',
        'Platform administrators require controlled automation run administration.'
    ),
    (
        'public',
        'automation_runs',
        'automation_worker',
        'Automation workers require access to create, execute, and update automation runs.'
    ),

    (
        'public',
        'automation_run_steps',
        'portal_user',
        'Portal users require tenant-scoped automation run step visibility through approved API/RPC contracts.'
    ),
    (
        'public',
        'automation_run_steps',
        'platform_admin',
        'Platform administrators require controlled automation run step administration.'
    ),
    (
        'public',
        'automation_run_steps',
        'automation_worker',
        'Automation workers require access to execute and update automation run steps.'
    ),

    (
        'public',
        'automation_event_subscriptions',
        'portal_user',
        'Portal users require tenant-scoped automation event subscription access through approved API/RPC contracts.'
    ),
    (
        'public',
        'automation_event_subscriptions',
        'platform_admin',
        'Platform administrators require controlled automation event subscription administration.'
    ),
    (
        'public',
        'automation_event_subscriptions',
        'automation_worker',
        'Automation workers require access to resolve and process automation event subscriptions.'
    )
)

insert into platform.security_table_actor (
    table_schema,
    table_name,
    actor_id,
    description,
    is_active
)
select
    s.table_schema,
    s.table_name,
    a.id,
    s.description,
    true
from seed s
join platform.security_table_registry r
    on r.table_schema = s.table_schema
   and r.table_name = s.table_name
join platform.security_actor a
    on a.actor_code = s.actor_code
where r.is_active = true
  and a.is_active = true
on conflict (
    table_schema,
    table_name,
    actor_id
)
do update
set
    description = excluded.description,
    is_active = true;
    
-- =====================================================
-- 5. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations ( migration_name, version, rollback_available)
values ( '021_grant_matrix_actors', 'REV1', false)
on conflict (version) do nothing;


-- =====================================================
-- COMMIT
-- =====================================================

COMMIT;
