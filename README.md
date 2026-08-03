# telemetry_dashboard

In-cabin telemetry dashboard for ECT Shell Eco-marathon workflows.

![CI](https://github.com/lugilugi/ect-dashboard/actions/workflows/ci.yml/badge.svg)
![Android Release](https://github.com/lugilugi/ect-dashboard/actions/workflows/android_release.yml/badge.svg)

## App Stack

- Flutter app for in-cabin telemetry and driver/service views.
- USB ingest from ESP32/CAN bridge.
- MQTT export to `telemetry/eco_archers/events`.
- Local spool and crash-recovery checkpointing.
- Readable local CSV mirror for decoded telemetry by session.
- Server-side continuous MQTT → CSV logging with 1-second fsync.

## Local Storage

- Spool DB: `edge_spool.db` managed by `LocalSpoolService`.
- Readable mirror: per-session CSV files in `session_csv` under the app database directory.
- CSV naming:
	- `session_<normalized_session_id>.csv`
- Retention: readable mirror retention days are configurable in Service mode (default 7 days) and pruned at MQTT service startup.
- Durability: mirror writes are buffered and flushed every second, so a sudden
  power loss costs at most ~1s of rows instead of losing buffered data.
- MQTT spool: up to 50,000 pending batches are kept on disk and replayed when
  the broker returns; if that cap is hit, the oldest batches are dropped and
  the driver display shows `SPOOL … DROP-OLDEST`.
- Service tools: Config page includes readable mirror preview and export actions.

## Planning and Contracts

- [BACKEND_GUIDE.md](BACKEND_GUIDE.md)

## Releases & Updates

Tag pushes (e.g. `git tag v1.0.0 && git push origin v1.0.0`) trigger the
[Android Release Build](.github/workflows/android_release.yml) workflow: it
runs analyze + tests, signs the APK with the release keystore, and attaches
it to a GitHub Release. Because every build uses the same signing key, new
versions install **over** the previous one — no uninstall needed. The
`versionCode` increments automatically on every build, which is what Android
uses to allow an update.

## Backend/Ops Artifacts

### Database Schema

- [db/schema.sql](db/schema.sql)

### DB Setup Runbook and Scripts

- [db/scripts/apply_migrations.ps1](db/scripts/apply_migrations.ps1)
- [db/scripts/apply_migrations.sh](db/scripts/apply_migrations.sh)
- [db/scripts/bootstrap_roles.sql](db/scripts/bootstrap_roles.sql)
- [db/scripts/verify_setup.sql](db/scripts/verify_setup.sql)

### Telegraf and Mosquitto

- [ops/mosquitto/mosquitto.conf.sample](ops/mosquitto/mosquitto.conf.sample)
- [ops/mosquitto/README.md](ops/mosquitto/README.md)

### Single-Container Backend (one Dockerfile, no Compose needed)

- [ops/backend/Dockerfile](ops/backend/Dockerfile) — TimescaleDB + Mosquitto + Telegraf + Grafana in one image; runs under tini (PID 1), pins Telegraf 1.31.x / Grafana 13.1.1, healthchecks DB + broker + CSV services
- [ops/backend/supervisord.conf](ops/backend/supervisord.conf)
- [ops/backend/mosquitto.conf](ops/backend/mosquitto.conf)
- [ops/backend/telegraf.conf](ops/backend/telegraf.conf)
- [ops/backend/csv_streamer.py](ops/backend/csv_streamer.py) — continuous MQTT → CSV logger (1s fsync, no retention)

### One-Command Multi-Container Local Stack (Compose)

- [ops/local-stack/docker-compose.yml](ops/local-stack/docker-compose.yml)
- [ops/local-stack/.env.example](ops/local-stack/.env.example)
- [ops/local-stack/telegraf/Dockerfile](ops/local-stack/telegraf/Dockerfile)
- [ops/backend/Dockerfile.csv-streamer](ops/backend/Dockerfile.csv-streamer) — minimal compose image for the CSV streamer

### CAN Signal Registry (app side)

- [lib/models/telemetry/can_signal_registry.dart](lib/models/telemetry/can_signal_registry.dart) — single source of truth for every CAN signal published over MQTT

### Grafana Dashboards

- [ops/grafana/dashboards/session_overview.json](ops/grafana/dashboards/session_overview.json)
- [ops/grafana/dashboards/lap_analysis.json](ops/grafana/dashboards/lap_analysis.json)
- [ops/grafana/provisioning/datasources/timescaledb.yml](ops/grafana/provisioning/datasources/timescaledb.yml)

## Backend Bootstrap

The easiest path is the single-container backend (one Dockerfile) or the
Compose stack — both are fully documented in [BACKEND_GUIDE.md](BACKEND_GUIDE.md):

```bash
# Option A: one container, everything inside
docker build -t ect-backend -f ops/backend/Dockerfile .
docker run -d --name ect-backend --restart unless-stopped \
  -p 1883:1883 -p 5432:5432 -p 3000:3000 -p 8080:8080 ect-backend

# Option B: separate containers per service
cd ops/local-stack && docker compose up --build -d
```

Manual schema bootstrap (only if you run your own Timescale/PostgreSQL):

### 1. Apply DB Schema

Use your Timescale/PostgreSQL connection string in `TS_DSN` and run:

```bash
psql "$TS_DSN" -f db/schema.sql
```

PowerShell helper (Windows):

```powershell
./db/scripts/apply_migrations.ps1 -Dsn "$env:TS_DSN"
```

### 2. Verify Schema and Hypertables

```sql
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;

SELECT hypertable_name
FROM timescaledb_information.hypertables
ORDER BY hypertable_name;

SELECT indexname
FROM pg_indexes
WHERE schemaname = 'public'
	AND tablename = 'telemetry_raw'
ORDER BY indexname;
```

### 3. Verify Readiness for Session/Lap Queries

```sql
SELECT COUNT(*) AS session_rows FROM sessions;
SELECT COUNT(*) AS raw_rows FROM telemetry_raw;
SELECT COUNT(*) AS lap_rows FROM laps;
```

Or run the bundled verification script:

```bash
psql "$TS_DSN" -f db/scripts/verify_setup.sql
```

### 4. Provision Grafana Dashboards

Mount the provisioning and dashboard files into Grafana (see [ops/grafana/provisioning](ops/grafana/provisioning)). The compose stack at [ops/local-stack/docker-compose.yml](ops/local-stack/docker-compose.yml) wires this up automatically.

For full DB bootstrap details, role setup, and smoke tests, see [BACKEND_GUIDE.md](BACKEND_GUIDE.md).

## Flutter Development

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```
