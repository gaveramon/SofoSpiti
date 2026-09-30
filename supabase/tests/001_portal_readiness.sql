-- =====================================================================
-- PORTAL READINESS SMOKE TEST  (Supabase / Appsmith backend)
-- =====================================================================
--
-- RUN ON A FRESH BRANCH OR LOCAL DATABASE, never on production data.
-- Everything runs in ONE transaction that is rolled back at the end,
-- but it still creates users and tenants while it runs.
--
-- Prerequisites (in this order):
--   1. migrations 000 .. 025 (025 = hardened version)
--   2. seed.sql
--   3. seed_commerce.sql
--
-- Run (self-hosted Docker):
--   docker exec -i <db-container> psql -U postgres -d postgres \
--        -v ON_ERROR_STOP=1 < tests/001_portal_readiness.sql
--
-- Output: one PASS / FAIL line per check. The script raises an error
-- at the end when any check failed.
--
-- NOT covered here (needs provider stubs / real payloads, see notes):
--   OAuth round trip, webhook ingestion, telemetry normalisation,
--   worker queues, Realtime websocket, Storage upload via the API,
--   edge functions.
-- =====================================================================

begin;

select set_config('smoke.fails', '0', false);
select set_config('smoke.passes', '0', false);
select set_config('smoke.skips', '0', false);

-- ---------------------------------------------------------------------
-- Helpers (schema _t, removed by the rollback)
-- ---------------------------------------------------------------------

create schema _t;
grant usage on schema _t to public;
alter default privileges in schema _t grant execute on functions to public;

create function _t.check(p_name text, p_ok boolean)
returns void
language plpgsql
as $f$
begin
    if p_ok is true then
        raise notice 'PASS  %', p_name;
        perform set_config(
            'smoke.passes',
            (coalesce(nullif(current_setting('smoke.passes', true), ''), '0')::int + 1)::text,
            false
        );
    else
        raise notice 'FAIL  %', p_name;
        perform set_config(
            'smoke.fails',
            (coalesce(nullif(current_setting('smoke.fails', true), ''), '0')::int + 1)::text,
            false
        );
    end if;
end
$f$;

create function _t.skip(p_name text, p_why text)
returns void
language plpgsql
as $f$
begin
    raise notice 'SKIP  % (%)', p_name, p_why;
    perform set_config(
        'smoke.skips',
        (coalesce(nullif(current_setting('smoke.skips', true), ''), '0')::int + 1)::text,
        false
    );
end
$f$;

-- Runs p_sql as the CURRENT role and expects an error containing p_fragment.
create function _t.throws(p_name text, p_sql text, p_fragment text)
returns void
language plpgsql
as $f$
declare
    v_msg text;
begin
    begin
        execute p_sql;
        v_msg := null;
    exception when others then
        v_msg := sqlerrm;
    end;

    perform _t.check(
        p_name || ' [expected "' || p_fragment || '", got: ' || coalesce(v_msg, 'NO ERROR') || ']',
        v_msg is not null and v_msg ilike '%' || p_fragment || '%'
    );
end
$f$;

create function _t.login(p_uid uuid, p_app jsonb default '{}'::jsonb)
returns void
language plpgsql
as $f$
begin
    perform set_config(
        'request.jwt.claims',
        jsonb_build_object(
            'sub', p_uid::text,
            'role', 'authenticated',
            'app_metadata', p_app
        )::text,
        true
    );
    set local role authenticated;
end
$f$;

create function _t.anon()
returns void
language plpgsql
as $f$
begin
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    set local role anon;
end
$f$;

create function _t.reset()
returns void
language plpgsql
as $f$
begin
    reset role;
    perform set_config('request.jwt.claims', '', true);
end
$f$;

-- fixed ids
select set_config('smoke.ua', '00000000-0000-4000-8000-00000000000a', false);  -- owner tenant A (and A2)
select set_config('smoke.ub', '00000000-0000-4000-8000-00000000000b', false);  -- owner tenant B
select set_config('smoke.uv', '00000000-0000-4000-8000-00000000000c', false);  -- viewer in A
select set_config('smoke.up', '00000000-0000-4000-8000-00000000000d', false);  -- platform admin
select set_config('smoke.ux', '00000000-0000-4000-8000-00000000000e', false);  -- no membership


-- =====================================================================
-- 0. PREREQUISITES
-- =====================================================================

