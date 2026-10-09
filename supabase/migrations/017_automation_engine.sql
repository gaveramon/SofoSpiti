-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 017 AUTOMATION ENGINE (RUNTIME EXECUTION LAYER)
-- =====================================================
--
-- Event-driven workflow execution — definitions live in 009
-- Platform queues / device commands live in 000
-- NO business rule duplication — triggers dispatch via RPC only
-- =====================================================


-- =====================================================
-- 1. AUTOMATION RUNS
-- Runtime execution instances of operation workflows
-- =====================================================

create table if not exists public.automation_runs (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    property_id uuid,

    workflow_id uuid not null references operation_workflows(id) on delete restrict,

    trigger_type public.automation_trigger_type not null,

    trigger_payload jsonb not null default '{}'::jsonb,

    correlation_id uuid not null default gen_random_uuid(),

    status public.automation_run_status not null default 'pending',

    started_at timestamptz,
    completed_at timestamptz,

    error_message text,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now()
);


-- =====================================================
-- 2. AUTOMATION RUN STEPS
-- Runtime execution state for individual workflow steps
-- =====================================================

create table if not exists public.automation_run_steps (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    run_id uuid not null references automation_runs(id) on delete cascade,

    workflow_step_id uuid not null references workflow_steps(id) on delete restrict,

    step_order int not null,

    action_type public.automation_action_type not null,

    status public.automation_step_status not null default 'pending',

    result jsonb not null default '{}'::jsonb,

    started_at timestamptz,
    completed_at timestamptz,

    created_at timestamptz not null default now(),

    unique (run_id, step_order),

    constraint chk_automation_run_steps_order check (step_order > 0)
);


-- =====================================================
-- 3. EVENT SUBSCRIPTIONS
-- Active bindings between workflow triggers and runtime
-- =====================================================

create table if not exists public.automation_event_subscriptions (
    id uuid primary key default gen_random_uuid(),

    tenant_id uuid not null references public.tenants(id) on delete cascade,

    workflow_trigger_id uuid not null references workflow_triggers(id) on delete cascade,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),

    unique (workflow_trigger_id)
);


-- =====================================================
-- 4. AUTOMATION INDEXES
-- Runtime lookup, execution state and tenant filtering
-- =====================================================

create index if not exists idx_automation_runs_tenant_created
    on public.automation_runs (tenant_id, created_at desc);


create index if not exists idx_automation_runs_workflow
    on public.automation_runs (workflow_id, created_at desc);


create index if not exists idx_automation_runs_property
    on public.automation_runs (property_id, created_at desc);


create index if not exists idx_automation_runs_status
    on public.automation_runs (tenant_id, status, created_at desc)
    where status in ('pending', 'running');


create index if not exists idx_automation_run_steps_run
    on public.automation_run_steps (run_id, step_order);


create index if not exists idx_automation_run_steps_tenant_created
    on public.automation_run_steps (tenant_id, created_at desc);


create index if not exists idx_automation_event_subscriptions_tenant
    on public.automation_event_subscriptions (tenant_id, created_at desc);


create index if not exists idx_automation_event_subscriptions_active
    on public.automation_event_subscriptions (tenant_id, is_active)
    where is_active = true;


-- =====================================================
-- 5. TENANT FOREIGN KEYS
-- Enforce tenant ownership at database level
-- =====================================================

do $$
begin
    alter table public.automation_runs
        add constraint fk_automation_runs_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table public.automation_runs
        add constraint fk_automation_runs_property_tenant
        foreign key (property_id, tenant_id)
        references public.properties(id, tenant_id) on delete set null;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table public.automation_run_steps
        add constraint fk_automation_run_steps_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


do $$
begin
    alter table public.automation_event_subscriptions
        add constraint fk_automation_event_subscriptions_tenant
        foreign key (tenant_id) references public.tenants(id) on delete cascade;
exception
    when duplicate_object then null;
end $$;


-- =====================================================
-- 6. AUTOMATION CONSISTENCY FUNCTIONS
-- Tenant and workflow ownership validation
-- =====================================================

create or replace function public.enforce_automation_run_tenant_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_workflow_tenant uuid;
begin
    select ow.tenant_id into v_workflow_tenant
    from public.operation_workflows ow
    where ow.id = new.workflow_id;

    if not found then
        raise exception 'workflow not found';
    end if;

    if v_workflow_tenant is distinct from new.tenant_id then
        raise exception 'tenant mismatch between automation run and workflow';
    end if;

    return new;
end;
$$;


create or replace function public.enforce_automation_run_step_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_run_tenant uuid;
    v_step_tenant uuid;
