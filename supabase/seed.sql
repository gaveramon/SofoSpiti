-- =====================================================
-- 004. DEVICE CATEGORY SEED
-- =====================================================

insert into public.device_categories
(
    code,
    name,
    is_gateway,
    is_lock,
    sort_order
)
values
    (
        'sensor',
        'Sensor',
        false,
        false,
        10
    ),
    (
        'switch',
        'Switch',
        false,
        false,
        20
    ),
    (
        'lock',
        'Lock',
        false,
        true,
        30
    ),
    (
        'thermostat',
        'Thermostat',
        false,
        false,
        40
    ),
    (
        'ir_controller',
        'IR Controller',
        false,
        false,
        50
    ),
    (
        'gateway',
        'Gateway',
        true,
        false,
        60
    ),
    (
        'other',
        'Other',
        false,
        false,
        99
    )

on conflict (code)
do update set
    name = excluded.name,
    is_gateway = excluded.is_gateway,
    is_lock = excluded.is_lock,
    sort_order = excluded.sort_order;





-- =====================================================
-- 007. PROVIDER AND CAPABILITY SEED DATA
-- =====================================================

insert into public.integration_providers (
    code,
    name,
    category,
    valid_from,
    supports_webhooks,
    supports_oauth
)
values
    ('aqara', 'Aqara', 'smarthome', '2026-01-01 00:00:00+00'::timestamptz, true, true),
    ('ttlock', 'TTLock', 'lock', '2026-01-01 00:00:00+00'::timestamptz, true, true),
    ('shelly', 'Shelly', 'smarthome', '2026-01-01 00:00:00+00'::timestamptz, true, true),
    ('beds24', 'Beds24', 'pms', '2026-01-01 00:00:00+00'::timestamptz, true, false),
    ('stripe', 'Stripe', 'payment', '2026-01-01 00:00:00+00'::timestamptz, true, true),
    ('vivawallet', 'Viva Wallet', 'payment', '2026-01-01 00:00:00+00'::timestamptz, true, true),
    ('zoho', 'Zoho', 'crm', '2026-01-01 00:00:00+00'::timestamptz, true, true),
    ('home_assistant', 'Home Assistant', 'smarthome', '2026-01-01 00:00:00+00'::timestamptz, true, false),
    ('generic', 'Generic', 'smarthome', '2026-01-01 00:00:00+00'::timestamptz, false, false),
    ('airbnb', 'Airbnb', 'ota', '2026-01-01 00:00:00+00'::timestamptz, true, true),
    ('booking', 'Booking.com', 'ota', '2026-01-01 00:00:00+00'::timestamptz, true, true),
    ('expedia', 'Expedia', 'ota', '2026-01-01 00:00:00+00'::timestamptz, true, true),
    ('pricelabs', 'PriceLabs', 'pricing', '2026-01-01 00:00:00+00'::timestamptz, true, false),
    ('hostaway', 'Hostaway', 'pms', '2026-01-01 00:00:00+00'::timestamptz, true, false),
    ('guesty', 'Guesty', 'pms', '2026-01-01 00:00:00+00'::timestamptz, true, false),
    ('smoobu', 'Smoobu', 'pms', '2026-01-01 00:00:00+00'::timestamptz, true, false),
    ('mailgun', 'Mailgun', 'email', '2026-01-01 00:00:00+00'::timestamptz, true, false),
    ('postmark', 'Postmark', 'email', '2026-01-01 00:00:00+00'::timestamptz, true, false),
    ('smtp', 'SMTP', 'email', '2026-01-01 00:00:00+00'::timestamptz, false, false),
    ('twilio', 'Twilio', 'sms', '2026-01-01 00:00:00+00'::timestamptz, true, false),
    ('whatsapp', 'WhatsApp', 'messaging', '2026-01-01 00:00:00+00'::timestamptz, true, true),
    ('firebase', 'Firebase', 'notification', '2026-01-01 00:00:00+00'::timestamptz, true, false),
    ('openai', 'OpenAI', 'ai', '2026-01-01 00:00:00+00'::timestamptz, false, false),
    ('openrouter', 'OpenRouter', 'ai', '2026-01-01 00:00:00+00'::timestamptz, false, false),
    ('anthropic', 'Anthropic', 'ai', '2026-01-01 00:00:00+00'::timestamptz, false, false)
on conflict (code)
do update set
    name = excluded.name,
    category = excluded.category,
    supports_webhooks = excluded.supports_webhooks,
    supports_oauth = excluded.supports_oauth,
    valid_from = excluded.valid_from,
    updated_at = now();