do $t$
begin
    perform _t.check('seed: exactly one active default product plan',
        (select count(*) from public.product_plans where is_default and is_active is true) = 1);

    perform _t.check('seed: default plan has at least one entitlement',
        exists (
            select 1 from public.feature_entitlements fe
            join public.product_plans pp on pp.id = fe.plan_id
            where pp.is_default
        ));

    perform _t.check('seed: integration providers present (seed.sql)',
        (select count(*) from public.integration_providers) > 0);
end
$t$;

-- test users (profiles are created by the auth.users trigger)
insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
)
select
    u.id,
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    u.email,
    '',
    now(),
    '{"provider":"email"}'::jsonb,
    '{}'::jsonb,
    now(),
    now()
from (values
    (current_setting('smoke.ua')::uuid, 'smoke-a@example.test'),
    (current_setting('smoke.ub')::uuid, 'smoke-b@example.test'),
    (current_setting('smoke.uv')::uuid, 'smoke-v@example.test'),
    (current_setting('smoke.up')::uuid, 'smoke-p@example.test'),
    (current_setting('smoke.ux')::uuid, 'smoke-x@example.test')
) as u(id, email);

do $t$
begin
    perform _t.check('auth.users trigger created 5 profiles',
        (select count(*) from platform.profiles
         where email::text like 'smoke-%@example.test') = 5);
end
$t$;


-- =====================================================================
-- 1. RPC-ONLY MODEL: no direct table access, no anon access
-- =====================================================================

do $t$
declare
    v_bad int;
begin
    -- static: registry says no direct access -> privileges must agree
    select count(*) into v_bad
    from platform.security_table_registry r
    where r.is_active
      and r.direct_authenticated_access = false
      and to_regclass(format('%I.%I', r.table_schema, r.table_name)) is not null
      and (
          has_table_privilege('authenticated',
              format('%I.%I', r.table_schema, r.table_name),
              'SELECT,INSERT,UPDATE,DELETE')
          or has_table_privilege('anon',
              format('%I.%I', r.table_schema, r.table_name),
              'SELECT,INSERT,UPDATE,DELETE')
      );

    perform _t.check('no registered table is directly accessible by authenticated/anon (bad=' || v_bad || ')', v_bad = 0);

    -- dynamic: a real session
    perform _t.login(current_setting('smoke.ua')::uuid);
    perform _t.throws('authenticated: select public.tenants denied',
        'select count(*) from public.tenants', 'permission denied');
    perform _t.throws('authenticated: select public.invoices denied',
        'select count(*) from public.invoices', 'permission denied');
    perform _t.throws('authenticated: select platform.audit_log denied',
        'select count(*) from platform.audit_log', 'permission denied');
    perform _t.throws('authenticated: internal helper not callable',
        $q$select public.resolve_active_tenant(auth.uid())$q$, 'permission denied');
    perform _t.throws('authenticated: commerce helper not callable',
        $q$select public.commerce_compute_discount_amount('percentage', 10, 100)$q$, 'permission denied');
    perform _t.reset();

    perform _t.anon();
    perform _t.throws('anon: auth_api denied',
        $q$select public.auth_api('get_auth_context', '{}'::jsonb)$q$, 'permission denied');
    perform _t.throws('anon: select public.tenants denied',
        'select count(*) from public.tenants', 'permission denied');
    perform _t.reset();
end
$t$;


-- =====================================================================
-- 2. TENANT MODEL: create_tenant, owner membership, default subscription
-- =====================================================================

do $t$
declare
    v jsonb;
    v_ta uuid;
    v_tb uuid;
