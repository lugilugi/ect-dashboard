-- verify_setup.sql
-- Run after migrations to confirm schema/index/policy readiness.

\echo '=== Tables in telemetry schema ==='
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'telemetry'
ORDER BY table_name;

\echo '=== Hypertables ==='
SELECT hypertable_name
FROM timescaledb_information.hypertables
WHERE hypertable_schema = 'telemetry'
ORDER BY hypertable_name;

\echo '=== Indexes on telemetry_events ==='
SELECT indexname
FROM pg_indexes
WHERE schemaname = 'telemetry'
  AND tablename = 'telemetry_events'
ORDER BY indexname;

\echo '=== Compression/Retention Jobs ==='
SELECT
  j.job_id,
  j.proc_name,
  j.schedule_interval,
  c.hypertable_schema,
  c.hypertable_name
FROM timescaledb_information.jobs j
LEFT JOIN LATERAL (
  SELECT
    (j.config ->> 'hypertable_schema')::text AS hypertable_schema,
    (j.config ->> 'hypertable_name')::text AS hypertable_name
) c ON TRUE
WHERE j.proc_name LIKE '%policy%'
ORDER BY j.job_id;

\echo '=== Summary Views ==='
SELECT schemaname, viewname
FROM pg_views
WHERE schemaname = 'telemetry'
  AND viewname IN ('session_summary_v1', 'lap_summary_v1', 'latest_metric_values_v1')
ORDER BY viewname;

\echo '=== Sanity counts ==='
SELECT COUNT(*) AS session_rows FROM telemetry.sessions;
SELECT COUNT(*) AS lap_rows FROM telemetry.laps;
SELECT COUNT(*) AS event_rows FROM telemetry.telemetry_events;
SELECT COUNT(*) AS lap_event_rows FROM telemetry.lap_events;
