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
UPDATE schema_metadata SET schema_sha256=:'schema_hash' WHERE version=2;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO telegraf_ingest, grafana_reader;
GRANT USAGE ON SCHEMA public TO telegraf_ingest, grafana_reader;
GRANT SELECT, INSERT ON telemetry_ingest_view, sessions_ingest_view TO telegraf_ingest;
GRANT SELECT ON schema_metadata TO telegraf_ingest;
GRANT SELECT ON schema_metadata, sessions, telemetry_samples, session_catalog,
  latest_signals, lap_bounds, accumulator_deltas, session_totals, lap_totals,
  gps_fixes, telemetry_seconds, lap_analytics, ingest_rejections TO grafana_reader;
ALTER ROLE grafana_reader SET statement_timeout = '30s';
ALTER FUNCTION ingest_metric() SECURITY DEFINER;
ALTER FUNCTION ingest_metric() SET search_path = pg_catalog, public, pg_temp;
ALTER FUNCTION ingest_session() SECURITY DEFINER;
ALTER FUNCTION ingest_session() SET search_path = pg_catalog, public, pg_temp;
