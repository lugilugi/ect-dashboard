-- bootstrap_roles.sql
-- Run as a superuser or role with CREATEROLE privileges.
-- Replace passwords before production use.
-- Applies to the public schema (db/schema.sql does not create a dedicated schema).

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'telemetry_owner') THEN
    CREATE ROLE telemetry_owner LOGIN PASSWORD 'CHANGE_ME_OWNER';
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'telegraf_ingest') THEN
    CREATE ROLE telegraf_ingest LOGIN PASSWORD 'CHANGE_ME_TELEGRAF';
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_reader') THEN
    CREATE ROLE grafana_reader LOGIN PASSWORD 'CHANGE_ME_GRAFANA';
  END IF;
END
$$;

GRANT CONNECT ON DATABASE telemetry TO telemetry_owner;
GRANT CONNECT ON DATABASE telemetry TO telegraf_ingest;
GRANT CONNECT ON DATABASE telemetry TO grafana_reader;

GRANT USAGE ON SCHEMA public TO telegraf_ingest;
GRANT USAGE ON SCHEMA public TO grafana_reader;

GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO telegraf_ingest;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_reader;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO telegraf_ingest;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE ON TABLES TO telegraf_ingest;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO grafana_reader;
