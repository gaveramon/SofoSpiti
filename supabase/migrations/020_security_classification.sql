-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 020_SECURITY_CLASSIFICATION.SQL
-- =====================================================
--
-- SECURITY REGISTRY INPUT
-- =====================================================
--
--
-- 021 OWNS
-- ---------
-- - INPUT FOR API, SECURITY HARDENING AND GRANTS/REVOKES


begin;


-- =====================================================
-- 1. REGISTER TABLE SECURITY CLASSIFICATIONS
-- =====================================================
--
-- 19 CONTAINS ONLY MANUAL TWO INSERTS
--
-- When a new governed table is introduced:
--
--   1. create the table in its domain migration
--   2. add ONE registry row here
--
-- security_class:
--   business / backend
--
-- portal_access:
--   rpc / none
--
-- Portal access is ALWAYS API/RPC mediated.
-- Platform admin states if a platform admin should be 
-- able to access the table.
-- No authenticated role receives direct table access.
-- =====================================================

insert into platform.security_table_registry (
    table_schema,
    table_name,
    security_class,
    portal_access,
    platform_admin_access,
    direct_authenticated_access,
    rls_required,
    force_rls_required,
    is_active,
    description
)
values
    -- =================================================
    -- SUPABASE TABLES
    -- =================================================

    (
        'partman',
        'part_config',
        'backend',
        'none',
        false,
        false,
        true,
        false,
        true,
        'pg_partman-managed backend configuration table. No portal or direct authenticated access. RLS is enabled as a public-schema security boundary.'
    ),
    (
        'partman',
        'part_config_sub',
        'backend',
        'none',
        false,
        false,
        true,
        false,
        true,
        'pg_partman-managed backend configuration table. No portal or direct authenticated access. RLS is enabled as a public-schema security boundary.'
    ),

    -- =================================================
    -- 000 PLATFORM / IDENTITY
    -- =================================================

    (
        'platform',
        'profiles',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Global user identity profile. Tenant portal access through approved API/RPC contracts; platform-admin access through explicit platform-admin RPC contracts; no direct authenticated table access.'
    ),

    (
        'platform',
        'platform_admins',
        'backend',
        'none',
        false,
        false,
        true,
        true,
        true,
        'Platform operator registry. Backend/security controlled; platform-admin status is resolved through controlled security functions; no portal or direct authenticated table access.'
    ),

    -- =================================================
    -- 000 PLATFORM / AUDIT + COMPLIANCE
    -- =================================================

    (
        'platform',
        'audit_log',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Immutable platform audit log. Platform-admin visibility only through explicit security/audit RPC; direct table access remains backend/service-role only.'
    ),

    (
        'platform',
        'constants',
        'backend',
        'none',
        false,
        false,
        true,
        true,
        true,
        'Global platform constants. System-controlled; no portal or platform-admin table access.'
    ),

    (
        'platform',
        'soft_delete_log',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Recovery and soft-delete audit data. Platform-admin visibility only through explicit administrative RPC; direct table access remains backend/service-role only.'
    ),

    (
        'platform',
        'error_log',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Platform error and diagnostic log. Platform-admin visibility only through explicit administrative RPC; direct table access remains backend/service-role only.'
    ),

    -- =================================================
    -- 000 PLATFORM / EVENT + EXECUTION
    -- =================================================

    (
        'platform',
        'internal_events',
        'backend',
        'none',
        false,
        false,
        true,
        true,
        true,
        'Internal platform event stream. Worker/backend processing only; no platform-admin table access.'
    ),

    (
        'platform',
        'event_log',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Internal high-volume event stream. Platform-admin visibility only through explicit observability RPC; direct table access remains backend/service-role only.'
    ),

    (
        'platform',
        'event_outbox',
        'backend',
        'none',
        false,
        false,
        true,
        true,
        true,
        'Internal consistency outbox. Worker/backend processing only; no platform-admin table access.'
    ),

    (
        'platform',
        'execution_supervisor',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Platform execution health supervisor. Platform-admin visibility only through explicit operations/observability RPC; direct table access remains backend/service-role only.'
    ),

    (
        'platform',
        'operation_contexts',
        'backend',
        'none',
        false,
        false,
        true,
        true,
        true,
        'Transient workflow execution context inbox. Worker/backend processing only; no platform-admin table access.'
    ),

    (
        'platform',
        'operation_log',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Internal command and operation execution log. Platform-admin visibility only through explicit operations RPC; direct table access remains backend/service-role only.'
    ),

    (
        'platform',
        'dead_letter_archive',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Final failure archive for platform processing. Platform-admin visibility only through explicit operations/observability RPC; direct table access remains backend/service-role only.'
    ),

    (
        'platform',
        'retry_tasks',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Generic worker retry queue. Platform-admin visibility or controlled retry actions only through explicit operations RPC; direct table access remains backend/service-role only.'
    ),

    -- =================================================
    -- 000 PLATFORM / DEVICE EXECUTION
    -- =================================================

    (
        'platform',
        'device_commands',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Device command execution queue. Platform-admin may inspect or manage commands only through explicit operations/device-admin RPC; direct table access remains backend/service-role only.'
    ),

    (
        'platform',
        'device_commands_dlq',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Failed device command dead-letter queue. Platform-admin visibility or controlled recovery only through explicit operations RPC; direct table access remains backend/service-role only.'
    ),

    -- =================================================
    -- 000 PLATFORM / INTEGRATION + WEBHOOK
    -- =================================================

    (
        'platform',
        'external_webhooks',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'External webhook ingestion boundary. Platform-admin may inspect operational state only through explicit integration/operations RPC; backend processing remains service-role controlled.'
    ),

    (
        'platform',
        'webhook_provider_tenant_map',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'External provider account to tenant resolution map. Platform-admin access only through explicit integration administration RPC; direct table access remains backend/service-role only.'
    ),

    (
        'platform',
        'integration_queue',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Durable integration delivery queue. Platform-admin visibility or controlled operational actions only through explicit integration/operations RPC.'
    ),

    -- =================================================
    -- 000 PLATFORM / LOGISTICS EXECUTION
    -- =================================================

    (
        'platform',
        'shipment_dispatch_queue',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Backend-owned shipment dispatch execution queue. Platform-admin operational visibility or controlled actions only through explicit logistics administration RPC.'
    ),

    (
        'platform',
        'shipment_tracking_events',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Backend-owned shipment tracking event storage. Platform-admin visibility only through explicit logistics/operations RPC; direct table access remains backend/service-role only.'
    ),

    -- =================================================
    -- 000 PLATFORM / PAYMENT EXECUTION
    -- =================================================

    (
        'platform',
        'payment_intents',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Backend-owned payment execution state. Portal may access tenant-scoped payment information only through approved payment API/RPC contracts; direct authenticated table access is prohibited.'
    ),

    (
        'platform',
        'payment_events',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Backend-owned immutable payment lifecycle events. Portal may read tenant-scoped history only through approved payment API/RPC contracts; direct authenticated table access is prohibited.'
    ),

    (
        'platform',
        'payment_provider_refs',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Provider reference mapping for payment execution. Platform-admin visibility only through explicit payment administration RPC; direct table access remains backend/service-role only.'
    ),

    -- =================================================
    -- 000 PLATFORM / SCHEDULING + NODES
    -- =================================================

    (
        'platform',
        'scheduled_jobs',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Platform scheduled-job control registry. Platform-admin management only through explicit scheduling/operations RPC; direct table access remains backend/service-role only.'
    ),

    (
        'platform',
        'job_executions',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Scheduled job execution history. Platform-admin visibility only through explicit scheduling/observability RPC.'
    ),

    (
        'platform',
        'system_nodes',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Canonical platform node registry. Platform-admin visibility/management only through explicit platform operations RPC.'
    ),

    (
        'platform',
        'node_heartbeats',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Platform node liveness history. Platform-admin visibility only through explicit observability RPC.'
    ),

    -- =================================================
    -- 000 PLATFORM / OBSERVABILITY
    -- =================================================

    (
        'platform',
        'query_performance_log',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Query performance observability data. Platform-admin visibility only through explicit observability RPC.'
    ),

    (
        'platform',
        'queue_processor_logs',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Queue processor observability data. Platform-admin visibility only through explicit observability RPC.'
    ),

    (
        'platform',
        'event_lag_monitor',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Queue and event lag monitoring data. Platform-admin visibility only through explicit observability RPC.'
    ),

    (
        'platform',
        'system_metrics',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Raw platform system metrics. Platform-admin visibility only through explicit observability RPC.'
    ),

    (
        'platform',
        'system_metrics_aggregated',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Aggregated platform system metrics. Platform-admin visibility only through explicit observability RPC.'
    ),

    (
        'platform',
        'performance_snapshots',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Platform performance snapshots. Platform-admin visibility only through explicit observability RPC.'
    ),

    (
        'platform',
        'index_usage_stats',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Database index usage telemetry. Platform-admin visibility only through explicit observability RPC.'
    ),

    (
        'platform',
        'slow_query_flags',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Slow-query anomaly registry. Platform-admin visibility only through explicit observability RPC.'
    ),

    -- =================================================
    -- 000 PLATFORM / SCHEMA + ARCHITECTURE CONTROL
    -- =================================================

    (
        'platform',
        'table_contracts',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Platform table contract registry. Platform-admin visibility only through explicit architecture/security administration RPC.'
    ),

    (
        'platform',
        'utility_function_registry',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Platform utility function dependency registry. Platform-admin visibility only through explicit architecture/security administration RPC.'
    ),

    (
        'platform',
        'schema_change_log',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Structured schema evolution log. Platform-admin visibility only through explicit architecture administration RPC.'
    ),

    (
        'platform',
        'schema_migrations',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Applied migration registry. Platform-admin visibility only through explicit architecture administration RPC.'
    ),

    (
        'platform',
        'migration_execution_log',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Migration execution audit log. Platform-admin visibility only through explicit architecture administration RPC.'
    ),

    (
        'platform',
        'realtime_streams',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Declarative realtime stream configuration. Platform-admin management only through explicit platform administration RPC.'
    ),

    -- =================================================
    -- 002 CORE SAAS
    -- =================================================

    (
    'public',
    'customer_accounts',
    'business',
    'rpc',
    true,
    false,
    true,
    true,
    true,
    'Business SSOT for customer accounts. Customer accounts may own or manage multiple tenants. Portal access is exclusively through the approved RPC/API layer; direct authenticated table access is denied. RLS and FORCE RLS are required.'
    ),
    
    (
        'public',
        'tenants',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant master data. Tenant portal access through approved API/RPC contracts; platform-admin access through explicit platform tenant administration RPC.'
    ),

    (
        'public',
        'tenant_memberships',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant membership and role data. Tenant portal access through approved API/RPC contracts; platform-admin access through explicit platform user/tenant administration RPC.'
    ),

    (
        'public',
        'subscriptions',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Subscription data and commercial plan binding. Tenant portal access through approved subscription/commerce API/RPC contracts; platform-admin access through explicit administration RPC.'
    ),

    (
        'public',
        'service_accounts',
        'backend',
        'none',
        false,
        false,
        true,
        true,
        true,
        'Internal service-account data. Backend/service-role only; no portal or platform-admin table access.'
    ),

    -- =================================================
    -- 003 CRM ENGINE
    -- =================================================
    
    (
        'public',
        'crm_pipelines',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM sales pipeline definitions. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_pipeline_stages',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM pipeline stage definitions. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_campaigns',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM marketing campaign definitions. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_tags',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM tag definitions. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_companies',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM company records and customer-company relationships. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_contacts',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM contact SSOT including contact details and consent state. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_leads',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM prospect and lead records including conversion state. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_contact_company',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM contact-to-company relationship records. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_company_tenants',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM company-to-customer-tenant relationship records. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_contact_tenants',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM contact-to-customer-tenant relationship records. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_opportunities',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM sales opportunity records including pipeline, stage, revenue and ownership. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_tasks',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM follow-up task records. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_interactions',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM append-oriented interaction history. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_notes',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM entity notes and note version state. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_tag_assignments',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM tag-to-entity assignments. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_lists',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM contact list definitions and optional dynamic filter configuration. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_list_members',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM list membership records. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_custom_fields',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM custom field definitions. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
    
    (
        'public',
        'crm_custom_field_values',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'CRM custom field values attached to CRM entities. Portal access exclusively through approved CRM API/RPC contracts; direct table access denied.'
    ),
  
    -- =================================================
    -- 004 PROPERTY / DEVICE ENGINE
    -- =================================================

    (
        'public',
        'properties',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Property and Device Engine business table. Tenant portal access exclusively through approved devices API/RPC contracts; platform-admin access through explicit platform/property administration RPC.'
    ),

    (
        'public',
        'rooms',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Property and Device Engine business table. Tenant portal access exclusively through approved devices API/RPC contracts; platform-admin access through explicit platform/property administration RPC.'
    ),

    (
        'public',
        'device_categories',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Device taxonomy business table. Tenant portal read access through approved devices API/RPC contracts; platform-admin catalog administration through explicit platform/device administration RPC.'
    ),

    (
        'public',
        'devices',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'SmartHellas device registry SSOT. Tenant portal access exclusively through approved devices API/RPC contracts; platform-admin access through explicit platform/device administration RPC.'
    ),

    (
        'public',
        'device_assignments',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Device-to-room assignment business table. Tenant portal access exclusively through approved devices API/RPC contracts; platform-admin access through explicit platform/device administration RPC.'
    ),

    (
        'public',
        'device_configurations',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Static device provisioning configuration. Tenant portal access exclusively through approved devices API/RPC contracts; platform-admin access through explicit platform/device administration RPC.'
    ),

    -- =================================================
    -- 005 BOOKING / LOCK ENGINE
    -- =================================================

    (
        'public',
        'bookings',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Booking SSOT. Tenant portal access exclusively through approved booking domain API/RPC operations; platform-admin access through explicit platform booking administration RPC.'
    ),

    (
        'public',
        'property_access_schedules',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Guest access-window template per property. Tenant portal access exclusively through booking domain RPC operations; platform-admin access through explicit platform booking administration RPC.'
    ),

    (
        'public',
        'booking_access',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Resolved guest access window per booking. Tenant portal access exclusively through approved booking domain RPC operations; platform-admin access through explicit platform booking administration RPC.'
    ),

    (
        'public',
        'access_policies',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Non-guest access grants. Tenant portal access exclusively through approved booking domain RPC operations; platform-admin access through explicit platform access administration RPC.'
    ),

    (
        'public',
        'access_rules',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Property-level access exceptions. Tenant portal access exclusively through approved booking domain RPC operations; platform-admin access through explicit platform access administration RPC.'
    ),

    (
        'public',
        'lock_devices',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Property-to-lock device mapping. Tenant portal access exclusively through approved locks domain RPC operations; platform-admin access through explicit platform/device administration RPC.'
    ),

    (
        'public',
        'access_credentials',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Issued credential metadata. Tenant portal may read through approved locks domain RPC operations; credential issuance/revocation remains controlled. Platform-admin access is through explicit administrative RPC and must never expose plaintext credentials.'
    ),

    -- =================================================
    -- 006 INTEGRATION ENGINE
    -- =================================================

    (
        'public',
        'integration_providers',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Integration provider catalog. Tenant portal access only through approved API/RPC contracts; platform-admin catalog administration through explicit integration administration RPC.'
    ),

    (
        'public',
        'integration_capabilities',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Provider capability catalog. Tenant portal access only through approved API/RPC contracts; platform-admin access through explicit integration administration RPC.'
    ),

    (
        'public',
        'integration_oauth_configs',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'OAuth configuration metadata. Backend-controlled; platform-admin access only through explicitly scoped integration administration RPC and never through direct table access.'
    ),

    (
        'public',
        'integration_oauth_states',
        'backend',
        'none',
        false,
        false,
        true,
        true,
        true,
        'Transient OAuth transaction state. Backend/service-role and security-definer lifecycle only; no platform-admin table access.'
    ),

    (
        'public',
        'tenant_integrations',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant integration configuration. Tenant portal access only through approved API/RPC contracts; platform-admin access through explicit integration administration RPC.'
    ),

    (
        'public',
        'webhook_definitions',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant webhook configuration. Tenant portal access only through approved API/RPC contracts; platform-admin access through explicit integration administration RPC.'
    ),

    (
        'public',
        'integration_webhook_mappings',
        'backend',
        'none',
        false,
        false,
        true,
        true,
        true,
        'Backend integration mapping table used to resolve external webhook identities to internal integrations. No direct portal or authenticated access.'
    ),

    (
        'public',
        'device_integration_map',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Provider-to-device identity mapping. Tenant portal access only through approved API/RPC contracts; platform-admin access through explicit integration/device administration RPC.'
    ),

    -- =================================================
    -- 007 DEVICE TELEMETRY RAW
    -- =================================================

    (
        'public',
        'device_telemetry_raw',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Immutable raw device telemetry. Backend/service-role ingestion and processing only; platform-admin visibility through explicit telemetry/observability RPC without direct table access.'
    ),
    (
        'public',
        'device_telemetry_raw_idempotency',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Backend-only ingestion idempotency registry for raw device telemetry. Contains tenant, provider event identity and telemetry linkage metadata. No direct portal access.'
    ),

    -- =================================================
    -- 008 DEVICE TELEMETRY PROCESSING
    -- =================================================
    
    (
        'public',
        'device_metrics',
        'business',
        'rpc',
        false,
        false,
        true,
        true,
        true,
        'Normalized device telemetry time series. Portal access exclusively through devices_domain()/devices_api(); no direct authenticated table access.'
    ),
    (
        'public',
        'device_current_state',
        'business',
        'rpc',
        false,
        false,
        true,
        true,
        true,
        'Latest known device metric state used by portal dashboards and device lists. Portal access exclusively through devices_domain()/devices_api(); no direct authenticated table access.'
    ),


    -- =================================================
    -- 009 OPERATIONS ENGINE
    -- =================================================

    (
        'public',
        'operation_templates',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'System and tenant operation templates. Portal access exclusively through operations API/RPC contracts. System templates are globally readable; tenant templates are tenant-scoped. Platform admins may inspect system and tenant templates through approved domain API.'
    ),

    (
        'public',
        'operation_workflows',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant workflow definitions. Portal access exclusively through operations API/RPC contracts. Tenant-scoped; platform-admin access only through approved domain/API operations.'
    ),

    (
        'public',
        'workflow_steps',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Workflow step definitions belonging to tenant workflows. No direct authenticated access; portal access exclusively through operations API/RPC contracts. Platform-admin access through approved domain/API operations.'
    ),

    (
        'public',
        'workflow_triggers',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Workflow trigger definitions associated with tenant workflows and optionally properties. No direct authenticated access; portal access exclusively through operations API/RPC contracts. Platform-admin access through approved domain/API operations.'
    ),

    (
        'public',
        'notification_templates',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'System and tenant notification message templates. Portal access exclusively through notification domain RPC contracts. System templates are globally readable; tenant templates are tenant-scoped. Platform-admin access through approved domain/API operations.'
    ),

    (
        'public',
        'notification_preferences',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant and user notification preferences. Portal access exclusively through notification domain RPC contracts. Tenant-scoped and user-scoped where applicable. Platform-admin access remains API/RPC mediated.'
    ),

    (
        'public',
        'notification_queue',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Backend-owned pending notification delivery records. Portal may inspect or cancel records only through approved notification domain RPC contracts; actual delivery processing remains backend/service-role responsibility.'
    ),

    (
        'public',
        'notification_history',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Backend-owned historical notification delivery records including recipient, message metadata and delivery errors. Portal reads only through approved notification domain RPC contracts; backend workers retain operational ownership.'
    ),

    (
        'public',
        'support_tickets',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant support case master records. Portal access exclusively through approved support/operations API/RPC contracts. Tenant users may access their tenant data; platform admin/support access is domain API mediated.'
    ),

    (
        'public',
        'support_messages',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Messages belonging to support tickets. Portal access exclusively through approved support/operations API/RPC contracts. Tenant scope is enforced through ticket and tenant consistency controls.'
    ),

    -- =================================================
    -- 010 PRECONFIG ENGINE
    -- =================================================

    (
        'public',
        'device_bundles',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Global versioned hardware bundle catalog. Tenant portal access exclusively through preconfig API/RPC contracts; platform-admin catalog administration through explicit platform preconfig RPC.'
    ),

    (
        'public',
        'bundle_devices',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Hardware components belonging to device bundles. Tenant portal access exclusively through preconfig API/RPC contracts; platform-admin administration through explicit platform preconfig RPC.'
    ),

    (
        'public',
        'onboarding_blueprints',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Global onboarding and installation blueprint catalog. Tenant portal access exclusively through preconfig API/RPC contracts; platform-admin administration through explicit platform preconfig RPC.'
    ),

    (
        'public',
        'onboarding_blueprint_steps',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Ordered steps belonging to global onboarding blueprints. Tenant portal access exclusively through preconfig API/RPC contracts; platform-admin administration through explicit platform preconfig RPC.'
    ),

    (
        'public',
        'preconfig_templates',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Global preconfiguration template catalog. Tenant portal access exclusively through preconfig API/RPC contracts; platform-admin administration through explicit platform preconfig RPC.'
    ),

    (
        'public',
        'preconfig_device_map',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Device-to-room installation mapping within preconfiguration templates. Tenant portal access exclusively through preconfig API/RPC contracts; platform-admin administration through explicit platform preconfig RPC.'
    ),

    -- =================================================
    -- 011 LOGISTICS — BUSINESS
    -- =================================================

    (
        'public',
        'shipping_carriers',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Global shipping carrier catalog. Portal reads through approved logistics API/RPC contracts; mutations require platform-admin authorization; no direct authenticated table access.'
    ),

    (
        'public',
        'shipping_label_templates',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Global carrier-specific shipping label definitions. Portal reads through approved logistics API/RPC contracts; mutations require platform-admin authorization; no direct authenticated table access.'
    ),

    (
        'public',
        'logistics_templates',
        'business',
        'rpc',
        false,
        false,
        true,
        true,
        true,
        'Tenant-scoped logistics delivery templates with optional system templates. Portal access exclusively through approved logistics API/RPC contracts; tenant mutations require manager authorization.'
    ),

    (
        'public',
        'warehouses',
        'business',
        'rpc',
        false,
        false,
        true,
        true,
        true,
        'Tenant-scoped fulfilment origin locations with optional system warehouses. Portal access exclusively through approved logistics API/RPC contracts; tenant mutations require manager authorization.'
    ),

    (
        'public',
        'shipping_rules',
        'business',
        'rpc',
        false,
        false,
        true,
        true,
        true,
        'Tenant-scoped shipping routing and pricing rules with optional system rules. Portal access exclusively through approved logistics API/RPC contracts; tenant mutations require manager authorization.'
    ),

    (
        'public',
        'package_definitions',
        'business',
        'rpc',
        false,
        false,
        true,
        true,
        true,
        'Shipment package definitions linking logistics templates to device bundles. Tenant scope is inherited through the parent logistics template. Portal access exclusively through approved logistics API/RPC contracts.'
    ),

    (
        'public',
        'fulfilment_orders',
        'business',
        'rpc',
        false,
        false,
        true,
        true,
        true,
        'Tenant-scoped shipment intent. Portal reads and mutations exclusively through approved logistics API/RPC contracts; tenant mutations require manager authorization; dispatch execution and tracking remain in the platform layer.'
    ),

    -- =================================================
    -- 012 COMMERCE ENGINE
    -- =================================================

    (
        'public',
        'product_plans',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Commercial subscription plan catalog. Portal reads active plans and platform admins manage plans exclusively through commerce API/RPC contracts.'
    ),

    (
        'public',
        'plan_pricing',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Commercial pricing attached to product plans. Portal reads pricing through commerce API/RPC contracts; platform admins manage pricing through RPC only.'
    ),

    (
        'public',
        'feature_entitlements',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Plan feature entitlement definitions. Portal reads effective entitlements through commerce API/RPC contracts; platform admins manage definitions through RPC only.'
    ),

    (
        'public',
        'upsell_rules',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped and platform-wide subscription upsell rule definitions. Portal access exclusively through commerce API/RPC contracts; tenant managers and platform admins are authorized by RPC.'
    ),

    (
        'public',
        'invoices',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped invoices. Portal access exclusively through commerce/payment API/RPC contracts.'
    ),

    (
        'public',
        'discount_codes',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped or platform-wide discount/coupon definitions. Portal access exclusively through commerce API/RPC contracts.'
    ),

    (
        'public',
        'discount_redemptions',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped discount redemption ledger. Portal access exclusively through commerce API/RPC contracts.'
    ),

    (
        'public',
        'invoice_lines',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped invoice line items. Written by the backend; portal read access exclusively through commerce API/RPC contracts.'
    ),

    (
        'public',
        'billing_customers',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped fiscal billing identity (legal name, VAT number, address) used on invoices. Portal reads and updates exclusively through commerce API/RPC contracts; Epsilon customer code is gateway-controlled.'
    ),

    (
        'public',
        'billing_item_mappings',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Plan-to-Epsilon item and myDATA classification mapping. Platform-wide configuration confirmed by the accountant; no portal access.'
    ),

    (
        'public',
        'invoice_snapshots',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Immutable snapshot of each invoice as frozen for Epsilon. Insert-only (update/delete blocked by trigger); service-role/workers only.'
    ),

    (
        'public',
        'epsilon_submissions',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Epsilon e-invoicing outbox: API tracking, retries and idempotency keys. Written by platform.epsilon_* functions; service-role/workers only.'
    ),

    -- =================================================
    -- 013 SERVICE & PORTAL ENGINE
    -- =================================================

    (
        'public',
        'tenant_portal_settings',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped portal UI configuration SSOT. Portal access only through portal domain API/RPC contracts. Platform admins may access for tenant administration.'
    ),

    (
        'public',
        'dashboard_configs',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped dashboard layout configuration. Portal access only through portal domain API/RPC contracts. Platform admins may access for tenant administration.'
    ),

    (
        'public',
        'portal_user_preferences',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Per-user portal UI preferences scoped to tenant and authenticated user. Portal access only through portal domain API/RPC contracts. Platform admins may access for support and administration.'
    ),

    (
        'public',
        'portal_feature_flags',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped UI-only feature visibility flags using ui_* keys. Plan entitlement truth remains in feature_entitlements. Portal access only through portal domain API/RPC contracts.'
    ),

    -- =================================================
    -- 014 ONBOARDING ENGINE
    -- =================================================

    (
        'public',
        'onboarding_sessions',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped onboarding sessions per property. Portal access only through onboarding domain RPC.'
    ),

    (
        'public',
        'onboarding_step_state',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped onboarding wizard step progress. Portal access only through onboarding domain RPC.'
    ),

    (
        'public',
        'onboarding_room_mapping',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped room mapping input created during onboarding. Portal access only through onboarding domain RPC.'
    ),

    (
        'public',
        'onboarding_device_mapping',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped device placement and QR pairing outcome state. No execution. Portal access only through onboarding domain RPC.'
    ),

    (
        'public',
        'onboarding_checklist',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped onboarding checklist and business validation state. Portal access only through onboarding domain RPC.'
    ),

    (
        'public',
        'onboarding_notes',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped onboarding notes and support context. Portal access only through onboarding domain RPC.'
    ),

    (
        'public',
        'onboarding_lifecycle',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped property onboarding lifecycle state. State changes through controlled onboarding lifecycle RPC.'
    ),

    (
        'public',
        'onboarding_lifecycle_transitions',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Immutable tenant-scoped onboarding lifecycle transition history. Portal read access only through approved RPC.'
    ),

    -- =================================================
    -- 015 OPTIMIZATION ENGINE
    -- =================================================

    (
        'public',
        'optimization_rules',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped optimization rules. Portal access only via optimization API/RPC contracts; no direct authenticated table access.'
    ),

    (
        'public',
        'insight_events',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped non-actionable insight events. Portal read-only via optimization API/RPC contracts; creation and mutation are backend/service-role responsibilities.'
    ),

    (
        'public',
        'optimization_recommendations',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped advisory recommendations. Portal access only via optimization API/RPC contracts; creation is backend/service-role controlled while approved portal mutations are RPC-mediated.'
    ),

    (
        'public',
        'device_usage_scores',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped device usage analytics. Backend-generated analytical snapshots; portal read-only via optimization API/RPC contracts.'
    ),

    (
        'public',
        'energy_profiles',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped property energy analytics. Backend-generated analytical snapshots; portal read-only via optimization API/RPC contracts.'
    ),

    -- =================================================
    -- 016 CUSTOMER PROPOSAL & MONETIZATION
    -- =================================================

    (
        'public',
        'customer_proposals',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped commercial customer proposals. Portal access only through approved monetization API/RPC operations.'
    ),

    (
        'public',
        'proposal_items',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped proposal line items. Portal access only through approved monetization API/RPC operations; tenant consistency enforced against customer_proposals.'
    ),

    (
        'public',
        'monetization_packages',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Global commercial package catalog. Readable by portal through RPC; creation, update and deletion restricted to platform administrators.'
    ),

    (
        'public',
        'upsell_campaigns',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant/global commercial upsell campaigns. Portal access only through approved monetization API/RPC operations; management restricted to managers/platform administrators.'
    ),

    (
        'public',
        'conversion_events',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Append-only commercial funnel events. Portal may read tenant-scoped events through RPC; event insertion and mutation are backend/platform controlled.'
    ),

    (
        'public',
        'conversion_scores',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped analytical conversion scoring data. Portal may read through RPC; calculation and mutation are backend controlled.'
    ),

    (
        'public',
        'service_activation_state',
        'backend',
        'none',
        true,
        false,
        true,
        true,
        true,
        'Worker-maintained service activation projection derived from subscriptions and feature entitlements. Not app-writable truth; service-role/workers only.'
    ),

    -- =================================================
    -- 017 AUTOMATION ENGINE
    -- =================================================

    (
        'public',
        'automation_runs',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped automation runtime executions. Portal access exclusively through approved automation API/RPC contracts; no direct authenticated table access.'
    ),

    (
        'public',
        'automation_run_steps',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped automation workflow step execution state. Portal access exclusively through approved automation API/RPC contracts; no direct authenticated table access.'
    ),

    (
        'public',
        'automation_event_subscriptions',
        'business',
        'rpc',
        true,
        false,
        true,
        true,
        true,
        'Tenant-scoped bindings between workflow triggers and automation runtime. Portal reads and modifies subscriptions exclusively through approved automation API/RPC contracts.'
    )
    
    on conflict (table_schema, table_name)
do update set
    security_class = excluded.security_class,
    portal_access = excluded.portal_access,
    platform_admin_access = excluded.platform_admin_access,
    direct_authenticated_access =
        excluded.direct_authenticated_access,
    rls_required = excluded.rls_required,
    force_rls_required = excluded.force_rls_required,
    is_active = excluded.is_active,
    description = excluded.description,
    updated_at = now();

-- =====================================================
-- =====================================================
-- 2. SECURITY VIEW REGISTRY
-- =====================================================
-- =====================================================

create table if not exists platform.security_view_registry (
    view_schema text not null,
    view_name text not null,

    security_class text not null,

    portal_access boolean not null default false,
    platform_admin_access boolean not null default false,
    direct_authenticated_access boolean not null default false,

    rls_required boolean not null default false,

    is_active boolean not null default true,

    description text,

    primary key (view_schema, view_name)
);


-- =====================================================
-- =====================================================
-- 3. REGISTER VIEW SECURITY CLASSIFICATIONS
-- FOR EVERY VIEW AVAILABLE, AN ENTRY SHOULD BE ADDED
-- =====================================================
-- =====================================================

insert into platform.security_view_registry (
    view_schema,
    view_name,
    security_class,
    portal_access,
    platform_admin_access,
    direct_authenticated_access,
    rls_required,
    is_active,
    description
)
values

-- =====================================================
-- 000 PLATFORM
-- =====================================================

(
    'public',
    'v_tenant_audit_overview',
    'business',
    false,
    false,
    false,
    true,
    true,
    'Tenant-scoped audit overview derived from platform.audit_log. Not directly accessible by the portal; tenant audit data must be exposed through an authorized API/RPC contract.'
),

(
    'public',
    'v_tenant_events_overview',
    'business',
    false,
    false,
    false,
    true,
    true,
    'Tenant-scoped event overview derived from platform.event_log. Not directly accessible by the portal; tenant event data must be exposed through an authorized API/RPC contract.'
),

-- =====================================================
-- 002 CORE SAAS
-- =====================================================

(
     'public',
    'tenant_user_context',
    'security',
    false,
    false,
    false,
    false,
    true,
    'Tenant membership and role context used internally for authorization and tenant resolution. Security-sensitive view; not directly accessible by authenticated portal clients. Security is enforced through security_invoker semantics and RLS on underlying tables.'
),

-- =====================================================
-- 003 CRM
-- =====================================================

(
    'public',
    'v_crm_pipeline',
    'business',
    false,
    false,
    false,
    true,
    true,
    'CRM pipeline overview combining opportunities, pipeline stages, pipelines, companies and contacts. Business read model; portal access must be provided through an authorized CRM API/RPC contract.'
),

-- =====================================================
-- 004 PROPERTY / DEVICE
-- =====================================================

(
    'public',
    'v_devices_overview',
    'business',
    false,
    false,
    false,
    true,
    true,
    'Tenant-scoped device overview combining devices, categories, room assignments and properties. Business read model; portal access must be provided through an authorized API/RPC contract.'
),

-- =====================================================
-- 005 BOOKING / LOCK
-- =====================================================

(
    'public',
    'v_bookings_overview',
    'business',
    false,
    false,
    false,
    true,
    true,
    'Tenant-scoped booking overview including property, guest, booking access and credential status. Sensitive business data; not directly accessible by authenticated portal clients.'
),

-- =====================================================
-- 012 COMMERCE ENGINE
-- =====================================================

(
    'public',
    'v_subscription_overview',
    'business',
    false,
    false,
    false,
    true,
    true,
    'Tenant subscription overview combining subscription, tenant and product plan data. Business read model; portal access must be provided through an authorized API/RPC contract.'
),

-- =====================================================
-- 013 SERVICE PORTAL / ONBOARDING
-- =====================================================

(
    'public',
    'v_onboarding_lifecycle_overview',
    'business',
    false,
    false,
    false,
    true,
    true,
    'Tenant-scoped onboarding lifecycle overview including property, session, lifecycle state and transition information. Portal access must be provided through an authorized onboarding API/RPC contract.'
),

(
    'public',
    'v_onboarding_progress',
    'business',
    false,
    false,
    false,
    true,
    true,
    'Tenant-scoped onboarding progress projection combining session, lifecycle and step-state information. Portal read access must be provided through an authorized API/RPC contract.'
),

(
    'public',
    'v_properties_overview',
    'business',
    false,
    false,
    false,
    true,
    true,
    'Tenant-scoped property overview including room, device and onboarding summary information. Business read model; portal access must be provided through an authorized API/RPC contract.'
),

-- =====================================================
-- 017 AUTOMATION
-- =====================================================

(
    'public',
    'v_automation_runs_overview',
    'business',
    false,
    false,
    false,
    true,
    true,
    'Automation run overview including workflow, execution status, correlation and step completion information. Business operational read model; portal access must be provided through an authorized API/RPC contract.'
)

on conflict (view_schema, view_name)
do update set
    security_class = excluded.security_class,
    portal_access = excluded.portal_access,
    platform_admin_access = excluded.platform_admin_access,
    direct_authenticated_access = excluded.direct_authenticated_access,
    rls_required = excluded.rls_required,
    is_active = excluded.is_active,
    description = excluded.description;


-- =====================================================
-- =====================================================
-- 5. SECURITY REVIEW REGISTRY 
-- THIS IS TO ALLOW TABLES WITH 
-- SECURITY DEFINER + EXECUTE COMBINATION
-- =====================================================
-- =====================================================

create table if not exists platform.security_dynamic_sql_review (
    function_schema text not null,
    function_name text not null,
    identity_arguments text not null,

    review_status text not null
        check (review_status in (
            'approved',
            'rejected'
        )),

    reviewed_reason text not null,

    reviewed_at timestamptz not null default now(),

    primary key (
        function_schema,
        function_name,
        identity_arguments
    )
);

-- =====================================================
-- =====================================================
-- 6. SECURITY REVIEW REGISTRY SEED
-- =====================================================
-- =====================================================

insert into platform.security_dynamic_sql_review (
    function_schema,
    function_name,
    identity_arguments,
    review_status,
    reviewed_reason
)
values (
    'platform',
    'enable_realtime',
    'p_table regclass',
    'approved',
    'Dynamic identifier is supplied as regclass and used only for controlled realtime configuration.'
),
(
    'platform',
    'drop_old_log_partitions',
    'p_base_table text, p_retention interval',
    'approved',
    'Validated identifier, restricted to safe characters and used with %I for dynamic SQL.'
),
 (
    'platform',
    'create_monthly_partition',
    'base_table text, start_date date',
    'approved',
    'Identifiers use %I and date values use %L; no raw SQL fragments are interpolated.'
),
 (
    'public',
    'crm_soft_delete_row',
    'p_table regclass, p_id uuid',
    'approved',
    'Table is restricted to a fixed CRM allowlist; row values use parameterized USING.'
)

on conflict (
    function_schema,
    function_name,
    identity_arguments
) do nothing;


-- =====================================================
-- 7. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations ( migration_name, version, rollback_available)
values ( '020_security_classification', 'REV1', false)
on conflict (migration_name) do nothing;


commit;