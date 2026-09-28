-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 009_OPERATIONS_ENGINE.SQL
-- =====================================================
--
-- Operational blueprints only 
-- — advisory rules live in 015.optimization_rules.
-- NO EXECUTION / NO LOGGING / NO RUNTIME STATE
-- =====================================================


-- =====================================================
-- 2. OPERATION TEMPLATES
-- System + tenant operation blueprints
-- =====================================================

create table if not exists public.operation_templates (

    id uuid primary key default gen_random_uuid(),

    tenant_id uuid,

    is_system boolean not null default false,

    name text not null,

    description text,

    template jsonb not null,

    version int not null default 1,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    constraint chk_operation_templates_system_scope check (
        (is_system and tenant_id is null)
        or (not is_system and tenant_id is not null)
    )
);


-- =====================================================
-- 3. OPERATION WORKFLOWS
-- Master workflow definitions
-- =====================================================

create table if not exists public.operation_workflows (

    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    source_template_id uuid references operation_templates(id) on delete set null,

    name text not null,

    description text,

    is_active boolean not null default true,

    version int not null default 1,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now()
);


-- =====================================================
-- 4. WORKFLOW STEPS
-- Workflow pipeline definitions
-- =====================================================

create table if not exists public.workflow_steps (

    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    workflow_id uuid not null references operation_workflows(id) on delete cascade,

    step_order int not null,

    action_type automation_action_type not null,

    config jsonb not null default '{}'::jsonb,

    delay_seconds int not null default 0,

    created_at timestamptz not null default now(),

    unique (workflow_id, step_order),

    constraint chk_workflow_steps_order check (step_order > 0),
    constraint chk_workflow_steps_delay check (delay_seconds >= 0)
);


-- =====================================================
-- 5. WORKFLOW TRIGGERS
-- Workflow start conditions
-- =====================================================

create table if not exists public.workflow_triggers (

    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null,

    workflow_id uuid not null references operation_workflows(id) on delete cascade,

    property_id uuid references properties(id) on delete cascade,

    trigger_type automation_trigger_type not null,

    trigger_config jsonb not null default '{}'::jsonb,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    unique (workflow_id, trigger_type, property_id)
);


-- =====================================================
-- 6. NOTIFICATION TEMPLATES
-- Notification message blueprints
-- =====================================================

create table if not exists public.notification_templates (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid references public.tenants(id) on delete cascade,
    code text not null,
    channel public.notification_channel not null,
    subject_template text,
    body_template text not null,
    metadata jsonb not null default '{}'::jsonb,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint chk_notification_templates_scope check (
        (tenant_id is null) or (tenant_id is not null)
    ),
    unique (tenant_id, code, channel)
);


-- =====================================================
-- 7. NOTIFICATION PREFERENCES
-- Tenant and user notification preferences
-- =====================================================

create table if not exists public.notification_preferences (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references public.tenants(id) on delete cascade,
    user_id uuid references platform.profiles(id) on delete cascade,
    channel public.notification_channel not null,
    is_enabled boolean not null default true,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (tenant_id, user_id, channel)
);


-- =====================================================
-- 8. NOTIFICATION QUEUE
-- Pending notification delivery records
-- =====================================================

create table if not exists public.notification_queue (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references public.tenants(id) on delete cascade,
    channel public.notification_channel not null,
    recipient text not null,
    template_id uuid references public.notification_templates(id) on delete set null,
    template_code text,
    subject text,
    body text,
    payload jsonb not null default '{}'::jsonb,
    status public.notification_delivery_status not null default 'queued',
    scheduled_at timestamptz not null default now(),
    attempt_count int not null default 0,
    max_attempts int not null default 5,
    last_error jsonb,
    correlation_id uuid not null default gen_random_uuid(),
    source text not null default 'api',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint chk_notification_queue_attempts check (
        attempt_count >= 0 and max_attempts > 0 and attempt_count <= max_attempts + 1
    )
);


-- =====================================================
-- 9. NOTIFICATION HISTORY
-- Historical notification delivery records
-- =====================================================

create table if not exists public.notification_history (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid not null references public.tenants(id) on delete cascade,
    queue_id uuid references public.notification_queue(id) on delete set null,
    channel public.notification_channel not null,
    recipient text not null,
    status public.notification_delivery_status not null,
    subject text,
    body text,
    payload jsonb not null default '{}'::jsonb,
    error jsonb,
    sent_at timestamptz not null default now(),
    created_at timestamptz not null default now()
);


-- =====================================================
-- 10. SUPPORT TICKETS
-- Support case master records
-- =====================================================

create table if not exists public.support_tickets (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references tenants(id) on delete cascade,

    user_id uuid references platform.profiles(id) on delete set null,

    subject text,

    description text,

    status support_ticket_status not null default 'open',

    priority priority_level not null default 'normal',

    created_at timestamptz default now(),

    updated_at timestamptz default now(),

    constraint chk_support_tickets_has_content check (
        subject is not null or description is not null
    )
);