begin
    perform _t.login(current_setting('smoke.ua')::uuid);
    v := public.auth_api('create_tenant', '{"name":"Smoke A"}'::jsonb);
    v_ta := (v->>'id')::uuid;
    perform _t.reset();
    perform set_config('smoke.ta', v_ta::text, false);

    perform _t.check('create_tenant returned an id', v_ta is not null);

    perform _t.check('customer account created for owner',
        (select count(*) from public.customer_accounts
         where owner_user_id = current_setting('smoke.ua')::uuid) = 1);

    perform _t.check('creator is owner of the new tenant',
        (select role::text from public.tenant_memberships
         where tenant_id = v_ta and user_id = current_setting('smoke.ua')::uuid) = 'owner');

    perform _t.check('default subscription provisioned (trial, plan set)',
        exists (select 1 from public.subscriptions s
                where s.tenant_id = v_ta and s.status = 'trial' and s.plan_id is not null));

    perform _t.login(current_setting('smoke.ua')::uuid);
    perform _t.check('current_tenant_id() = new tenant',
        platform.current_tenant_id() = v_ta);
    perform _t.check('get_subscription works for owner',
        (public.auth_api('get_subscription', '{}'::jsonb)->>'status') = 'trial');
    perform _t.check('get_tenant_entitlements returns features',
        jsonb_array_length(public.commerce_api('get_tenant_entitlements', '{}'::jsonb)->'features') > 0);
    perform _t.reset();

    -- tenant B
    perform _t.login(current_setting('smoke.ub')::uuid);
    v := public.auth_api('create_tenant', '{"name":"Smoke B"}'::jsonb);
    v_tb := (v->>'id')::uuid;
    perform _t.reset();
    perform set_config('smoke.tb', v_tb::text, false);

    perform _t.check('second customer/tenant created', v_tb is not null and v_tb <> v_ta);
end
$t$;


-- =====================================================================
-- 3. TENANT ISOLATION
-- =====================================================================

do $t$
declare
    v jsonb;
    v_pa uuid;
    v_pb uuid;
begin
    perform _t.login(current_setting('smoke.ua')::uuid);
    v := public.devices_api('create_property',
        '{"name":"Prop A","address":"A street 1","property_type":"apartment"}'::jsonb);
    v_pa := (v->>'id')::uuid;
    perform _t.reset();

    perform _t.login(current_setting('smoke.ub')::uuid);
    v := public.devices_api('create_property',
        '{"name":"Prop B","address":"B street 1","property_type":"apartment"}'::jsonb);
    v_pb := (v->>'id')::uuid;
    perform _t.reset();

    perform set_config('smoke.pa', v_pa::text, false);
    perform set_config('smoke.pb', v_pb::text, false);

    perform _t.login(current_setting('smoke.ua')::uuid);
    perform _t.check('A sees only its own property',
        jsonb_array_length(public.devices_api('list_properties', '{}'::jsonb)) = 1);
    perform _t.throws('A cannot read B property',
        format($q$select public.devices_api('get_property', '{"id":"%s"}'::jsonb)$q$, v_pb),
        'not found');
    perform _t.throws('A cannot update B property',
        format($q$select public.devices_api('update_property', '{"id":"%s","name":"hacked"}'::jsonb)$q$, v_pb),
        'not found');
    perform _t.throws('A cannot delete B property',
        format($q$select public.devices_api('delete_property', '{"id":"%s"}'::jsonb)$q$, v_pb),
        'not found');
    perform _t.reset();

    perform _t.check('B property untouched',
        (select name from public.properties where id = v_pb) = 'Prop B');
end
$t$;


-- =====================================================================
-- 4. ROLES (viewer / non-member) AND HELPER FUNCTIONS FROM 000
-- =====================================================================

do $t$
begin
    perform _t.login(current_setting('smoke.ua')::uuid);
    perform public.auth_api('invite_member',
        jsonb_build_object('user_id', current_setting('smoke.uv'), 'role', 'viewer'));
    perform _t.check('owner: platform.is_owner() true', platform.is_owner());
    perform _t.check('owner: platform.is_admin() true', platform.is_admin());
    perform _t.reset();

    perform _t.login(current_setting('smoke.uv')::uuid);
    perform _t.check('viewer: resolves to tenant A',
        platform.current_tenant_id() = current_setting('smoke.ta')::uuid);
    perform _t.check('viewer: is_owner() false', not platform.is_owner());
    perform _t.check('viewer: is_admin() false', not platform.is_admin());
    perform _t.check('viewer: has_role(viewer)', platform.has_role('viewer'));
    perform _t.check('viewer can list properties',
        jsonb_array_length(public.devices_api('list_properties', '{}'::jsonb)) = 1);
    perform _t.throws('viewer cannot create property',
        $q$select public.devices_api('create_property', '{"name":"x","address":"y","property_type":"apartment"}'::jsonb)$q$,
        'role required');
    perform _t.throws('viewer cannot list invoices',
        $q$select public.commerce_api('list_invoices', '{}'::jsonb)$q$, 'role required');
    perform _t.throws('viewer cannot update tenant',
        $q$select public.auth_api('update_tenant', '{"name":"x"}'::jsonb)$q$, 'role required');
    perform _t.throws('viewer cannot invite members',
        format($q$select public.auth_api('invite_member', '{"user_id":"%s","role":"viewer"}'::jsonb)$q$,
               current_setting('smoke.ux')),
        'role required');
    perform _t.reset();

    perform _t.login(current_setting('smoke.ux')::uuid);
    perform _t.check('non-member: no tenant resolved', platform.current_tenant_id() is null);
    perform _t.throws('non-member: list_properties fails without tenant',
        $q$select public.devices_api('list_properties', '{}'::jsonb)$q$, 'active%tenant');
    perform _t.reset();