begin
    select ar.tenant_id into v_run_tenant
    from public.automation_runs ar
    where ar.id = new.run_id;

    if not found then
        raise exception 'automation run not found';
    end if;

    select ws.tenant_id, ws.step_order, ws.action_type
    into v_step_tenant, new.step_order, new.action_type
    from public.workflow_steps ws
    where ws.id = new.workflow_step_id;

    if not found then
        raise exception 'workflow step not found';
    end if;

    if v_run_tenant is distinct from new.tenant_id
       or v_step_tenant is distinct from new.tenant_id then
        raise exception 'tenant mismatch on automation run step';
    end if;

    return new;
end;
$$;


create or replace function public.enforce_automation_subscription_consistency()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_trigger_tenant uuid;
begin
    select wt.tenant_id into v_trigger_tenant
    from public.workflow_triggers wt
    where wt.id = new.workflow_trigger_id;

    if not found then
        raise exception 'workflow trigger not found';
    end if;

    if v_trigger_tenant is distinct from new.tenant_id then
        raise exception 'tenant mismatch on automation subscription';
    end if;

    return new;
end;
$$;


-- =====================================================
-- 7. AUTOMATION TRIGGERS
-- Updated-at and tenant consistency enforcement
-- =====================================================

drop trigger if exists trg_automation_runs_tenant_consistency on public.automation_runs;

drop trigger if exists trg_automation_run_steps_consistency on public.automation_run_steps;

drop trigger if exists trg_automation_event_subscriptions_consistency on public.automation_event_subscriptions;

create trigger trg_automation_runs_updated_at
before update on automation_runs
for each row execute function platform.set_updated_at();

create trigger trg_automation_runs_tenant_consistency
before insert or update on public.automation_runs
for each row execute function public.enforce_automation_run_tenant_consistency();

create trigger trg_automation_run_steps_consistency
before insert or update on public.automation_run_steps
for each row execute function public.enforce_automation_run_step_consistency();

create trigger trg_automation_event_subscriptions_consistency
before insert or update on public.automation_event_subscriptions
for each row execute function public.enforce_automation_subscription_consistency();


-- =====================================================
-- 9. AUTOMATION RUNTIME OPERATIONS
-- Start, cancel and dispatch automation runs
-- =====================================================