-- =====================================================
-- 11. SUPPORT MESSAGES
-- Messages belonging to support tickets
-- =====================================================

create table if not exists public.support_messages (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references tenants(id) on delete cascade,

    ticket_id uuid not null references support_tickets(id) on delete cascade,

    sender_type support_sender_type not null,

    message text,

    created_at timestamptz default now()
);


-- =====================================================
-- 12. INDEXES
-- =====================================================

-- Operation templates

create index if not exists idx_operation_templates_tenant
    on public.operation_templates (tenant_id);


create index if not exists idx_operation_templates_tenant_created
    on public.operation_templates (tenant_id, created_at desc);


create index if not exists idx_operation_templates_system
    on public.operation_templates (is_system);


-- Operation workflows

create index if not exists idx_operation_workflows_tenant
    on public.operation_workflows (tenant_id);


create index if not exists idx_operation_workflows_created
    on public.operation_workflows (tenant_id, created_at desc);


-- Workflow steps

create index if not exists idx_workflow_steps_workflow
    on public.workflow_steps (workflow_id);


create index if not exists idx_workflow_steps_tenant_created
    on public.workflow_steps (tenant_id, created_at desc);


-- Workflow triggers

create index if not exists idx_workflow_triggers_workflow
    on public.workflow_triggers (workflow_id);


create index if not exists idx_workflow_triggers_property
    on public.workflow_triggers (property_id)
    where property_id is not null;


create index if not exists idx_workflow_triggers_active
    on public.workflow_triggers (workflow_id, trigger_type)
    where is_active = true;


create index if not exists idx_workflow_triggers_property_type
    on public.workflow_triggers (property_id, trigger_type)
    where property_id is not null;


create index if not exists idx_workflow_triggers_workflow_created
    on public.workflow_triggers (workflow_id, created_at desc);


create index if not exists idx_workflow_triggers_tenant_created
    on workflow_triggers (tenant_id, created_at desc);


-- Notification templates

create index if not exists idx_notification_templates_tenant_created
on public.notification_templates (tenant_id, created_at desc);


create index if not exists idx_notification_templates_code
on public.notification_templates (code, channel);


-- Notification preferences

create unique index if not exists uq_notification_preferences_tenant_default_channel
on public.notification_preferences (tenant_id, channel)
where user_id is null;


create index if not exists idx_notification_preferences_tenant_created
on public.notification_preferences (tenant_id, created_at desc);


-- Notification queue

create index if not exists idx_notification_queue_pending
on public.notification_queue (status, scheduled_at)
where status in ('queued', 'processing');


create index if not exists idx_notification_queue_tenant_created
on public.notification_queue (tenant_id, created_at desc);


-- Notification history

create index if not exists idx_notification_history_tenant_sent
on public.notification_history (tenant_id, sent_at desc);


create index if not exists idx_notification_history_queue
on public.notification_history (queue_id);


-- Support tickets

create index if not exists idx_support_tickets_tenant_created
on support_tickets (tenant_id, created_at desc);


create index if not exists idx_support_tickets_tenant_status_created
on support_tickets (tenant_id, status, created_at desc);


create index if not exists idx_support_tickets_tenant_priority_created
on support_tickets (tenant_id, priority, created_at desc);


-- Support messages

create index if not exists idx_support_messages_tenant_created
on public.support_messages (tenant_id, created_at desc);


create index if not exists idx_support_messages_ticket_created
on public.support_messages (ticket_id, created_at asc);


-- =====================================================
-- 13. TENANT FOREIGN KEYS
-- =====================================================

do $$
begin
    alter table public.operation_workflows
        add constraint fk_operation_workflows_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;


do $$
begin
    alter table public.operation_templates
        add constraint fk_operation_templates_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;


do $$
begin
    alter table public.workflow_steps
        add constraint fk_workflow_steps_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;


do $$
begin
    alter table public.workflow_triggers
        add constraint fk_workflow_triggers_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception when duplicate_object then null;
end $$;


-- =====================================================
-- 14. INTEGRITY & SCOPE HELPER FUNCTIONS
-- =====================================================

create or replace function public.enforce_support_message_tenant_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_ticket_tenant uuid;
begin
    select st.tenant_id
    into v_ticket_tenant
    from public.support_tickets st
    where st.id = new.ticket_id;

    if not found then
        raise exception 'support ticket not found';
    end if;

    if new.tenant_id <> v_ticket_tenant then
        raise exception 'support message tenant_id must match ticket tenant_id';
    end if;

    return new;
end;
$$;


create or replace function public.enforce_support_ticket_user_membership()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.user_id is null then
        return new;
    end if;

    if not exists (
        select 1
        from public.tenant_memberships tm
        where tm.tenant_id = new.tenant_id
          and tm.user_id = new.user_id
          and tm.is_active = true
    ) then
        raise exception 'support ticket user_id must be an active member of tenant_id';
    end if;

    return new;
end;
$$;


