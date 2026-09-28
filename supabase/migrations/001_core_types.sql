-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 001_CORE_TYPES.SQL
-- =====================================================
--
-- CORE TYPE SSOT
--
-- This migration contains:
--   - shared enum/type definitions
--   - no tables
--   - no data
--   - no business logic
--   - no RLS
--   - no grants
--   - no RPC/API contracts
--
-- 000_supabase_platform.sql MUST be applied before 001.
--
-- These types form the stable database/API vocabulary used
-- by subsequent domain migrations and RPC contracts.
--
-- ENUM EXPANSION RULES 
--   1. Never remove or rename labels after baseline deploy.
--   2. Append only:
--        alter type ... add value if not exists 'label';
--   3. Enum values are domain-local; never compare across
--      different enum types.
--   4. Platform execution states remain text in 000 unless
--      explicitly bound here.
--   5. Use domain-specific status enums; no global lifecycle enum.
--  
-- 001 is the single SSOT for all PostgreSQL enum/type definitions.
-- Domain migrations may reference these types but must not create
-- duplicate domain enums.
-- =====================================================


-- =====================================================
-- 1. TENANCY & PLATFORM CORE
-- =====================================================

create type public.tenant_status as enum (
    'active',
    'suspended',
    'deleted'
);


create type public.platform_event_type as enum (
    'onboarding.lifecycle.changed',
    'onboarding.step.updated',
    'device.provisioned',
    'device.assigned',
    'booking.created',
    'booking.started',
    'booking.ended',
    'booking.cancelled',
    'automation.run.started',
    'automation.run.completed',
    'subscription.created',
    'subscription.changed',
    'crm.lead.created',
    'crm.opportunity.stage_changed',
    'crm.contact.updated',
    'integration.connected',
    'logistics.shipped',
    'logistics.installed',
    'monetization.proposal.generated',
    'optimization.score.calculated'
);


create type public.operation_context_type as enum (
    'booking_event',
    'device_event',
    'manual_trigger',
    'system_event',
    'integration_event',
    'onboarding_event',
    'optimization_event',
    'monetization_event',
    'support_event'
);


create type public.priority_level as enum (
    'low',
    'normal',
    'high',
    'urgent',
    'critical'
);


-- =====================================================
-- 2. USER & ACCESS ROLES
-- =====================================================

create type public.membership_role as enum (
    'owner',
    'admin',
    'manager',
    'support',
    'viewer'
);


create type public.access_credential_status as enum (
    'pending',
    'active',
    'revoking',
    'revoked',
    'expired',
    'failed'
);


create type public.access_rule_type as enum (
    'check_in_window',
    'checkout_window',
    'override',
    'emergency_access'
);


create type public.access_type as enum (
    'guest',
    'owner',
    'temporary',
    'emergency',
    'scheduled'
);


-- =====================================================
-- 3. PROPERTY & STRUCTURE TYPES
-- =====================================================

create type public.property_type as enum (
    'apartment',
    'house',
    'villa',
    'hotel',
    'guesthouse',
    'studio',
    'hostel',
    'resort',
    'other'
);


create type public.room_type as enum (
    'living_room',
    'bedroom',
    'bathroom',
    'kitchen',
    'hallway',
    'outdoor',
    'office',
    'storage',
    'laundry',
    'garage',
    'toilet',
    'other'
);


-- =====================================================
-- 4. BOOKING DOMAIN TYPES
-- =====================================================

create type public.booking_status as enum (
    'pending',
    'confirmed',
    'checked_in',
    'checked_out',
    'cancelled'
);


-- =====================================================
-- 5. DEVICE PROTOCOL TYPES
-- =====================================================

create type public.device_protocol as enum (
    'zigbee',
    'wifi',
    'bluetooth',
    'infrared',
    'matter',
    'thread',
    'z_wave',
    'ethernet'
);


create type public.device_usage_score_category as enum (
    'efficiency',
    'usage',
    'energy',
    'reliability'
);