insert into public.integration_capabilities (
    provider_code,
    capability_code,
    is_supported
)
values
    ('aqara', 'send_command', true),
    ('aqara', 'receive_event', true),
    ('ttlock', 'send_command', true),
    ('ttlock', 'receive_event', true),
    ('ttlock', 'create_user', true),
    ('shelly', 'receive_event', true),
    ('beds24', 'sync_state', true),
    ('stripe', 'receive_event', true),
    ('zoho', 'send_command', true),
    ('home_assistant', 'sync_state', true),
    ('generic', 'send_command', true)
on conflict (provider_code, capability_code)
do nothing;


-- =====================================================
-- 007. WEBHOOK MAPPING SEED DATA
-- =====================================================

-- =====================================================
-- 9.1 AQARA WEBHOOK MAPPINGS
--
-- 007 Integration Engine
--
-- These mappings describe the Aqara message contract.
-- No provider-specific CASE logic is required in the
-- webhook processor.
-- =====================================================

insert into public.integration_webhook_mappings (
    provider_code,
    event_type,
    mapping_code,
    payload_path,
    value_type,
    is_required,
    is_active
)
values

    -- -------------------------------------------------
    -- Aqara device attribute messages
    -- -------------------------------------------------

    (
        'aqara',
        'resource_report',
        'provider_event_id',
        array['msgId'],
        'text',
        true,
        true
    ),

    (
        'aqara',
        'resource_report',
        'device_external_id',
        array['subjectId'],
        'text',
        true,
        true
    ),

    (
        'aqara',
        'resource_report',
        'observed_at',
        array['time'],
        'epoch_milliseconds',
        true,
        true
    ),

    -- -------------------------------------------------
    -- Aqara device control failure
    -- -------------------------------------------------

    (
        'aqara',
        'control_fail',
        'provider_event_id',
        array['msgId'],
        'text',
        true,
        true
    ),

    (
        'aqara',
        'control_fail',
        'device_external_id',
        array['subjectId'],
        'text',
        true,
        true
    ),

    (
        'aqara',
        'control_fail',
        'observed_at',
        array['time'],
        'epoch_milliseconds',
        true,
        true
    ),

    -- -------------------------------------------------
    -- Aqara device lifecycle events
    -- -------------------------------------------------

    (
        'aqara',
        'subdevice_online',
        'provider_event_id',
        array['msgId'],
        'text',
        true,
        true
    ),

    (
        'aqara',
        'subdevice_online',
        'device_external_id',
        array['did'],
        'text',
        true,
        true
    ),

    (
        'aqara',
        'subdevice_online',
        'observed_at',
        array['time'],
        'epoch_milliseconds',
        true,
        true
    ),

    (
        'aqara',
        'subdevice_offline',
        'provider_event_id',
        array['msgId'],
        'text',
        true,
        true
    ),

    (
        'aqara',
        'subdevice_offline',
        'device_external_id',
        array['did'],
        'text',
        true,
        true
    ),

    (
        'aqara',
        'subdevice_offline',
        'observed_at',
        array['time'],
        'epoch_milliseconds',
        true,
        true
    ),

    -- -------------------------------------------------
    -- Gateway lifecycle events
    -- -------------------------------------------------

    (
        'aqara',
        'gateway_online',
        'provider_event_id',
        array['msgId'],
        'text',
        true,
        true
    ),

    (
        'aqara',
        'gateway_online',
        'device_external_id',
        array['did'],
        'text',
        true,
        true
    ),

    (
        'aqara',
        'gateway_online',
        'observed_at',
        array['time'],
        'epoch_milliseconds',
        true,
        true
    ),

    (
        'aqara',
        'gateway_offline',
        'provider_event_id',
        array['msgId'],
        'text',
        true,
        true
    ),

    (
        'aqara',
        'gateway_offline',
        'device_external_id',
        array['did'],
        'text',
        true,
        true
    ),

    (
        'aqara',
        'gateway_offline',
        'observed_at',
        array['time'],
        'epoch_milliseconds',
        true,
        true
    )

on conflict (
    provider_code,
    event_type,
    mapping_code
)
do update set
    payload_path = excluded.payload_path,
    value_type = excluded.value_type,
    is_required = excluded.is_required,
    is_active = excluded.is_active,
    updated_at = now();

-- =====================================================
-- 9.2 SHELLY WEBHOOK MAPPINGS
--
-- 007 Integration Engine
--
-- Shelly webhook payloads use different paths and
-- timestamps than Aqara/TTLock.
-- =====================================================