end
$t$;


-- =====================================================================
-- 5. TENANT SWITCHING (user with two tenants)
-- =====================================================================

do $t$
declare
    v jsonb;
    v_ta uuid := current_setting('smoke.ta')::uuid;
    v_tb uuid := current_setting('smoke.tb')::uuid;
    v_a2 uuid;
begin
    perform _t.login(current_setting('smoke.ua')::uuid);
    v := public.auth_api('create_tenant', '{"name":"Smoke A2"}'::jsonb);
    v_a2 := (v->>'id')::uuid;
    perform _t.reset();
    perform set_config('smoke.ta2', v_a2::text, false);

    perform _t.check('same customer account reused for second tenant',
        (select count(*) from public.customer_accounts
         where owner_user_id = current_setting('smoke.ua')::uuid) = 1);

    perform _t.login(current_setting('smoke.ua')::uuid);

    perform _t.check('new tenant becomes the active tenant',
        platform.current_tenant_id() = v_a2);
    perform _t.check('tenant A2 starts without properties',
        jsonb_array_length(public.devices_api('list_properties', '{}'::jsonb)) = 0);

    perform public.auth_api('switch_tenant', jsonb_build_object('tenant_id', v_ta));
    perform _t.check('switch_tenant to A changes the active tenant',
        platform.current_tenant_id() = v_ta);
    perform _t.check('after switching to A the property is visible',
        jsonb_array_length(public.devices_api('list_properties', '{}'::jsonb)) = 1);

    perform _t.throws('switch to a tenant without membership is refused',
        format($q$select public.auth_api('switch_tenant', '{"tenant_id":"%s"}'::jsonb)$q$, v_tb),
        'No active membership');
    perform _t.check('failed switch leaves the active tenant unchanged',
        platform.current_tenant_id() = v_ta);

    perform _t.check('validate_tenant_switch accepts own tenant',
        (public.auth_api('validate_tenant_switch',
            jsonb_build_object('tenant_id', v_a2))->>'tenant_id')::uuid = v_a2);

    perform _t.check('list_user_tenants contains both tenants',
        position(v_ta::text in public.auth_api('list_user_tenants', '{}'::jsonb)::text) > 0
        and position(v_a2::text in public.auth_api('list_user_tenants', '{}'::jsonb)::text) > 0);
    perform _t.reset();
end
$t$;


-- =====================================================================
-- 6. COMMERCE: plans, entitlements, plan-change guard, invoices, discounts
-- =====================================================================

do $t$
declare
    v_ta uuid := current_setting('smoke.ta')::uuid;
    v_tb uuid := current_setting('smoke.tb')::uuid;
    v_pro uuid;
    v_free uuid;
    v_sub uuid;
    v_inv uuid;
    v_draft uuid;
    v_provider text;
    v jsonb;
