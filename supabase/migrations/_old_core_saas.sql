-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 002_CORE_SAAS.SQL
-- =====================================================
--
-- =====================================================
-- 1. TENANTS (CORE MULTI-TENANCY ENTITY)
-- =====================================================

create table if not exists public.tenants (
    id uuid primary key default gen_random_uuid(),

    name text not null,

    status tenant_status default 'active',

    created_at timestamptz default now(),
    updated_at timestamptz default now()
);


-- =====================================================
-- 2. TENANT MEMBERSHIPS (ACCESS CONTROL LAYER)
-- user_id → platform.profiles (auth-linked identity)
-- =====================================================

create table if not exists public.tenant_memberships (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references tenants(id) on delete cascade,

    user_id uuid not null references platform.profiles(id) on delete cascade,

    role membership_role not null,

    is_active boolean not null default true,

    revoked_at timestamptz,

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    unique (tenant_id, user_id)
);


-- =====================================================
-- 3. SERVICE ACCOUNTS (SYSTEM INTEGRATIONS)
-- =====================================================

create table if not exists public.service_accounts (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references tenants(id) on delete cascade,

    name text not null,

    provider_code text,

    is_active boolean default true,

    created_at timestamptz default now()
);


-- =====================================================
-- 4. SUBSCRIPTIONS (COMMERCIAL STATE ONLY)
-- =====================================================

create table if not exists public.subscriptions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references tenants(id) on delete cascade,

    tier subscription_tier not null,

    status subscription_status not null default 'trial',

    current_period_start timestamptz,
    current_period_end timestamptz,

    created_at timestamptz default now(),

    updated_at timestamptz default now()
);


-- =====================================================
-- 5. CORE INDEXES
-- =====================================================

create index if not exists idx_tenants_status
on tenants (status);


create index if not exists idx_memberships_tenant
on tenant_memberships (tenant_id);


create index if not exists idx_memberships_user
on tenant_memberships (user_id);


create index if not exists idx_memberships_active
on tenant_memberships (tenant_id, is_active)
where is_active = true;


create index if not exists idx_memberships_user_tenant_active
on tenant_memberships (user_id, tenant_id)
where is_active = true;


create index if not exists idx_service_accounts_tenant
on service_accounts (tenant_id);


create index if not exists idx_service_accounts_tenant_created
on service_accounts (tenant_id, created_at desc);


create index if not exists idx_subscriptions_tenant
on subscriptions (tenant_id);


-- =====================================================
-- 6. TENANT MEMBERSHIP RESOLUTION (SINGLE AUTHORITY)
-- Internal membership resolver + active tenant resolver
-- =====================================================

-- -----------------------------------------------------
-- Internal membership resolution (ONLY table access point)
-- -----------------------------------------------------

