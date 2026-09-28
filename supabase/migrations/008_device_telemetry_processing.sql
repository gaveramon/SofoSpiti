-- =====================================================
-- REV1 GREENFIELD BASELINE
-- 008_DEVICE_TELEMETRY_PROCESSING.SQL
-- =====================================================
--
-- =====================================================
-- TODO


-- =====================================================
-- 1. SCHEMA MIGRATION REGISTRATION
-- =====================================================

insert into platform.schema_migrations ( migration_name, version, rollback_available)
values ( '008_device_telemetry_processing', 'REV1',false)
on conflict (version) do nothing;


commit;

-- =====================================================
-- END 008 DEVICE TELEMETRY PROCESSING
-- =====================================================
