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

\echo '=== Background jobs (compression policy, 1 s staged ingest) ==='
SELECT
  j.job_id,
  j.proc_name,
  j.schedule_interval,
  s.last_run_status,
  s.total_failures
FROM timescaledb_information.jobs j
LEFT JOIN timescaledb_information.job_stats s USING (job_id)
WHERE j.proc_name LIKE '%policy%' OR j.proc_name = 'ingest_staged'
ORDER BY j.job_id;

\echo '=== Ingest staging backlog ==='
SELECT * FROM ingest_status ORDER BY kind;

\echo '=== Sanity counts ==='
SELECT COUNT(*) AS session_rows FROM sessions;
SELECT COUNT(*) AS completed_laps FROM lap_bounds;
SELECT version,contract,schema_sha256 FROM schema_metadata;
SELECT COUNT(*) AS raw_rows FROM telemetry_raw;
