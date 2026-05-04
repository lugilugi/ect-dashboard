# telemetry_dashboard

In-cabin telemetry dashboard for ECT Shell Eco-marathon workflows.

## App Stack

- Flutter app for in-cabin telemetry and driver/service views.
- USB ingest from ESP32/CAN bridge.
- MQTT export to `telemetry/eco_archers/events`.
- Local spool and crash-recovery checkpointing.
- Readable local CSV mirror for decoded telemetry by session.

## Local Storage

- Spool DB: `edge_spool.db` managed by `LocalSpoolService`.
- Readable mirror: per-session CSV files in `readable_local_copy/session_csv` under the app database directory.
- CSV naming:
	- `session_<normalized_session_id>.csv`
- Retention: readable mirror retention days are configurable in Service mode (default 7 days) and pruned at MQTT service startup.
- Service tools: Config page includes readable mirror preview and export actions.

## Planning and Contracts

- [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)
- [REBUILD_PLAN.md](REBUILD_PLAN.md)
- [UI.md](UI.md)
- [DB_REFERENCE.md](DB_REFERENCE.md)
- [PHASE7_HARDWARE_RUNBOOK.md](PHASE7_HARDWARE_RUNBOOK.md)

## Backend/Ops Artifacts

### Database Migrations

- [db/migrations/001_telemetry_schema.sql](db/migrations/001_telemetry_schema.sql)
- [db/migrations/002_indexes_policies.sql](db/migrations/002_indexes_policies.sql)
- [db/migrations/003_command_and_recovery_audit.sql](db/migrations/003_command_and_recovery_audit.sql)
- [db/migrations/004_query_performance_views.sql](db/migrations/004_query_performance_views.sql)

### DB Setup Runbook and Scripts

- [db/README.md](db/README.md)
- [db/scripts/apply_migrations.ps1](db/scripts/apply_migrations.ps1)
- [db/scripts/apply_migrations.sh](db/scripts/apply_migrations.sh)
- [db/scripts/bootstrap_roles.sql](db/scripts/bootstrap_roles.sql)
- [db/scripts/verify_setup.sql](db/scripts/verify_setup.sql)

### Telegraf and Mosquitto

- [ops/telegraf/telegraf.conf](ops/telegraf/telegraf.conf)
- [ops/mosquitto/mosquitto.conf.sample](ops/mosquitto/mosquitto.conf.sample)
- [ops/mosquitto/README.md](ops/mosquitto/README.md)

### One-Command Local Backend Stack

- [ops/local-stack/docker-compose.yml](ops/local-stack/docker-compose.yml)
- [ops/local-stack/README.md](ops/local-stack/README.md)
- [ops/local-stack/telegraf/Dockerfile](ops/local-stack/telegraf/Dockerfile)

### Grafana Dashboards

- [ops/grafana/dashboards/session_overview.json](ops/grafana/dashboards/session_overview.json)
- [ops/grafana/dashboards/lap_analysis.json](ops/grafana/dashboards/lap_analysis.json)
- [ops/grafana/README.md](ops/grafana/README.md)

## Backend Bootstrap

### 1. Apply DB Migrations (In Order)

Use your Timescale/PostgreSQL connection string in `TS_DSN` and run:

```bash
psql "$TS_DSN" -f db/migrations/001_telemetry_schema.sql
psql "$TS_DSN" -f db/migrations/002_indexes_policies.sql
psql "$TS_DSN" -f db/migrations/003_command_and_recovery_audit.sql
psql "$TS_DSN" -f db/migrations/004_query_performance_views.sql
```

PowerShell helper (Windows):

```powershell
./db/scripts/apply_migrations.ps1 -Dsn "$env:TS_DSN"
```

### 2. Verify Schema and Hypertables

```sql
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'telemetry'
ORDER BY table_name;

SELECT hypertable_name
FROM timescaledb_information.hypertables
WHERE hypertable_schema = 'telemetry'
ORDER BY hypertable_name;

SELECT indexname
FROM pg_indexes
WHERE schemaname = 'telemetry'
	AND tablename = 'telemetry_events'
ORDER BY indexname;
```

### 3. Verify Readiness for Session/Lap Queries

```sql
SELECT COUNT(*) AS session_rows FROM telemetry.sessions;
SELECT COUNT(*) AS event_rows FROM telemetry.telemetry_events;
SELECT COUNT(*) AS lap_rows FROM telemetry.laps;
```

Or run the bundled verification script:

```bash
psql "$TS_DSN" -f db/scripts/verify_setup.sql
```

### 4. Provision Grafana Dashboards

Follow [ops/grafana/README.md](ops/grafana/README.md) to mount provisioning and dashboards into Grafana.

For full DB bootstrap details, role setup, and smoke tests, see [db/README.md](db/README.md).

## Flutter Development

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```