insert into public.integration_webhook_mappings (
    provider_code,
    event_type,
    mapping_code,
    payload_path,
    value_type,
    is_required,
    is_active
)
values

    -- -------------------------------------------------
    -- Temperature
    -- -------------------------------------------------

    (
        'shelly',
        'temperature.change',
        'device_external_id',
        array['info','mac'],
        'text',
        true,
        true
    ),

    (
        'shelly',
        'temperature.change',
        'temperature',
        array['ev','tC'],
        'text',
        true,
        true
    ),

    -- -------------------------------------------------
    -- Humidity
    -- -------------------------------------------------

    (
        'shelly',
        'humidity.change',
        'device_external_id',
        array['info','mac'],
        'text',
        true,
        true
    ),

    (
        'shelly',
        'humidity.change',
        'humidity',
        array['ev','rh'],
        'text',
        true,
        true
    )

on conflict (
    provider_code,
    event_type,
    mapping_code
)
do update set
    payload_path = excluded.payload_path,
    value_type = excluded.value_type,
    is_required = excluded.is_required,
    is_active = excluded.is_active,
    updated_at = now();

-- =====================================================
-- 9.3 TTLOCK WEBHOOK / RECORD MAPPINGS
--
-- 007 Integration Engine
--
-- TTLock records are normally obtained through the
-- TTLock API rather than native push webhooks.
--
-- These mappings are intended for the normalized raw
-- event representation created by the TTLock integration
-- worker.
-- =====================================================

insert into public.integration_webhook_mappings (
    provider_code,
    event_type,
    mapping_code,
    payload_path,
    value_type,
    is_required,
    is_active
)
values

    -- -------------------------------------------------
    -- DEVICE
    -- -------------------------------------------------

    (
        'ttlock',
        'lock.record',
        'device_external_id',
        array['lockId'],
        'text',
        true,
        true
    ),

    -- -------------------------------------------------
    -- EVENT
    -- -------------------------------------------------

    (
        'ttlock',
        'lock.record',
        'record_type',
        array['recordType'],
        'text',
        true,
        true
    ),

    (
        'ttlock',
        'lock.record',
        'success',
        array['success'],
        'text',
        true,
        true
    ),

    -- -------------------------------------------------
    -- ACTOR
    -- -------------------------------------------------

    (
        'ttlock',
        'lock.record',
        'username',
        array['username'],
        'text',
        false,
        true
    ),

    -- -------------------------------------------------
    -- PASSCODE / CREDENTIAL
    -- -------------------------------------------------

    (
        'ttlock',
        'lock.record',
        'credential',
        array['keyboardPwd'],
        'text',
        false,
        true
    ),

    -- -------------------------------------------------
    -- EVENT TIMESTAMP
    --
    -- TTLock uses Unix epoch milliseconds.
    -- This becomes device_telemetry_raw.observed_at.
    -- -------------------------------------------------

    (
        'ttlock',
        'lock.record',
        'observed_at',
        array['lockDate'],
        'epoch_milliseconds',
        true,
        true
    ),

    -- -------------------------------------------------
    -- SERVER TIMESTAMP
    --
    -- Also Unix epoch milliseconds.
    -- -------------------------------------------------

    (
        'ttlock',
        'lock.record',
        'server_at',
        array['serverDate'],
        'epoch_milliseconds',
        false,
        true
    )

on conflict (
    provider_code,
    event_type,
    mapping_code
)
do update set
    payload_path = excluded.payload_path,
    value_type = excluded.value_type,
    is_required = excluded.is_required,
    is_active = excluded.is_active,
    updated_at = now();


-- =====================================================
-- INTEGRATION OAUTH CONFIGURATION SEED
-- =====================================================