-- =====================================================
-- 6. INTEGRATION PROVIDER TYPES
-- =====================================================
--
-- Provider codes (aqara, stripe, …) live in the
-- integration provider catalog in the integration domain.
--
-- 001 defines only the provider CATEGORY vocabulary.
-- Provider records themselves are not defined here.
-- =====================================================

create type public.integration_provider_category as enum (
    'smarthome',
    'lock',
    'pms',
    'payment',
    'crm',
    'ota',
    'pricing',
    'email',
    'sms',
    'messaging',
    'notification',
    'ai'
);


-- =====================================================
-- 7. AUTOMATION & WORKFLOW TYPES
-- =====================================================

create type public.automation_action_type as enum (
    'send_notification',
    'update_device',
    'generate_code',
    'update_booking',
    'run_optimization',
    'trigger_webhook'
);


create type public.automation_run_status as enum (
    'pending',
    'running',
    'completed',
    'failed',
    'cancelled'
);


create type public.automation_step_status as enum (
    'pending',
    'running',
    'completed',
    'failed',
    'skipped'
);


create type public.automation_trigger_type as enum (
    'booking_created',
    'booking_started',
    'booking_ended',
    'device_added',
    'manual_trigger',
    'schedule_based'
);


-- =====================================================
-- 8. ONBOARDING TYPES
-- =====================================================

create type public.onboarding_lifecycle_state as enum (
    'created',
    'pre_onboarding',
    'configured',
    'devices_assigned',
    'shipped',
    'installed',
    'verified',
    'active'
);


create type public.onboarding_status as enum (
    'not_started',
    'in_progress',
    'waiting_user',
    'completed',
    'blocked'
);


create type public.onboarding_step_status as enum (
    'pending',
    'in_progress',
    'completed',
    'skipped',
    'blocked'
);


create type public.onboarding_step_type as enum (
    'wifi_setup',
    'device_assignment',
    'room_mapping',
    'integration_link',
    'testing',
    'finalization'
);


-- =====================================================
-- 9. OPERATIONS / NOTIFICATION TYPES
-- =====================================================

do $$
begin
    if not exists (
        select 1
        from pg_type
        where typnamespace = 'public'::regnamespace
          and typname = 'notification_channel'
    ) then
        create type public.notification_channel as enum (
            'email',
            'sms',
            'push',
            'portal'
        );
    end if;

    if not exists (
        select 1
        from pg_type
        where typnamespace = 'public'::regnamespace
          and typname = 'notification_delivery_status'
    ) then
        create type public.notification_delivery_status as enum (
            'queued',
            'processing',
            'sent',
            'failed',
            'cancelled'
        );
    end if;
end $$;


-- =====================================================
-- 10. CRM DOMAIN TYPES
-- =====================================================

create type public.crm_campaign_status as enum (
    'draft',
    'active',
    'paused',
    'completed',
    'cancelled'
);


create type public.crm_campaign_type as enum (
    'google_ads',
    'facebook',
    'referral',
    'partner',
    'email',
    'other'
);


create type public.crm_contact_status as enum (
    'active',
    'inactive',
    'archived',
    'unqualified'
);


create type public.crm_custom_field_type as enum (
    'text',
    'number',
    'boolean',
    'date',
    'datetime',
    'select',
    'multiselect'
);


create type public.crm_entity_type as enum (
    'lead',
    'opportunity',
    'contact',
    'company',
    'tenant'
);


create type public.crm_interaction_type as enum (
    'call',
    'email',
    'meeting',
    'portal',
    'sms',
    'whatsapp',
    'system'
);


create type public.crm_lead_status as enum (
    'new',
    'contacted',
    'qualified',
    'unqualified',
    'converted',
    'lost'
);


create type public.crm_lead_temperature as enum (
    'cold',
    'warm',
    'hot'
);


create type public.crm_list_type as enum (
    'static',
    'dynamic'
);


create type public.crm_opportunity_status as enum (
    'open',
    'won',
    'lost',
    'abandoned'
);


create type public.crm_task_status as enum (
    'pending',
    'in_progress',
    'completed',
    'cancelled'
);