create or replace function platform._resolve_membership(
    p_user_id uuid,
    p_verify_tenant_id uuid default null
)
returns table(tenant_id uuid, role text, tenant_status text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    if p_user_id is null then
        return;
    end if;

    if (select auth.uid()) is not null
       and p_user_id <> (select auth.uid())
       and not platform.is_platform_admin() then
        raise exception 'unauthorized';
    end if;

    if p_verify_tenant_id is not null then
        return query
        select tm.tenant_id, tm.role::text, t.status::text
        from public.tenant_memberships tm
        join public.tenants t on t.id = tm.tenant_id
        where tm.user_id = p_user_id
          and tm.tenant_id = p_verify_tenant_id
          and tm.is_active = true
          and t.status not in ('suspended', 'deleted')
        limit 1;
        return;
    end if;

    return query
    select tm.tenant_id, tm.role::text, t.status::text
    from public.tenant_memberships tm
    join public.tenants t on t.id = tm.tenant_id
    where tm.user_id = p_user_id
      and tm.is_active = true
      and t.status not in ('suspended', 'deleted')
    order by tm.created_at desc
    limit 1;
end;
$$;


-- -----------------------------------------------------
-- resolve_active_tenant: sole tenant authority
-- Membership SSOT
-- -----------------------------------------------------

create or replace function public.resolve_active_tenant(
    p_user_id uuid,
    p_verify_tenant_id uuid default null
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
    select m.tenant_id
    from platform._resolve_membership(p_user_id, p_verify_tenant_id) m
    limit 1;
$$;


-- =====================================================
-- 7. TENANT CONTEXT AND ROLE FUNCTIONS
-- Derived exclusively from the membership resolver
-- =====================================================

-- -----------------------------------------------------
-- Role context: derived from resolver internal only
-- -----------------------------------------------------

create or replace function platform.current_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
    select m.role
    from platform._resolve_membership((select auth.uid()), null) m
    limit 1;
$$;


-- -----------------------------------------------------
-- platform.current_tenant_id: pure resolver wrapper
-- Non-authoritative domain context reader
-- -----------------------------------------------------

create or replace function platform.current_tenant_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
    select public.resolve_active_tenant((select auth.uid()));
$$;


-- -----------------------------------------------------
-- platform.has_role: derived from resolver internal only
-- -----------------------------------------------------

create or replace function platform.has_role(required_role text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from platform._resolve_membership((select auth.uid()), null) m
        where m.role = required_role
    );
$$;


-- -----------------------------------------------------
-- has_tenant_membership: REV21 shim
-- Post-authority compatibility wrapper
-- -----------------------------------------------------

create or replace function platform.has_tenant_membership(p_user_id uuid, p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select public.resolve_active_tenant(p_user_id, p_tenant_id) is not null;
$$;


-- =====================================================
-- 8. USER-TO-TENANT CONTEXT VIEW
-- =====================================================

create or replace view public.tenant_user_context
with (security_invoker = true)
as
select
    tm.user_id,
    tm.tenant_id,
    tm.role,
    tm.is_active,
    t.status as tenant_status
from public.tenant_memberships tm
join public.tenants t
    on t.id = tm.tenant_id;


-- =====================================================
-- 9. TENANT SWITCHING AND AUTH DOMAIN
-- =====================================================

-- -----------------------------------------------------
-- auth_resolve_tenant_switch: no direct membership reads
-- -----------------------------------------------------

create or replace function public.auth_resolve_tenant_switch(
    p_user_id uuid,
    p_target_tid uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_row record;
begin
    if p_user_id is null then
        raise exception 'authentication required';
    end if;
    if p_target_tid is null then
        raise exception 'tenant_id is required';
    end if;

    select m.tenant_id, m.role, m.tenant_status
    into v_row
    from platform._resolve_membership(p_user_id, p_target_tid) m
    limit 1;

    if v_row.tenant_id is null then
        raise exception 'No active membership for tenant';
    end if;

    if v_row.tenant_status in ('suspended', 'deleted') then
        raise exception 'Tenant is not available';
    end if;

    return jsonb_build_object(
        'tenant_id', v_row.tenant_id,
        'role', v_row.role,
        'tenant_status', v_row.tenant_status
    );
end;
$$;


-- -----------------------------------------------------
-- auth_domain_ext_031: tenant switching + invitations
-- -----------------------------------------------------

create or replace function public.auth_domain_ext_031(
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
    v_row record;
    v_result jsonb;
    v_target_tid uuid;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);
    v_uid := (select auth.uid());

    case p_op
    when 'validate_tenant_switch' then
        if v_uid is null then raise exception 'authentication required'; end if;
        if p_payload->>'tenant_id' is null then raise exception 'tenant_id is required'; end if;
        v_target_tid := (p_payload->>'tenant_id')::uuid;
        v_result := public.auth_resolve_tenant_switch(v_uid, v_target_tid);

    when 'invite_member' then
        v_tid := platform.current_tenant_id();
        if p_payload->>'user_id' is null then raise exception 'user_id is required'; end if;
        if p_payload->>'role' is null then raise exception 'role is required'; end if;
        if exists (
            select 1
            from public.tenant_memberships tm
            where tm.tenant_id = v_tid
              and tm.user_id = (p_payload->>'user_id')::uuid
              and tm.is_active = true
        ) then
            raise exception 'User is already an active member of this tenant';
        end if;
        insert into public.tenant_memberships (tenant_id, user_id, role, is_active)
        values (
            v_tid,
            (p_payload->>'user_id')::uuid,
            (p_payload->>'role')::public.membership_role,
            true
        )
        returning id, user_id, tenant_id, role, is_active, revoked_at, created_at into v_row;
        perform platform.log_audit(
            'membership.created',
            'tenant_membership',
            v_row.id,
            jsonb_build_object(
                'tenant_id', v_tid,
                'user_id', v_row.user_id,
                'role', v_row.role,
                'invited_by', v_uid
            )
        );
        select jsonb_build_object(
            'id', v_row.id,
            'user_id', v_row.user_id,
            'tenant_id', v_row.tenant_id,
            'role', v_row.role,
            'is_active', v_row.is_active,
            'revoked_at', v_row.revoked_at,
            'email', coalesce(p_payload->>'email', p.email),
            'full_name', p.full_name,
            'created_at', v_row.created_at
        ) into v_result
        from platform.profiles p
        where p.id = v_row.user_id;

    else
        raise exception 'unknown auth_domain operation: %', p_op;
    end case;

    return v_result;
end;
$$;


-- -----------------------------------------------------
-- auth_domain_ext: extended auth router
-- -----------------------------------------------------

create or replace function public.auth_domain_ext(
    p_op text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_result jsonb;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);

    case p_op
    when 'resolve_user_by_email' then
        if p_payload->>'email' is null then raise exception 'email is required'; end if;
        select to_jsonb(t) into v_result from (
            select p.id, p.email, p.full_name
            from platform.profiles p
            where lower(p.email) = lower(p_payload->>'email')
            limit 1
        ) t;
        return v_result;

    else
        return public.auth_domain_ext_031(p_op, p_payload);
    end case;
end;
$$;


-- -----------------------------------------------------
-- auth_domain: core tenant/member/subscription router
-- -----------------------------------------------------

create or replace function public.auth_domain(
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
    v_row record;
    v_result jsonb;
    v_role text;
    v_tenant_status text;
    v_existing record;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);
    v_uid := (select auth.uid());

    case p_op
    when 'get_auth_context' then
        if v_uid is null then raise exception 'authentication required'; end if;
        v_tid := platform.current_tenant_id();
        v_role := platform.current_role();
        v_tenant_status := null;
        if v_tid is not null then
            select t.status::text into v_tenant_status
            from public.tenants t
            where t.id = v_tid;
        end if;
        v_result := jsonb_build_object(
            'user_id', v_uid,
            'email', (select p.email from platform.profiles p where p.id = v_uid),
            'tenant_id', v_tid,
            'role', v_role,
            'tenant_status', v_tenant_status,
            'is_platform_admin', platform.is_platform_admin()
        );

    when 'list_user_tenants' then
        if v_uid is null then raise exception 'authentication required'; end if;
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb) into v_result
        from (
            select tm.tenant_id, t.name as tenant_name, tm.role, tm.is_active, t.status as tenant_status, tm.created_at
            from public.tenant_memberships tm
            join public.tenants t on t.id = tm.tenant_id
            where tm.user_id = v_uid and tm.is_active = true
        ) t;

    when 'get_current_tenant' then
        v_tid := platform.current_tenant_id();
        if v_tid is null then raise exception 'NO_ACTIVE_TENANT'; end if;
        select to_jsonb(t) into v_result from (
            select tn.id, tn.name, tn.status, tn.created_at, tn.updated_at
            from public.tenants tn where tn.id = v_tid
        ) t;
        if v_result is null then raise exception 'Tenant not found'; end if;

    when 'create_tenant' then
        if v_uid is null then raise exception 'authentication required'; end if;
        if not platform.is_platform_admin()
           and exists (
               select 1
               from public.tenant_memberships tm
               join public.tenants t on t.id = tm.tenant_id
               where tm.user_id = v_uid
                 and tm.is_active = true
                 and tm.role = 'owner'
                 and t.status not in ('suspended', 'deleted')
           ) then
            raise exception 'User already has an active owner membership';
        end if;
        insert into public.tenants (name) values (p_payload->>'name')
        returning id, name, status, created_at, updated_at into v_row;
        perform platform.log_audit('tenant.created', 'tenant', v_row.id,
            jsonb_build_object('name', p_payload->>'name', 'created_by', v_uid));
        v_result := to_jsonb(v_row);

    when 'update_tenant' then
        perform public.edge_require_admin();
        v_tid := platform.current_tenant_id();
        update public.tenants tn set
            name = case when p_payload ? 'name' then p_payload->>'name' else tn.name end,
            status = case when p_payload ? 'status'
                then (p_payload->>'status')::public.tenant_status else tn.status end
        where tn.id = v_tid
        returning tn.id, tn.name, tn.status, tn.created_at, tn.updated_at into v_row;
        if not found then raise exception 'Tenant not found'; end if;
        perform platform.log_audit('tenant.updated', 'tenant', v_tid, p_payload);
        v_result := to_jsonb(v_row);

    when 'list_memberships' then
        v_tid := platform.current_tenant_id();
        if v_tid is null then raise exception 'NO_ACTIVE_TENANT'; end if;
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb) into v_result
        from (
            select tm.id, tm.user_id, tm.tenant_id, tm.role, tm.is_active, tm.revoked_at,
                   p.email, p.full_name, tm.created_at
            from public.tenant_memberships tm
            left join platform.profiles p on p.id = tm.user_id
            where tm.tenant_id = v_tid
        ) t;

    when 'update_membership' then
        v_tid := platform.current_tenant_id();
        if v_tid is null then raise exception 'NO_ACTIVE_TENANT'; end if;
        select tm.id, tm.user_id, tm.tenant_id into v_existing
        from public.tenant_memberships tm
        where tm.id = (p_payload->>'membership_id')::uuid and tm.tenant_id = v_tid;
        if not found then raise exception 'Membership not found'; end if;
        if v_existing.user_id = v_uid then
            if p_payload ? 'role' then raise exception 'Cannot change your own role via this endpoint'; end if;
        else
            perform public.edge_require_admin();
        end if;
        update public.tenant_memberships tm set
            role = case when p_payload ? 'role' then (p_payload->>'role')::public.membership_role else tm.role end,
            is_active = case when p_payload ? 'is_active' then (p_payload->>'is_active')::boolean else tm.is_active end,
            revoked_at = case
                when p_payload ? 'is_active' and not (p_payload->>'is_active')::boolean then now()
                when p_payload ? 'is_active' and (p_payload->>'is_active')::boolean then null
                else tm.revoked_at
            end
        where tm.id = (p_payload->>'membership_id')::uuid and tm.tenant_id = v_tid
        returning tm.id, tm.user_id, tm.tenant_id, tm.role, tm.is_active, tm.revoked_at, tm.created_at into v_row;
        if not found then raise exception 'Membership not found'; end if;
        perform platform.log_audit('membership.updated', 'tenant_membership', v_row.id, p_payload);
        select jsonb_build_object(
            'id', v_row.id,
            'user_id', v_row.user_id,
            'tenant_id', v_row.tenant_id,
            'role', v_row.role,
            'is_active', v_row.is_active,
            'revoked_at', v_row.revoked_at,
            'email', p.email,
            'full_name', p.full_name,
            'created_at', v_row.created_at
        ) into v_result
        from platform.profiles p where p.id = v_row.user_id;

    when 'revoke_membership' then
        v_tid := platform.current_tenant_id();
        if v_tid is null then raise exception 'NO_ACTIVE_TENANT'; end if;
        select tm.id, tm.user_id into v_existing
        from public.tenant_memberships tm
        where tm.id = (p_payload->>'membership_id')::uuid and tm.tenant_id = v_tid;
        if not found then raise exception 'Membership not found'; end if;
        if v_existing.user_id <> v_uid then perform public.edge_require_admin(); end if;
        delete from public.tenant_memberships tm where tm.id = (p_payload->>'membership_id')::uuid and tm.tenant_id = v_tid;
        perform platform.log_audit('membership.revoked', 'tenant_membership', (p_payload->>'membership_id')::uuid,
            jsonb_build_object('tenant_id', v_tid, 'revoked_by', v_uid));
        v_result := jsonb_build_object('revoked', true, 'membership_id', p_payload->>'membership_id');

    when 'get_subscription' then
        v_tid := platform.current_tenant_id();
        if v_tid is null then raise exception 'NO_ACTIVE_TENANT'; end if;
        select to_jsonb(t) into v_result from (
            select s.id, s.tenant_id, s.tier, s.status, s.current_period_start, s.current_period_end, s.created_at, s.updated_at
            from public.subscriptions s where s.tenant_id = v_tid
        ) t;

    when 'update_subscription' then
        perform public.edge_require_admin();
        v_tid := platform.current_tenant_id();
        if v_tid is null then raise exception 'NO_ACTIVE_TENANT'; end if;
        if not exists (select 1 from public.subscriptions s where s.tenant_id = v_tid) then
            raise exception 'Subscription not found for tenant';
        end if;
        update public.subscriptions s set
            status = case when p_payload ? 'status' then (p_payload->>'status')::public.subscription_status else s.status end,
            current_period_start = case when p_payload ? 'current_period_start'
                then (p_payload->>'current_period_start')::timestamptz else s.current_period_start end,
            current_period_end = case when p_payload ? 'current_period_end'
                then (p_payload->>'current_period_end')::timestamptz else s.current_period_end end
        where s.tenant_id = v_tid
        returning s.id, s.tenant_id, s.tier, s.status, s.current_period_start, s.current_period_end, s.created_at, s.updated_at into v_row;
        perform platform.log_audit('subscription.updated', 'subscription', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'list_service_accounts' then
        v_tid := platform.current_tenant_id();
        if v_tid is null then raise exception 'NO_ACTIVE_TENANT'; end if;
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb) into v_result
        from (
            select sa.id, sa.tenant_id, sa.name, sa.provider_code, sa.is_active, sa.created_at
            from public.service_accounts sa where sa.tenant_id = v_tid
        ) t;

    when 'create_service_account' then
        perform public.edge_require_admin();
        v_tid := platform.current_tenant_id();
        if v_tid is null then raise exception 'NO_ACTIVE_TENANT'; end if;
        insert into public.service_accounts (tenant_id, name, provider_code, is_active)
        values (
            v_tid, p_payload->>'name', p_payload->>'provider_code',
            coalesce((p_payload->>'is_active')::boolean, true)
        )
        returning id, tenant_id, name, provider_code, is_active, created_at into v_row;
        perform platform.log_audit('service_account.created', 'service_account', v_row.id,
            jsonb_build_object('name', p_payload->>'name', 'provider_code', p_payload->>'provider_code'));
        v_result := to_jsonb(v_row);

    when 'update_service_account' then
        perform public.edge_require_admin();
        v_tid := platform.current_tenant_id();
        if v_tid is null then raise exception 'NO_ACTIVE_TENANT'; end if;
        update public.service_accounts sa set
            name = case when p_payload ? 'name' then p_payload->>'name' else sa.name end,
            provider_code = case when p_payload ? 'provider_code' then p_payload->>'provider_code' else sa.provider_code end,
            is_active = case when p_payload ? 'is_active' then (p_payload->>'is_active')::boolean else sa.is_active end
        where sa.id = (p_payload->>'service_account_id')::uuid and sa.tenant_id = v_tid
        returning sa.id, sa.tenant_id, sa.name, sa.provider_code, sa.is_active, sa.created_at into v_row;
        if not found then raise exception 'Service account not found'; end if;
        perform platform.log_audit('service_account.updated', 'service_account', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_service_account' then
        perform public.edge_require_admin();
        v_tid := platform.current_tenant_id();
        if v_tid is null then raise exception 'NO_ACTIVE_TENANT'; end if;
        delete from public.service_accounts sa
        where sa.id = (p_payload->>'service_account_id')::uuid and sa.tenant_id = v_tid;
        if not found then raise exception 'Service account not found'; end if;
        perform platform.log_audit('service_account.deleted', 'service_account', (p_payload->>'service_account_id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'service_account_id', p_payload->>'service_account_id');

    else
        return public.auth_domain_ext(p_op, p_payload);
    end case;

    return v_result;
end;
$$;


-- -----------------------------------------------------
-- auth_invite_member: admin-gated invitation wrapper
-- -----------------------------------------------------

create or replace function public.auth_invite_member(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_uid uuid;
    v_payload jsonb;
begin
    perform public.edge_require_admin();
    p_payload := coalesce(p_payload, '{}'::jsonb);
    v_payload := p_payload;

    if v_payload->>'user_id' is null then
        if v_payload->>'email' is null then
            raise exception 'email or user_id is required';
        end if;
        select p.id into v_uid
        from platform.profiles p
        where lower(p.email) = lower(v_payload->>'email')
        limit 1;
        if v_uid is null then
            raise exception 'User not found for email. User must register before invite.';
        end if;
        v_payload := v_payload || jsonb_build_object('user_id', v_uid::text);
    end if;

    return public.auth_domain('invite_member', v_payload);
end;
$$;


-- -----------------------------------------------------
-- auth_switch_tenant: membership gate only
-- -----------------------------------------------------

create or replace function public.auth_switch_tenant(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_uid uuid;
    v_target_tid uuid;
    v_result jsonb;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);
    v_uid := auth.uid();
    if v_uid is null then
        raise exception 'authentication required';
    end if;
    if p_payload->>'tenant_id' is null then
        raise exception 'tenant_id is required';
    end if;

    v_target_tid := (p_payload->>'tenant_id')::uuid;
    v_result := public.auth_resolve_tenant_switch(v_uid, v_target_tid);

    update auth.users
    set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb)
        || jsonb_build_object('tenant_id', v_target_tid::text)
    where id = v_uid;

    return v_result;
end;
$$;


-- =====================================================
-- 10. TENANT PROVISIONING AND OWNER INVARIANT
-- =====================================================

-- -----------------------------------------------------
-- Tenant provisioning: creator becomes owner
-- -----------------------------------------------------

create or replace function public.handle_new_tenant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if (select auth.uid()) is not null then
        insert into public.tenant_memberships (
            tenant_id,
            user_id,
            role,
            is_active
        )
        values (
            new.id,
            (select auth.uid()),
            'owner',
            true
        );
    end if;

    return new;
end;
$$;


-- -----------------------------------------------------
-- Owner invariant: at least one active owner
-- -----------------------------------------------------

create or replace function public.enforce_tenant_owner_invariant()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_owner_count int;
begin
    if tg_op = 'DELETE' then
        if old.role = 'owner' and old.is_active then
            select count(*)
            into v_owner_count
            from public.tenant_memberships tm
            where tm.tenant_id = old.tenant_id
              and tm.role = 'owner'
              and tm.is_active = true
              and tm.id <> old.id;

            if v_owner_count = 0 then
                raise exception 'cannot remove last active owner from tenant';
            end if;
        end if;

        return old;
    end if;

    if tg_op = 'UPDATE' then
        if old.role = 'owner'
           and old.is_active
           and (new.role <> 'owner' or not new.is_active) then
            select count(*)
            into v_owner_count
            from public.tenant_memberships tm
            where tm.tenant_id = old.tenant_id
              and tm.role = 'owner'
              and tm.is_active = true
              and tm.id <> old.id;

            if v_owner_count = 0 then
                raise exception 'cannot demote or deactivate last active owner';
            end if;
        end if;
    end if;

    return new;
end;
$$;


-- =====================================================
-- 11. INTEGRATIONS API AND EXTENSIONS
-- Integration execution wrappers only
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
        when 'list_providers', 'get_provider', 'list_capabilities', 'list_tenant_integrations', 'get_tenant_integration', 'list_webhook_definitions', 'list_device_maps' then
            perform public.edge_require_tenant();
        when 'connect_integration', 'update_integration', 'disconnect_integration', 'create_webhook_definition', 'update_webhook_definition', 'delete_webhook_definition', 'create_device_map', 'update_device_map', 'delete_device_map', 'register_oauth_state', 'request_sync' then
            perform public.edge_require_manager();
        when 'resolve_oauth_state', 'complete_oauth' then
            null;
        else
            raise exception 'unknown integrations_api operation: %', p_op;
    end case;

    return public.integrations_domain(p_op, p_payload);
end;
$$;


-- -----------------------------------------------------
-- Integration OAuth state and synchronization extension
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

    when 'resolve_oauth_state' then
        if p_payload->>'state_token' is null or length(trim(p_payload->>'state_token')) = 0 then
            raise exception 'state_token is required';
        end if;
        return public.integrations_resolve_oauth_state(p_payload->>'state_token');

    when 'complete_oauth' then
        if p_payload->>'state_token' is null or length(trim(p_payload->>'state_token')) = 0 then
            raise exception 'state_token is required';
        end if;
        return public.integrations_complete_oauth(
            (p_payload->>'tenant_id')::uuid,
            p_payload->>'provider_code',
            p_payload->>'credentials_ref',
            p_payload->>'state_token'
        );

    else
        raise exception 'unknown integrations_domain operation: %', p_op;
    end case;

    return v_result;
end;
$$;


-- =====================================================
-- 13. CORE UPDATED_AT AND PROVISIONING TRIGGERS
-- =====================================================

create trigger trg_tenants_updated_at
before update on public.tenants
for each row execute function platform.set_updated_at();


create trigger trg_memberships_updated_at
before update on public.tenant_memberships
for each row execute function platform.set_updated_at();


create trigger trg_tenant_bootstrap_owner
after insert on public.tenants
for each row execute function public.handle_new_tenant();


create trigger trg_memberships_owner_invariant
before update or delete on public.tenant_memberships
for each row execute function public.enforce_tenant_owner_invariant();


create trigger trg_subscriptions_updated_at
before update on public.subscriptions
for each row execute function platform.set_updated_at();


-- =====================================================
-- 14. FUNCTION SECURITY LOCKDOWN
-- =====================================================

do $block$
declare
    r record;
begin

    for r in
        select
            n.nspname,
            p.proname,
            pg_get_function_identity_arguments(p.oid) as args
        from pg_proc p
        join pg_namespace n
            on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname = any (array[
            'auth_domain_ext',
            'auth_domain_ext_031',
            'commerce_domain',
            'booking_domain',
            'locks_domain',
            'crm_domain',
            'preconfig_domain',
            'portal_domain',
            'onboarding_domain',
            'optimization_domain',
            'monetization_domain',
            'operations_domain',
            'automation_domain',
            'automation_domain_ext',
            'notification_domain',
            'payment_domain'
          ])
    loop

        execute format(
            'revoke all on function %I.%I(%s) from public, authenticated',
            r.nspname,
            r.proname,
            r.args
        );

    end loop;

end;
$block$;


-- -----------------------------------------------------
-- H1, H2, H4, H5, M1: revoke direct authenticated execute
-- on standalone RPCs
-- Idempotent: only functions that exist at apply time
-- -----------------------------------------------------

do $block$
declare
    r record;


begin
    for r in
        select
            n.nspname,
            p.proname,
            pg_get_function_identity_arguments(p.oid) as args
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname = any (array[
            'commerce_change_subscription_plan',
            'commerce_create_subscription',
            'automation_dispatch_event',
            'automation_start_run',
            'automation_cancel_run',
            'automation_enqueue_notification',
            'integrations_start_oauth',
            'insert_event'
          ])
    loop
        execute format(
            'revoke all on function %I.%I(%s) from public, authenticated',
            r.nspname, r.proname, r.args
        );


        execute format(
            'grant execute on function %I.%I(%s) to service_role',
            r.nspname, r.proname, r.args
        );


    end loop;


end;


$block$;


-- =====================================================
-- 15. FINAL FUNCTION SECURITY ATTRIBUTES
-- =====================================================

comment on function public.resolve_active_tenant(uuid, uuid) is
    'REV21 sole tenant authority. All membership is_active evaluation occurs here only.';


alter function public.resolve_active_tenant(uuid, uuid) set search_path = '';

alter function platform._resolve_membership(uuid, uuid) set search_path = '';

alter function platform.current_role() set search_path = '';

alter function platform.has_role(text) set search_path = '';


comment on function platform.has_tenant_membership(uuid, uuid) is
    'Non-authoritative shim. Delegates to resolve_active_tenant(user_id, tenant_id).';


comment on function platform.current_tenant_id() is
    'Non-authoritative domain context reader. Delegates to resolve_active_tenant(auth.uid())';


alter function platform.current_tenant_id() set search_path = '';


-- =====================================================
-- 16. REV21 FINAL TENANT AUTHORITY FREEZE
-- =====================================================

-- SINGLE SOURCE OF TRUTH ENFORCEMENT NOTE
-- Tenant resolution MUST ONLY occur via:
-- public.resolve_active_tenant(auth.uid())

-- DO NOT introduce:
-- - JWT-based tenant resolution
-- - membership EXISTS checks outside resolver
-- - alternative tenant gates

-- Any deviation is considered architecture drift
-- =====================================================


-- =====================================================
-- END 002 CORE SAAS (CLEAN DOMAIN ONLY)
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('002_core_saas', 'REV1.CORE.SAAS', false)
on conflict (version) do nothing;