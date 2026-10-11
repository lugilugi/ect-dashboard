-- Fresh initialization only. Password values arrive as safely quoted psql variables.
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='telegraf_ingest') THEN
    CREATE ROLE telegraf_ingest;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='grafana_reader') THEN
    CREATE ROLE grafana_reader;
  END IF;
END $$;
ALTER ROLE telegraf_ingest LOGIN PASSWORD :'ingest_password';
ALTER ROLE grafana_reader LOGIN PASSWORD :'reader_password';
UPDATE schema_metadata SET schema_sha256=:'schema_hash' WHERE version=3;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO telegraf_ingest, grafana_reader;
GRANT USAGE ON SCHEMA public TO telegraf_ingest, grafana_reader;
GRANT SELECT, INSERT ON telemetry_ingest, sessions_ingest TO telegraf_ingest;
GRANT SELECT ON schema_metadata TO telegraf_ingest;
GRANT SELECT ON schema_metadata, sessions, telemetry_samples, telemetry_observations,
  session_catalog, latest_session, latest_signals, lap_bounds, accumulator_deltas,
  session_totals, lap_totals, gps_fixes, observation_intervals, telemetry_seconds,
  lap_analytics, ingest_rejections, ingest_status TO grafana_reader;
ALTER ROLE grafana_reader SET statement_timeout = '30s';
-- Staged rows are validated by the owner's ingest_staged job, never by the
-- ingest role; it cannot run the ingest functions or write owned tables.
REVOKE EXECUTE ON FUNCTION ingest_metric_range(bigint, bigint),
  ingest_session_range(bigint, bigint), ingest_staged_batch(text, integer) FROM PUBLIC;
REVOKE EXECUTE ON PROCEDURE ingest_staged(integer, jsonb) FROM PUBLIC;