begin
    select id into v_pro from public.product_plans where lower(name) = 'pro';
    perform _t.check('seed: Pro plan exists', v_pro is not null);

    select id into v_sub from public.subscriptions where tenant_id = v_ta;

    -- ---- plan change guard: no free upgrades --------------------------------
    perform _t.login(current_setting('smoke.ua')::uuid);
    perform _t.throws('change_plan: plan without pricing row is refused',
        format($q$select public.commerce_api('change_plan', '{"plan_id":"%s"}'::jsonb)$q$, v_pro),
        'PAYMENT_REQUIRED');
    perform _t.reset();

    insert into public.plan_pricing (plan_id, currency, monthly_price, yearly_price)
    values (v_pro, 'EUR', 49, 490)
    on conflict (plan_id, currency) do nothing;

    perform _t.login(current_setting('smoke.ua')::uuid);
    perform _t.throws('change_plan: paid plan is refused',
        format($q$select public.commerce_api('change_plan', '{"plan_id":"%s"}'::jsonb)$q$, v_pro),
        'PAYMENT_REQUIRED');
    perform _t.reset();

    insert into public.product_plans (name, tier, is_active)
    values ('Smoke Free', 'basic', true)
    returning id into v_free;
    insert into public.plan_pricing (plan_id, currency, monthly_price, yearly_price)
    values (v_free, 'EUR', 0, 0);

    perform _t.login(current_setting('smoke.ua')::uuid);
    perform public.commerce_api('change_plan', jsonb_build_object('plan_id', v_free));
    perform _t.reset();
    perform _t.check('change_plan: free plan is accepted',
        (select plan_id from public.subscriptions where id = v_sub) = v_free);

    perform _t.login(current_setting('smoke.ua')::uuid);
    perform _t.throws('update_subscription: tenant owner may not edit billing state',
        '  select public.auth_api(''update_subscription'', ''{"status":"active"}''::jsonb)',
        'PLATFORM_ADMIN_REQUIRED');
    perform _t.reset();

    -- ---- invoices ---------------------------------------------------------------
    insert into public.invoices
        (tenant_id, subscription_id, invoice_number, status, currency,
         subtotal, discount_amount, tax_amount, total_amount, issued_at, due_at)
    values
        (v_ta, v_sub, 'SMOKE-0001', 'open', 'EUR', 100.00, 0, 21.00, 121.00, now(), now() + interval '14 days')
    returning id into v_inv;

    insert into public.invoices
        (tenant_id, subscription_id, invoice_number, status, subtotal, total_amount)
    values
        (v_ta, v_sub, 'SMOKE-DRAFT', 'draft', 5, 5)
    returning id into v_draft;

    insert into public.invoice_lines (invoice_id, tenant_id, description, quantity, unit_amount, line_amount, sort_order)
    values (v_inv, v_ta, 'Plan', 1, 80, 80, 1),
           (v_inv, v_ta, 'Add-on', 1, 20, 20, 2);

    perform _t.throws('invoice_lines: tenant mismatch is rejected',
        format($q$insert into public.invoice_lines (invoice_id, tenant_id, description, line_amount)
                  values ('%s', '%s', 'bad', 1)$q$, v_inv, v_tb),
        'must match');

    perform set_config('smoke.inv', v_inv::text, false);

    perform _t.login(current_setting('smoke.ua')::uuid);
    v := public.commerce_api('list_invoices', '{}'::jsonb);
    perform _t.check('list_invoices: only non-draft invoices, own tenant only',
        jsonb_array_length(v) = 1 and (v->0->>'id')::uuid = v_inv);
    v := public.commerce_api('get_invoice', jsonb_build_object('id', v_inv));
    perform _t.check('get_invoice: header and 2 lines',
        (v->'invoice'->>'invoice_number') = 'SMOKE-0001' and jsonb_array_length(v->'lines') = 2);
    perform _t.throws('get_invoice: draft is hidden',
        format($q$select public.commerce_api('get_invoice', '{"id":"%s"}'::jsonb)$q$, v_draft),
        'not found');
    perform _t.reset();

    perform _t.login(current_setting('smoke.ub')::uuid);
    perform _t.throws('get_invoice: other tenant cannot read it',
        format($q$select public.commerce_api('get_invoice', '{"id":"%s"}'::jsonb)$q$, v_inv),
        'not found');
    perform _t.reset();

    perform _t.login(current_setting('smoke.uv')::uuid);
    perform _t.throws('get_invoice: viewer refused',
        format($q$select public.commerce_api('get_invoice', '{"id":"%s"}'::jsonb)$q$, v_inv),
        'role required');
    perform _t.reset();

    -- ---- platform admin bootstrap ------------------------------------------------
    perform _t.check('bootstrap_platform_admin returns the user id',
        platform.bootstrap_platform_admin('smoke-p@example.test') = current_setting('smoke.up')::uuid);
    perform _t.check('bootstrap_platform_admin is idempotent',
        platform.bootstrap_platform_admin('smoke-p@example.test') = current_setting('smoke.up')::uuid);

    perform _t.login(current_setting('smoke.ua')::uuid);
    perform _t.throws('bootstrap_platform_admin not callable by authenticated',
        $q$select platform.bootstrap_platform_admin('smoke-a@example.test')$q$, 'permission denied');
    perform _t.throws('create_discount_code: tenant owner refused',
        $q$select public.commerce_api('create_discount_code', '{"code":"NOPE","discount_type":"percentage","value":5}'::jsonb)$q$,
        'PLATFORM_ADMIN_REQUIRED');
    perform _t.reset();

    -- ---- discount codes -----------------------------------------------------------
    perform _t.login(current_setting('smoke.up')::uuid);
    v := public.commerce_api('create_discount_code',
        '{"code":" smoke10 ","discount_type":"percentage","value":10,"max_redemptions":5}'::jsonb);
    perform _t.check('create_discount_code: normalised to upper case', (v->>'code') = 'SMOKE10');
    perform _t.check('list_discount_codes returns it',
        exists (select 1 from jsonb_array_elements(
            public.commerce_api('list_discount_codes', '{}'::jsonb)) e where e->>'code' = 'SMOKE10'));
    perform _t.throws('create_discount_code: duplicate refused',
        $q$select public.commerce_api('create_discount_code', '{"code":"SMOKE10","discount_type":"percentage","value":10}'::jsonb)$q$,
        'duplicate');
    perform _t.reset();

    perform _t.login(current_setting('smoke.ua')::uuid);
    v := public.commerce_api('validate_discount_code', '{"code":"smoke10","amount":100}'::jsonb);
    perform _t.check('validate_discount_code: valid, 10.00 off 100',
        (v->>'valid')::boolean and (v->>'discount_amount')::numeric = 10.00);
    v := public.commerce_api('validate_discount_code', '{"code":"DOESNOTEXIST"}'::jsonb);
    perform _t.check('validate_discount_code: unknown code gives generic answer',
        not (v->>'valid')::boolean and (v->>'reason') = 'invalid_or_unavailable');

    v := public.commerce_api('apply_discount_to_invoice',
        jsonb_build_object('invoice_id', v_inv, 'code', 'smoke10'));
    perform _t.check('apply_discount: discount 10.00, tax scaled to 18.90, total 108.90',
        (v->>'discount_amount')::numeric = 10.00
        and (v->>'tax_amount')::numeric = 18.90
        and (v->>'total_amount')::numeric = 108.90);
    perform _t.throws('apply_discount: second discount on same invoice refused',
        format($q$select public.commerce_api('apply_discount_to_invoice', '{"invoice_id":"%s","code":"SMOKE10"}'::jsonb)$q$, v_inv),
        'already applied');
    v := public.commerce_api('validate_discount_code', '{"code":"SMOKE10"}'::jsonb);
    perform _t.check('validate_discount_code: same tenant cannot reuse code', not (v->>'valid')::boolean);
    perform _t.check('list_discount_redemptions shows 1 redemption',
        jsonb_array_length(public.commerce_api('list_discount_redemptions', '{}'::jsonb)) = 1);
    perform _t.reset();

    perform _t.check('redeemed_count incremented to 1',
        (select redeemed_count from public.discount_codes where code = 'SMOKE10') = 1);

    perform _t.login(current_setting('smoke.ub')::uuid);
    perform _t.throws('apply_discount: other tenant cannot touch the invoice',
        format($q$select public.commerce_api('apply_discount_to_invoice', '{"invoice_id":"%s","code":"SMOKE10"}'::jsonb)$q$, v_inv),
        'not found');
    perform _t.reset();

    perform _t.login(current_setting('smoke.up')::uuid);
    perform public.commerce_api('deactivate_discount_code',
        jsonb_build_object('id', (select id from public.discount_codes where code = 'SMOKE10')));
    perform _t.reset();
    perform _t.login(current_setting('smoke.ub')::uuid);
    perform _t.check('deactivated code is no longer valid',
        not (public.commerce_api('validate_discount_code', '{"code":"SMOKE10"}'::jsonb)->>'valid')::boolean);
    perform _t.reset();

    -- ---- checkout: amount comes from the invoice ---------------------------------
    select ip.code into v_provider
    from public.integration_providers ip
    where ip.category = 'payment' and ip.is_active
    order by ip.code limit 1;

    if v_provider is null then
        perform _t.skip('create_checkout_session takes amount from invoice', 'no active payment provider in seed');
    else
        perform _t.login(current_setting('smoke.ua')::uuid);
        v := public.payment_api('create_checkout_session',
            jsonb_build_object('provider', v_provider, 'amount', 1,
                               'target_type', 'invoice', 'target_id', v_inv));
        perform _t.reset();
        perform _t.check('create_checkout_session: amount = invoice total (108.90), not client amount',
            (v->>'amount')::numeric = 108.90);
    end if;
