# telemetry_dashboard

In-cabin telemetry dashboard for ECT Shell Eco-marathon workflows.

## App Stack

- Flutter app for in-cabin telemetry and driver/service views.
- USB ingest from ESP32/CAN bridge.
- MQTT export to `telemetry/eco_archers/events`.
- Local spool and crash-recovery checkpointing.
- Readable local NDJSON mirror for spool activity and telemetry traces.

## Local Storage

- Spool DB: `edge_spool.db` managed by `LocalSpoolService`.
- Readable mirror: NDJSON files in `readable_local_copy` under the app database directory.
- Streams mirrored as human-readable lines:
	- `publish_batches_YYYYMMDD.ndjson`
	- `publish_attempts_YYYYMMDD.ndjson`
	- `decoded_events_YYYYMMDD.ndjson`
	- `raw_frames_YYYYMMDD.ndjson`
	- `session_checkpoints_YYYYMMDD.ndjson`
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

### Telegraf and Mosquitto

- [ops/telegraf/telegraf.conf](ops/telegraf/telegraf.conf)
- [ops/mosquitto/mosquitto.conf.sample](ops/mosquitto/mosquitto.conf.sample)
- [ops/mosquitto/README.md](ops/mosquitto/README.md)

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

### 4. Provision Grafana Dashboards

Follow [ops/grafana/README.md](ops/grafana/README.md) to mount provisioning and dashboards into Grafana.

## Flutter Development

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```
