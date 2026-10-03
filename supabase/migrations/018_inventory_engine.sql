-- =====================================================
-- REV1 GREENFIELD BASELINE 
-- 018_INVENTORY_ENGINE.SQL
-- =====================================================

-- TODO

-- =====================================================
-- xx. MIGRATION REGISTRATION
-- =====================================================
--
-- 018 EDGE RPC FOUNDATION
--
-- Security/API foundation only.
--
-- =====================================================

insert into platform.schema_migrations (migration_name,version,rollback_available)
values ('018_inventory_engine','REV1',false)
on conflict (migration_name) do nothing;


-- =====================================================
-- END 018 EDGE RPC FOUNDATION
-- =====================================================