create or replace function public.automation_start_run(
    p_workflow_id uuid,
    p_trigger_type public.automation_trigger_type,
    p_trigger_payload jsonb default '{}'::jsonb,
    p_property_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_run_id uuid;
    v_step record;
    v_property_id uuid := p_property_id;
begin
    v_tid := platform.current_tenant_id();
    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    if v_property_id is not null and not exists (
        select 1 from public.properties p
        where p.id = v_property_id and p.tenant_id = v_tid
    ) then
        raise exception 'property not found or not owned by active tenant';
    end if;

    if not exists (
        select 1 from public.operation_workflows ow
        where ow.id = p_workflow_id and ow.tenant_id = v_tid and ow.is_active = true
    ) then
        raise exception 'workflow not found or inactive';
    end if;

    insert into public.automation_runs (
        tenant_id, property_id, workflow_id, trigger_type, trigger_payload, status
    )
    values (
        v_tid, v_property_id, p_workflow_id, p_trigger_type, coalesce(p_trigger_payload, '{}'::jsonb), 'pending'
    )
    returning id into v_run_id;

    for v_step in
        select ws.id, ws.step_order, ws.action_type, ws.config
        from public.workflow_steps ws
        where ws.workflow_id = p_workflow_id
        order by ws.step_order
    loop
        insert into public.automation_run_steps (
            tenant_id, run_id, workflow_step_id, step_order, action_type, status
        )
        values (
            v_tid, v_run_id, v_step.id, v_step.step_order, v_step.action_type, 'pending'
        );
    end loop;

    perform platform.log_event(
        'automation.run.started',
        'automation_engine',
        jsonb_build_object('run_id', v_run_id, 'workflow_id', p_workflow_id),
        'info',
        null,
        (select correlation_id from public.automation_runs where id = v_run_id)
    );

    return v_run_id;
end;
$$;


create or replace function public.automation_cancel_run(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_row record;
begin
    v_tid := platform.current_tenant_id();
    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    update public.automation_runs ar set
        status = 'cancelled',
        completed_at = coalesce(ar.completed_at, now())
    where ar.id = p_run_id
      and ar.tenant_id = v_tid
      and ar.status in ('pending', 'running')
    returning ar.id, ar.status, ar.completed_at into v_row;

    if not found then
        raise exception 'run not found or not cancellable';
    end if;

    return to_jsonb(v_row);
end;
$$;


create or replace function public.automation_dispatch_event(
    p_event_type text,
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_tid uuid;
    v_trigger record;
    v_run_ids uuid[] := '{}';
    v_run_id uuid;
begin
    v_tid := platform.current_tenant_id();
    if v_tid is null then
        raise exception 'no active tenant';
    end if;

    for v_trigger in
        select wt.id, wt.workflow_id, wt.trigger_type, wt.property_id
        from public.workflow_triggers wt
        join public.automation_event_subscriptions aes on aes.workflow_trigger_id = wt.id
        where wt.tenant_id = v_tid
          and wt.is_active = true
          and aes.is_active = true
          and wt.trigger_type::text = p_event_type
    loop
        v_run_id := public.automation_start_run(
            v_trigger.workflow_id,
            v_trigger.trigger_type,
            coalesce(p_payload, '{}'::jsonb),
            v_trigger.property_id
        );
        v_run_ids := array_append(v_run_ids, v_run_id);
    end loop;

    return jsonb_build_object(
        'dispatched', coalesce(array_length(v_run_ids, 1), 0),
        'run_ids', to_jsonb(v_run_ids)
    );
end;
$$;


-- =====================================================
-- 10. AUTOMATION DOMAIN API
-- Primary SSOT interface for automation operations
-- =====================================================

create or replace function public.automation_domain(
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
    v_run_id uuid;
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);
    v_tid := platform.current_tenant_id();

    case p_op
    when 'list_runs' then
        if v_tid is null then
            raise exception 'no active tenant';
        end if;
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb)
        into v_result
        from (
            select ar.id, ar.tenant_id, ar.property_id, ar.workflow_id, ar.trigger_type, ar.status,
                   ar.correlation_id, ar.started_at, ar.completed_at, ar.created_at
            from public.automation_runs ar
            where ar.tenant_id = v_tid
              and case
                when p_payload ? 'workflow_id'
                then ar.workflow_id = (p_payload->>'workflow_id')::uuid
                else true
            end
        ) t;

    when 'get_run' then
        if v_tid is null then
            raise exception 'no active tenant';
        end if;
        select to_jsonb(t) into v_result
        from (
            select ar.id, ar.tenant_id, ar.property_id, ar.workflow_id, ar.trigger_type, ar.trigger_payload,
                   ar.status, ar.correlation_id, ar.started_at, ar.completed_at,
                   ar.error_message, ar.created_at
            from public.automation_runs ar
            where ar.id = (p_payload->>'id')::uuid
              and ar.tenant_id = v_tid
        ) t;
        if v_result is null then raise exception 'automation run not found'; end if;

    when 'list_run_steps' then
        if v_tid is null then
            raise exception 'no active tenant';
        end if;
        select coalesce(jsonb_agg(to_jsonb(t) order by t.step_order), '[]'::jsonb)
        into v_result
        from (
            select ars.id, ars.run_id, ars.workflow_step_id, ars.step_order,
                   ars.action_type, ars.status, ars.result, ars.started_at, ars.completed_at
            from public.automation_run_steps ars
            join public.automation_runs ar on ar.id = ars.run_id
            where ars.run_id = (p_payload->>'run_id')::uuid
              and ar.tenant_id = v_tid
        ) t;

    when 'dispatch_event' then
        v_result := public.automation_dispatch_event(
            p_payload->>'event_type',
            coalesce(p_payload->'payload', '{}'::jsonb)
        );

        perform platform.log_audit(
            'automation.event_dispatched',
            'automation_event',
            null::uuid,
            jsonb_build_object('event_type', p_payload->>'event_type', 'dispatched', v_result->'dispatched')
        );

    when 'start_run' then
        v_run_id := public.automation_start_run(
            (p_payload->>'workflow_id')::uuid,
            (p_payload->>'trigger_type')::public.automation_trigger_type,
            coalesce(p_payload->'trigger_payload', '{}'::jsonb),
            (p_payload->>'property_id')::uuid
        );
        select to_jsonb(t) into v_result
        from (
            select ar.id, ar.tenant_id, ar.property_id, ar.workflow_id, ar.trigger_type, ar.status,
                   ar.correlation_id, ar.started_at, ar.completed_at, ar.created_at
            from public.automation_runs ar
            where ar.id = v_run_id and ar.tenant_id = v_tid
        ) t;

        perform platform.log_audit(
            'automation_run.started',
            'automation_run',
            v_run_id,
            jsonb_build_object('workflow_id', p_payload->>'workflow_id', 'trigger_type', p_payload->>'trigger_type')
        );

    when 'cancel_run' then
        v_result := public.automation_cancel_run((p_payload->>'id')::uuid);

        perform platform.log_audit(
            'automation_run.cancelled',
            'automation_run',
            (p_payload->>'id')::uuid
        );

    else
        return public.automation_domain_ext(p_op, p_payload);
    end case;

    return v_result;
end;
$$;


-- =====================================================
-- 11. AUTOMATION DOMAIN EXTENSION
-- Event subscription operations
-- =====================================================

create or replace function public.automation_domain_ext(
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
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);
    v_tid := platform.current_tenant_id();

    case p_op
    when 'list_subscriptions' then
        if v_tid is null then
            raise exception 'no active tenant';
        end if;
        select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), '[]'::jsonb)
        into v_result
        from (
            select
                aes.id,
                aes.tenant_id,
                aes.workflow_trigger_id,
                aes.is_active,
                wt.workflow_id,
                wt.trigger_type,
                wt.property_id,
                aes.created_at
            from public.automation_event_subscriptions aes
            join public.workflow_triggers wt on wt.id = aes.workflow_trigger_id
            where aes.tenant_id = v_tid
              and case
                when p_payload ? 'workflow_id'
                then wt.workflow_id = (p_payload->>'workflow_id')::uuid
                else true
            end
        ) t;

    when 'upsert_subscription' then
        if v_tid is null then
            raise exception 'no active tenant';
        end if;
        insert into public.automation_event_subscriptions (
            tenant_id, workflow_trigger_id, is_active
        )
        values (
            v_tid,
            (p_payload->>'workflow_trigger_id')::uuid,
            coalesce((p_payload->>'is_active')::boolean, true)
        )
        on conflict (workflow_trigger_id) do update set
            is_active = coalesce(
                excluded.is_active,
                public.automation_event_subscriptions.is_active
            )
        where public.automation_event_subscriptions.tenant_id = excluded.tenant_id
        returning id, tenant_id, workflow_trigger_id, is_active, created_at into v_row;
        v_result := to_jsonb(v_row);

        perform platform.log_audit(
            'automation_subscription.upserted',
            'automation_subscription',
            v_row.id,
            jsonb_build_object('workflow_trigger_id', v_row.workflow_trigger_id, 'is_active', v_row.is_active)
        );

    when 'delete_subscription' then
        if v_tid is null then
            raise exception 'no active tenant';
        end if;
        delete from public.automation_event_subscriptions aes
        where aes.id = (p_payload->>'id')::uuid
          and aes.tenant_id = v_tid;
        if not found then raise exception 'subscription not found'; end if;
        v_result := jsonb_build_object('deleted', true, 'id', p_payload->>'id');

        perform platform.log_audit(
            'automation_subscription.deleted',
            'automation_subscription',
            (p_payload->>'id')::uuid
        );

    else
        raise exception 'unknown automation_domain operation: %', p_op;
    end case;

    return v_result;