create or replace function public.enforce_workflow_child_tenant_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_workflow_tenant uuid;
begin
    select w.tenant_id
    into v_workflow_tenant
    from public.operation_workflows w
    where w.id = new.workflow_id;

    if not found then
        raise exception 'workflow not found';
    end if;

    if new.tenant_id <> v_workflow_tenant then
        raise exception 'workflow child tenant_id must match operation_workflows tenant_id';
    end if;

    return new;
end;
$$;


-- =====================================================
-- 15. WORKFLOW & TEMPLATE SCOPE VALIDATION
-- =====================================================

create or replace function public.enforce_workflow_template_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_template_tenant uuid;
    v_template_is_system boolean;
begin

    if new.source_template_id is null then
        return new;
    end if;

    select tenant_id, is_system
    into v_template_tenant, v_template_is_system
    from public.operation_templates
    where id = new.source_template_id;

    if not found then
        raise exception 'template not found';
    end if;

    if v_template_is_system then
        return new;
    end if;

    if v_template_tenant is distinct from new.tenant_id then
        raise exception 'tenant mismatch between workflow and template';
    end if;

    return new;
end;
$$;


create or replace function public.enforce_workflow_trigger_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_tenant uuid;
    v_property_tenant uuid;
begin

    select tenant_id
    into v_tenant
    from public.operation_workflows
    where id = new.workflow_id;

    if not found then
        raise exception 'workflow not found';
    end if;

    if new.property_id is null then
        return new;
    end if;

    select tenant_id
    into v_property_tenant
    from public.properties
    where id = new.property_id;

    if v_property_tenant is distinct from v_tenant then
        raise exception 'tenant mismatch between workflow and property';
    end if;

    return new;
end;
$$;


-- =====================================================
-- 16. NOTIFICATION HELPER FUNCTIONS
-- =====================================================