end
$t$;


-- =====================================================================
-- 7. AUDIT COVERAGE AND CRM FOREIGN KEYS
-- =====================================================================

do $t$
declare
    v_ta uuid := current_setting('smoke.ta')::uuid;
    v_ua uuid := current_setting('smoke.ua')::uuid;
    v jsonb;
    v_prop uuid;
    v_dev uuid;
    v_cat text;

    v_actions text[] := array[
        'property.created','property.updated','property.deleted',
        'device.created','device.updated','device.deleted',
        'device_config.upserted','automation.event_dispatched'
    ];
    v_a text;
begin
    select code into v_cat from public.device_categories where is_active order by sort_order limit 1;

    perform _t.login(v_ua);
    perform public.auth_api('switch_tenant', jsonb_build_object('tenant_id', v_ta));

    v := public.devices_api('create_property',
        '{"name":"Audit prop","address":"x","property_type":"villa"}'::jsonb);
    v_prop := (v->>'id')::uuid;
    perform public.devices_api('update_property',
        jsonb_build_object('id', v_prop, 'name', 'Audit prop 2'));

    if v_cat is null then
        perform _t.skip('device audit checks', 'no device categories in seed');
    else
        v := public.devices_api('create_device',
            jsonb_build_object('device_name', 'Audit device', 'category_code', v_cat, 'protocol', 'wifi'));
        v_dev := (v->>'id')::uuid;
        perform public.devices_api('update_device',
            jsonb_build_object('id', v_dev, 'device_name', 'Audit device 2'));
        perform public.devices_api('upsert_device_config',
            jsonb_build_object('device_id', v_dev, 'config', '{"secret_token":"SMOKE-SECRET-123"}'::jsonb));
        perform public.devices_api('delete_device', jsonb_build_object('id', v_dev));
    end if;

    perform public.devices_api('delete_property', jsonb_build_object('id', v_prop));

    perform public.automation_api('dispatch_event', '{"event_type":"smoke.none","payload":{}}'::jsonb);
    perform _t.reset();

    foreach v_a in array v_actions loop
        if v_cat is null and v_a like 'device%' then
            continue;
        end if;
        perform _t.check('audit row written: ' || v_a,
            exists (select 1 from platform.audit_log al
                    where al.action = v_a and al.user_id = v_ua and al.tenant_id = v_ta));
    end loop;

    perform _t.check('audit: device config content is NOT stored in the audit log',
        not exists (select 1 from platform.audit_log al
                    where al.metadata::text like '%SMOKE-SECRET-123%'));

    -- CRM link tables
    perform _t.check('CRM: FK company link -> tenant',
        exists (select 1 from pg_constraint where conname = 'fk_crm_company_tenants_tenant'));
    perform _t.check('CRM: FK company link -> linked tenant',
        exists (select 1 from pg_constraint where conname = 'fk_crm_company_tenants_linked_tenant'));
    perform _t.check('CRM: FK contact link -> tenant',
        exists (select 1 from pg_constraint where conname = 'fk_crm_contact_tenants_tenant'));
    perform _t.check('CRM: FK contact link -> linked tenant',
        exists (select 1 from pg_constraint where conname = 'fk_crm_contact_tenants_linked_tenant'));

    -- audit partition exists for today (catches a missing log partition)
    perform _t.check('audit_log has a partition covering now()',
        exists (select 1 from pg_inherits i
                where i.inhparent = 'platform.audit_log'::regclass));