end;
$$;


-- =====================================================
-- 12. AUTOMATION INTEGRATION / ENQUEUE
-- Delegation from automation engine to notification domain
-- =====================================================

create or replace function public.automation_enqueue_notification(
    p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    p_payload := coalesce(p_payload, '{}'::jsonb);
    p_payload := p_payload || jsonb_build_object('source', 'automation');
    return public.notification_domain('enqueue_notification', p_payload);
end;
$$;


-- =====================================================
-- 13. UI READ CONTRACT
-- Appsmith overview of automation execution
-- =====================================================

create or replace view public.v_automation_runs_overview
with (security_invoker = true)
as
select
    ar.id,
    ar.tenant_id,
    ar.property_id,
    ar.workflow_id,
    ow.name as workflow_name,
    ar.trigger_type,
    ar.status,
    ar.correlation_id,
    ar.started_at,
    ar.completed_at,
    ar.error_message,
    (
        select count(*)
        from public.automation_run_steps ars
        where ars.run_id = ar.id
    ) as step_count,
    (
        select count(*)
        from public.automation_run_steps ars
        where ars.run_id = ar.id and ars.status = 'completed'
    ) as completed_step_count,
    ar.created_at
from public.automation_runs ar
join public.operation_workflows ow on ow.id = ar.workflow_id;


-- =====================================================
-- END 017 AUTOMATION ENGINE
-- =====================================================

insert into platform.schema_migrations (migration_name, version, rollback_available)
values ('017_automation_engine', 'REV1', false)
on conflict (migration_name) do nothing;