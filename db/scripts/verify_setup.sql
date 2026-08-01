-- verify_setup.sql
-- Run after db/schema.sql to confirm schema/index/policy readiness.

\echo '=== Tables in public schema ==='
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;

\echo '=== Hypertables ==='
SELECT hypertable_name
FROM timescaledb_information.hypertables
ORDER BY hypertable_name;

\echo '=== Indexes on telemetry_raw ==='
SELECT indexname
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename = 'telemetry_raw'
ORDER BY indexname;

\echo '=== Compression/Retention Jobs ==='
SELECT
  j.job_id,
  j.proc_name,
  j.schedule_interval
FROM timescaledb_information.jobs j
WHERE j.proc_name LIKE '%policy%'
ORDER BY j.job_id;

\echo '=== Ingestion Views ==='
SELECT schemaname, viewname
FROM pg_views
WHERE schemaname = 'public'
  AND viewname = 'sessions_ingest_view'
ORDER BY viewname;

\echo '=== Sanity counts ==='
SELECT COUNT(*) AS session_rows FROM sessions;
SELECT COUNT(*) AS lap_rows FROM laps;
SELECT COUNT(*) AS raw_rows FROM telemetry_raw;
