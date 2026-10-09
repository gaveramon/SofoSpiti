-- ============================================================
-- 026 SUPABASE FUNCTIONAL HEALTHCHECK SUPPORT  (HARDENED)
-- ============================================================
--
-- Only ONE identity may use this schema, the storage bucket and
-- the realtime test table: the dedicated healthcheck user.
--
-- The healthcheck user is recognised by the JWT claim
--     app_metadata.healthcheck = true
-- app_metadata cannot be edited by end users (unlike
-- user_metadata); it can only be set with the service_role key,
-- the Auth admin API or SQL.
--
-- ONE-TIME SETUP (manual, not part of the migration):
--
--   update auth.users
--   set raw_app_meta_data =
--       coalesce(raw_app_meta_data, '{}'::jsonb)
--       || '{"healthcheck": true}'::jsonb
--   where email = '<healthcheck user email>';
--
-- Then sign in again: the claim is only in tokens issued after
-- the update.
--
-- The healthcheck user must NOT be a member of any customer
-- tenant. Give it its own test tenant if the daily check also
-- exercises the *_api functions.
--
-- Idempotent: safe to run on top of the earlier version.
-- ============================================================

begin;

create schema if not exists healthcheck;

revoke all on schema healthcheck from public, anon;
grant usage on schema healthcheck to authenticated;


-- ------------------------------------------------------------
-- Identity check (used by every policy and function below)
-- ------------------------------------------------------------

create or replace function healthcheck.is_healthcheck_user()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
    select
        coalesce((select auth.role()), '') = 'authenticated'
        and coalesce(
            (select auth.jwt()) -> 'app_metadata' ->> 'healthcheck',
            'false'
        ) = 'true'
        and coalesce(
            (select auth.jwt()) ->> 'is_anonymous',
            'false'
        ) <> 'true';
$$;

revoke all on function healthcheck.is_healthcheck_user() from public, anon;
grant execute on function healthcheck.is_healthcheck_user() to authenticated;


-- ------------------------------------------------------------
-- REST/PostgREST test
-- ------------------------------------------------------------

create or replace function healthcheck.ping()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
    if not healthcheck.is_healthcheck_user() then
        raise exception 'HEALTHCHECK_USER_REQUIRED'
            using errcode = '42501';
    end if;

    return jsonb_build_object(
        'status', 'ok',
        'timestamp', now()
    );
end;
$$;

revoke all on function healthcheck.ping() from public, anon;
grant execute on function healthcheck.ping() to authenticated;


-- ------------------------------------------------------------
-- Realtime test table
-- ------------------------------------------------------------

create table if not exists healthcheck.realtime_test (
    id uuid primary key default gen_random_uuid(),
    test_id uuid not null,
    user_id uuid default auth.uid(),
    created_at timestamptz not null default now()
);

-- Table may already exist from the earlier version of this file.
alter table healthcheck.realtime_test
    add column if not exists user_id uuid default auth.uid();

alter table healthcheck.realtime_test enable row level security;

revoke all on healthcheck.realtime_test from public, anon, authenticated;

grant select, insert, delete
on healthcheck.realtime_test
to authenticated;

drop policy if exists healthcheck_realtime_insert
    on healthcheck.realtime_test;

create policy healthcheck_realtime_insert
on healthcheck.realtime_test
for insert
to authenticated
with check (
    healthcheck.is_healthcheck_user()
    and user_id = (select auth.uid())
);

drop policy if exists healthcheck_realtime_select
    on healthcheck.realtime_test;

create policy healthcheck_realtime_select
on healthcheck.realtime_test
for select
to authenticated
using (
    healthcheck.is_healthcheck_user()
    and user_id = (select auth.uid())
);

drop policy if exists healthcheck_realtime_delete
    on healthcheck.realtime_test;

create policy healthcheck_realtime_delete
on healthcheck.realtime_test
for delete
to authenticated
using (
    healthcheck.is_healthcheck_user()
    and user_id = (select auth.uid())
);


-- ------------------------------------------------------------
-- Cleanup (call at the end of the daily/weekly run)
-- ------------------------------------------------------------

create or replace function healthcheck.cleanup(
    p_older_than interval default interval '1 day'
)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_count integer;
begin
    if not healthcheck.is_healthcheck_user() then
        raise exception 'HEALTHCHECK_USER_REQUIRED'
            using errcode = '42501';
    end if;

    delete from healthcheck.realtime_test t
    where t.created_at < now() - p_older_than
      and t.user_id = (select auth.uid());

    get diagnostics v_count = row_count;

    return v_count;
end;
$$;

revoke all on function healthcheck.cleanup(interval) from public, anon;
grant execute on function healthcheck.cleanup(interval) to authenticated;


-- ------------------------------------------------------------
-- Realtime publication (idempotent)
-- ------------------------------------------------------------

do $$
begin
    if not exists (
        select 1
        from pg_publication
        where pubname = 'supabase_realtime'
    ) then
        create publication supabase_realtime;
    end if;

    if not exists (
        select 1
        from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'healthcheck'
          and tablename = 'realtime_test'
    ) then
        alter publication supabase_realtime
            add table healthcheck.realtime_test;
    end if;
end
$$;


-- ------------------------------------------------------------
-- Storage bucket (private, small, text/json only)
-- ------------------------------------------------------------

insert into storage.buckets (
    id,
    name,
    public,
    file_size_limit,
    allowed_mime_types
)
values (
    'healthcheck',
    'healthcheck',
    false,
    1048576,
    array['text/plain', 'application/json']
)
on conflict (id) do update
set
    public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;


-- ------------------------------------------------------------
-- Storage policies (healthcheck user only)
-- ------------------------------------------------------------

drop policy if exists healthcheck_storage_insert
on storage.objects;

create policy healthcheck_storage_insert
on storage.objects
for insert
to authenticated
with check (
    bucket_id = 'healthcheck'
    and healthcheck.is_healthcheck_user()
);

drop policy if exists healthcheck_storage_select
on storage.objects;

create policy healthcheck_storage_select
on storage.objects
for select
to authenticated
using (
    bucket_id = 'healthcheck'
    and healthcheck.is_healthcheck_user()
);

drop policy if exists healthcheck_storage_delete
on storage.objects;

create policy healthcheck_storage_delete
on storage.objects
for delete
to authenticated
using (
    bucket_id = 'healthcheck'
    and healthcheck.is_healthcheck_user()
);


-- ------------------------------------------------------------
-- Self-check: fail the migration if the isolation is missing
-- ------------------------------------------------------------

do $$
begin
    if exists (
        select 1
        from pg_policies p
        where (
                p.schemaname = 'healthcheck'
                or (
                    p.schemaname = 'storage'
                    and p.tablename = 'objects'
                    and p.policyname like 'healthcheck\_%'
                )
              )
          and (coalesce(p.qual, '') || coalesce(p.with_check, ''))
              not like '%is_healthcheck_user%'
    ) then
        raise exception
            '026 healthcheck: a policy is not restricted to the healthcheck user';
    end if;

    if has_table_privilege('anon', 'healthcheck.realtime_test', 'SELECT')
       or has_table_privilege('anon', 'healthcheck.realtime_test', 'INSERT') then
        raise exception
            '026 healthcheck: anon must not have access to healthcheck.realtime_test';
    end if;
end
$$;

commit;