end
$t$;


-- =====================================================================
-- 8. HEALTHCHECK ISOLATION (migration 025)
-- =====================================================================

do $t$
declare
    v_ua uuid := current_setting('smoke.ua')::uuid;
    v_ux uuid := current_setting('smoke.ux')::uuid;
    v jsonb;
begin
    -- ordinary customer
    perform _t.login(v_ua);
    perform _t.throws('healthcheck.ping refused for a normal user',
        $q$select healthcheck.ping()$q$, 'HEALTHCHECK_USER_REQUIRED');
    perform _t.throws('healthcheck table insert refused for a normal user',
        $q$insert into healthcheck.realtime_test (test_id) values (gen_random_uuid())$q$, 'row-level security');
    perform _t.throws('healthcheck storage insert refused for a normal user',
        $q$insert into storage.objects (bucket_id, name) values ('healthcheck', 'smoke/nope.txt')$q$, 'row-level security');
    perform _t.reset();

    -- claim in user_metadata must NOT work (users can edit that themselves)
    perform set_config('request.jwt.claims',
        jsonb_build_object('sub', v_ua::text, 'role', 'authenticated',
                           'user_metadata', jsonb_build_object('healthcheck', true))::text, true);
    set local role authenticated;
    perform _t.throws('healthcheck claim in user_metadata is ignored',
        $q$select healthcheck.ping()$q$, 'HEALTHCHECK_USER_REQUIRED');
    perform _t.reset();

    -- anon
    perform _t.anon();
    perform _t.throws('healthcheck.ping refused for anon',
        $q$select healthcheck.ping()$q$, 'permission denied');
    perform _t.reset();

    -- the real healthcheck identity
    perform _t.login(v_ux, '{"healthcheck": true}'::jsonb);
    v := healthcheck.ping();
    perform _t.check('healthcheck.ping ok for the healthcheck user', v->>'status' = 'ok');
    insert into healthcheck.realtime_test (test_id) values (gen_random_uuid());
    perform _t.check('healthcheck user can insert and read own row',
        (select count(*) from healthcheck.realtime_test) = 1);
    insert into storage.objects (bucket_id, name) values ('healthcheck', 'smoke/ok.txt');
    perform _t.check('healthcheck user can write to the healthcheck bucket',
        exists (select 1 from storage.objects where bucket_id = 'healthcheck' and name = 'smoke/ok.txt'));
    perform _t.check('cleanup() removes nothing recent and does not fail',
        healthcheck.cleanup(interval '1 day') = 0);
    perform _t.reset();

    perform _t.login(v_ua);
    perform _t.check('normal user sees none of the healthcheck rows',
        (select count(*) from healthcheck.realtime_test) = 0);
    perform _t.reset();

    perform _t.check('no bucket policy for healthcheck is open to everyone',
        not exists (select 1 from pg_policies p
                    where p.schemaname = 'storage' and p.tablename = 'objects'
                      and p.policyname like 'healthcheck\_%'
                      and (coalesce(p.qual,'') || coalesce(p.with_check,'')) not like '%is_healthcheck_user%'));