insert into public.integration_oauth_configs (
    provider_code,
    authorization_url,
    token_url,
    default_scopes,
    response_type,
    grant_type,
    client_auth_method,
    pkce_required,
    pkce_method,
    redirect_uri_mode,
    is_active
)
values
(
    -- =================================================
    -- AQARA - EU
    -- =================================================
    'aqara',
    'https://open-ger.aqara.com/v3.0/open/authorize',
    'https://open-ger.aqara.com/v3.0/open/access_token',
    array[]::text[],
    'code',
    'authorization_code',
    'client_secret_post',
    false,
    null,
    'supabase_function',
    true
),
(
    -- =================================================
    -- SHELLY - CENTRAL OAUTH
    -- =================================================
    'shelly',
    'https://shelly.cloud',
    'https://shelly.cloud',
    array[]::text[],
    'code',
    'authorization_code',
    'client_secret_post',
    false,
    null,
    'supabase_function',
    true
),
(
    -- =================================================
    -- TTLOCK - RESOURCE OWNER PASSWORD CREDENTIALS
    -- =================================================
    'ttlock',
    null,
    '<TTLOCK_TOKEN_URL>',
    array[]::text[],
    'none',
    'password',
    'client_secret_post',
    false,
    null,
    'supabase_function',
    true
)
on conflict (provider_code)
do update
set
    authorization_url = excluded.authorization_url,
    token_url = excluded.token_url,
    default_scopes = excluded.default_scopes,
    response_type = excluded.response_type,
    grant_type = excluded.grant_type,
    client_auth_method = excluded.client_auth_method,
    pkce_required = excluded.pkce_required,
    pkce_method = excluded.pkce_method,
    redirect_uri_mode = excluded.redirect_uri_mode,
    is_active = excluded.is_active,
    updated_at = now();

-- =====================================================
-- 012 COMMERCE CATALOGUE (required reference data)
-- =====================================================
--
-- aDIT MOET WORDEN AANGEPAST IS TESTDATA!!!!!!!!!!
--
-- Run AFTER all migrations and BEFORE the first tenant is
-- created. The tenant trigger (012, provision_default_subscription)
-- fails with NO_DEFAULT_PRODUCT_PLAN when no default plan exists.
--
-- Contains: plans, feature entitlements. No prices, see
-- seed_commerce_pricing_example.sql.
--
-- Idempotent and non-destructive: existing rows are left
-- untouched, so changes made by a platform admin survive a re-run.
--
-- PRODUCTION: a plain `supabase db push` does NOT run seed files.
-- Run this file explicitly against production once.
--
-- Feature keys map to public.service_type through
-- platform.sync_service_activation_state():
--   auto_door_code       -> auto_door_code
--   energy_optimization  -> energy_optimization
--   energy_reports       -> energy_optimization (portal report gating)
--   security_monitoring  -> security_monitoring
--   managed_service      -> managed_service
-- The plan/feature split below is a PROPOSAL, adjust as needed.
-- =====================================================

insert into public.product_plans (name, description, tier, is_active, is_default)
values
    (
        'Basic',
        'Starter plan: automatic door codes.',
        'basic',
        true,
        true
    ),
    (
        'Pro',
        'Door codes, energy optimization and security monitoring.',
        'pro',
        true,
        false
    ),
    (
        'Enterprise',
        'Everything in Pro plus managed service.',
        'enterprise',
        true,
        false
    )
on conflict ((lower(name))) do nothing;


insert into public.feature_entitlements (plan_id, feature_key, enabled)
select
    pp.id,
    v.feature_key,
    true
from (
    values
        ('basic',      'auto_door_code'),

        ('pro',        'auto_door_code'),
        ('pro',        'energy_optimization'),
        ('pro',        'energy_reports'),
        ('pro',        'security_monitoring'),

        ('enterprise', 'auto_door_code'),
        ('enterprise', 'energy_optimization'),
        ('enterprise', 'energy_reports'),
        ('enterprise', 'security_monitoring'),
        ('enterprise', 'managed_service')
) as v(plan_name, feature_key)
join public.product_plans pp
  on lower(pp.name) = v.plan_name
on conflict (plan_id, feature_key) do nothing;


-- Sanity check: exactly one active default plan.
do $$
begin
    if (
        select count(*)
        from public.product_plans
        where is_default and is_active is true
    ) <> 1 then
        raise exception
            'seed_commerce: expected exactly one active default plan';
    end if;
end
$$;


-- =====================================================
-- EXAMPLE PRICING  --  DEVELOPMENT / TEST ONLY
-- =====================================================
--
-- !! THESE ARE EXAMPLE PRICES, NOT REAL ONES. !!
-- Do not run against production until the real prices are
-- filled in.
--
-- Safe default without this file: plans without a plan_pricing
-- row cannot be self-assigned through change_plan (PAYMENT_REQUIRED).
-- With this file every plan has a positive price, so all plan
-- changes must go through checkout.
-- =====================================================


insert into public.plan_pricing (plan_id, currency, monthly_price, yearly_price)
select
    pp.id,
    'EUR',
    v.monthly_price,
    v.yearly_price
from (
    values
        ('basic',      19.00,  190.00),
        ('pro',        49.00,  490.00),
        ('enterprise', 149.00, 1490.00)
) as v(plan_name, monthly_price, yearly_price)
join public.product_plans pp
  on lower(pp.name) = v.plan_name
on conflict (plan_id, currency) do nothing;
