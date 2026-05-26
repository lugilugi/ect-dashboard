# Telemetry Database Setup Runbook

This runbook provides a complete path to stand up the backend database side for telemetry ingest and analytics.

> [!NOTE]
> For local development, the database setup is fully automated. You do not need to run migrations or configure roles manually. Simply spin up the docker-compose stack:
> ```bash
> docker compose -f ops/local-stack/docker-compose.yml up --build -d
> ```
> The custom TimescaleDB Dockerfile automatically initializes the schema, applies migrations in order, sets up local credentials (Telegraf/Grafana), and runs verification scripts.
> 
> The manual steps outlined below are optional and intended only for custom/remote database environments.

It covers:

1. TimescaleDB schema setup.
2. Optional least-privilege role bootstrap.
3. Migration apply order.
4. Verification checks.
5. Ingest smoke testing.

## 1. Prerequisites

Required:

1. PostgreSQL with TimescaleDB extension available.
2. A database named `telemetry`.
3. `psql` client installed and on PATH.

Recommended:

1. Dedicated roles for owner, ingest, and reader access.
2. Telegraf writing to TimescaleDB using ingest role credentials.

## 2. Create Database (if needed)

Run as a superuser:

```sql
CREATE DATABASE telemetry;
```

## 3. Optional Role Bootstrap

If roles do not exist yet:

```bash
psql "$TS_DSN" -v ON_ERROR_STOP=1 -f db/scripts/bootstrap_roles.sql
```

Notes:

1. Edit placeholder passwords in `db/scripts/bootstrap_roles.sql` before production use.
2. This step requires CREATEROLE privileges.

## 4. Apply Migrations

### PowerShell (Windows)

```powershell
./db/scripts/apply_migrations.ps1 -Dsn "$env:TS_DSN"
```

### POSIX shell (Linux/macOS)

```bash
./db/scripts/apply_migrations.sh "$TS_DSN"
```

### Manual (any shell)

```bash
psql "$TS_DSN" -v ON_ERROR_STOP=1 -f db/migrations/001_telemetry_schema.sql
psql "$TS_DSN" -v ON_ERROR_STOP=1 -f db/migrations/002_indexes_policies.sql
psql "$TS_DSN" -v ON_ERROR_STOP=1 -f db/migrations/003_command_and_recovery_audit.sql
psql "$TS_DSN" -v ON_ERROR_STOP=1 -f db/migrations/004_query_performance_views.sql
```

## 5. Verify Setup

Run:

```bash
psql "$TS_DSN" -v ON_ERROR_STOP=1 -f db/scripts/verify_setup.sql
```

Expected outcomes:

1. Telemetry tables exist in schema `telemetry`.
2. Hypertables are registered for time-series tables.
3. Policy jobs exist for compression and retention.
4. Summary views are present:
   1. `telemetry.session_summary_v1`
   2. `telemetry.lap_summary_v1`
   3. `telemetry.latest_metric_values_v1`

## 6. Ingest Smoke Test

Run this SQL to validate basic write/read behavior:

```sql
INSERT INTO telemetry.sessions (
  session_id,
  session_name,
  session_state,
  ui_mode,
  started_at_utc
) VALUES (
  '11111111-1111-1111-1111-111111111111',
  'smoke_test_session',
  'LOGGING',
  'DRIVER',
  now()
) ON CONFLICT (session_id) DO NOTHING;

INSERT INTO telemetry.telemetry_events (
  ts_wall_utc,
  session_id,
  lap_number,
  ts_session_ms,
  session_state,
  lap_phase,
  metric_key,
  metric_value,
  unit,
  source,
  seq_in_session
) VALUES (
  now(),
  '11111111-1111-1111-1111-111111111111',
  1,
  1000,
  'LOGGING',
  'RUNNING',
  'Speed_Kmh',
  32.5,
  'km/h',
  'smoke_test',
  1
) ON CONFLICT DO NOTHING;

SELECT *
FROM telemetry.latest_metric_values_v1
WHERE session_id = '11111111-1111-1111-1111-111111111111'
  AND metric_key = 'Speed_Kmh';
```

## 7. Telegraf Integration Notes

Use the provided baseline config:

1. `ops/telegraf/telegraf.conf`

Before startup:

1. Replace output connection credentials.
2. Ensure Telegraf can read MQTT topic `telemetry/eco_archers/events`.
3. Confirm DB role has `INSERT` and `UPDATE` on `telemetry` schema tables.

## 8. Operational Improvements Included

The setup now includes:

1. Additional query indexes for common session/metric lookups.
2. Session/lap/latest metric summary views for dashboards and ops debugging.
3. A reproducible migration runner and verification script.

## 9. Common Troubleshooting

1. `extension "timescaledb" does not exist`:
   1. Install TimescaleDB package for your PostgreSQL version.
2. Policy function missing in migration output:
   1. Confirm Timescale extension is loaded in the target database.
3. Telegraf writes failing with permission errors:
   1. Re-run grants in `db/scripts/bootstrap_roles.sql`.
4. Dashboard queries empty:
   1. Confirm `session_id` values are present in `telemetry.sessions`.