create type public.crm_task_target_type as enum (
    'lead',
    'opportunity',
    'contact',
    'company',
    'tenant'
);


create type public.crm_terminal_outcome as enum (
    'won',
    'lost'
);


-- =====================================================
-- 11. SUPPORT / SERVICE STATES
-- =====================================================

create type public.support_sender_type as enum (
    'user',
    'support',
    'system'
);


create type public.support_ticket_status as enum (
    'open',
    'in_progress',
    'waiting_customer',
    'resolved',
    'closed'
);


create type public.service_activation_status as enum (
    'inactive',
    'pending',
    'active',
    'suspended',
    'cancelled',
    'failed'
);


create type public.service_type as enum (
    'managed_service',
    'auto_door_code',
    'energy_optimization',
    'security_monitoring'
);


-- =====================================================
-- 12. OPTIMIZATION TYPES
-- =====================================================

create type public.optimization_category as enum (
    'energy',
    'security',
    'cost',
    'efficiency',
    'performance',
    'user_experience'
);


create type public.optimization_insight_type as enum (
    'anomaly_detected',
    'optimization_opportunity',
    'usage_pattern'
);


create type public.optimization_recommendation_type as enum (
    'reduce_energy',
    'improve_security',
    'optimize_devices',
    'reduce_cost',
    'improve_efficiency',
    'improve_performance',
    'improve_user_experience'
);


create type public.recommendation_severity as enum (
    'low',
    'medium',
    'high'
);


create type public.recommendation_status as enum (
    'open',
    'acknowledged',
    'dismissed',
    'converted_to_proposal',
    'implemented'
);


-- =====================================================
-- 13. COMMERCE / SUBSCRIPTION TYPES
-- =====================================================

create type public.fulfilment_status as enum (
    'draft',
    'ready_to_ship',
    'dispatched',
    'delivered',
    'cancelled'
);


create type public.package_type as enum (
    'hardware',
    'service',
    'hybrid'
);


create type public.payment_status as enum (
    'pending',
    'authorized',
    'paid',
    'failed',
    'refunded',
    'cancelled',
    'partially_refunded',
    'charged_back'
);


create type public.subscription_status as enum (
    'trial',
    'pending',
    'active',
    'past_due',
    'suspended',
    'cancelled',
    'expired',
    'trial_expired'
);


create type public.subscription_tier as enum (
    'basic',
    'pro',
    'enterprise'
);


-- =====================================================
-- 14. PROPOSAL / MONETIZATION TYPES
-- =====================================================

create type public.conversion_event_type as enum (
    'view_proposal',
    'add_item',
    'remove_item',
    'checkout_start',
    'checkout_complete',
    'upsell_clicked',
    'proposal_accepted',
    'proposal_rejected'
);


create type public.proposal_item_type as enum (
    'device_package',
    'subscription',
    'service'
);


create type public.proposal_status as enum (
    'draft',
    'presented',
    'accepted',
    'rejected',
    'expired'
);


-- =====================================================
-- 15. UPSELL / MONETIZATION TRIGGERS
-- =====================================================
--
-- Do not compare or cast across these enum types.
-- =====================================================

create type public.upsell_package_trigger as enum (
    'onboarding_completed',
    'device_added',
    'booking_created',
    'usage_threshold',
    'manual_review'
);

create type public.upsell_plan_trigger as enum (
    'onboarding_completed',
    'device_added',
    'booking_created',
    'usage_threshold',
    'manual_review'
);

-- =====================================================
-- PLATFORM ENUM BINDS
-- =====================================================
--
-- 000_supabase_platform.sql MUST exist before this call.
--
-- This binds the newly-created core enum to the existing
-- platform operation-context column contract.
--
-- No new business logic is introduced here.
-- =====================================================

select platform.bind_operation_context_type_column();


-- =====================================================
-- MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations ( migration_name, version, rollback_available)
values ('001_core_types', 'REV1', false)
on conflict (version) do nothing;


-- =====================================================
-- END 001 CORE TYPES (SSOT COMPLETE)
-- =====================================================