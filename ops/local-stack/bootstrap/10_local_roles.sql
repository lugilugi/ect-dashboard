-- 10_local_roles.sql
-- Local development credentials and grants for Telegraf and Grafana.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'telegraf') THEN
    CREATE ROLE telegraf LOGIN PASSWORD 'telegraf_dev';
  ELSE
    ALTER ROLE telegraf WITH PASSWORD 'telegraf_dev';
  END IF;
END
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana') THEN
    CREATE ROLE grafana LOGIN PASSWORD 'grafana_dev';
  ELSE
    ALTER ROLE grafana WITH PASSWORD 'grafana_dev';
  END IF;
END
$$;

DO $$
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO telegraf', current_database());
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO grafana', current_database());
END
$$;

GRANT USAGE ON SCHEMA telemetry TO telegraf;
GRANT USAGE ON SCHEMA telemetry TO grafana;

GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA telemetry TO telegraf;
GRANT SELECT ON ALL TABLES IN SCHEMA telemetry TO grafana;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA telemetry TO telegraf;

ALTER DEFAULT PRIVILEGES IN SCHEMA telemetry
  GRANT SELECT, INSERT, UPDATE ON TABLES TO telegraf;

ALTER DEFAULT PRIVILEGES IN SCHEMA telemetry
  GRANT SELECT ON TABLES TO grafana;