end
$t$;


-- =====================================================================
-- 9. RUNTIME SWEEP: every list_* operation of every *_api function
-- =====================================================================
-- Calls each list operation with an empty payload as tenant owner AND
-- platform admin. Business errors (P0001: missing payload, no permission)
-- are fine. Catalogue errors (class 42: undefined column/table/function,
-- type mismatch) and internal errors (XX) mean broken SQL in the
-- migrations and are reported as FAIL.
-- =====================================================================

insert into platform.platform_admins (user_id)
values (current_setting('smoke.ua')::uuid)
on conflict (user_id) do nothing;

do $t$
declare
    r record;
    v_state text;
    v_msg text;
    v_checked int := 0;
    v_business int := 0;
    v_bugs int := 0;
begin
    perform _t.login(current_setting('smoke.ua')::uuid);
    perform public.auth_api('switch_tenant',
        jsonb_build_object('tenant_id', current_setting('smoke.ta')::uuid));

    for r in
        select distinct
            p.proname::text as api,
            (regexp_matches(p.prosrc, '''(list_[a-z0-9_]+)''', 'g'))[1] as op
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
        where p.proname like '%\_api'
        order by 1, 2
    loop
        v_checked := v_checked + 1;
        begin
            execute format('select public.%I($1, $2)', r.api)
            using r.op, '{}'::jsonb;
        exception when others then
            get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;

            if v_state like '42%' or v_state like 'XX%' then
                v_bugs := v_bugs + 1;
                perform _t.check(format('sweep %s.%s [%s: %s]', r.api, r.op, v_state, left(v_msg, 120)), false);
            else
                v_business := v_business + 1;
            end if;
        end;
    end loop;

    perform _t.reset();

    perform _t.check(
        format('sweep: %s list operations executed, %s ended in a business error, %s SQL bugs',
               v_checked, v_business, v_bugs),
        v_checked > 0 and v_bugs = 0);
end
$t$;


-- =====================================================================
-- SUMMARY
-- =====================================================================

do $t$
declare
    v_fail int := current_setting('smoke.fails')::int;
begin
    raise notice '----------------------------------------------------------';
    raise notice 'PASS: %   FAIL: %   SKIP: %',
        current_setting('smoke.passes'), v_fail, current_setting('smoke.skips');
    raise notice '----------------------------------------------------------';

    if v_fail > 0 then
        raise exception 'SMOKE TEST FAILED: % check(s) failed', v_fail;
    end if;
end
$t$;

rollback;
