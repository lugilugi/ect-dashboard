-- Fresh initialization only. Password values arrive as safely quoted psql variables.
CREATE ROLE telegraf_ingest LOGIN PASSWORD :'ingest_password';
CREATE ROLE grafana_reader LOGIN PASSWORD :'reader_password';
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