create or replace function public.notification_is_channel_enabled(
    p_tenant_id uuid,
    p_user_id uuid,
    p_channel public.notification_channel
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_pref boolean;
begin
    select np.is_enabled into v_pref
    from public.notification_preferences np
    where np.tenant_id = p_tenant_id
      and np.channel = p_channel
      and (np.user_id = p_user_id or np.user_id is null)
    order by np.user_id nulls last
    limit 1;

    return coalesce(v_pref, true);
end;
$$;


create or replace function public.notification_resolve_template(
    p_tenant_id uuid,
    p_template_code text,
    p_channel public.notification_channel
)
returns public.notification_templates
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_row public.notification_templates;
begin
    select * into v_row
    from public.notification_templates nt
    where nt.code = p_template_code
      and nt.channel = p_channel
      and nt.is_active = true
      and (nt.tenant_id = p_tenant_id or nt.tenant_id is null)
    order by nt.tenant_id nulls last
    limit 1;

    return v_row;
end;
$$;


-- =====================================================
-- 17. OPERATIONS DOMAIN API
-- =====================================================

create or replace function public.operations_domain(
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
    v_workflow_tenant uuid;
    v_workflow_id uuid;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);
    v_uid := (select auth.uid());

    case p_op
    when 'list_templates' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.name), '[]'::jsonb) into v_result
        from (
            select ot.id, ot.tenant_id, ot.is_system, ot.name, ot.description, ot.template, ot.version, ot.is_active, ot.created_at, ot.updated_at
            from public.operation_templates ot
            where ot.is_system = true or ot.tenant_id = v_tid or platform.is_platform_admin()
        ) t;

    when 'get_template' then
        v_tid := platform.current_tenant_id();
        select to_jsonb(t) into v_result from (
            select ot.id, ot.tenant_id, ot.is_system, ot.name, ot.description, ot.template, ot.version, ot.is_active, ot.created_at, ot.updated_at
            from public.operation_templates ot
            where ot.id = (p_payload->>'id')::uuid
              and (ot.is_system = true or ot.tenant_id = v_tid or platform.is_platform_admin())
        ) t;
        if v_result is null then raise exception 'Template not found'; end if;

    when 'create_template' then
        v_tid := platform.current_tenant_id();
        insert into public.operation_templates (tenant_id, is_system, name, description, template, version, is_active)
        values (
            v_tid, false, p_payload->>'name', p_payload->>'description',
            p_payload->'template', coalesce((p_payload->>'version')::int, 1),
            coalesce((p_payload->>'is_active')::boolean, true)
        )
        returning id, tenant_id, is_system, name, description, template, version, is_active, created_at, updated_at into v_row;
        perform platform.log_audit('operation_template.created', 'operation_template', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_template' then
        v_tid := platform.current_tenant_id();
        update public.operation_templates ot set
            name = case when p_payload ? 'name' then p_payload->>'name' else ot.name end,
            description = case when p_payload ? 'description' then p_payload->>'description' else ot.description end,
            template = case when p_payload ? 'template' then p_payload->'template' else ot.template end,
            version = case when p_payload ? 'version' then (p_payload->>'version')::int else ot.version end,
            is_active = case when p_payload ? 'is_active' then (p_payload->>'is_active')::boolean else ot.is_active end
        where ot.id = (p_payload->>'id')::uuid and ot.is_system = false and ot.tenant_id = v_tid
        returning ot.id, ot.tenant_id, ot.is_system, ot.name, ot.description, ot.template, ot.version, ot.is_active, ot.created_at, ot.updated_at into v_row;
        if not found then raise exception 'Template not found'; end if;
        perform platform.log_audit('operation_template.updated', 'operation_template', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_template' then
        v_tid := platform.current_tenant_id();
        delete from public.operation_templates ot
        where ot.id = (p_payload->>'id')::uuid and ot.is_system = false and ot.tenant_id = v_tid;
        if not found then raise exception 'Template not found'; end if;
        perform platform.log_audit('operation_template.deleted', 'operation_template', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_workflows' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb) into v_result
        from (
            select ow.id, ow.tenant_id, ow.source_template_id, ow.name, ow.description, ow.is_active, ow.version, ow.created_at, ow.updated_at
            from public.operation_workflows ow where ow.tenant_id = v_tid
        ) t;

    when 'get_workflow' then
        v_tid := platform.current_tenant_id();
        v_workflow_id := (p_payload->>'id')::uuid;
        select jsonb_build_object(
            'workflow', (
                select to_jsonb(t) from (
                    select ow.id, ow.tenant_id, ow.source_template_id, ow.name, ow.description, ow.is_active, ow.version, ow.created_at, ow.updated_at
                    from public.operation_workflows ow where ow.id = v_workflow_id and ow.tenant_id = v_tid
                ) t
            ),
            'steps', coalesce((
                select jsonb_agg(to_jsonb(ws) order by ws.step_order)
                from (
                    select ws.id, ws.tenant_id, ws.workflow_id, ws.step_order, ws.action_type, ws.config, ws.delay_seconds, ws.created_at
                    from public.workflow_steps ws where ws.workflow_id = v_workflow_id
                ) ws
            ), '[]'::jsonb),
            'triggers', coalesce((
                select jsonb_agg(to_jsonb(wt) order by wt.created_at)
                from (
                    select wt.id, wt.tenant_id, wt.workflow_id, wt.property_id, wt.trigger_type, wt.trigger_config, wt.is_active, wt.created_at
                    from public.workflow_triggers wt where wt.workflow_id = v_workflow_id
                ) wt
            ), '[]'::jsonb)
        ) into v_result;
        if v_result->'workflow' = 'null'::jsonb then raise exception 'Workflow not found'; end if;

    when 'create_workflow' then
        v_tid := platform.current_tenant_id();
        insert into public.operation_workflows (tenant_id, name, description, source_template_id, is_active, version)
        values (
            v_tid, p_payload->>'name', p_payload->>'description',
            case when p_payload ? 'source_template_id' then (p_payload->>'source_template_id')::uuid else null end,
            coalesce((p_payload->>'is_active')::boolean, true),
            coalesce((p_payload->>'version')::int, 1)
        )
        returning id, tenant_id, source_template_id, name, description, is_active, version, created_at, updated_at into v_row;
        perform platform.log_audit('operation_workflow.created', 'operation_workflow', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_workflow' then
        v_tid := platform.current_tenant_id();
        update public.operation_workflows ow set
            name = case when p_payload ? 'name' then p_payload->>'name' else ow.name end,
            description = case when p_payload ? 'description' then p_payload->>'description' else ow.description end,
            source_template_id = case when p_payload ? 'source_template_id'
                then (p_payload->>'source_template_id')::uuid else ow.source_template_id end,
            is_active = case when p_payload ? 'is_active' then (p_payload->>'is_active')::boolean else ow.is_active end,
            version = case when p_payload ? 'version' then (p_payload->>'version')::int else ow.version end
        where ow.id = (p_payload->>'id')::uuid and ow.tenant_id = v_tid
        returning ow.id, ow.tenant_id, ow.source_template_id, ow.name, ow.description, ow.is_active, ow.version, ow.created_at, ow.updated_at into v_row;
        if not found then raise exception 'Workflow not found'; end if;
        perform platform.log_audit('operation_workflow.updated', 'operation_workflow', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_workflow' then
        v_tid := platform.current_tenant_id();
        delete from public.operation_workflows ow
        where ow.id = (p_payload->>'id')::uuid and ow.tenant_id = v_tid;
        if not found then raise exception 'Workflow not found'; end if;
        perform platform.log_audit('operation_workflow.deleted', 'operation_workflow', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_workflow_steps' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.step_order), '[]'::jsonb) into v_result
        from (
            select ws.id, ws.tenant_id, ws.workflow_id, ws.step_order, ws.action_type, ws.config, ws.delay_seconds, ws.created_at
            from public.workflow_steps ws
            join public.operation_workflows ow on ow.id = ws.workflow_id
            where ws.workflow_id = (p_payload->>'workflow_id')::uuid and ow.tenant_id = v_tid
        ) t;

    when 'create_workflow_step' then
        v_tid := platform.current_tenant_id();
        select ow.tenant_id into v_workflow_tenant from public.operation_workflows ow
        where ow.id = (p_payload->>'workflow_id')::uuid and ow.tenant_id = v_tid;
        if not found then raise exception 'Workflow not found'; end if;
        insert into public.workflow_steps (tenant_id, workflow_id, step_order, action_type, config, delay_seconds)
        values (
            v_workflow_tenant,
            (p_payload->>'workflow_id')::uuid,
            (p_payload->>'step_order')::int,
            (p_payload->>'action_type')::public.automation_action_type,
            coalesce(p_payload->'config', '{}'::jsonb),
            coalesce((p_payload->>'delay_seconds')::int, 0)
        )
        returning id, tenant_id, workflow_id, step_order, action_type, config, delay_seconds, created_at into v_row;
        perform platform.log_audit('workflow_step.created', 'workflow_step', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_workflow_step' then
        v_tid := platform.current_tenant_id();
        update public.workflow_steps ws set
            step_order = case when p_payload ? 'step_order' then (p_payload->>'step_order')::int else ws.step_order end,
            action_type = case when p_payload ? 'action_type'
                then (p_payload->>'action_type')::public.automation_action_type else ws.action_type end,
            config = case when p_payload ? 'config' then p_payload->'config' else ws.config end,
            delay_seconds = case when p_payload ? 'delay_seconds' then (p_payload->>'delay_seconds')::int else ws.delay_seconds end
        where ws.id = (p_payload->>'id')::uuid and ws.tenant_id = v_tid
        returning ws.id, ws.tenant_id, ws.workflow_id, ws.step_order, ws.action_type, ws.config, ws.delay_seconds, ws.created_at into v_row;
        if not found then raise exception 'Workflow step not found'; end if;
        perform platform.log_audit('workflow_step.updated', 'workflow_step', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_workflow_step' then
        v_tid := platform.current_tenant_id();
        delete from public.workflow_steps ws where ws.id = (p_payload->>'id')::uuid and ws.tenant_id = v_tid;
        if not found then raise exception 'Workflow step not found'; end if;
        perform platform.log_audit('workflow_step.deleted', 'workflow_step', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_workflow_triggers' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb) into v_result
        from (
            select wt.id, wt.tenant_id, wt.workflow_id, wt.property_id, wt.trigger_type, wt.trigger_config, wt.is_active, wt.created_at
            from public.workflow_triggers wt
            join public.operation_workflows ow on ow.id = wt.workflow_id
            where wt.workflow_id = (p_payload->>'workflow_id')::uuid and ow.tenant_id = v_tid
        ) t;

    when 'create_workflow_trigger' then
        v_tid := platform.current_tenant_id();
        select ow.tenant_id into v_workflow_tenant from public.operation_workflows ow
        where ow.id = (p_payload->>'workflow_id')::uuid and ow.tenant_id = v_tid;
        if not found then raise exception 'Workflow not found'; end if;
        insert into public.workflow_triggers (tenant_id, workflow_id, property_id, trigger_type, trigger_config, is_active)
        values (
            v_workflow_tenant,
            (p_payload->>'workflow_id')::uuid,
            case when p_payload ? 'property_id' then (p_payload->>'property_id')::uuid else null end,
            (p_payload->>'trigger_type')::public.automation_trigger_type,
            coalesce(p_payload->'trigger_config', '{}'::jsonb),
            coalesce((p_payload->>'is_active')::boolean, true)
        )
        returning id, tenant_id, workflow_id, property_id, trigger_type, trigger_config, is_active, created_at into v_row;
        perform platform.log_audit('workflow_trigger.created', 'workflow_trigger', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_workflow_trigger' then
        v_tid := platform.current_tenant_id();
        update public.workflow_triggers wt set
            trigger_type = case when p_payload ? 'trigger_type'
                then (p_payload->>'trigger_type')::public.automation_trigger_type else wt.trigger_type end,
            property_id = case when p_payload ? 'property_id'
                then (p_payload->>'property_id')::uuid else wt.property_id end,
            trigger_config = case when p_payload ? 'trigger_config' then p_payload->'trigger_config' else wt.trigger_config end,
            is_active = case when p_payload ? 'is_active' then (p_payload->>'is_active')::boolean else wt.is_active end
        where wt.id = (p_payload->>'id')::uuid and wt.tenant_id = v_tid
        returning wt.id, wt.tenant_id, wt.workflow_id, wt.property_id, wt.trigger_type, wt.trigger_config, wt.is_active, wt.created_at into v_row;
        if not found then raise exception 'Workflow trigger not found'; end if;
        perform platform.log_audit('workflow_trigger.updated', 'workflow_trigger', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_workflow_trigger' then
        v_tid := platform.current_tenant_id();
        delete from public.workflow_triggers wt where wt.id = (p_payload->>'id')::uuid and wt.tenant_id = v_tid;
        if not found then raise exception 'Workflow trigger not found'; end if;
        perform platform.log_audit('workflow_trigger.deleted', 'workflow_trigger', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_support_tickets' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb) into v_result
        from (
            select st.id, st.tenant_id, st.user_id, st.subject, st.description, st.status, st.priority, st.created_at, st.updated_at
            from public.support_tickets st
            where st.tenant_id = v_tid
              and (p_payload->>'status' is null or st.status::text = p_payload->>'status')
              and (p_payload->>'priority' is null or st.priority::text = p_payload->>'priority')
        ) t;

    when 'get_support_ticket' then
        v_tid := platform.current_tenant_id();
        select to_jsonb(t) into v_result from (
            select st.id, st.tenant_id, st.user_id, st.subject, st.description, st.status, st.priority, st.created_at, st.updated_at
            from public.support_tickets st
            where st.id = (p_payload->>'id')::uuid and st.tenant_id = v_tid
        ) t;
        if v_result is null then raise exception 'Support ticket not found'; end if;

    when 'create_support_ticket' then
        v_tid := platform.current_tenant_id();
        insert into public.support_tickets (tenant_id, user_id, subject, description, priority)
        values (
            v_tid,
            coalesce((p_payload->>'user_id')::uuid, v_uid),
            p_payload->>'subject',
            p_payload->>'description',
            coalesce((p_payload->>'priority')::public.priority_level, 'normal'::public.priority_level)
        )
        returning id, tenant_id, user_id, subject, description, status, priority, created_at, updated_at into v_row;
        perform platform.log_audit('support_ticket.created', 'support_ticket', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_support_ticket' then
        v_tid := platform.current_tenant_id();
        update public.support_tickets st set
            subject = case when p_payload ? 'subject' then p_payload->>'subject' else st.subject end,
            description = case when p_payload ? 'description' then p_payload->>'description' else st.description end,
            status = case when p_payload ? 'status'
                then (p_payload->>'status')::public.support_ticket_status else st.status end,
            priority = case when p_payload ? 'priority'
                then (p_payload->>'priority')::public.priority_level else st.priority end,
            user_id = case when p_payload ? 'user_id' then (p_payload->>'user_id')::uuid else st.user_id end
        where st.id = (p_payload->>'id')::uuid and st.tenant_id = v_tid
        returning st.id, st.tenant_id, st.user_id, st.subject, st.description, st.status, st.priority, st.created_at, st.updated_at into v_row;
        if not found then raise exception 'Support ticket not found'; end if;
        perform platform.log_audit('support_ticket.updated', 'support_ticket', v_row.id, p_payload);
        v_result := to_jsonb(v_row);

    when 'delete_support_ticket' then
        v_tid := platform.current_tenant_id();
        delete from public.support_tickets st where st.id = (p_payload->>'id')::uuid and st.tenant_id = v_tid;
        if not found then raise exception 'Support ticket not found'; end if;
        perform platform.log_audit('support_ticket.deleted', 'support_ticket', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_support_messages' then
        v_tid := platform.current_tenant_id();
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), '[]'::jsonb) into v_result
        from (
            select sm.id, sm.tenant_id, sm.ticket_id, sm.sender_type, sm.message, sm.created_at
            from public.support_messages sm
            where sm.ticket_id = (p_payload->>'ticket_id')::uuid and sm.tenant_id = v_tid
        ) t;

    when 'create_support_message' then
        v_tid := platform.current_tenant_id();
        if coalesce(p_payload->>'sender_type', 'user') <> 'user' then
            raise exception 'Tenant portal may only send user messages';
        end if;
        insert into public.support_messages (tenant_id, ticket_id, sender_type, message)
        values (
            v_tid,
            (p_payload->>'ticket_id')::uuid,
            'user'::public.support_sender_type,
            p_payload->>'message'
        )
        returning id, tenant_id, ticket_id, sender_type, message, created_at into v_row;
        perform platform.log_audit('support_message.created', 'support_message', v_row.id);
        v_result := to_jsonb(v_row);

    else
        raise exception 'unknown operations_api operation: %', p_op;
    end case;

    return v_result;
end;
$$;


-- =====================================================
-- 18. NOTIFICATION DOMAIN API
-- =====================================================

create or replace function public.notification_domain(
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
    v_template public.notification_templates;
    v_result jsonb;
    v_subject text;
    v_body text;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);
    v_tid := platform.current_tenant_id();
    v_uid := auth.uid();

    case p_op
    when 'list_templates' then
        if v_tid is null then raise exception 'no active tenant'; end if;
        select coalesce(jsonb_agg(to_jsonb(t) order by t.code), '[]'::jsonb) into v_result
        from (
            select nt.id, nt.tenant_id, nt.code, nt.channel, nt.subject_template,
                   nt.body_template, nt.metadata, nt.is_active, nt.created_at, nt.updated_at
            from public.notification_templates nt
            where nt.tenant_id is null or nt.tenant_id = v_tid
        ) t;

    when 'get_template' then
        if v_tid is null then raise exception 'no active tenant'; end if;
        select to_jsonb(t) into v_result from (
            select nt.id, nt.tenant_id, nt.code, nt.channel, nt.subject_template,
                   nt.body_template, nt.metadata, nt.is_active, nt.created_at, nt.updated_at
            from public.notification_templates nt
            where nt.id = (p_payload->>'id')::uuid
              and (nt.tenant_id is null or nt.tenant_id = v_tid)
        ) t;
        if v_result is null then raise exception 'Notification template not found'; end if;

    when 'create_template' then
        if v_tid is null then raise exception 'no active tenant'; end if;
        insert into public.notification_templates (
            tenant_id, code, channel, subject_template, body_template, metadata, is_active
        )
        values (
            v_tid,
            p_payload->>'code',
            (p_payload->>'channel')::public.notification_channel,
            p_payload->>'subject_template',
            p_payload->>'body_template',
            coalesce(p_payload->'metadata', '{}'::jsonb),
            coalesce((p_payload->>'is_active')::boolean, true)
        )
        returning id, tenant_id, code, channel, subject_template, body_template,
                  metadata, is_active, created_at, updated_at into v_row;
        perform platform.log_audit('notification_template.created', 'notification_template', v_row.id);
        v_result := to_jsonb(v_row);

    when 'update_template' then
        if v_tid is null then raise exception 'no active tenant'; end if;
        update public.notification_templates nt set
            subject_template = case when p_payload ? 'subject_template' then p_payload->>'subject_template' else nt.subject_template end,
            body_template = case when p_payload ? 'body_template' then p_payload->>'body_template' else nt.body_template end,
            metadata = case when p_payload ? 'metadata' then p_payload->'metadata' else nt.metadata end,
            is_active = case when p_payload ? 'is_active' then (p_payload->>'is_active')::boolean else nt.is_active end
        where nt.id = (p_payload->>'id')::uuid and nt.tenant_id = v_tid
        returning nt.id, nt.tenant_id, nt.code, nt.channel, nt.subject_template, nt.body_template,
                  nt.metadata, nt.is_active, nt.created_at, nt.updated_at into v_row;
        if not found then raise exception 'Notification template not found'; end if;
        perform platform.log_audit('notification_template.updated', 'notification_template', v_row.id);
        v_result := to_jsonb(v_row);

    when 'delete_template' then
        if v_tid is null then raise exception 'no active tenant'; end if;
        delete from public.notification_templates nt
        where nt.id = (p_payload->>'id')::uuid and nt.tenant_id = v_tid;
        if not found then raise exception 'Notification template not found'; end if;
        perform platform.log_audit('notification_template.deleted', 'notification_template', (p_payload->>'id')::uuid);
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

    when 'list_preferences' then
        if v_tid is null then raise exception 'no active tenant'; end if;
        select coalesce(jsonb_agg(to_jsonb(t) order by t.channel), '[]'::jsonb) into v_result
        from (
            select np.id, np.tenant_id, np.user_id, np.channel, np.is_enabled, np.metadata,
                   np.created_at, np.updated_at
            from public.notification_preferences np
            where np.tenant_id = v_tid
              and (p_payload->>'user_id' is null or np.user_id = (p_payload->>'user_id')::uuid)
        ) t;

    when 'upsert_preference' then
        if v_tid is null then raise exception 'no active tenant'; end if;
        insert into public.notification_preferences (tenant_id, user_id, channel, is_enabled, metadata)
        values (
            v_tid,
            case when p_payload ? 'user_id' then (p_payload->>'user_id')::uuid else null end,
            (p_payload->>'channel')::public.notification_channel,
            coalesce((p_payload->>'is_enabled')::boolean, true),
            coalesce(p_payload->'metadata', '{}'::jsonb)
        )
        on conflict (tenant_id, user_id, channel) do update set
            is_enabled = excluded.is_enabled,
            metadata = excluded.metadata,
            updated_at = now()
        returning id, tenant_id, user_id, channel, is_enabled, metadata, created_at, updated_at into v_row;
        perform platform.log_audit('notification_preference.upserted', 'notification_preference', v_row.id);
        v_result := to_jsonb(v_row);

    when 'enqueue_notification' then
        if v_tid is null then raise exception 'no active tenant'; end if;

        if not public.notification_is_channel_enabled(
            v_tid,
            case when p_payload ? 'user_id' then (p_payload->>'user_id')::uuid else v_uid end,
            (p_payload->>'channel')::public.notification_channel
        ) then
            return jsonb_build_object('skipped', true, 'reason', 'channel_disabled');
        end if;

        v_subject := p_payload->>'subject';
        v_body := p_payload->>'body';

        if p_payload ? 'template_code' then
            v_template := public.notification_resolve_template(
                v_tid,
                p_payload->>'template_code',
                (p_payload->>'channel')::public.notification_channel
            );
            if v_template.id is not null then
                v_subject := coalesce(v_subject, v_template.subject_template);
                v_body := coalesce(v_body, v_template.body_template);
            end if;
        end if;

        if v_body is null then
            raise exception 'notification body or template_code is required';
        end if;

        insert into public.notification_queue (
            tenant_id, channel, recipient, template_id, template_code,
            subject, body, payload, status, scheduled_at, source, correlation_id
        )
        values (
            v_tid,
            (p_payload->>'channel')::public.notification_channel,
            p_payload->>'recipient',
            v_template.id,
            p_payload->>'template_code',
            v_subject,
            v_body,
            coalesce(p_payload->'payload', '{}'::jsonb),
            'queued'::public.notification_delivery_status,
            coalesce((p_payload->>'scheduled_at')::timestamptz, now()),
            coalesce(p_payload->>'source', 'api'),
            coalesce((p_payload->>'correlation_id')::uuid, gen_random_uuid())
        )
        returning id, tenant_id, channel, recipient, template_id, template_code, subject, body,
                  payload, status, scheduled_at, attempt_count, max_attempts, correlation_id,
                  source, created_at, updated_at into v_row;

        perform platform.log_audit('notification.enqueued', 'notification_queue', v_row.id);
        v_result := to_jsonb(v_row);

    when 'list_queue' then
        if v_tid is null then raise exception 'no active tenant'; end if;
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb) into v_result
        from (
            select nq.id, nq.tenant_id, nq.channel, nq.recipient, nq.template_code, nq.status,
                   nq.scheduled_at, nq.attempt_count, nq.max_attempts, nq.correlation_id,
                   nq.source, nq.created_at, nq.updated_at
            from public.notification_queue nq
            where nq.tenant_id = v_tid
              and (p_payload->>'status' is null or nq.status::text = p_payload->>'status')
        ) t;

    when 'get_notification' then
        if v_tid is null then raise exception 'no active tenant'; end if;
        select to_jsonb(t) into v_result from (
            select nh.id, nh.tenant_id, nh.queue_id, nh.channel, nh.recipient, nh.status,
                   nh.subject, nh.body, nh.payload, nh.error, nh.sent_at, nh.created_at
            from public.notification_history nh
            where nh.id = (p_payload->>'id')::uuid and nh.tenant_id = v_tid
        ) t;
        if v_result is null then raise exception 'Notification not found'; end if;

    when 'list_history' then
        if v_tid is null then raise exception 'no active tenant'; end if;
        select coalesce(jsonb_agg(to_jsonb(t) order by t.sent_at desc), '[]'::jsonb) into v_result
        from (
            select nh.id, nh.tenant_id, nh.queue_id, nh.channel, nh.recipient, nh.status,
                   nh.subject, nh.payload, nh.sent_at, nh.created_at
            from public.notification_history nh
            where nh.tenant_id = v_tid
              and (p_payload->>'channel' is null or nh.channel::text = p_payload->>'channel')
        ) t;

    when 'cancel_notification' then
        if v_tid is null then raise exception 'no active tenant'; end if;
        update public.notification_queue nq set
            status = 'cancelled'::public.notification_delivery_status,
            updated_at = now()
        where nq.id = (p_payload->>'id')::uuid
          and nq.tenant_id = v_tid
          and nq.status = 'queued'::public.notification_delivery_status
        returning nq.id into v_row;
        if not found then raise exception 'Queued notification not found'; end if;
        perform platform.log_audit('notification.cancelled', 'notification_queue', v_row.id);
        v_result := jsonb_build_object('cancelled', true, 'id', v_row.id);

    else
        raise exception 'unknown notification_domain operation: %', p_op;
    end case;

    return v_result;
end;
$$;

-- =====================================================
-- 21. TRIGGERS
-- =====================================================

create trigger trg_operation_templates_updated_at
before update on operation_templates
for each row execute function platform.set_updated_at();


create trigger trg_operation_workflows_updated_at
before update on operation_workflows
for each row execute function platform.set_updated_at();


create trigger trg_operation_workflows_template_scope
before insert or update on operation_workflows
for each row execute function public.enforce_workflow_template_scope();


create trigger trg_workflow_triggers_scope
before insert or update on workflow_triggers
for each row execute function public.enforce_workflow_trigger_scope();


create trigger trg_workflow_steps_tenant_consistency
before insert or update on public.workflow_steps
for each row execute function public.enforce_workflow_child_tenant_consistency();


create trigger trg_workflow_triggers_tenant_consistency
before insert or update on public.workflow_triggers
for each row execute function public.enforce_workflow_child_tenant_consistency();


create trigger trg_support_tickets_updated_at
before update on support_tickets
for each row execute function platform.set_updated_at();


create trigger trg_support_tickets_user_membership
before insert or update on public.support_tickets
for each row execute function public.enforce_support_ticket_user_membership();


create trigger trg_support_messages_tenant_consistency
before insert or update on public.support_messages
for each row execute function public.enforce_support_message_tenant_consistency();


create trigger trg_notification_templates_updated_at
before update on public.notification_templates
for each row execute function platform.set_updated_at();


create trigger trg_notification_preferences_updated_at
before update on public.notification_preferences
for each row execute function platform.set_updated_at();


create trigger trg_notification_queue_updated_at
before update on public.notification_queue
for each row execute function platform.set_updated_at();


-- =====================================================
-- 22. MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('009_operations_engine', 'REV1', false)
on conflict (version) do nothing;


-- =====================================================
-- END 009 OPERATIONS ENGINE
-- =====================================================